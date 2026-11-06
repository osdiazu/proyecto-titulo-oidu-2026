#!/usr/bin/env bash
# =============================================================================
# s11_revocar_clave_api.sh - Proyecto APT Cobranza Automatizada (ADR-001 5.9; politica A.9, A.10.4)
#
# REGLA SEG-H01: SOLO LO EJECUTA UN HUMANO, nunca un agente de Claude Code.
# Lo ejecuta un integrante miembro de grp-cobranza-sql-admin, en su propia terminal
# y fuera de Claude Code.
#
# Revoca una clave de API:
#   1. cob.sp_RevocarClaveApi @Prefijo (idempotente; 50069 si el prefijo no existe).
#   2. Opcional (--verificar-401 <host>): espera 61 s (cache de la API: 60 s DEMO) y
#      comprueba que la clave responde 401 en /api/v1/yo (AUT-12). La clave se lee de
#      Key Vault a una variable y se envia a curl por stdin (no queda en la lista de
#      procesos); luego se borra de la memoria del script.
#   3. Deshabilita el secreto en Key Vault, elimina las asignaciones de rol con alcance
#      en ese secreto (lectores) y elimina el secreto. Queda 90 dias en soft-delete y no
#      se puede purgar (proteccion de purga).
#
# Uso:
#   scripts/s11_revocar_clave_api.sh --prefijo <prefijo> [--verificar-401 <host de la API>]
#
# Variables: RG y DEPLOY_NAME (por defecto cobranza-main), o SQL_SERVER, SQL_DB y KV_NAME.
# Requisitos: miembro de grp-cobranza-sql-admin; Key Vault Secrets Officer; para borrar
# asignaciones de lectores, Owner o User Access Administrator; acceso de red a SQL y a
# Key Vault (ventana ipOperador) y, para --verificar-401, a la API (regla de transicion).
# Sin set -x, sin tee. Evidencia: docs/seguridad/plantilla_claves_api.md.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

PREFIJO="" HOST_API=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefijo) PREFIJO="${2:-}"; shift 2 ;;
    --verificar-401) HOST_API="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $1" ;;
  esac
done

exigir_humano
exigir_sqlcmd
[[ "$PREFIJO" =~ $PATRON_PREFIJO ]] || error "--prefijo no valido (8 caracteres a-z y 2-7)."
if [[ -n "$HOST_API" && ! "$HOST_API" =~ ^[A-Za-z0-9.-]+$ ]]; then error "--verificar-401 espera un nombre de host (sin https://)."; fi
RG="${RG:-rg-cobranza-apt}"
resolver_sql
KV_NAME="${KV_NAME:-$(salida keyVaultName)}"
[[ -n "$KV_NAME" ]] || error "Defina KV_NAME o RG/DEPLOY_NAME."

NOMBRE_SECRETO="$(sql_lote "$SQL_DB" <<SQL | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1
SET NOCOUNT ON;
SELECT NombreSecretoKv FROM cob.ClaveApi WHERE Prefijo = '${PREFIJO}';
SQL
)" || error "No se pudo consultar cob.ClaveApi."
[[ "$NOMBRE_SECRETO" =~ ^apikey-[a-z0-9-]{3,50}-${PREFIJO}$ ]] || error "No existe una clave con el prefijo ${PREFIJO} (o su secreto tiene un nombre inesperado)."

echo "Revocacion de la clave ${PREFIJO} (secreto ${NOMBRE_SECRETO}, Key Vault ${KV_NAME}, base ${SQL_DB})."
confirmar "Confirma la revocacion."

CLAVE=""
trap 'unset CLAVE' EXIT
if [[ -n "$HOST_API" ]]; then
  CLAVE="$(az keyvault secret show --vault-name "$KV_NAME" -n "$NOMBRE_SECRETO" --query value -o tsv | tr -d '\r')" \
    || error "No se pudo leer el secreto para la verificacion AUT-12."
fi

echo "== 1. Revocacion en SQL (sp_RevocarClaveApi)"
if ! sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC cob.sp_RevocarClaveApi @Prefijo = '${PREFIJO}';
SQL
then explicar_error_sql; exit 1; fi

if [[ -n "$HOST_API" ]]; then
  echo "== 2. AUT-12: esperando 61 s (cache de validacion de la API, 60 s DEMO)"
  sleep 61
  CODIGO="$(printf 'X-Api-Key: %s\n' "$CLAVE" | curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H @- "https://${HOST_API}/api/v1/yo" || echo "sin-respuesta")"
  unset CLAVE
  if [[ "$CODIGO" == "401" ]]; then echo "   AUT-12 CUMPLE: 401"; else echo "   AUT-12 NO CUMPLE: obtenido ${CODIGO} (esperado 401)"; fi
else
  echo "== 2. AUT-12 no verificado por este script (sin --verificar-401). Verificar con pruebas/consumidor_ventas_demo.sh antes de eliminar el secreto, o manualmente."
fi

echo "== 3. Key Vault: deshabilitar el secreto, quitar lectores y eliminarlo"
az keyvault secret set-attributes --vault-name "$KV_NAME" -n "$NOMBRE_SECRETO" --enabled false --output none
KV_ID="$(az keyvault show -n "$KV_NAME" --query id -o tsv | tr -d '\r')"
ALCANCE="${KV_ID}/secrets/${NOMBRE_SECRETO}"
mapfile -t ASIGNACIONES < <(MSYS_NO_PATHCONV=1 az role assignment list --scope "$ALCANCE" \
    --query "[?scope=='${ALCANCE}'].id" -o tsv 2>/dev/null | tr -d '\r')
for a in "${ASIGNACIONES[@]}"; do
  [[ -n "$a" ]] && MSYS_NO_PATHCONV=1 az role assignment delete --ids "$a" --output none
done
echo "   Asignaciones de lectores eliminadas: ${#ASIGNACIONES[@]}"
az keyvault secret delete --vault-name "$KV_NAME" -n "$NOMBRE_SECRETO" --output none
echo "Clave ${PREFIJO} revocada (evento RevocacionClaveApi). Secreto en soft-delete 90 dias (no purgable)."
echo "Registrar la evidencia (prefijo, codigo HTTP de AUT-12, hora UTC) sin la clave ni el hash."
