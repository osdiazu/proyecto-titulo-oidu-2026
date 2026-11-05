#!/usr/bin/env bash
# =============================================================================
# s10_configurar_jobs.sh
# Proyecto APT Cobranza Automatizada - Evidencia S10
# Configura la Function App existente (desplegada con main.bicep en S6-S8):
#   1. guarda la cadena de conexion de ACS como secreto en Key Vault;
#   2. carga los ajustes de aplicacion (con referencias a Key Vault);
#   3. publica el paquete de la Function App.
#
# Requisitos: Azure CLI con extension "communication", sesion iniciada (az login),
# rol Key Vault Secrets Officer sobre el Key Vault y Contributor sobre el grupo de recursos.
# Si el Key Vault no admite acceso publico, ejecutar desde un equipo con acceso a la VNet
# o agregar temporalmente la IP del operador al firewall del Key Vault (paso 1b).
#
# Todos los valores marcados PENDIENTE deben completarse antes de ejecutar.
# =============================================================================
set -euo pipefail

RG="${RG:?Definir RG (grupo de recursos)}"
FUNC_APP="${FUNC_APP:?Definir FUNC_APP (nombre de la Function App)}"
KV_NAME="${KV_NAME:?Definir KV_NAME (nombre del Key Vault)}"
ACS_NAME="${ACS_NAME:?Definir ACS_NAME (recurso Communication Services)}"
SQL_SERVER="${SQL_SERVER:?Definir SQL_SERVER (nombre sin .database.windows.net)}"
SQL_DB="${SQL_DB:?Definir SQL_DB}"
REMITENTE="${REMITENTE:?Definir REMITENTE (DoNotReply@dominio verificado)}"
DIAS_PREAVISO="${DIAS_PREAVISO:?Definir DIAS_PREAVISO (Finanzas)}"
DIAS_MORA1="${DIAS_MORA1:?Definir DIAS_MORA1 (Finanzas)}"
DIAS_MORA2="${DIAS_MORA2:?Definir DIAS_MORA2 (Finanzas)}"
CANALES_PAGO="${CANALES_PAGO:?Definir CANALES_PAGO (texto oficial de Finanzas)}"
TELEFONO="${TELEFONO:?Definir TELEFONO de contacto}"
CORREO_CONTACTO="${CORREO_CONTACTO:?Definir CORREO_CONTACTO}"
PAQUETE="${PAQUETE:-functions.zip}"

echo "== 1. Secreto de ACS en Key Vault"
# 1b (opcional): az keyvault network-rule add -n "$KV_NAME" --ip-address "$(curl -s https://ifconfig.me)/32"
ACS_CS=$(az communication list-key -n "$ACS_NAME" -g "$RG" --query primaryConnectionString -o tsv)
az keyvault secret set --vault-name "$KV_NAME" -n acs-connection-string --value "$ACS_CS" --output none
unset ACS_CS

SQL_CS="Server=tcp:${SQL_SERVER}.database.windows.net,1433;Database=${SQL_DB};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;"
# Mientras la base de la embotelladora no este definida, la fuente es origen_sim en la misma base.
SQL_ORIGEN_CS="${SQL_CS}ApplicationIntent=ReadOnly;"

echo "== 2. Ajustes de aplicacion"
az functionapp config appsettings set -g "$RG" -n "$FUNC_APP" --output none --settings \
  "CRON_SINCRONIZACION=0 */15 * * * *" \
  "CRON_NOTIFICACIONES=0 0 12-17 * * 1-5" \
  "Cobranza__SqlCobranza=${SQL_CS}" \
  "Cobranza__SqlOrigen=${SQL_ORIGEN_CS}" \
  "Cobranza__VistaOrigen=origen_sim.vw_ClientesRegularizados" \
  "Cobranza__AcsConnectionString=@Microsoft.KeyVault(VaultName=${KV_NAME};SecretName=acs-connection-string)" \
  "Cobranza__RemitenteCorreo=${REMITENTE}" \
  "Cobranza__DiasPreaviso=${DIAS_PREAVISO}" \
  "Cobranza__DiasMora1=${DIAS_MORA1}" \
  "Cobranza__DiasMora2=${DIAS_MORA2}" \
  "Cobranza__MaxCorreosPorEjecucion=90" \
  "Cobranza__PausaEntreCorreosMs=2100" \
  "Cobranza__NombreEmpresa=Embotelladora del Pacifico S.A." \
  "Cobranza__CanalesPagoTexto=${CANALES_PAGO}" \
  "Cobranza__TelefonoContacto=${TELEFONO}" \
  "Cobranza__CorreoContacto=${CORREO_CONTACTO}"

echo "== 3. Verificacion de la referencia a Key Vault (debe indicar Resolved)"
az rest --method get \
  --url "$(az functionapp show -g "$RG" -n "$FUNC_APP" --query id -o tsv)/config/configreferences/appsettings/Cobranza__AcsConnectionString?api-version=2023-12-01" \
  --query "properties.status" -o tsv || echo "Revisar manualmente en el portal: Configuracion > Referencias de Key Vault"

echo "== 4. Publicacion (paquete generado con: dotnet publish -c Release -o publish && cd publish && zip -r ../functions.zip .)"
az functionapp deployment source config-zip -g "$RG" -n "$FUNC_APP" --src "$PAQUETE"

echo "Listo. Revisar ejecuciones en Application Insights (consultas en docs/consultas_kql_s10.kql)."
