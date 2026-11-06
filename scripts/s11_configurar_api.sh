#!/usr/bin/env bash
# =============================================================================
# s11_configurar_api.sh - Proyecto APT Cobranza Automatizada (Evidencia S11)
# Actualizado el 06-11-2026 por ADR-001 (autenticacion propia, sin Easy Auth).
#
# Alinea y verifica la configuracion de la Web App de la API con infra/main.bicep:
#   1. Easy Auth deshabilitado (si estuviera activo interceptaria las solicitudes; SEG-05).
#   2. Sin el ajuste obsoleto MICROSOFT_PROVIDER_AUTHENTICATION_SECRET.
#   3. Ajustes de ADR-001 (valores tomados de las salidas de la plantilla, no escritos a mano):
#        DataProtection__BlobUri, DataProtection__KeyIdentifier,
#        Seguridad__SaltosProxyConfiables, ASPNETCORE_FORWARDEDHEADERS_ENABLED=false
#      y ConnectionStrings__Cobranza.
#   4. HTTPS, TLS 1.2, sin FTP, sonda /salud.
#   5. Verificacion (lectura) de los ajustes.
#
# NO publica la API. La publicacion la hace scripts/desplegar.sh (paso 6) y solo si se
# cumple la regla de transicion de ADR-001 5.11 (implementacion compilada, pruebas en
# verde e informe de qa APROBADO o APROBADO CON OBSERVACIONES).
#
# Los ajustes coinciden con infra/main.bicep; un redespliegue de main los vuelve a
# imponer. Este script sirve para corregir sin redesplegar.
#
# Variables: RG (por defecto rg-cobranza-apt) y DEPLOY_NAME (por defecto cobranza-main).
# Requisitos: Azure CLI con sesion iniciada; Contributor o Website Contributor en la Web App.
# Ya no requiere Key Vault ni el registro de Entra ID (s11_registro_entra_id.sh retirado).
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

RG="${RG:-rg-cobranza-apt}"
WEB_APP="${WEB_APP:-$(salida apiAppName)}"
[[ -n "$WEB_APP" ]] || error "No se pudo leer apiAppName del despliegue ${DEPLOY_NAME} en ${RG}."
BLOB_URI="$(salida dataProtectionBlobUri)"
KEY_ID="$(salida dataProtectionKeyId)"
SALTOS="$(salida saltosProxyConfiables)"
SQL_FQDN="$(salida sqlServerFqdn)"; SQL_DB="$(salida sqlDatabaseName)"
[[ -n "$BLOB_URI" && -n "$KEY_ID" && "$SALTOS" =~ ^[12]$ && -n "$SQL_FQDN" && -n "$SQL_DB" ]] \
  || error "Faltan salidas de la plantilla (dataProtectionBlobUri, dataProtectionKeyId, saltosProxyConfiables, sqlServerFqdn, sqlDatabaseName)."
SQL_CS="Server=tcp:${SQL_FQDN},1433;Database=${SQL_DB};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;"

echo "== 1. Easy Auth (debe quedar deshabilitado, ADR-001)"
EA="$(az webapp auth show -g "$RG" -n "$WEB_APP" --query "properties.platform.enabled" -o tsv 2>/dev/null | tr -d '\r' || true)"
if [[ "${EA,,}" == "true" ]]; then
  echo "   Easy Auth esta ACTIVO: se deshabilita."
  az webapp auth update -g "$RG" -n "$WEB_APP" --enabled false --output none
else
  echo "   Easy Auth no activo (${EA:-sin configuracion})."
fi

echo "== 2. Ajuste obsoleto MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
if [[ "$(az webapp config appsettings list -g "$RG" -n "$WEB_APP" --query "length([?name=='MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'])" -o tsv | tr -d '\r')" != "0" ]]; then
  az webapp config appsettings delete -g "$RG" -n "$WEB_APP" --setting-names MICROSOFT_PROVIDER_AUTHENTICATION_SECRET --output none
  echo "   eliminado."
else
  echo "   no existe."
fi

echo "== 3. Ajustes de aplicacion (ADR-001)"
az webapp config appsettings set -g "$RG" -n "$WEB_APP" --output none --settings \
  "ConnectionStrings__Cobranza=${SQL_CS}" \
  "DataProtection__BlobUri=${BLOB_URI}" \
  "DataProtection__KeyIdentifier=${KEY_ID}" \
  "Seguridad__SaltosProxyConfiables=${SALTOS}" \
  "ASPNETCORE_FORWARDEDHEADERS_ENABLED=false"

echo "== 4. Configuracion general: HTTPS, TLS 1.2, sondeo de salud, sin FTP"
az webapp update -g "$RG" -n "$WEB_APP" --https-only true --output none
az webapp config set -g "$RG" -n "$WEB_APP" --min-tls-version 1.2 --ftps-state Disabled \
  --generic-configurations '{"healthCheckPath":"/salud"}' --output none

echo "== 5. Verificacion"
for k in DataProtection__BlobUri DataProtection__KeyIdentifier Seguridad__SaltosProxyConfiables ASPNETCORE_FORWARDEDHEADERS_ENABLED; do
  v="$(az webapp config appsettings list -g "$RG" -n "$WEB_APP" --query "[?name=='${k}'].value | [0]" -o tsv | tr -d '\r')"
  echo "   ${k} = ${v}"
done
echo "Listo. La API NO se publico (ADR-001 5.11). Siguiente: scripts/s12_endurecer.sh."
