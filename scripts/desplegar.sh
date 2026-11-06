#!/usr/bin/env bash
# =============================================================================
# desplegar.sh - Proyecto APT Cobranza Automatizada (06-11-2026, ADR-001)
# Guia ejecutable del despliegue completo. Pide confirmacion en CADA paso
# (si / omitir / salir). Es interactivo: requiere una terminal.
#
# ACCIONES EN AZURE: crean y modifican recursos. Requieren aprobacion explicita de un
# integrante humano (CLAUDE.md regla 5). Siempre modo Incremental; nunca --mode Complete
# ni az group delete.
#
#   1. Variables, herramientas y verificacion de la suscripcion (SUBSCRIPTION_ID_ESPERADA).
#   2. az group create del grupo (solo si no existe).
#   3. Validacion: bicep build, lint, build-params (a carpeta temporal) y what-if.
#   4. az deployment group create (abre la ventana del operador: IP_OPERADOR).
#   5. scripts/desplegar_sql.sh (orden ADR-001 5.10; --demo si se pasa --demo).
#   6. Publicacion: dotnet publish + az functionapp deploy / az webapp deploy, con la
#      ventana SCM abierta por s12_endurecer.sh (IP_PUBLICACION_SCM) y cerrada al terminar.
#      La API se publica SOLO con APROBACION_QA (ADR-001 5.11): ruta del informe de qa
#      APROBADO o APROBADO CON OBSERVACIONES. Sin ella solo se publica la Function App.
#   7. scripts/s10_configurar_jobs.sh (sin publicar) y scripts/s11_configurar_api.sh.
#   8. scripts/s12_endurecer.sh (regla 7: despues de cada despliegue de main).
#   9. Verificacion de https://<api>/salud desde la IP del operador (regla operador-transicion).
#  10. Cierre de la ventana: despliegue con IP_OPERADOR vacio + s12_endurecer.sh
#      (docs/seguridad/plantilla_ventana_operador.md). Obligatorio en la misma sesion.
#
# Uso (Git Bash, desde la raiz del repositorio):
#   set -a; source infra/entorno.local.env; set +a      # SQL_ADMIN_GROUP_OBJECT_ID, OPERADOR_OBJECT_ID,
#                                                        # IP_OPERADOR, CICLO_KV, SUBSCRIPTION_ID_ESPERADA
#   [APROBACION_QA=evidencias/qa/<informe>.md] scripts/desplegar.sh [--demo]
#
# Variables opcionales: RG (rg-cobranza-apt), UBICACION (brazilsouth), DEPLOY_NAME (cobranza-main).
# Evidencias: evidencias/<fecha>_despliegue/ (sin IP ni GUID completos).
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

DEMO=no
for arg in "$@"; do
  case "$arg" in
    --demo) DEMO=si ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $arg" ;;
  esac
done

exigir_terminal
RG="${RG:-rg-cobranza-apt}"
UBICACION="${UBICACION:-brazilsouth}"
APROBACION_QA="${APROBACION_QA:-}"
cd "$RAIZ_REPO"
FECHA="$(date -u +%Y-%m-%d)"
DIR_EVID="evidencias/${FECHA}_despliegue"
mkdir -p "$DIR_EVID"
TMP_TRABAJO="$(mktemp -d)"
trap 'rm -rf "$TMP_TRABAJO"' EXIT

# Ocultar GUID e IP en lo que se guarda como evidencia.
sanear () {
  sed -E -e 's/([0-9a-fA-F]{4})[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{8}([0-9a-fA-F]{4})/\1...\2/g' \
         -e 's/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/<IP>/g'
}

# -----------------------------------------------------------------------------
echo "== Paso 1. Variables, herramientas y suscripcion"
for t in az dotnet sqlcmd python curl; do
  command -v "$t" >/dev/null 2>&1 || error "Falta la herramienta ${t} (sqlcmd: winget install sqlcmd)."
done
{
  echo "# Versiones $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  az version --query '"azure-cli"' -o tsv
  az bicep version
  dotnet --version
  sqlcmd --version 2>&1 | head -1
} 2>&1 | tee "${DIR_EVID}/01_versiones.txt"
az bicep version | grep -q '0\.48\.1' || echo "AVISO: la version de referencia de Bicep es 0.48.1."

for v in SQL_ADMIN_GROUP_OBJECT_ID OPERADOR_OBJECT_ID; do
  [[ "${!v:-}" =~ $PATRON_GUID ]] || error "${v} vacia o no es un GUID (cargar infra/entorno.local.env)."
done
if grep -n "PENDIENTE" infra/main.bicepparam; then
  error "infra/main.bicepparam tiene valores PENDIENTE (lineas arriba). No se despliega."
fi
[[ -n "${IP_OPERADOR:-}" ]] || echo "AVISO: IP_OPERADOR vacia: el paso 5 (SQL) y el paso 9 no podran ejecutarse desde este equipo."
SUB_ID="$(az account show --query id -o tsv | tr -d '\r')"
SUB_NOMBRE="$(az account show --query name -o tsv | tr -d '\r')"
echo "Suscripcion activa: ${SUB_NOMBRE} ($(truncar "$SUB_ID"))"
ESPERADA="${SUBSCRIPTION_ID_ESPERADA:-}"; ESPERADA="${ESPERADA//$'\r'/}"
[[ -n "$ESPERADA" ]] || error "Defina SUBSCRIPTION_ID_ESPERADA (infra/entorno.local.env)."
[[ "${SUB_ID,,}" == "${ESPERADA,,}" ]] || error "La suscripcion activa no coincide con SUBSCRIPTION_ID_ESPERADA. Use az account set."
echo "Grupo ${RG} (${UBICACION}); despliegue ${DEPLOY_NAME}; demo=${DEMO}; APROBACION_QA=${APROBACION_QA:-(no: la API no se publica)}"
confirmar "Datos correctos."

# -----------------------------------------------------------------------------
echo "== Paso 2. Grupo de recursos"
if [[ "$(az group exists -n "$RG" | tr -d '\r')" == "true" ]]; then
  echo "   ${RG} ya existe ($(az group show -n "$RG" --query location -o tsv | tr -d '\r'))."
elif preguntar_paso "Crear el grupo ${RG} en ${UBICACION}?"; then
  az group create -n "$RG" -l "$UBICACION" --tags proyecto=APT-Cobranza-Automatizada --output none
fi

# -----------------------------------------------------------------------------
echo "== Paso 3. Validacion (build, lint, build-params, what-if)"
if preguntar_paso "Ejecutar la validacion?"; then
  az bicep build --file infra/main.bicep --outfile "$(ruta_nativa "$TMP_TRABAJO/main.json")" 2>&1 | tee "${DIR_EVID}/03a_bicep_build.txt"
  az bicep lint --file infra/main.bicep 2>&1 | tee "${DIR_EVID}/03b_bicep_lint.txt"
  az bicep build-params --file infra/main.bicepparam --outfile "$(ruta_nativa "$TMP_TRABAJO/main.parameters.json")" 2>&1 \
    | tee "${DIR_EVID}/03c_build_params.txt"
  rm -f "$TMP_TRABAJO/main.parameters.json"
  whatif_main "${IP_OPERADOR:-}" 2>&1 | sanear | tee "${DIR_EVID}/03d_whatif.txt"
  echo "   Revise el what-if: no debe haber Delete inesperados."
fi

# -----------------------------------------------------------------------------
echo "== Paso 4. Despliegue de infra/main.bicep (Incremental; abre la ventana con IP_OPERADOR)"
if preguntar_paso "Desplegar infra/main.bicep en ${RG}?"; then
  desplegar_main "${IP_OPERADOR:-}"
  az deployment group show -g "$RG" -n "$DEPLOY_NAME" --query "{estado:properties.provisioningState, fin:properties.timestamp}" -o tsv \
    | tee "${DIR_EVID}/04_create.txt"
fi
exportar_nombres_recursos
API_HOST="$(salida apiHostName)"

# -----------------------------------------------------------------------------
echo "== Paso 5. Scripts SQL (scripts/desplegar_sql.sh)"
if preguntar_paso "Ejecutar desplegar_sql.sh (demo=${DEMO})?"; then
  if [[ "$DEMO" == "si" ]]; then "${RAIZ_REPO}/scripts/desplegar_sql.sh" --demo; else "${RAIZ_REPO}/scripts/desplegar_sql.sh"; fi
fi

# -----------------------------------------------------------------------------
echo "== Paso 6. Publicacion de la Function App y (si procede) de la API"
zipear () {   # zipear <carpeta> <zip>: rutas relativas con '/', como espera App Service Linux
  python -I -c 'import os,sys,zipfile
src,dst=sys.argv[1],sys.argv[2]
with zipfile.ZipFile(dst,"w",zipfile.ZIP_DEFLATED) as z:
    for r,_,fs in os.walk(src):
        for f in fs:
            p=os.path.join(r,f); z.write(p, os.path.relpath(p,src).replace(os.sep,"/"))' "$(ruta_nativa "$1")" "$(ruta_nativa "$2")"
}
if preguntar_paso "Compilar y publicar?"; then
  [[ -n "${IP_OPERADOR:-}" ]] || error "La publicacion usa el SCM y requiere IP_OPERADOR para abrir la regla operador-publicacion."
  PUBLICAR_API=no
  ESTADO="vigente"
  if [[ -n "$APROBACION_QA" ]]; then
    echo "   APROBACION_QA=${APROBACION_QA}: s12_endurecer.sh valida el veredicto antes de abrir el SCM de la Web App."
    confirmar "Confirma que ADR-001 esta implementado, compilado, con pruebas en verde y aprobado por qa (5.11 regla 1)."
    PUBLICAR_API=si; ESTADO="publicacion-aprobada"
  else
    echo "   Sin APROBACION_QA: rige la transicion (ADR-001 5.11). La API NO se publica; solo la Function App."
  fi

  dotnet publish src/Cobranza.Functions -c Release -o "$(ruta_nativa "$TMP_TRABAJO/func")" 2>&1 | tail -3
  zipear "$TMP_TRABAJO/func" "$TMP_TRABAJO/functions.zip"
  if [[ "$PUBLICAR_API" == "si" ]]; then
    dotnet publish src/Cobranza.Api -c Release -o "$(ruta_nativa "$TMP_TRABAJO/api")" 2>&1 | tail -3
    zipear "$TMP_TRABAJO/api" "$TMP_TRABAJO/api.zip"
  fi

  echo "   Abriendo la ventana SCM (operador-publicacion) con s12_endurecer.sh"
  IP_PUBLICACION_SCM="$IP_OPERADOR" ESTADO_TRANSICION="$ESTADO" APROBACION_QA="$APROBACION_QA" \
    "${RAIZ_REPO}/scripts/s12_endurecer.sh"
  set +e
  az functionapp deploy -g "$RG" -n "$FUNC_APP" --src-path "$(ruta_nativa "$TMP_TRABAJO/functions.zip")" --type zip --output none
  R_FUNC=$?
  R_API=0
  if [[ "$PUBLICAR_API" == "si" ]]; then
    az webapp deploy -g "$RG" -n "$WEB_APP" --src-path "$(ruta_nativa "$TMP_TRABAJO/api.zip")" --type zip --output none
    R_API=$?
  fi
  set -e
  echo "   Cerrando la ventana SCM (s12_endurecer.sh sin IP_PUBLICACION_SCM)"
  env -u IP_PUBLICACION_SCM ESTADO_TRANSICION="$ESTADO" APROBACION_QA="$APROBACION_QA" "${RAIZ_REPO}/scripts/s12_endurecer.sh"
  echo "Function App: codigo ${R_FUNC}; API: ${PUBLICAR_API} (codigo ${R_API})" | tee "${DIR_EVID}/06_publicacion.txt"
  [[ "$R_FUNC" -eq 0 && "$R_API" -eq 0 ]] || error "La publicacion fallo (ver arriba). La ventana SCM ya se cerro."
fi

# -----------------------------------------------------------------------------
echo "== Paso 7. s10_configurar_jobs.sh (sin publicar) y s11_configurar_api.sh"
if preguntar_paso "Ejecutar s10 y s11?"; then
  ajuste () { az functionapp config appsettings list -g "$RG" -n "$FUNC_APP" --query "[?name=='$1'].value | [0]" -o tsv | tr -d '\r'; }
  # Valores tomados de lo que la plantilla ya fijo (sin duplicarlos en este archivo).
  RG="$RG" FUNC_APP="$FUNC_APP" KV_NAME="$KV_NAME" SQL_SERVER="$SQL_SERVER" SQL_DB="$(salida sqlDatabaseName)" \
  REMITENTE="$(salida remitenteCorreo)" DIAS_PREAVISO="$(ajuste Cobranza__DiasPreaviso)" \
  DIAS_MORA1="$(ajuste Cobranza__DiasMora1)" DIAS_MORA2="$(ajuste Cobranza__DiasMora2)" \
  CANALES_PAGO="$(ajuste Cobranza__CanalesPagoTexto)" TELEFONO="$(ajuste Cobranza__TelefonoContacto)" \
  CORREO_CONTACTO="$(ajuste Cobranza__CorreoContacto)" OMITIR_PUBLICACION=si \
    "${RAIZ_REPO}/scripts/s10_configurar_jobs.sh"
  "${RAIZ_REPO}/scripts/s11_configurar_api.sh"
fi

# -----------------------------------------------------------------------------
echo "== Paso 8. s12_endurecer.sh (CLAUDE.md regla 7)"
if preguntar_paso "Ejecutar s12_endurecer.sh?"; then
  env -u IP_PUBLICACION_SCM "${RAIZ_REPO}/scripts/s12_endurecer.sh"
fi

# -----------------------------------------------------------------------------
echo "== Paso 9. Verificacion de /salud (desde la IP del operador; regla operador-transicion)"
if preguntar_paso "Consultar https://${API_HOST}/salud?"; then
  CODIGO="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://${API_HOST}/salud" || echo "sin-respuesta")"
  echo "   /salud -> ${CODIGO} (esperado 200 si la API se publico; sin publicar, la API no responde /salud)" \
    | tee "${DIR_EVID}/09_salud.txt"
  echo "   Estado del sitio: $(az webapp show -g "$RG" -n "$WEB_APP" --query state -o tsv | tr -d '\r')" | tee -a "${DIR_EVID}/09_salud.txt"
fi

# -----------------------------------------------------------------------------
echo "== Paso 10. Cierre de la ventana del operador (obligatorio en la misma sesion)"
if preguntar_paso "Desplegar con IP_OPERADOR vacio y reaplicar s12_endurecer.sh?"; then
  desplegar_main ""
  env -u IP_OPERADOR -u IP_PUBLICACION_SCM "${RAIZ_REPO}/scripts/s12_endurecer.sh"
  echo "   Ventana cerrada. Verificar con scripts/s12_verificar_seguridad.sh (SEG-11, SEG-18, SEG-KV-06, SEG-27, SEG-28, SEG-TR-01/02)."
  echo "Ventana cerrada $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${DIR_EVID}/10_cierre.txt"
else
  echo "   AVISO: la ventana sigue ABIERTA (SQL, Key Vault y la regla operador-transicion de la Web App)."
fi
echo "Fin. Evidencias en ${DIR_EVID}/ (registrar la ventana con docs/seguridad/plantilla_ventana_operador.md)."
