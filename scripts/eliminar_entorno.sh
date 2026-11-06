#!/usr/bin/env bash
# =============================================================================
# eliminar_entorno.sh - Proyecto APT Cobranza Automatizada
# Elimina el grupo de recursos del entorno (modelo de costos: desplegar, tomar
# evidencias, eliminar y volver a desplegar con infra/main.bicep).
#
# SOLO LO EJECUTA UN HUMANO. Ningun agente de Claude Code ejecuta este script
# (ni siquiera con --dry-run sin pedirlo): .claude/agents/devops.md prohibe al
# agente ejecutar az group delete.
# ACCION DESTRUCTIVA: requiere confirmacion explicita de un integrante humano
# (CLAUDE.md, regla 5). Probar primero con --dry-run.
#
# Uso:
#   export SUBSCRIPTION_ID_ESPERADA=<id de la suscripcion del proyecto>   # obligatorio para borrar
#   scripts/eliminar_entorno.sh --dry-run            # solo inventario, no borra nada
#   scripts/eliminar_entorno.sh                      # pide escribir el nombre del grupo
#   RG=otro-rg scripts/eliminar_entorno.sh --dry-run
#
# SUBSCRIPTION_ID_ESPERADA: el script compara la suscripcion activa de la CLI con
# este valor y se detiene si no coinciden (en --dry-run solo avisa si no esta
# definida). El ID real va en infra/entorno.local.env (no versionado), nunca aqui.
#
# Que queda DESPUES de eliminar el grupo (no lo borra este script):
#   - Key Vault: queda en estado soft-deleted 90 dias y, por la proteccion de
#     purga, NO se puede purgar; su nombre queda reservado. Por eso este script
#     incrementa CICLO_KV en infra/entorno.local.env: el siguiente despliegue
#     crea un vault con nombre nuevo. El vault eliminado no genera cobro.
#   - Respaldos LTR de Azure SQL (P8W / P12M): sobreviven a la eliminacion del
#     servidor y SE SIGUEN COBRANDO hasta su vencimiento. Este script solo los
#     lista; eliminarlos (az sql db ltr-backup delete) es decision del equipo.
#   - Log Analytics: soft-delete 14 dias. Si se vuelve a crear con el mismo
#     nombre en el mismo grupo y region, Azure lo recupera (con sus datos).
#
# Despues de eliminar, para volver a desplegar:
#   set -a; source infra/entorno.local.env; set +a   (recarga CICLO_KV nuevo)
#   az group create -n "$RG" -l brazilsouth
#   (luego what-if y despliegue de infra/main.bicep, y s12_endurecer.sh)
# =============================================================================
set -euo pipefail

RG="${RG:-rg-cobranza-apt}"
ENV_LOCAL="${ENV_LOCAL:-$(cd "$(dirname "$0")/.." && pwd)/infra/entorno.local.env}"
DRY_RUN=no

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=si ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "Argumento no reconocido: $arg" >&2; exit 2 ;;
  esac
done

echo "== 0. Contexto"
SUB=$(az account show --query name -o tsv | tr -d '\r')
SUB_ID=$(az account show --query id -o tsv | tr -d '\r')
echo "Suscripcion: ${SUB} (${SUB_ID:0:4}...${SUB_ID: -4})"
ESPERADA="${SUBSCRIPTION_ID_ESPERADA:-}"
ESPERADA="${ESPERADA//$'\r'/}"
if [[ -z "$ESPERADA" ]]; then
  if [[ "$DRY_RUN" == "si" ]]; then
    echo "AVISO: SUBSCRIPTION_ID_ESPERADA no esta definida; sin ella no se permite el borrado real."
  else
    echo "Defina SUBSCRIPTION_ID_ESPERADA (ID de la suscripcion del proyecto) antes de eliminar." >&2
    exit 1
  fi
elif [[ "${SUB_ID,,}" != "${ESPERADA,,}" ]]; then
  echo "La suscripcion activa (${SUB_ID:0:4}...${SUB_ID: -4}) no coincide con SUBSCRIPTION_ID_ESPERADA" >&2
  echo "(${ESPERADA:0:4}...${ESPERADA: -4}). Use az account set --subscription <id>. Operacion cancelada." >&2
  exit 1
else
  echo "Suscripcion activa = SUBSCRIPTION_ID_ESPERADA: OK"
fi
if [[ "$(az group exists -n "$RG" | tr -d '\r')" != "true" ]]; then
  echo "El grupo de recursos ${RG} no existe. Nada que eliminar."
  exit 0
fi
UBICACION=$(az group show -n "$RG" --query location -o tsv | tr -d '\r')
echo "Grupo: ${RG} (${UBICACION})"

echo "== 1. Inventario de recursos que se eliminaran"
az resource list -g "$RG" --query "[].{tipo:type, nombre:name}" -o table

echo "== 2. Key Vault (quedaran soft-deleted 90 dias, sin posibilidad de purga)"
KVS=$(az keyvault list -g "$RG" --query "[].name" -o tsv | tr -d '\r')
if [[ -n "$KVS" ]]; then echo "$KVS"; else echo "(ninguno)"; fi

echo "== 3. Respaldos LTR de Azure SQL (sobreviven y siguen costando)"
for SRV in $(az sql server list -g "$RG" --query "[].name" -o tsv | tr -d '\r'); do
  echo "-- Servidor ${SRV}:"
  az sql db ltr-backup list -l "$UBICACION" -s "$SRV" \
     --query "[].{base:databaseName, creado:backupTime, vence:backupExpirationTime}" -o table 2>/dev/null \
     || echo "   (no se pudieron listar)"
done

if [[ "$DRY_RUN" == "si" ]]; then
  echo
  echo "MODO --dry-run: no se elimino nada."
  echo "Se ejecutaria: az group delete -n ${RG} --yes"
  echo "Y se incrementaria CICLO_KV en ${ENV_LOCAL} (si existe)."
  exit 0
fi

echo
echo "ATENCION: se eliminara el grupo ${RG} y TODOS sus recursos."
read -r -p "Escriba el nombre exacto del grupo para confirmar: " RESPUESTA
if [[ "$RESPUESTA" != "$RG" ]]; then
  echo "Confirmacion no coincide. Operacion cancelada."
  exit 1
fi

echo "== 4. Eliminando ${RG} (puede tardar varios minutos)"
az group delete -n "$RG" --yes

echo "== 5. Ciclo del Key Vault para el proximo despliegue"
if [[ -f "$ENV_LOCAL" ]]; then
  ACTUAL=$(grep -E '^CICLO_KV=' "$ENV_LOCAL" | tail -1 | cut -d= -f2 | tr -d '\r' || true)
  ACTUAL="${ACTUAL:-1}"
  if [[ "$ACTUAL" =~ ^[0-9]+$ ]]; then
    NUEVO=$((ACTUAL + 1))
    if grep -qE '^CICLO_KV=' "$ENV_LOCAL"; then
      sed -i.bak -E "s/^CICLO_KV=.*/CICLO_KV=${NUEVO}/" "$ENV_LOCAL" && rm -f "${ENV_LOCAL}.bak"
    else
      echo "CICLO_KV=${NUEVO}" >> "$ENV_LOCAL"
    fi
    echo "CICLO_KV: ${ACTUAL} -> ${NUEVO} (${ENV_LOCAL})"
    echo "IMPORTANTE: el archivo cambio, pero no la variable de esta ni de otras terminales."
    if [[ -n "${CICLO_KV:-}" ]]; then
      echo "En esta sesion CICLO_KV sigue exportada con el valor anterior (${CICLO_KV})."
    fi
    echo "Antes del proximo what-if o despliegue, vuelva a cargar el archivo:"
    echo "  set -a; source infra/entorno.local.env; set +a"
  else
    echo "CICLO_KV tiene un valor no numerico (${ACTUAL}); actualizarlo a mano."
  fi
else
  echo "No existe ${ENV_LOCAL}. Antes del proximo despliegue exporte CICLO_KV con un valor"
  echo "distinto de los ya usados (si no, el despliegue falla: el nombre del vault esta reservado)."
fi

echo "== 6. Estado posterior"
echo "-- Key Vault eliminados (soft-delete):"
az keyvault list-deleted --query "[].{nombre:name, purgaProgramada:properties.scheduledPurgeDate}" -o table || true
echo "-- Respaldos LTR restantes en ${UBICACION} (siguen costando):"
az sql db ltr-backup list -l "$UBICACION" --query "[].{servidor:serverName, base:databaseName, vence:backupExpirationTime}" -o table 2>/dev/null || true
echo
echo "Para volver a desplegar: az group create -n ${RG} -l ${UBICACION}; luego what-if y despliegue."
