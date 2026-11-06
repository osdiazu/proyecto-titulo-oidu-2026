#!/usr/bin/env bash
# =============================================================================
# s12_endurecer.sh - Proyecto APT Cobranza Automatizada (Evidencia S12)
# Aplica configuraciones de endurecimiento sobre recursos EXISTENTES con
# operaciones de actualizacion parcial (no reemplaza su configuracion completa).
# Actualizado el 06-11-2026 por ADR-001 (autenticacion propia, sin Easy Auth) y
# por el hallazgo SEG-H08 (docs/seguridad/politica_credenciales_y_accesos.md).
#
# Este script SOLO cierra o mantiene cerrado: nunca abre puertos, nunca habilita
# acceso publico y nunca agrega reglas de permiso a la Web App principal.
#
# Orden recomendado (CLAUDE.md regla 7):
#   1. Desplegar infra/main.bicep con ipOperador VACIO (cierre de la ventana).
#   2. (Opcional, D11 aprobado) desplegar infra/modulos/seguridad_perimetral.bicep.
#   3. Ejecutar este script. Debe reaplicarse despues de CADA despliegue de main.
#   4. Ejecutar scripts/s12_verificar_seguridad.sh y registrar la matriz.
#
# Que cierra (SEG-H08):
#   - Key Vault: publicNetworkAccess Disabled, defaultAction Deny y SIN ipRules.
#   - Azure SQL: sin acceso publico y sin la regla de firewall operador-temporal.
#   - Si main.bicep se vuelve a desplegar con ipOperador con valor, ambos se reabren
#     a esa IP: la ventana se cierra con un nuevo despliegue con ipOperador vacio
#     seguido de este script.
#
# Regla de transicion (ADR-001, seccion 5.11). Variable ESTADO_TRANSICION:
#   vigente               (por defecto) La Web App queda con entrada por defecto Deny.
#                         El sitio SCM de la Web App queda SIN reglas de permiso: la
#                         API no se puede publicar (refuerzo tecnico de la regla 1).
#   publicacion-aprobada  La Web App sigue con entrada Deny (la restriccion se mantiene
#                         hasta que un humano la levante). El SCM de la Web App admite
#                         IP_PUBLICACION_SCM para publicar. Exige APROBACION_QA con la
#                         ruta del informe de qa (APROBADO o APROBADO CON OBSERVACIONES).
#   levantada             El script deja de forzar Deny en la Web App principal (no la
#                         abre: la apertura la define infra/main.bicep). Exige
#                         APROBACION_LEVANTAMIENTO con la ruta de la evidencia humana
#                         (plantilla docs/seguridad/plantilla_levantamiento_transicion.md).
#
# Sitio SCM (Kudu, publicacion) - decision de seguridad (ADR-001 5.11, regla 3):
#   - scmIpSecurityRestrictionsUseMain=false: el SCM NO hereda las reglas del sitio
#     principal. Si heredara, levantar la transicion (o abrir la API detras del WAF)
#     abriria tambien Kudu, que permite leer el sistema de archivos y las variables
#     del sitio.
#   - scmIpSecurityRestrictionsDefaultAction=Deny en la Web App y en la Function App.
#   - La unica regla de permiso admitida es operador-publicacion con la IP de
#     IP_PUBLICACION_SCM, y solo durante la ventana de publicacion. Sin esa variable
#     el script ELIMINA operador-publicacion (cierre de la ventana).
#   - Se usa IP_PUBLICACION_SCM y no IP_OPERADOR a proposito: IP_OPERADOR suele quedar
#     exportada desde infra/entorno.local.env y abriria Kudu sin intencion.
#
# CERRAR_API_PUBLICA=si (solo con D11/WAF aprobado y probado) deja la API accesible
# SOLO por el Private Endpoint; de lo contrario los usuarios pierden el panel.
# =============================================================================
set -euo pipefail

RG="${RG:?Definir RG}"
WEB_APP="${WEB_APP:?Definir WEB_APP}"
FUNC_APP="${FUNC_APP:?Definir FUNC_APP}"
SQL_SERVER="${SQL_SERVER:?Definir SQL_SERVER}"
STORAGE="${STORAGE:?Definir STORAGE (cuenta de la Function App)}"
KV_NAME="${KV_NAME:?Definir KV_NAME}"
IP_PUBLICACION_SCM="${IP_PUBLICACION_SCM:-}"     # IP publica (o /32) del operador SOLO durante la publicacion
ESTADO_TRANSICION="${ESTADO_TRANSICION:-vigente}"
APROBACION_QA="${APROBACION_QA:-}"
APROBACION_LEVANTAMIENTO="${APROBACION_LEVANTAMIENTO:-}"
CERRAR_API_PUBLICA="${CERRAR_API_PUBLICA:-no}"

# ---------------------------------------------------------------------------
# Validaciones previas (antes de modificar nada)
# ---------------------------------------------------------------------------
case "$ESTADO_TRANSICION" in
  vigente) ;;
  publicacion-aprobada)
    if [[ -z "$APROBACION_QA" || ! -f "$APROBACION_QA" ]]; then
      echo "ERROR: ESTADO_TRANSICION=publicacion-aprobada exige APROBACION_QA con la ruta de un informe de qa existente." >&2
      exit 2
    fi
    # Se exige una linea de veredicto ("Veredicto ...:" o "... general:") con APROBADO y
    # ninguna linea de veredicto con RECHAZADO. Ante la duda, el script no continua.
    if ! grep -qiE "(veredicto|general)[^:]*:[[:space:]*]*APROBADO" "$APROBACION_QA" \
       || grep -qiE "(veredicto|general)[^:]*:[[:space:]*]*RECHAZADO" "$APROBACION_QA"; then
      echo "ERROR: el informe ${APROBACION_QA} no contiene un veredicto APROBADO (o contiene uno RECHAZADO)." >&2
      exit 2
    fi ;;
  levantada)
    if [[ -z "$APROBACION_LEVANTAMIENTO" || ! -f "$APROBACION_LEVANTAMIENTO" ]]; then
      echo "ERROR: ESTADO_TRANSICION=levantada exige APROBACION_LEVANTAMIENTO con la ruta de la evidencia de aprobacion humana." >&2
      exit 2
    fi
    if ! grep -qE "^\| *Aprobado por *\| *[^| ]" "$APROBACION_LEVANTAMIENTO"; then
      echo "ERROR: ${APROBACION_LEVANTAMIENTO} no registra quien aprueba (fila 'Aprobado por' vacia)." >&2
      exit 2
    fi ;;
  *)
    echo "ERROR: ESTADO_TRANSICION debe ser vigente, publicacion-aprobada o levantada." >&2
    exit 2 ;;
esac

if [[ -n "${IP_OPERADOR:-}" ]]; then
  echo "AVISO: IP_OPERADOR tiene valor en esta terminal. Este script la IGNORA (no abre nada con ella)."
  echo "       Si main.bicep se desplego con ipOperador, la ventana NO esta cerrada: volver a desplegar con ipOperador vacio y repetir este script."
fi

# Elimina todas las reglas de permiso del SCM con nombre operador-publicacion.
cerrar_scm_operador () {
  local APP="$1" TIPO="$2" cuenta
  cuenta=$(az "$TIPO" config access-restriction show -g "$RG" -n "$APP" \
             --query "length(scmIpSecurityRestrictions[?name=='operador-publicacion'])" -o tsv 2>/dev/null | tr -d '\r' || echo 0)
  while [[ "${cuenta:-0}" -gt 0 ]]; do
    az "$TIPO" config access-restriction remove -g "$RG" -n "$APP" --scm-site true \
       --rule-name operador-publicacion --output none
    cuenta=$((cuenta-1))
  done
}

endurecer_app () {
  local APP="$1" TIPO="$2" PERMITIR_SCM="$3"   # TIPO: webapp | functionapp ; PERMITIR_SCM: si | no
  local CFG
  CFG="$(az "$TIPO" show -g "$RG" -n "$APP" --query id -o tsv | tr -d '\r')/config/web"

  echo "== ${APP}: HTTPS, TLS 1.2, sin FTP, trafico saliente por la VNet"
  az "$TIPO" update -g "$RG" -n "$APP" --set httpsOnly=true --output none
  az "$TIPO" config set -g "$RG" -n "$APP" --min-tls-version 1.2 --ftps-state Disabled --output none
  az resource update --ids "$CFG" \
     --set properties.vnetRouteAllEnabled=true properties.scmMinTlsVersion=1.2 --output none

  echo "== ${APP}: sitio SCM independiente del principal y con accion por defecto Deny"
  az resource update --ids "$CFG" \
     --set properties.scmIpSecurityRestrictionsUseMain=false properties.scmIpSecurityRestrictionsDefaultAction=Deny --output none

  # Se elimina siempre la regla anterior para no acumular IP de sesiones previas.
  cerrar_scm_operador "$APP" "$TIPO"
  if [[ "$PERMITIR_SCM" == "si" && -n "$IP_PUBLICACION_SCM" ]]; then
    echo "== ${APP}: SCM abierto SOLO a IP_PUBLICACION_SCM (regla operador-publicacion). Repetir este script sin esa variable al terminar de publicar."
    az "$TIPO" config access-restriction add -g "$RG" -n "$APP" --scm-site true \
       --rule-name operador-publicacion --action Allow --ip-address "$IP_PUBLICACION_SCM" --priority 100 --output none
  else
    echo "== ${APP}: SCM sin reglas de permiso"
  fi
}

# ---------------------------------------------------------------------------
# Function App (los jobs no reciben solicitudes HTTP)
# ---------------------------------------------------------------------------
endurecer_app "$FUNC_APP" functionapp si
echo "== ${FUNC_APP}: sin trafico de entrada publico"
az resource update --ids "$(az functionapp show -g "$RG" -n "$FUNC_APP" --query id -o tsv | tr -d '\r')/config/web" \
   --set properties.ipSecurityRestrictionsDefaultAction=Deny --output none

# ---------------------------------------------------------------------------
# Web App (API) y regla de transicion ADR-001 5.11
# ---------------------------------------------------------------------------
if [[ "$ESTADO_TRANSICION" == "vigente" ]]; then
  endurecer_app "$WEB_APP" webapp no
  if [[ -n "$IP_PUBLICACION_SCM" ]]; then
    echo "   (IP_PUBLICACION_SCM ignorada en la Web App: con la transicion vigente la API no se publica, ADR-001 5.11 regla 1)"
  fi
else
  endurecer_app "$WEB_APP" webapp si
fi

WEB_CFG="$(az webapp show -g "$RG" -n "$WEB_APP" --query id -o tsv | tr -d '\r')/config/web"
if [[ "$CERRAR_API_PUBLICA" == "si" ]]; then
  echo "== ${WEB_APP}: entrada publica denegada (solo Private Endpoint / Application Gateway, D11)"
  az resource update --ids "$WEB_CFG" --set properties.ipSecurityRestrictionsDefaultAction=Deny --output none
elif [[ "$ESTADO_TRANSICION" != "levantada" ]]; then
  echo "== ${WEB_APP}: regla de transicion ADR-001 5.11 vigente: entrada por defecto Deny (solo la regla de ipOperador definida en main.bicep)"
  az resource update --ids "$WEB_CFG" --set properties.ipSecurityRestrictionsDefaultAction=Deny --output none
  if [[ -z "${IP_OPERADOR:-}" ]]; then
    PERMISOS=$(az resource show --ids "$WEB_CFG" \
                 --query "length(properties.ipSecurityRestrictions[?action=='Allow' && ipAddress!='Any'])" -o tsv 2>/dev/null | tr -d '\r' || echo "?")
    if [[ "$PERMISOS" != "0" ]]; then
      echo "   AVISO: la Web App tiene ${PERMISOS} regla(s) de permiso con la ventana cerrada. Revisar: main.bicep debe dejarla sin reglas con ipOperador vacio."
    fi
  fi
else
  echo "== ${WEB_APP}: transicion levantada (evidencia: ${APROBACION_LEVANTAMIENTO})."
  echo "   La entrada publica queda como la define infra/main.bicep, protegida por autenticacion propia (sin MFA) hasta desplegar el WAF (D11)."
fi

# ---------------------------------------------------------------------------
# Azure SQL (SEG-H08)
# ---------------------------------------------------------------------------
echo "== Azure SQL: TLS minimo 1.2 y sin acceso publico"
az sql server update -g "$RG" -n "$SQL_SERVER" --minimal-tls-version 1.2 --enable-public-network false --output none

if az sql server firewall-rule show -g "$RG" -s "$SQL_SERVER" -n operador-temporal --output none 2>/dev/null; then
  echo "== Azure SQL: eliminando la regla de firewall operador-temporal"
  az sql server firewall-rule delete -g "$RG" -s "$SQL_SERVER" -n operador-temporal --output none
else
  echo "== Azure SQL: sin regla operador-temporal"
fi
RESTO_SQL=$(az sql server firewall-rule list -g "$RG" -s "$SQL_SERVER" --query "length(@)" -o tsv 2>/dev/null | tr -d '\r' || echo "?")
if [[ "$RESTO_SQL" != "0" ]]; then
  echo "   AVISO: quedan ${RESTO_SQL} regla(s) de firewall en SQL que no crea main.bicep. No se eliminan automaticamente: revisar y registrar."
fi

# ---------------------------------------------------------------------------
# Key Vault (SEG-H08): sin acceso publico y sin ipRules
# ---------------------------------------------------------------------------
echo "== Key Vault: eliminando ipRules (no se muestran las IP)"
mapfile -t REGLAS_KV < <(az keyvault network-rule list -g "$RG" -n "$KV_NAME" --query "ipRules[].value" -o tsv 2>/dev/null | tr -d '\r')
for ip in "${REGLAS_KV[@]}"; do
  if [[ -n "$ip" ]]; then
    az keyvault network-rule remove -g "$RG" -n "$KV_NAME" --ip-address "$ip" --output none
  fi
done
echo "   ipRules eliminadas: ${#REGLAS_KV[@]}"
echo "== Key Vault: acceso publico Disabled y accion por defecto Deny"
az keyvault update -g "$RG" -n "$KV_NAME" --public-network-access Disabled --default-action Deny --output none

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
echo "== Storage: TLS 1.2, sin acceso anonimo a blobs, sin clave compartida, sin acceso publico"
az storage account update -g "$RG" -n "$STORAGE" --min-tls-version TLS1_2 \
   --allow-blob-public-access false --allow-shared-key-access false \
   --public-network-access Disabled --default-action Deny --output none

echo "Listo. Ejecutar scripts/s12_verificar_seguridad.sh"
