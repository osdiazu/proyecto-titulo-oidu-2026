#!/usr/bin/env bash
# =============================================================================
# s11_alta_clave_api.sh - Proyecto APT Cobranza Automatizada (ADR-001 5.9; politica A.10.2)
#
# REGLA SEG-H01: SOLO LO EJECUTA UN HUMANO, nunca un agente de Claude Code.
# Lo ejecuta un integrante miembro de grp-cobranza-sql-admin, en su propia terminal
# y fuera de Claude Code.
#
# Emite una clave de API para un consumidor (DEMO: ventas-demo, 30 dias; carga-demo, 1 dia):
#   1. Cobranza.Herramientas nueva-clave-api escribe la clave SOLO en un archivo temporal
#      (mktemp en el perfil del usuario; trap lo borra tambien ante error). En Git Bash
#      para Windows chmod 600 no aplica sobre NTFS: la proteccion real es la ACL del perfil.
#   2. La clave se guarda en Key Vault como apikey-<consumidor>-<prefijo> (--file, sin pasar
#      por la linea de comandos). El atributo exp es informativo (SEG-H09); la vigencia real
#      se controla en SQL.
#   3. Se registra prefijo y hash SHA-256 con cob.sp_RegistrarClaveApi (evento AltaClaveApi).
#      Si el registro SQL falla, el secreto recien creado se deshabilita.
#   4. Opcional: Key Vault Secrets User a un lector, con alcance SOLO en ese secreto.
# La salida muestra solo prefijo, nombre del secreto y vencimiento (nunca la clave ni el hash).
#
# Uso:
#   scripts/s11_alta_clave_api.sh --consumidor ventas-demo --dias 30 [--lector-object-id <OID>]
#
# Variables: RG y DEPLOY_NAME (por defecto cobranza-main) para leer servidor, base y Key Vault
# de las salidas de infra/main.bicep; o SQL_SERVER, SQL_DB y KV_NAME.
# Vigencia maxima: Seguridad:DiasVigenciaClaveApi de src/Cobranza.Api/appsettings.json
# (DEMO 180, PENDIENTE de aprobacion, ADR-001 5.4); se lee de ese archivo, no se repite aqui.
# Requisitos: miembro de grp-cobranza-sql-admin; Key Vault Secrets Officer en el vault
# (raKvOperador); para --lector-object-id, Owner/User Access Administrator; acceso de red
# a SQL y a Key Vault (ventana ipOperador abierta); go-sqlcmd; .NET SDK 10.
#
# ADVERTENCIA (ADR-001 4.2): el hash SHA-256 de la clave viaja en el lote SQL y queda en
# la auditoria de Azure SQL (BATCH_COMPLETED_GROUP). Una clave de 256 bits no se puede
# recuperar desde su hash (ADR-001 5.3).
# Sin set -x, sin tee. Evidencia: docs/seguridad/plantilla_claves_api.md.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

CONSUMIDOR="" DIAS="" LECTOR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --consumidor) CONSUMIDOR="${2:-}"; shift 2 ;;
    --dias) DIAS="${2:-}"; shift 2 ;;
    --lector-object-id) LECTOR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $1" ;;
  esac
done

exigir_humano
exigir_sqlcmd
[[ "$CONSUMIDOR" =~ $PATRON_CONSUMIDOR ]] || error "--consumidor no valido (a-z, 0-9 y guion; 3 a 50)."
[[ "$DIAS" =~ ^[0-9]+$ && "$DIAS" -ge 1 ]] || error "--dias debe ser un entero mayor o igual a 1."
if [[ -n "$LECTOR" && ! "$LECTOR" =~ $PATRON_GUID ]]; then error "--lector-object-id debe ser un GUID."; fi

DIAS_MAX="$(python -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["Seguridad"]["DiasVigenciaClaveApi"])' \
             "$(ruta_nativa "${RAIZ_REPO}/src/Cobranza.Api/appsettings.json")" 2>/dev/null | tr -d '\r' || true)"
[[ "$DIAS_MAX" =~ ^[0-9]+$ ]] || error "No se pudo leer Seguridad:DiasVigenciaClaveApi de src/Cobranza.Api/appsettings.json."
[[ "$DIAS" -le "$DIAS_MAX" ]] || error "--dias (${DIAS}) supera el maximo Seguridad:DiasVigenciaClaveApi (${DIAS_MAX})."

RG="${RG:-rg-cobranza-apt}"
resolver_sql
KV_NAME="${KV_NAME:-$(salida keyVaultName)}"
[[ -n "$KV_NAME" ]] || error "Defina KV_NAME o RG/DEPLOY_NAME."

VENCE_ISO="$(date -u -d "+${DIAS} days" +%Y-%m-%dT%H:%M:%SZ)"
VENCE_SQL="${VENCE_ISO%Z}"

echo "Alta de clave de API"
echo "  Consumidor : ${CONSUMIDOR}"
echo "  Vigencia   : ${DIAS} dias (vence ${VENCE_ISO} UTC; maximo ${DIAS_MAX})"
echo "  Key Vault  : ${KV_NAME}"
echo "  Base       : ${SQL_DB}"
[[ -n "$LECTOR" ]] && echo "  Lector     : $(truncar "$LECTOR") (Key Vault Secrets User solo sobre el secreto nuevo)"

# Politica C.2: alerta si el consumidor ya tiene dos o mas claves activas.
ACTIVAS="$(sql_lote "$SQL_DB" <<SQL | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1
SET NOCOUNT ON;
SELECT COUNT(*) FROM cob.ClaveApi
 WHERE Consumidor = '${CONSUMIDOR}' AND Activa = 1 AND FechaRevocacion IS NULL AND FechaVencimiento > SYSUTCDATETIME();
SQL
)" || error "No se pudo consultar cob.ClaveApi (acceso de red a SQL o permisos)."
echo "  Claves activas del consumidor antes del alta: ${ACTIVAS}"
if [[ "${ACTIVAS:-0}" =~ ^[0-9]+$ && "$ACTIVAS" -ge 2 ]]; then
  echo "AVISO (politica C.2): ${CONSUMIDOR} ya tiene ${ACTIVAS} claves activas. Revoque las anteriores antes de emitir otra."
fi
confirmar "Confirma el alta de una clave para ${CONSUMIDOR}."

compilar_herramienta
TMP_CLAVE="$(mktemp "${TMPDIR:-/tmp}/cobk.XXXXXXXX")"
SECRETO_CREADO=""
REGISTRADO=no
limpiar () {
  rm -f "$TMP_CLAVE"
  limpiar_herramienta
  if [[ -n "$SECRETO_CREADO" && "$REGISTRADO" != "si" ]]; then
    echo "El registro en SQL no se completo: se deshabilita el secreto ${SECRETO_CREADO}." >&2
    az keyvault secret set-attributes --vault-name "$KV_NAME" -n "$SECRETO_CREADO" --enabled false --output none \
      || echo "No se pudo deshabilitar ${SECRETO_CREADO}: hacerlo a mano." >&2
  fi
}
trap limpiar EXIT

# --- 1. Generar la clave (solo al archivo temporal) -------------------------------
SALIDA_HERR="$(dotnet "$HERR" nueva-clave-api --consumidor "$CONSUMIDOR" --salida-archivo "$(ruta_nativa "$TMP_CLAVE")")" \
  || error "nueva-clave-api fallo (codigos: 1 uso, 3 archivo; ver src/Cobranza.Herramientas/README.md)."
read -r PREFIJO HASH_HEX <<< "$SALIDA_HERR"
unset SALIDA_HERR
[[ "$PREFIJO" =~ $PATRON_PREFIJO ]] || error "Prefijo con formato inesperado."
[[ "$HASH_HEX" =~ ^[0-9A-F]{64}$ ]] || error "Hash con formato inesperado."
grep -qE "^cobk_${PREFIJO}_[A-Za-z0-9_-]{43}$" "$TMP_CLAVE" || error "El archivo temporal no contiene una clave con el formato esperado."
NOMBRE_SECRETO="apikey-${CONSUMIDOR}-${PREFIJO}"

# --- 2. Key Vault -----------------------------------------------------------------
echo "== Guardando la clave en Key Vault como ${NOMBRE_SECRETO}"
az keyvault secret set --vault-name "$KV_NAME" -n "$NOMBRE_SECRETO" \
   --file "$(ruta_nativa "$TMP_CLAVE")" --encoding utf-8 --expires "$VENCE_ISO" \
   --content-type api-key --tags "consumidor=${CONSUMIDOR}" ambiente=DEMO "prefijo=${PREFIJO}" --output none
SECRETO_CREADO="$NOMBRE_SECRETO"
rm -f "$TMP_CLAVE"

# --- 3. SQL -----------------------------------------------------------------------
echo "== Registrando prefijo y hash en cob.ClaveApi"
if ! sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC cob.sp_RegistrarClaveApi @Prefijo = '${PREFIJO}', @HashClave = 0x${HASH_HEX}, @Consumidor = '${CONSUMIDOR}',
     @Rol = 'Ventas', @FechaVencimiento = '${VENCE_SQL}', @NombreSecretoKv = '${NOMBRE_SECRETO}';
SQL
then unset HASH_HEX; explicar_error_sql; exit 1; fi
unset HASH_HEX
REGISTRADO=si

# --- 4. Lector opcional (alcance: solo el secreto) ----------------------------------
if [[ -n "$LECTOR" ]]; then
  echo "== Key Vault Secrets User para el lector $(truncar "$LECTOR"), alcance: solo ${NOMBRE_SECRETO}"
  echo "   Leer desde una IP distinta de ipOperador: PENDIENTE (requiere aprobacion; abre otra IP en Key Vault)."
  KV_ID="$(az keyvault show -n "$KV_NAME" --query id -o tsv | tr -d '\r')"
  MSYS_NO_PATHCONV=1 az role assignment create --role "Key Vault Secrets User" \
     --assignee-object-id "$LECTOR" --assignee-principal-type User \
     --scope "${KV_ID}/secrets/${NOMBRE_SECRETO}" --output none
fi

echo
echo "Clave de API emitida (evento AltaClaveApi):"
echo "  Prefijo  : ${PREFIJO}"
echo "  Secreto  : ${NOMBRE_SECRETO}"
echo "  Vence    : ${VENCE_ISO} UTC"
echo "Siguiente: pruebas/consumidor_ventas_demo.sh (AUT-10) y evidencia desde docs/seguridad/plantilla_claves_api.md."
