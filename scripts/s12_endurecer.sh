#!/usr/bin/env bash
# =============================================================================
# s12_endurecer.sh - Proyecto APT Cobranza Automatizada (Evidencia S12)
# Aplica configuraciones de endurecimiento sobre recursos EXISTENTES con
# operaciones de actualizacion parcial (no reemplaza su configuracion completa).
#
# Orden recomendado:
#   1. Desplegar infra/modulos/seguridad_perimetral.bicep (con o sin WAF).
#   2. Ejecutar este script.
#   3. Ejecutar scripts/s12_verificar_seguridad.sh y registrar la matriz.
#
# IMPORTANTE: CERRAR_API_PUBLICA=si deja la API accesible SOLO por el Private
# Endpoint (Application Gateway o equipos dentro de la VNet). Usarlo solo cuando
# el Application Gateway WAF este desplegado y probado; de lo contrario la fuerza
# de ventas y Finanzas pierden el acceso al panel.
# =============================================================================
set -euo pipefail

RG="${RG:?Definir RG}"
WEB_APP="${WEB_APP:?Definir WEB_APP}"
FUNC_APP="${FUNC_APP:?Definir FUNC_APP}"
SQL_SERVER="${SQL_SERVER:?Definir SQL_SERVER}"
STORAGE="${STORAGE:?Definir STORAGE (cuenta de la Function App)}"
IP_OPERADOR="${IP_OPERADOR:-}"            # IP publica/32 autorizada para publicar en SCM (opcional)
CERRAR_API_PUBLICA="${CERRAR_API_PUBLICA:-no}"

endurecer_app () {
  local APP="$1" TIPO="$2"   # TIPO: webapp | functionapp
  echo "== ${APP}: HTTPS, TLS 1.2, sin FTP, trafico saliente por la VNet"
  az "$TIPO" update -g "$RG" -n "$APP" --set httpsOnly=true --output none
  az "$TIPO" config set -g "$RG" -n "$APP" --min-tls-version 1.2 --ftps-state Disabled --output none
  az resource update --ids "$(az "$TIPO" show -g "$RG" -n "$APP" --query id -o tsv)/config/web" \
     --set properties.vnetRouteAllEnabled=true properties.scmMinTlsVersion=1.2 --output none

  echo "== ${APP}: sitio SCM (publicacion) cerrado salvo IP del operador"
  az resource update --ids "$(az "$TIPO" show -g "$RG" -n "$APP" --query id -o tsv)/config/web" \
     --set properties.scmIpSecurityRestrictionsUseMain=false properties.scmIpSecurityRestrictionsDefaultAction=Deny --output none
  if [[ -n "$IP_OPERADOR" ]]; then
    az "$TIPO" config access-restriction add -g "$RG" -n "$APP" --scm-site true \
       --rule-name operador-publicacion --action Allow --ip-address "$IP_OPERADOR" --priority 100 --output none || true
  fi
}

endurecer_app "$FUNC_APP" functionapp
echo "== ${FUNC_APP}: sin trafico de entrada publico (los jobs no reciben solicitudes HTTP)"
az resource update --ids "$(az functionapp show -g "$RG" -n "$FUNC_APP" --query id -o tsv)/config/web" \
   --set properties.ipSecurityRestrictionsDefaultAction=Deny --output none

endurecer_app "$WEB_APP" webapp
if [[ "$CERRAR_API_PUBLICA" == "si" ]]; then
  echo "== ${WEB_APP}: entrada publica denegada (solo Private Endpoint / Application Gateway)"
  az resource update --ids "$(az webapp show -g "$RG" -n "$WEB_APP" --query id -o tsv)/config/web" \
     --set properties.ipSecurityRestrictionsDefaultAction=Deny --output none
else
  echo "== ${WEB_APP}: entrada publica se mantiene (protegida por Entra ID) hasta desplegar el WAF"
fi

echo "== Azure SQL: TLS minimo 1.2 y sin acceso publico"
az sql server update -g "$RG" -n "$SQL_SERVER" --minimal-tls-version 1.2 --enable-public-network false --output none

echo "== Storage: TLS 1.2, sin acceso anonimo a blobs, sin clave compartida"
az storage account update -g "$RG" -n "$STORAGE" --min-tls-version TLS1_2 \
   --allow-blob-public-access false --allow-shared-key-access false --output none

echo "Listo. Ejecutar scripts/s12_verificar_seguridad.sh"
