#!/usr/bin/env bash
# =============================================================================
# s10_configurar_jobs.sh
# Proyecto APT Cobranza Automatizada - Evidencia S10
# Configura la Function App existente (desplegada con infra/main.bicep):
#   1. carga los ajustes de aplicacion (con referencias a Key Vault);
#   2. verifica la referencia al secreto de ACS;
#   3. publica el paquete de la Function App.
#
# 05-11-2026 (hallazgo M-06 de QA):
#   - Se retiro el antiguo paso 1 (az communication list-key + az keyvault secret set):
#     infra/main.bicep ya crea el secreto acs-connection-string por el plano de control
#     (recurso secretAcs; docs/05), que funciona con el vault cerrado. Recrearlo por el
#     plano de datos era redundante y obligaba a abrir el Key Vault a la IP del operador.
#   - MaxCorreosPorEjecucion y PausaEntreCorreosMs quedan en los valores DEMO de D12
#     (10 y 15000, aprobados por el usuario), iguales a infra/main.bicepparam. Los valores
#     anteriores (90 / 2100) superaban los limites de ACS con dominio administrado (H1).
#   - Los ajustes coinciden con los que ya fija infra/main.bicep; este script solo hace
#     falta para publicar o para cambiar valores sin redesplegar. Un redespliegue de main
#     vuelve a imponer los valores de la plantilla.
#
# Requisitos: Azure CLI, sesion iniciada (az login) y Contributor (o Website Contributor)
# sobre la Function App. No requiere acceso al plano de datos del Key Vault.
#
# Todos los valores marcados PENDIENTE deben completarse antes de ejecutar.
# =============================================================================
set -euo pipefail

RG="${RG:?Definir RG (grupo de recursos)}"
FUNC_APP="${FUNC_APP:?Definir FUNC_APP (nombre de la Function App)}"
KV_NAME="${KV_NAME:?Definir KV_NAME (nombre del Key Vault)}"
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

SQL_CS="Server=tcp:${SQL_SERVER}.database.windows.net,1433;Database=${SQL_DB};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;"
# Mientras la base de la embotelladora no este definida, la fuente es origen_sim en la misma base.
SQL_ORIGEN_CS="${SQL_CS}ApplicationIntent=ReadOnly;"

echo "== 1. Ajustes de aplicacion"
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
  "Cobranza__MaxCorreosPorEjecucion=10" \
  "Cobranza__PausaEntreCorreosMs=15000" \
  "Cobranza__NombreEmpresa=Embotelladora del Pacifico S.A." \
  "Cobranza__CanalesPagoTexto=${CANALES_PAGO}" \
  "Cobranza__TelefonoContacto=${TELEFONO}" \
  "Cobranza__CorreoContacto=${CORREO_CONTACTO}"

echo "== 2. Verificacion de la referencia a Key Vault (debe indicar Resolved)"
az rest --method get \
  --url "$(az functionapp show -g "$RG" -n "$FUNC_APP" --query id -o tsv)/config/configreferences/appsettings/Cobranza__AcsConnectionString?api-version=2023-12-01" \
  --query "properties.status" -o tsv || echo "Revisar manualmente en el portal: Configuracion > Referencias de Key Vault"

# 06-11-2026 (ADR-001): OMITIR_PUBLICACION=si salta este paso. Lo usa scripts/desplegar.sh,
# que publica antes (paso 6) con la ventana SCM abierta por s12_endurecer.sh.
if [[ "${OMITIR_PUBLICACION:-no}" == "si" ]]; then
  echo "== 3. Publicacion omitida (OMITIR_PUBLICACION=si)"
else
  echo "== 3. Publicacion (paquete generado con: dotnet publish -c Release -o publish && cd publish && zip -r ../functions.zip .)"
  echo "   Requiere el SCM abierto a la IP del operador: IP_PUBLICACION_SCM=<ip> scripts/s12_endurecer.sh (y repetirlo sin la variable al terminar)."
  az functionapp deployment source config-zip -g "$RG" -n "$FUNC_APP" --src "$PAQUETE"
fi

echo "Listo. Revisar ejecuciones en Application Insights (consultas en docs/consultas_kql_s10.kql)."
