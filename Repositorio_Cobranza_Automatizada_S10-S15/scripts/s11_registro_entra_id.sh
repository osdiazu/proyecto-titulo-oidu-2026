#!/usr/bin/env bash
# =============================================================================
# s11_registro_entra_id.sh - Proyecto APT Cobranza Automatizada (Evidencia S11)
# Crea el registro de aplicacion de Entra ID para la API interna con tres roles:
#   Ventas.Consulta   : fuerza de ventas (consulta de estado de clientes)
#   Finanzas.Consulta : Finanzas y Tesoreria (consulta de clientes, panel de cartera)
#   TI.Operacion      : area de TI (historial de sincronizaciones)
# Guarda el secreto de cliente en Key Vault y exige asignacion de rol para ingresar.
#
# Requisitos: rol de Entra ID que permita registrar aplicaciones (por ejemplo
# Application Developer) y Key Vault Secrets Officer en el Key Vault.
# Nota de licenciamiento: con Entra ID Free los roles se asignan a USUARIOS; la
# asignacion a GRUPOS requiere Entra ID P1 o P2 (no incluido en la estimacion de costos).
# =============================================================================
set -euo pipefail

NOMBRE_APP="${NOMBRE_APP:-Cobranza-API-Interna}"
HOST_API="${HOST_API:?Definir HOST_API (ej. <webapp>.azurewebsites.net o el dominio publicado en el Application Gateway)}"
KV_NAME="${KV_NAME:?Definir KV_NAME}"
ASIGNACIONES="${ASIGNACIONES:-asignaciones_roles.csv}"   # formato: upn,rol (sin encabezado)

uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

cat > /tmp/roles_cobranza.json <<JSON
[
  {"allowedMemberTypes":["User"],"description":"Consulta del estado financiero de clientes","displayName":"Ventas - Consulta","isEnabled":true,"id":"$(uuid)","value":"Ventas.Consulta"},
  {"allowedMemberTypes":["User"],"description":"Consulta de clientes y panel de cartera","displayName":"Finanzas - Consulta","isEnabled":true,"id":"$(uuid)","value":"Finanzas.Consulta"},
  {"allowedMemberTypes":["User"],"description":"Historial de sincronizaciones y operacion","displayName":"TI - Operacion","isEnabled":true,"id":"$(uuid)","value":"TI.Operacion"}
]
JSON

echo "== 1. Registro de aplicacion"
APP_ID=$(az ad app create \
  --display-name "$NOMBRE_APP" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "https://${HOST_API}/.auth/login/aad/callback" \
  --enable-id-token-issuance true \
  --app-roles @/tmp/roles_cobranza.json \
  --query appId -o tsv)
az ad app update --id "$APP_ID" --identifier-uris "api://${APP_ID}"
echo "Application (client) ID: $APP_ID"

echo "== 2. Entidad de servicio con asignacion obligatoria"
SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
az ad sp update --id "$SP_ID" --set appRoleAssignmentRequired=true

echo "== 3. Secreto de cliente en Key Vault (vigencia 1 anio; registrar fecha de rotacion)"
SECRETO=$(az ad app credential reset --id "$APP_ID" --display-name easyauth --years 1 --query password -o tsv)
az keyvault secret set --vault-name "$KV_NAME" -n easyauth-client-secret --value "$SECRETO" --output none
unset SECRETO

echo "== 4. Asignacion de roles a usuarios desde $ASIGNACIONES"
if [[ -f "$ASIGNACIONES" ]]; then
  while IFS=, read -r UPN ROL; do
    [[ -z "$UPN" ]] && continue
    USR=$(az ad user show --id "$UPN" --query id -o tsv)
    ROL_ID=$(az ad sp show --id "$SP_ID" --query "appRoles[?value=='${ROL}'].id | [0]" -o tsv)
    az rest --method POST \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/appRoleAssignedTo" \
      --body "{\"principalId\":\"${USR}\",\"resourceId\":\"${SP_ID}\",\"appRoleId\":\"${ROL_ID}\"}" --output none
    echo "  asignado ${ROL} a ${UPN}"
  done < "$ASIGNACIONES"
else
  echo "  (sin archivo de asignaciones; asignar roles en Entra ID > Aplicaciones empresariales)"
fi

echo "Usar clientId=${APP_ID} en infra/modulos/autenticacion_api.bicep"
