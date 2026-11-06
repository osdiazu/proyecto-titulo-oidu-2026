#!/usr/bin/env bash
# =============================================================================
# desplegar_sql.sh - Proyecto APT Cobranza Automatizada (06-11-2026, ADR-001)
# Ejecuta los scripts de sql/ contra la base de la plantilla, en el orden de ADR-001 5.10:
#
#   01, 02, 03, 04, 05, 06, 12, 11, 00 (verificacion), 07 (pruebas: 10/10),
#   13 (pruebas de autenticacion) y 08 (datos DEMO) SOLO con --demo, al final.
#
# ACCION SOBRE LA BASE REAL: requiere confirmacion explicita de un integrante humano
# (CLAUDE.md regla 5). Ningun agente lo ejecuta sin esa aprobacion. Es interactivo.
#
# Servidor, base y usuarios: se leen de las salidas del despliegue DEPLOY_NAME
# (por defecto cobranza-main) de infra/main.bicep en el grupo RG:
#   sqlServerFqdn, sqlDatabaseName, usuarioFunctionApp, usuarioApi, accesoOperadorAbierto.
# sqlcmd: -b (se detiene en el primer error), autenticacion Entra ID ActiveDirectoryDefault
# (sesion de az login del operador, miembro de grp-cobranza-sql-admin) y
# -v UsuarioFunctionApp=<funcAppName> UsuarioApi=<apiAppName>.
#
# Acceso de red (ventana ipOperador): Azure SQL no tiene acceso publico. Para ejecutar este
# script la plantilla debe estar desplegada con IP_OPERADOR = IP publica del operador
# (abre SQL solo a esa IP con la regla operador-temporal). Opciones:
#   --abrir-ventana   despliega infra/main.bicep con IP_OPERADOR (exportada) antes de
#                     ejecutar los scripts (pide confirmacion).
#   --cerrar-ventana  al terminar: despliega con IP_OPERADOR vacio y ejecuta
#                     scripts/s12_endurecer.sh (cierra SQL, Key Vault y elimina
#                     operador-temporal; CLAUDE.md regla 7). Pide confirmacion.
# Sin esas opciones, el script verifica que la ventana este abierta y, al final, recuerda
# como cerrarla (docs/seguridad/plantilla_ventana_operador.md).
#
# Uso:
#   set -a; source infra/entorno.local.env; set +a
#   scripts/desplegar_sql.sh [--demo] [--abrir-ventana] [--cerrar-ventana]
#
# Registro: evidencias/<fecha>_despliegue_sql/registro.txt (salida de sqlcmd; no contiene
# secretos ni IP; los nombres de usuario de base son los nombres de los sitios).
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

DEMO=no ABRIR=no CERRAR=no
for arg in "$@"; do
  case "$arg" in
    --demo) DEMO=si ;;
    --abrir-ventana) ABRIR=si ;;
    --cerrar-ventana) CERRAR=si ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $arg" ;;
  esac
done

exigir_terminal
exigir_sqlcmd
RG="${RG:-rg-cobranza-apt}"

if [[ "$ABRIR" == "si" ]]; then
  [[ -n "${IP_OPERADOR:-}" ]] || error "--abrir-ventana requiere IP_OPERADOR exportada (infra/entorno.local.env)."
  echo "== Apertura de la ventana: despliegue de infra/main.bicep con IP_OPERADOR=<IP_OPERADOR>"
  echo "   Restablece ajustes y configuracion del sitio: reaplicar s12_endurecer.sh al cerrar (regla 7)."
  confirmar "Desplegar infra/main.bicep (modo Incremental) en ${RG}."
  desplegar_main "$IP_OPERADOR"
fi

SQL_FQDN="$(salida sqlServerFqdn)"; SQL_DB="$(salida sqlDatabaseName)"
SQL_SERVER="$(salida sqlServerName)"
U_FUNC="$(salida usuarioFunctionApp)"; U_API="$(salida usuarioApi)"
ABIERTO="$(salida accesoOperadorAbierto)"
[[ -n "$SQL_FQDN" && -n "$SQL_DB" && -n "$U_FUNC" && -n "$U_API" ]] \
  || error "No se pudieron leer las salidas del despliegue ${DEPLOY_NAME} en ${RG}. Desplegar primero infra/main.bicep."

PUBLICO="$(az sql server show -g "$RG" -n "$SQL_SERVER" --query publicNetworkAccess -o tsv | tr -d '\r')"
REGLA="$(az sql server firewall-rule list -g "$RG" -s "$SQL_SERVER" --query "length([?name=='operador-temporal'])" -o tsv | tr -d '\r')"
if [[ "${ABIERTO,,}" != "true" || "$PUBLICO" != "Enabled" || "$REGLA" != "1" ]]; then
  echo "La ventana del operador NO esta abierta (accesoOperadorAbierto=${ABIERTO}, publicNetworkAccess=${PUBLICO}, operador-temporal=${REGLA})." >&2
  echo "Abrirla: exportar IP_OPERADOR y ejecutar este script con --abrir-ventana (o scripts/desplegar.sh paso 4)." >&2
  echo "Nota: s12_endurecer.sh cierra SQL; si se ejecuto despues del despliegue, hay que volver a desplegar con IP_OPERADOR." >&2
  exit 1
fi

ORDEN=(01 02 03 04 05 06 12 11 00 07 13)
[[ "$DEMO" == "si" ]] && ORDEN+=(08)
ARCHIVOS=()
for n in "${ORDEN[@]}"; do
  mapfile -t f < <(ls "${RAIZ_REPO}/sql/${n}_"*.sql 2>/dev/null)
  [[ ${#f[@]} -eq 1 ]] || error "Se esperaba exactamente un archivo sql/${n}_*.sql (encontrados: ${#f[@]})."
  ARCHIVOS+=("${f[0]}")
done

FECHA="$(date -u +%Y-%m-%d)"
DIR_EVID="${RAIZ_REPO}/evidencias/${FECHA}_despliegue_sql"
mkdir -p "$DIR_EVID"
REGISTRO="${DIR_EVID}/registro.txt"

echo "Despliegue SQL"
echo "  Servidor : ${SQL_FQDN}"
echo "  Base     : ${SQL_DB}"
echo "  -v UsuarioFunctionApp=${U_FUNC}  UsuarioApi=${U_API}"
echo "  Orden    :"; for a in "${ARCHIVOS[@]}"; do echo "    sql/$(basename "$a")"; done
[[ "$DEMO" == "si" ]] && echo "  --demo: se cargan datos DEMO (08) al final. Antes de correr el job contra ACS, qa confirma que los correos DEMO son direcciones controladas por el equipo."
echo "  Registro : ${REGISTRO#"${RAIZ_REPO}"/}"
confirmar "Ejecutar los scripts contra la base REAL ${SQL_DB}."

{
  echo "# Despliegue SQL $(date -u +%Y-%m-%dT%H:%M:%SZ) - base ${SQL_DB} - demo=${DEMO}"
} >> "$REGISTRO"

for a in "${ARCHIVOS[@]}"; do
  nombre="$(basename "$a")"
  echo "== sql/${nombre}" | tee -a "$REGISTRO"
  if ! sqlcmd -S "tcp:${SQL_FQDN},1433" -d "$SQL_DB" --authentication-method ActiveDirectoryDefault -b \
         -i "$(ruta_nativa "$a")" -v UsuarioFunctionApp="$U_FUNC" UsuarioApi="$U_API" 2>&1 | tee -a "$REGISTRO"; then
    echo "ERROR en sql/${nombre}: se detiene el despliegue (los scripts anteriores ya se aplicaron)." | tee -a "$REGISTRO" >&2
    exit 1
  fi
  case "$nombre" in
    00_*) echo "   Revisar arriba: 00 debe terminar sin hallazgos." ;;
    07_*) echo "   Revisar arriba: resultado esperado 10/10." ;;
    13_*) echo "   Revisar arriba: resultado esperado 28/28 (estatico segun dba; NO VERIFICADO en ejecucion)." ;;
  esac
done
echo "# Fin $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$REGISTRO"
echo "Scripts SQL aplicados. Registro: ${REGISTRO#"${RAIZ_REPO}"/}"

if [[ "$CERRAR" == "si" ]]; then
  echo "== Cierre de la ventana: despliegue con IP_OPERADOR vacio y s12_endurecer.sh"
  confirmar "Desplegar infra/main.bicep con ipOperador vacio y ejecutar s12_endurecer.sh."
  desplegar_main ""
  exportar_nombres_recursos
  env -u IP_OPERADOR -u IP_PUBLICACION_SCM "${RAIZ_REPO}/scripts/s12_endurecer.sh"
else
  echo "RECORDATORIO: la ventana sigue ABIERTA. Cerrarla en la misma sesion:"
  echo "  scripts/desplegar.sh (paso 10) o bien: IP_OPERADOR= az deployment group create -g ${RG} -n ${DEPLOY_NAME} --parameters infra/main.bicepparam --mode Incremental"
  echo "  y luego scripts/s12_endurecer.sh sin IP_OPERADOR ni IP_PUBLICACION_SCM (docs/seguridad/plantilla_ventana_operador.md)."
fi
