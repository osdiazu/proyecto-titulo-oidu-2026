#!/usr/bin/env bash
# =============================================================================
# s11_configurar_api.sh - Proyecto APT Cobranza Automatizada (Evidencia S11)
# Configura y publica la API interna en la Web App existente.
# Orden: 1) s11_registro_entra_id.sh  2) este script  3) autenticacion_api.bicep
# =============================================================================
set -euo pipefail

RG="${RG:?Definir RG}"
WEB_APP="${WEB_APP:?Definir WEB_APP (nombre de la Web App de la API)}"
KV_NAME="${KV_NAME:?Definir KV_NAME}"
SQL_SERVER="${SQL_SERVER:?Definir SQL_SERVER (sin .database.windows.net)}"
SQL_DB="${SQL_DB:?Definir SQL_DB}"
PAQUETE="${PAQUETE:-api.zip}"   # dotnet publish src/Cobranza.Api -c Release -o publish-api && (cd publish-api && zip -r ../api.zip .)

SQL_CS="Server=tcp:${SQL_SERVER}.database.windows.net,1433;Database=${SQL_DB};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;"

echo "== 1. Ajustes de aplicacion"
az webapp config appsettings set -g "$RG" -n "$WEB_APP" --output none --settings \
  "ConnectionStrings__Cobranza=${SQL_CS}" \
  "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=@Microsoft.KeyVault(VaultName=${KV_NAME};SecretName=easyauth-client-secret)"

echo "== 2. Configuracion general: HTTPS, TLS 1.2, sondeo de salud, sin FTP"
az webapp update -g "$RG" -n "$WEB_APP" --https-only true --output none
az webapp config set -g "$RG" -n "$WEB_APP" --min-tls-version 1.2 --ftps-state Disabled \
  --generic-configurations '{"healthCheckPath":"/salud"}' --output none

echo "== 3. Publicacion"
az webapp deploy -g "$RG" -n "$WEB_APP" --src-path "$PAQUETE" --type zip

echo "== 4. Verificacion basica"
HOST=$(az webapp show -g "$RG" -n "$WEB_APP" --query defaultHostName -o tsv)
echo "Probar desde un equipo con acceso de red: curl -s https://${HOST}/salud  (esperado: {\"estado\":\"ok\"})"
