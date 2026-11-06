#!/usr/bin/env bash
# =============================================================================
# s12_verificar_seguridad.sh - Proyecto APT Cobranza Automatizada (Evidencia S12)
# Lee la configuracion real de los recursos y la compara con lo esperado.
# Genera matriz_seguridad_<fecha>.csv para adjuntar a la evidencia.
# Solo lectura: no modifica recursos.
# Actualizado el 06-11-2026 por ADR-001 (tabla 6.2) y SEG-H08.
#
# Resultados posibles: CUMPLE, NO CUMPLE, NO VERIFICADO (el control no se pudo
# leer; por ejemplo SEG-KV-04 necesita acceso de red al plano de datos de Key
# Vault, que esta cerrado fuera de la ventana del operador).
#
# La matriz NO contiene Object IDs, IP publicas, nombres de secretos ni valores:
# solo conteos y estados. Los IDs de identidades se usan en memoria.
#
# Variables:
#   RG WEB_APP FUNC_APP SQL_SERVER SQL_DB KV_NAME STORAGE   obligatorias
#   ESTADO_TRANSICION  vigente (por defecto) | publicacion-aprobada | levantada
#   OPERADOR_OBJECT_ID opcional: habilita SEG-KV-07 (solo el operador con
#                      Secrets Officer). No se escribe en la matriz.
# =============================================================================
set -uo pipefail

RG="${RG:?Definir RG}"; WEB_APP="${WEB_APP:?}"; FUNC_APP="${FUNC_APP:?}"
SQL_SERVER="${SQL_SERVER:?}"; SQL_DB="${SQL_DB:?}"; KV_NAME="${KV_NAME:?}"; STORAGE="${STORAGE:?}"
ESTADO_TRANSICION="${ESTADO_TRANSICION:-vigente}"
OPERADOR_OBJECT_ID="${OPERADOR_OBJECT_ID:-}"
CONTENEDOR_DP="dataprotection-keys"            # ADR-001 5.5
CLAVE_DP="dataprotection-cobranza-api"         # ADR-001 5.5
SECRETO_ACS="acs-connection-string"

SALIDA="matriz_seguridad_$(date +%Y%m%d_%H%M).csv"
echo "id;control;esperado;obtenido;resultado" > "$SALIDA"
n=0; ok=0; nv=0

# chk "id" "control" "esperado" "obtenido"
chk () {
  n=$((n+1)); local r="NO CUMPLE"
  if [[ "$4" == "error" || "$4" == "NO VERIFICADO"* ]]; then
    r="NO VERIFICADO"; nv=$((nv+1))
  elif [[ "${4,,}" == "${3,,}" ]]; then
    r="CUMPLE"; ok=$((ok+1))
  fi
  printf '%s;%s;%s;%s;%s\n' "$1" "$2" "$3" "$4" "$r" | tee -a "$SALIDA"
}
q () { "$@" 2>/dev/null | tr -d '\r' || echo "error"; }
# Valor vacio o null de la CLI -> texto dado (p. ej. propiedades nunca configuradas).
o_si_vacio () { local v="$1"; if [[ -z "$v" || "$v" == "null" || "$v" == "None" ]]; then echo "$2"; else echo "$v"; fi; }

WEB_ID=$(q az webapp show -g "$RG" -n "$WEB_APP" --query id -o tsv)
FUNC_ID=$(q az functionapp show -g "$RG" -n "$FUNC_APP" --query id -o tsv)
WEB_CFG="${WEB_ID}/config/web"
FUNC_CFG="${FUNC_ID}/config/web"
KV_ID=$(q az keyvault show -n "$KV_NAME" --query id -o tsv)
API_PID=$(q az webapp identity show -g "$RG" -n "$WEB_APP" --query principalId -o tsv)
FUNC_PID=$(q az functionapp identity show -g "$RG" -n "$FUNC_APP" --query principalId -o tsv)

# ---------------------------------------------------------------------------
# Controles S12 originales (los id SEG-01 a SEG-22 se conservan)
# ---------------------------------------------------------------------------
chk SEG-01 "API: solo HTTPS"                       "true"     "$(q az webapp show -g "$RG" -n "$WEB_APP" --query httpsOnly -o tsv)"
chk SEG-02 "API: TLS minimo"                       "1.2"      "$(q az resource show --ids "$WEB_CFG" --query properties.minTlsVersion -o tsv)"
chk SEG-03 "API: FTP deshabilitado"                "Disabled" "$(q az resource show --ids "$WEB_CFG" --query properties.ftpsState -o tsv)"
chk SEG-04 "API: SCM con accion por defecto Deny"  "Deny"     "$(q az resource show --ids "$WEB_CFG" --query properties.scmIpSecurityRestrictionsDefaultAction -o tsv)"
# SEG-05 (ADR-001 6.2): Easy Auth NO debe estar activo; si lo estuviera interceptaria
# las solicitudes. Un authsettingsV2 nunca configurado devuelve enabled=false o vacio
# (comportamiento exacto: PENDIENTE verificar en Azure); vacio se informa como false.
EA2=$(q az resource show --ids "${WEB_ID}/config/authsettingsV2" --query properties.platform.enabled -o tsv)
chk SEG-05 "API: Easy Auth deshabilitado (autenticacion propia ADR-001)" "false" "$(o_si_vacio "$EA2" false)"
chk SEG-06 "API: identidad administrada"           "SystemAssigned" "$(q az webapp identity show -g "$RG" -n "$WEB_APP" --query type -o tsv)"
chk SEG-07 "Functions: solo HTTPS"                 "true"     "$(q az functionapp show -g "$RG" -n "$FUNC_APP" --query httpsOnly -o tsv)"
chk SEG-08 "Functions: TLS minimo"                 "1.2"      "$(q az resource show --ids "$FUNC_CFG" --query properties.minTlsVersion -o tsv)"
chk SEG-09 "Functions: entrada publica denegada"   "Deny"     "$(q az resource show --ids "$FUNC_CFG" --query properties.ipSecurityRestrictionsDefaultAction -o tsv)"
chk SEG-10 "Functions: todo el trafico por VNet"   "true"     "$(q az resource show --ids "$FUNC_CFG" --query properties.vnetRouteAllEnabled -o tsv)"
chk SEG-11 "SQL: acceso publico"                   "Disabled" "$(q az sql server show -g "$RG" -n "$SQL_SERVER" --query publicNetworkAccess -o tsv)"
chk SEG-12 "SQL: TLS minimo"                       "1.2"      "$(q az sql server show -g "$RG" -n "$SQL_SERVER" --query minimalTlsVersion -o tsv)"
chk SEG-13 "SQL: solo autenticacion Entra ID"      "true"     "$(q az sql server ad-only-auth get -g "$RG" -n "$SQL_SERVER" --query azureAdOnlyAuthentication -o tsv)"
chk SEG-14 "SQL: TDE habilitado"                   "Enabled"  "$(q az sql db tde show -g "$RG" -s "$SQL_SERVER" -d "$SQL_DB" --query state -o tsv)"
chk SEG-15 "SQL: auditoria habilitada"             "Enabled"  "$(q az sql server audit-policy show -g "$RG" -n "$SQL_SERVER" --query state -o tsv)"
chk SEG-16 "Key Vault: autorizacion RBAC"          "true"     "$(q az keyvault show -n "$KV_NAME" --query properties.enableRbacAuthorization -o tsv)"
chk SEG-17 "Key Vault: proteccion de purga"        "true"     "$(q az keyvault show -n "$KV_NAME" --query properties.enablePurgeProtection -o tsv)"
chk SEG-18 "Key Vault: acceso publico"             "Disabled" "$(q az keyvault show -n "$KV_NAME" --query properties.publicNetworkAccess -o tsv)"
chk SEG-19 "Storage: TLS minimo"                   "TLS1_2"   "$(q az storage account show -g "$RG" -n "$STORAGE" --query minimumTlsVersion -o tsv)"
chk SEG-20 "Storage: sin acceso anonimo a blobs"   "false"    "$(q az storage account show -g "$RG" -n "$STORAGE" --query allowBlobPublicAccess -o tsv)"
chk SEG-21 "Storage: sin clave compartida"         "false"    "$(q az storage account show -g "$RG" -n "$STORAGE" --query allowSharedKeyAccess -o tsv)"
chk SEG-22 "Private Endpoints no aprobados"        "0"        "$(q az network private-endpoint list -g "$RG" --query "length([?privateLinkServiceConnections[0].privateLinkServiceConnectionState.status!='Approved'])" -o tsv)"

# ---------------------------------------------------------------------------
# Complementos de exposicion publica, SCM y red (06-11-2026)
# ---------------------------------------------------------------------------
chk SEG-23 "Storage: acceso publico"               "Disabled" "$(q az storage account show -g "$RG" -n "$STORAGE" --query publicNetworkAccess -o tsv)"
chk SEG-24 "Functions: SCM con accion por defecto Deny" "Deny" "$(q az resource show --ids "$FUNC_CFG" --query properties.scmIpSecurityRestrictionsDefaultAction -o tsv)"
chk SEG-25 "API: SCM no hereda reglas del sitio principal" "false" "$(q az resource show --ids "$WEB_CFG" --query properties.scmIpSecurityRestrictionsUseMain -o tsv)"
chk SEG-26 "Functions: SCM no hereda reglas del sitio principal" "false" "$(q az resource show --ids "$FUNC_CFG" --query properties.scmIpSecurityRestrictionsUseMain -o tsv)"
SCM_ALLOW=$(q az webapp config access-restriction show -g "$RG" -n "$WEB_APP" --query "length(scmIpSecurityRestrictions[?action=='Allow' && ipAddress!='Any'])" -o tsv)
chk SEG-27 "API: SCM sin reglas de permiso al cerrar la ventana" "0" "$SCM_ALLOW"
SCM_ALLOW_F=$(q az functionapp config access-restriction show -g "$RG" -n "$FUNC_APP" --query "length(scmIpSecurityRestrictions[?action=='Allow' && ipAddress!='Any'])" -o tsv)
chk SEG-28 "Functions: SCM sin reglas de permiso al cerrar la ventana" "0" "$SCM_ALLOW_F"
chk SEG-29 "nsg-pe: Deny-VNet-Inbound en prioridad 4000" "Deny/4000" \
    "$(q az network nsg rule show -g "$RG" --nsg-name nsg-pe -n Deny-VNet-Inbound --query "join('/', [access, to_string(priority)])" -o tsv)"
chk SEG-30 "nsg-pe: 1433 permitido desde snet-app"  "Allow/10.20.1.0/24/1433" \
    "$(q az network nsg rule show -g "$RG" --nsg-name nsg-pe -n Allow-App-To-SQL --query "join('/', [access, sourceAddressPrefix, destinationPortRange])" -o tsv)"
chk SEG-31 "nsg-pe: 443 permitido desde snet-app"   "Allow/10.20.1.0/24/443" \
    "$(q az network nsg rule show -g "$RG" --nsg-name nsg-pe -n Allow-App-To-KeyVault-Storage --query "join('/', [access, sourceAddressPrefix, destinationPortRange])" -o tsv)"

# Registros A de las zonas DNS privadas (plano de control). La resolucion efectiva
# desde la VNet se prueba aparte (nslookup desde la consola SSH de la Function App).
dns () { q az network private-dns record-set a list -g "$RG" -z "$1" --query "[].aRecords[].ipv4Address | join(',', @)" -o tsv; }
chk SEG-DNS-01 "DNS privado SQL"       "10.20.2.4" "$(dns privatelink.database.windows.net)"
chk SEG-DNS-02 "DNS privado Key Vault" "10.20.2.5" "$(dns privatelink.vaultcore.azure.net)"
chk SEG-DNS-03 "DNS privado blob"      "10.20.2.6" "$(dns privatelink.blob.core.windows.net)"
chk SEG-DNS-04 "DNS privado queue"     "10.20.2.7" "$(dns privatelink.queue.core.windows.net)"
chk SEG-DNS-05 "DNS privado table"     "10.20.2.8" "$(dns privatelink.table.core.windows.net)"

# ---------------------------------------------------------------------------
# ADR-001 tabla 6.2: RBAC, Data Protection, Key Vault, transicion
# ---------------------------------------------------------------------------
# Una sola lectura de asignaciones de la suscripcion (incluye ambitos de grupo de
# recursos y de recurso; no incluye grupos de administracion).
RA=$(q az role assignment list --all --query "[].[principalId, principalType, roleDefinitionName, scope]" -o tsv)
if [[ "$RA" == "error" || -z "$KV_ID" || "$KV_ID" == "error" || "$API_PID" == "error" || "$FUNC_PID" == "error" ]]; then
  RA_OK=no
else
  RA_OK=si
fi
kv_l="${KV_ID,,}"

# Devuelve las lineas "rol<TAB>ambito" de un principal.
asignaciones_de () { printf '%s\n' "$RA" | awk -F'\t' -v p="$1" '$1==p {print $3 "\t" $4}'; }
# 1 si el ambito es el vault, un secreto/clave del vault o un ancestro del vault.
alcanza_kv () { local s="${1,,}"; [[ "$kv_l" == "$s" || "$kv_l" == "$s/"* || "$s" == "$kv_l/"* ]]; }
es_ancestro_o_vault () { local s="${1,,}"; [[ "$kv_l" == "$s" || "$kv_l" == "$s/"* ]]; }

# Clasifica las asignaciones de un rol para un principal segun el sufijo de ambito esperado.
# Salida: "ninguna" | "alcance <sufijo>" | "alcance amplio (N)"
clasificar () {   # clasificar principal rol sufijo
  local total=0 exactas=0 rol scope
  while IFS=$'\t' read -r rol scope; do
    [[ "$rol" == "$2" ]] || continue
    total=$((total+1))
    [[ "${scope,,}" == *"${3,,}" ]] && exactas=$((exactas+1))
  done < <(asignaciones_de "$1")
  if (( total == 0 )); then echo "ninguna"
  elif (( total == exactas )); then echo "alcance ${3}"
  else echo "alcance amplio ($((total-exactas)) de ${total})"; fi
}

if [[ "$RA_OK" == "si" ]]; then
  chk SEG-DP-01 "API: Storage Blob Data Contributor solo en el contenedor ${CONTENEDOR_DP}" \
      "alcance /containers/${CONTENEDOR_DP}" "$(clasificar "$API_PID" "Storage Blob Data Contributor" "/containers/${CONTENEDOR_DP}")"
  chk SEG-DP-02 "API: Key Vault Crypto User solo en la clave ${CLAVE_DP}" \
      "alcance /keys/${CLAVE_DP}" "$(clasificar "$API_PID" "Key Vault Crypto User" "/keys/${CLAVE_DP}")"

  # SEG-KV-01: la API no tiene ningun rol con acceso a secretos sobre el vault.
  c=0
  while IFS=$'\t' read -r rol scope; do
    case "$rol" in "Key Vault Secrets User"|"Key Vault Secrets Officer"|"Key Vault Administrator"|"Key Vault Data Access Administrator"|Owner|Contributor)
      alcanza_kv "$scope" && c=$((c+1)) ;;
    esac
  done < <(asignaciones_de "$API_PID")
  chk SEG-KV-01 "API: sin roles de secretos ni de administracion sobre Key Vault" "0" "$c"

  # SEG-KV-02: Function App con Secrets User SOLO en acs-connection-string.
  chk SEG-KV-02 "Functions: Key Vault Secrets User solo en ${SECRETO_ACS}" \
      "alcance /secrets/${SECRETO_ACS}" "$(clasificar "$FUNC_PID" "Key Vault Secrets User" "/secrets/${SECRETO_ACS}")"
  c=0
  while IFS=$'\t' read -r rol scope; do
    case "$rol" in "Key Vault Secrets Officer"|"Key Vault Administrator"|"Key Vault Data Access Administrator")
      alcanza_kv "$scope" && c=$((c+1)) ;;
    esac
  done < <(asignaciones_de "$FUNC_PID")
  chk SEG-KV-02b "Functions: sin roles de escritura o administracion en Key Vault" "0" "$c"

  # SEG-KV-03: ningun usuario humano con Secrets User sobre el vault completo o un ancestro.
  c=$(printf '%s\n' "$RA" | while IFS=$'\t' read -r pid tipo rol scope; do
        [[ "$tipo" == "User" && "$rol" == "Key Vault Secrets User" ]] && es_ancestro_o_vault "$scope" && echo x
      done | wc -l | tr -d ' ')
  chk SEG-KV-03 "Ningun usuario con Key Vault Secrets User sobre el vault completo" "0" "$c"

  # SEG-KV-07 (opcional): solo el operador con Secrets Officer o Administrator sobre el vault.
  if [[ -n "$OPERADOR_OBJECT_ID" ]]; then
    c=$(printf '%s\n' "$RA" | while IFS=$'\t' read -r pid tipo rol scope; do
          [[ "$tipo" == "User" && "$pid" != "$OPERADOR_OBJECT_ID" ]] || continue
          case "$rol" in "Key Vault Secrets Officer"|"Key Vault Administrator") es_ancestro_o_vault "$scope" && echo x ;; esac
        done | wc -l | tr -d ' ')
    chk SEG-KV-07 "Usuarios distintos del operador con Secrets Officer o Administrator en el vault" "0" "$c"
  fi

  # SEG-DP-03 (parte estatica): condicion ABAC en Storage Blob Data Owner de la Function App.
  COND=$(q az role assignment list --all --query "[?principalId=='${FUNC_PID}' && roleDefinitionName=='Storage Blob Data Owner'].[conditionVersion, condition]" -o tsv)
  if [[ "$COND" == "error" ]]; then cond_r="error"
  elif [[ -z "$COND" ]]; then cond_r="sin asignacion"
  elif grep -q "$CONTENEDOR_DP" <<<"$COND" && grep -q "2.0" <<<"$COND"; then cond_r="condicion 2.0 excluye ${CONTENEDOR_DP}"
  else cond_r="sin condicion sobre ${CONTENEDOR_DP}"; fi
  chk SEG-DP-03a "Functions: Storage Blob Data Owner con condicion ABAC" "condicion 2.0 excluye ${CONTENEDOR_DP}" "$cond_r"
else
  for id in SEG-DP-01 SEG-DP-02 SEG-KV-01 SEG-KV-02 SEG-KV-02b SEG-KV-03 SEG-DP-03a; do
    chk "$id" "Asignaciones RBAC (lectura fallida)" "-" "NO VERIFICADO (no se pudo leer az role assignment list o las identidades)"
  done
fi
# SEG-DP-03 (prueba negativa real con la identidad de la Function App): manual.
chk SEG-DP-03b "Functions: lectura de blobs en ${CONTENEDOR_DP} rechazada (403)" "403" \
    "NO VERIFICADO (prueba manual: docs/seguridad/plantilla_prueba_negativa_abac.md)"

# SEG-KV-04: secretos apikey-* con expiracion y sin vencidos habilitados. Requiere
# acceso al plano de datos (ventana del operador abierta o equipo dentro de la VNet).
SEC=$(az keyvault secret list --vault-name "$KV_NAME" --query "[?starts_with(name,'apikey-')].[to_string(attributes.enabled), to_string(attributes.expires)]" -o tsv 2>/dev/null | tr -d '\r')
st=$?
if [[ $st -ne 0 ]]; then
  chk SEG-KV-04 "Secretos apikey-*: sin expiracion o vencidos habilitados" "0" "NO VERIFICADO (sin acceso al plano de datos de Key Vault)"
else
  ahora=$(date -u +%s); malos=0
  while IFS=$'\t' read -r hab exp; do
    [[ -z "$hab$exp" ]] && continue
    if [[ -z "$exp" || "$exp" == "null" ]]; then malos=$((malos+1)); continue; fi
    t=$(date -u -d "$exp" +%s 2>/dev/null || echo 0)
    if [[ "$hab" == "true" ]] && (( t <= ahora )); then malos=$((malos+1)); fi
  done <<<"$SEC"
  chk SEG-KV-04 "Secretos apikey-*: sin expiracion o vencidos habilitados" "0" "$malos"
fi

DIAG=$(q az monitor diagnostic-settings list --resource "$KV_ID" --query "length([?logs[?categoryGroup=='audit' && enabled]])" -o tsv)
if [[ "$DIAG" =~ ^[0-9]+$ ]]; then (( DIAG > 0 )) && DIAG="existe" || DIAG="no existe"; fi
chk SEG-KV-05 "Key Vault: diagnostico de auditoria (categoryGroup audit) activo" "existe" "$DIAG"

chk SEG-KV-06a "Key Vault: sin ipRules" "0" "$(o_si_vacio "$(q az keyvault show -n "$KV_NAME" --query "length(properties.networkAcls.ipRules || \`[]\`)" -o tsv)" 0)"
chk SEG-KV-06b "SQL: sin regla de firewall operador-temporal" "0" "$(q az sql server firewall-rule list -g "$RG" -s "$SQL_SERVER" --query "length([?name=='operador-temporal'])" -o tsv)"
chk SEG-KV-06c "SQL: sin reglas de firewall (ninguna IP publica permitida)" "0" "$(q az sql server firewall-rule list -g "$RG" -s "$SQL_SERVER" --query "length(@)" -o tsv)"
chk SEG-KV-08 "Key Vault: accion por defecto de red" "Deny" "$(q az keyvault show -n "$KV_NAME" --query properties.networkAcls.defaultAction -o tsv)"

if [[ "$ESTADO_TRANSICION" != "levantada" ]]; then
  chk SEG-TR-01 "API: regla de transicion ADR-001 5.11 (entrada por defecto Deny)" "Deny" \
      "$(q az resource show --ids "$WEB_CFG" --query properties.ipSecurityRestrictionsDefaultAction -o tsv)"
  chk SEG-TR-02 "API: sin reglas de permiso al cerrar la ventana (ipOperador vacio)" "0" \
      "$(q az resource show --ids "$WEB_CFG" --query "length(properties.ipSecurityRestrictions[?action=='Allow' && ipAddress!='Any'])" -o tsv)"
else
  echo "SEG-TR-01;Regla de transicion;-;levantada (ver evidencia de aprobacion);NO APLICA" | tee -a "$SALIDA"
fi

chk SEG-FH-01 "API: ASPNETCORE_FORWARDEDHEADERS_ENABLED" "false" \
    "$(o_si_vacio "$(q az webapp config appsettings list -g "$RG" -n "$WEB_APP" --query "[?name=='ASPNETCORE_FORWARDEDHEADERS_ENABLED'].value | [0]" -o tsv)" "sin ajuste")"
chk SEG-EA-02 "API: sin ajuste MICROSOFT_PROVIDER_AUTHENTICATION_SECRET (Easy Auth obsoleto)" "0" \
    "$(q az webapp config appsettings list -g "$RG" -n "$WEB_APP" --query "length([?name=='MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'])" -o tsv)"

WAF=$(q az network application-gateway waf-policy list -g "$RG" --query "[0].policySettings.mode" -o tsv)
if [[ -n "$WAF" && "$WAF" != "error" ]]; then
  chk SEG-WAF "WAF: modo Prevencion" "Prevention" "$WAF"
else
  echo "SEG-WAF;WAF no desplegado (D11 PENDIENTE);-;-;PENDIENTE" | tee -a "$SALIDA"
fi

echo "Resumen: ${ok} de ${n} controles cumplen; ${nv} no verificados. Archivo: ${SALIDA}"
echo "Cookie, CSRF, limitador y encabezados reenviados: ver scripts/s12_pruebas_red.sh (RED-11 a RED-17)."
