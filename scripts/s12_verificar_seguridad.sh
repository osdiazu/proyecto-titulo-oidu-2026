#!/usr/bin/env bash
# =============================================================================
# s12_verificar_seguridad.sh - Proyecto APT Cobranza Automatizada (Evidencia S12)
# Lee la configuracion real de los recursos y la compara con lo esperado.
# Genera matriz_seguridad_<fecha>.csv para adjuntar a la evidencia.
# Solo lectura: no modifica recursos.
# =============================================================================
set -uo pipefail

RG="${RG:?Definir RG}"; WEB_APP="${WEB_APP:?}"; FUNC_APP="${FUNC_APP:?}"
SQL_SERVER="${SQL_SERVER:?}"; SQL_DB="${SQL_DB:?}"; KV_NAME="${KV_NAME:?}"; STORAGE="${STORAGE:?}"
SALIDA="matriz_seguridad_$(date +%Y%m%d_%H%M).csv"
echo "id;control;esperado;obtenido;resultado" > "$SALIDA"
n=0; ok=0

chk () {   # chk "control" "esperado" "obtenido"
  n=$((n+1)); local r="NO CUMPLE"
  [[ "${3,,}" == "${2,,}" ]] && { r="CUMPLE"; ok=$((ok+1)); }
  printf 'SEG-%02d;%s;%s;%s;%s\n' "$n" "$1" "$2" "$3" "$r" | tee -a "$SALIDA"
}
q () { "$@" 2>/dev/null | tr -d '\r' || echo "error"; }

WEB_CFG=$(az webapp show -g "$RG" -n "$WEB_APP" --query id -o tsv)/config/web
FUNC_CFG=$(az functionapp show -g "$RG" -n "$FUNC_APP" --query id -o tsv)/config/web

chk "API: solo HTTPS"                       "true"     "$(q az webapp show -g "$RG" -n "$WEB_APP" --query httpsOnly -o tsv)"
chk "API: TLS minimo"                       "1.2"      "$(q az resource show --ids "$WEB_CFG" --query properties.minTlsVersion -o tsv)"
chk "API: FTP deshabilitado"                "Disabled" "$(q az resource show --ids "$WEB_CFG" --query properties.ftpsState -o tsv)"
chk "API: SCM con accion por defecto Deny"  "Deny"     "$(q az resource show --ids "$WEB_CFG" --query properties.scmIpSecurityRestrictionsDefaultAction -o tsv)"
chk "API: autenticacion Entra ID activa"    "true"     "$(q az webapp auth show -g "$RG" -n "$WEB_APP" --query properties.platform.enabled -o tsv)"
chk "API: identidad administrada"           "SystemAssigned" "$(q az webapp identity show -g "$RG" -n "$WEB_APP" --query type -o tsv)"
chk "Functions: solo HTTPS"                 "true"     "$(q az functionapp show -g "$RG" -n "$FUNC_APP" --query httpsOnly -o tsv)"
chk "Functions: TLS minimo"                 "1.2"      "$(q az resource show --ids "$FUNC_CFG" --query properties.minTlsVersion -o tsv)"
chk "Functions: entrada publica denegada"   "Deny"     "$(q az resource show --ids "$FUNC_CFG" --query properties.ipSecurityRestrictionsDefaultAction -o tsv)"
chk "Functions: todo el trafico por VNet"   "true"     "$(q az resource show --ids "$FUNC_CFG" --query properties.vnetRouteAllEnabled -o tsv)"
chk "SQL: acceso publico"                   "Disabled" "$(q az sql server show -g "$RG" -n "$SQL_SERVER" --query publicNetworkAccess -o tsv)"
chk "SQL: TLS minimo"                       "1.2"      "$(q az sql server show -g "$RG" -n "$SQL_SERVER" --query minimalTlsVersion -o tsv)"
chk "SQL: solo autenticacion Entra ID"      "true"     "$(q az sql server ad-only-auth get -g "$RG" -n "$SQL_SERVER" --query azureAdOnlyAuthentication -o tsv)"
chk "SQL: TDE habilitado"                   "Enabled"  "$(q az sql db tde show -g "$RG" -s "$SQL_SERVER" -d "$SQL_DB" --query state -o tsv)"
chk "SQL: auditoria habilitada"             "Enabled"  "$(q az sql server audit-policy show -g "$RG" -n "$SQL_SERVER" --query state -o tsv)"
chk "Key Vault: autorizacion RBAC"          "true"     "$(q az keyvault show -n "$KV_NAME" --query properties.enableRbacAuthorization -o tsv)"
chk "Key Vault: proteccion de purga"        "true"     "$(q az keyvault show -n "$KV_NAME" --query properties.enablePurgeProtection -o tsv)"
chk "Key Vault: acceso publico"             "Disabled" "$(q az keyvault show -n "$KV_NAME" --query properties.publicNetworkAccess -o tsv)"
chk "Storage: TLS minimo"                   "TLS1_2"   "$(q az storage account show -g "$RG" -n "$STORAGE" --query minimumTlsVersion -o tsv)"
chk "Storage: sin acceso anonimo a blobs"   "false"    "$(q az storage account show -g "$RG" -n "$STORAGE" --query allowBlobPublicAccess -o tsv)"
chk "Storage: sin clave compartida"         "false"    "$(q az storage account show -g "$RG" -n "$STORAGE" --query allowSharedKeyAccess -o tsv)"
chk "Private Endpoints no aprobados"        "0"        "$(q az network private-endpoint list -g "$RG" --query "length([?privateLinkServiceConnections[0].privateLinkServiceConnectionState.status!='Approved'])" -o tsv)"

WAF=$(q az network application-gateway waf-policy list -g "$RG" --query "[0].policySettings.mode" -o tsv)
if [[ -n "$WAF" && "$WAF" != "error" ]]; then
  chk "WAF: modo Prevencion" "Prevention" "$WAF"
else
  echo "WAF no desplegado: control SEG-WAF queda PENDIENTE" | tee -a "$SALIDA"
fi

echo "Resumen: ${ok} de ${n} controles cumplen. Archivo: ${SALIDA}"
