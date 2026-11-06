#!/usr/bin/env bash
# =============================================================================
# consumidor_ventas_demo.sh - Proyecto APT Cobranza Automatizada (ADR-001 5.9, politica A.5)
# Consumidor DEMO "ventas-demo" de la API de Ventas (RF-06), simulado (decision U1).
#
# Casos:
#   AUT-10  GET /api/v1/clientes/<RUT>/estado con la clave      -> 200
#   AUT-11  GET /api/v1/cartera/indicadores con la clave        -> 403
#   FORMATO GET /api/v1/clientes/<RUT>/estado con clave invalida -> 401
#
# La clave se toma de la variable de entorno API_KEY (exportada en la sesion, nunca como
# argumento). Si API_KEY no esta definida y se indican KV_NAME y NOMBRE_SECRETO, se lee de
# Key Vault en tiempo de ejecucion a una variable, sin imprimirla.
# La clave se envia a curl por la entrada estandar (-H @-) para que no aparezca en la lista de
# procesos. La salida registra solo el prefijo de la clave, el codigo HTTP y la hora UTC.
#
# Variables:
#   BASE_URL        (obligatoria) https://<host de la API>
#   API_KEY         clave completa cobk_<prefijo>_<secreto> (o bien KV_NAME + NOMBRE_SECRETO)
#   KV_NAME         nombre del Key Vault (opcional)
#   NOMBRE_SECRETO  apikey-ventas-demo-<prefijo> (opcional)
#   RUT             RUT DEMO de sql/08 (por defecto 76555555-8)
#
# Ejecutarlo contra Azure requiere confirmacion humana (CLAUDE.md regla 5). No usar set -x.
# Codigo de salida: 0 si los tres casos dan lo esperado; 1 si alguno falla; 2 por error de uso.
# =============================================================================
set -euo pipefail

limpiar() { unset API_KEY CLAVE; }
trap limpiar EXIT

: "${BASE_URL:?Defina BASE_URL (https://<host de la API>)}"
RUT="${RUT:-76555555-8}"

case "$BASE_URL" in
  https://*) ;;
  *) echo "BASE_URL debe usar https://" >&2; exit 2 ;;
esac

if [[ -n "${API_KEY:-}" ]]; then
  CLAVE="$API_KEY"
elif [[ -n "${KV_NAME:-}" && -n "${NOMBRE_SECRETO:-}" ]]; then
  CLAVE="$(az keyvault secret show --vault-name "$KV_NAME" -n "$NOMBRE_SECRETO" --query value -o tsv)"
  CLAVE="${CLAVE%$'\r'}"   # az en Windows puede terminar la linea con CR
else
  echo "Defina API_KEY en el entorno, o KV_NAME y NOMBRE_SECRETO para leerla de Key Vault." >&2
  exit 2
fi

if [[ ! "$CLAVE" =~ ^cobk_[a-z2-7]{8}_[A-Za-z0-9_-]{43}$ ]]; then
  echo "La clave no tiene el formato cobk_<prefijo>_<secreto> (ADR-001 5.3)." >&2
  exit 2
fi
PREFIJO="${CLAVE:5:8}"

# Envia la clave por stdin: printf es un comando interno de bash (no crea proceso con la clave).
llamar() {
  local clave="$1" url="$2"
  printf 'X-Api-Key: %s\n' "$clave" \
    | curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -H @- -H 'Accept: application/json' "$url"
}

fallos=0
verificar() {
  local caso="$1" esperado="$2" obtenido="$3" resultado="OK"
  [[ "$obtenido" == "$esperado" ]] || { resultado="FALLA"; fallos=$((fallos + 1)); }
  printf '%s | %s | prefijo=%s | esperado=%s | obtenido=%s | %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$caso" "$PREFIJO" "$esperado" "$obtenido" "$resultado"
}

verificar "AUT-10 estado cliente" 200 "$(llamar "$CLAVE" "$BASE_URL/api/v1/clientes/$RUT/estado")"
verificar "AUT-11 cartera"        403 "$(llamar "$CLAVE" "$BASE_URL/api/v1/cartera/indicadores")"
# Clave con formato invalido (no es una clave real): 401 sin consultar la base.
verificar "Formato invalido"      401 "$(llamar "cobk_formato_invalido" "$BASE_URL/api/v1/clientes/$RUT/estado")"

[[ "$fallos" -eq 0 ]] || exit 1
