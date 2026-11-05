#!/usr/bin/env bash
# =============================================================================
# s12_pruebas_red.sh - Proyecto APT Cobranza Automatizada (Evidencia S12)
# Pruebas de exposicion EJECUTADAS DESDE INTERNET (equipo fuera de la VNet).
# Cada prueba muestra el codigo HTTP o el error obtenido para registrarlo en la
# tabla de pruebas de la evidencia. Solo envia solicitudes de lectura.
# =============================================================================
set -uo pipefail
WEB_HOST="${WEB_HOST:?Definir WEB_HOST (<webapp>.azurewebsites.net)}"
FUNC_HOST="${FUNC_HOST:?Definir FUNC_HOST (<funcapp>.azurewebsites.net)}"
KV_NAME="${KV_NAME:?Definir KV_NAME}"
WAF_HOST="${WAF_HOST:-}"     # dominio publicado en el Application Gateway (vacio si no hay WAF)

codigo () { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@" || echo "sin respuesta"; }

echo "RED-01 API directa /salud (esperado con API cerrada: 403; abierta: 200)  -> $(codigo "https://${WEB_HOST}/salud")"
echo "RED-02 API directa sin sesion /api/v1/cartera/indicadores (esperado 401/302/403) -> $(codigo -H 'X-Requested-With: XMLHttpRequest' "https://${WEB_HOST}/api/v1/cartera/indicadores")"
echo "RED-03 Function App desde internet (esperado 403)                       -> $(codigo "https://${FUNC_HOST}/")"
echo "RED-04 HTTP sin cifrar a la API (esperado 301 a HTTPS)                   -> $(codigo "http://${WEB_HOST}/salud")"
echo "RED-05 TLS 1.1 contra la API (esperado: fallo de negociacion)"
curl -s -o /dev/null --max-time 15 --tlsv1.1 --tls-max 1.1 "https://${WEB_HOST}/salud" && echo "   NEGOCIO TLS 1.1 (NO CUMPLE)" || echo "   rechazado (CUMPLE)"
echo "RED-06 Key Vault desde internet (esperado 403 ForbiddenByConnection o similar)"
az keyvault secret list --vault-name "$KV_NAME" -o none 2>&1 | head -2
if [[ -n "$WAF_HOST" ]]; then
  echo "RED-07 WAF /salud (esperado 200)                                         -> $(codigo "https://${WAF_HOST}/salud")"
  echo "RED-08 WAF con patron de inyeccion SQL (esperado 403 por el WAF)         -> $(codigo "https://${WAF_HOST}/api/v1/clientes/1'%20OR%20'1'='1/estado")"
  echo "RED-09 WAF con patron XSS (esperado 403)                                 -> $(codigo "https://${WAF_HOST}/?q=%3Cscript%3Ealert(1)%3C/script%3E")"
  echo "RED-10 WAF HTTP 80 (esperado 301 a HTTPS)                                -> $(codigo "http://${WAF_HOST}/salud")"
else
  echo "RED-07 a RED-10: WAF no desplegado (PENDIENTE)"
fi
