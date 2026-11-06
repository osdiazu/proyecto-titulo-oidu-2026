#!/usr/bin/env bash
# =============================================================================
# s14_simulacro_pitr.sh - Proyecto APT Cobranza Automatizada (Evidencia S14)
# Simulacro DR-01: perdida de datos por error humano y recuperacion con
# Point-In-Time Restore (PITR) de Azure SQL Database. Mide RPO y RTO reales.
#
# Escenario: un operador elimina por error los pedidos DEMO. Se restaura la base
# al instante previo al incidente como una base nueva en el mismo servidor, se
# valida y se redirige la API y la Function App a la base restaurada.
#
# Requisitos:
#  - Datos DEMO cargados (08_datos_prueba.sql) y 10_marcador_rpo.sql ejecutado.
#  - Generador de marcadores corriendo en otra sesion (seccion 2 de 10_marcador_rpo.sql).
#  - go-sqlcmd y Azure CLI con sesion iniciada; acceso de red privada a Azure SQL
#    (equipo dentro de la VNet o acceso publico temporal y controlado, revertido al final).
#  - Ventana acordada: la plataforma queda apuntando a la base restaurada.
# Costo: la base restaurada S0 cuesta USD 0,68 por dia mientras exista.
# =============================================================================
set -euo pipefail

RG="${RG:?}"; SQL_SERVER="${SQL_SERVER:?}"; SQL_DB="${SQL_DB:?}"
WEB_APP="${WEB_APP:?}"; FUNC_APP="${FUNC_APP:?}"
SLO="${SLO:-S0}"
SIMULACRO="${SIMULACRO:-DR-01-$(date -u +%Y%m%d)}"
DB_REST="${SQL_DB}-rest-$(date -u +%Y%m%d%H%M)"
REGISTRO="simulacro_${SIMULACRO}.log"
FQDN="${SQL_SERVER}.database.windows.net"

sq () { sqlcmd -S "tcp:${FQDN},1433" -d "$1" --authentication-method ActiveDirectoryDefault -h -1 -W -Q "SET NOCOUNT ON; $2"; }
marca () { local t; t=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "$t | $1" | tee -a "$REGISTRO"; }
seg () { date -u +%s; }

marca "Inicio del simulacro ${SIMULACRO}. Base origen: ${SQL_DB}"
marca "Pedidos DEMO antes del incidente: $(sq "$SQL_DB" "SELECT COUNT(*) FROM cob.Pedido WHERE NumeroPedido LIKE 'DEMO-%'")"

# --- Incidente simulado -------------------------------------------------------
T_INCIDENTE_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ); T_INCIDENTE=$(seg)
sq "$SQL_DB" "DELETE FROM cob.Pedido WHERE NumeroPedido LIKE 'DEMO-%';"
marca "INCIDENTE: pedidos DEMO eliminados. Pedidos DEMO ahora: $(sq "$SQL_DB" "SELECT COUNT(*) FROM cob.Pedido WHERE NumeroPedido LIKE 'DEMO-%'")"

# --- Restauracion -------------------------------------------------------------
PUNTO=$(date -u -d "${T_INCIDENTE_ISO} - 60 seconds" +%Y-%m-%dT%H:%M:%SZ)
marca "Punto de restauracion solicitado: ${PUNTO} (60 s antes del incidente)"
marca "Punto mas antiguo disponible: $(az sql db show -g "$RG" -s "$SQL_SERVER" -n "$SQL_DB" --query earliestRestoreDate -o tsv)"
T_REST_INI=$(seg)
until az sql db restore -g "$RG" -s "$SQL_SERVER" -n "$SQL_DB" --dest-name "$DB_REST" \
        --time "$PUNTO" --service-objective "$SLO" --output none; do
  marca "Restauracion aun no disponible para ese punto (respaldo de log pendiente); reintento en 2 min"
  sleep 120
done
T_REST_FIN=$(seg)
marca "Base restaurada ${DB_REST} en $(( T_REST_FIN - T_REST_INI )) s"

# --- Validacion ----------------------------------------------------------------
PED=$(sq "$DB_REST" "SELECT COUNT(*) FROM cob.Pedido WHERE NumeroPedido LIKE 'DEMO-%'")
ULT=$(sq "$DB_REST" "SELECT CONVERT(varchar(30), MAX(FechaUtc), 126) FROM ops.MarcadorRpo WHERE Simulacro = '${SIMULACRO}'")
marca "Validacion: pedidos DEMO en base restaurada = ${PED} (esperado 3)"
marca "Ultimo marcador restaurado: ${ULT}"
if [[ -n "$ULT" && "$ULT" != "NULL" ]]; then
  RPO=$(( $(date -u -d "$PUNTO" +%s) - $(date -u -d "${ULT}Z" +%s) ))
  marca "RPO medido (punto solicitado - ultimo marcador): ${RPO} s"
fi

# --- Conmutacion de la plataforma a la base restaurada ------------------------
CS="Server=tcp:${FQDN},1433;Database=${DB_REST};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;"
az webapp config appsettings set -g "$RG" -n "$WEB_APP" --settings "ConnectionStrings__Cobranza=${CS}" --output none
az functionapp config appsettings set -g "$RG" -n "$FUNC_APP" --settings \
   "Cobranza__SqlCobranza=${CS}" "Cobranza__SqlOrigen=${CS}ApplicationIntent=ReadOnly;" --output none
marca "API y Function App apuntan a ${DB_REST} (los usuarios de identidades administradas viajan dentro de la base)"

echo "Verifique ahora /salud de la API y una consulta del panel. Presione ENTER cuando el servicio responda correctamente."
read -r _
T_SERVICIO=$(seg)
marca "Servicio verificado por el operador"
marca "RTO medido (incidente -> servicio restablecido): $(( T_SERVICIO - T_INCIDENTE )) s = $(( (T_SERVICIO - T_INCIDENTE) / 60 )) min"
marca "Metas: RPO < 900 s (15 min); RTO < 14400 s (4 h)"
marca "Pendiente post simulacro: decidir si se mantiene ${DB_REST} o se vuelve a ${SQL_DB} y se elimina la restaurada (costo)."
# ADR-001 4.2 / politica C.3 (06-11-2026): la restauracion no termina sin esta revision.
marca "OBLIGATORIO (ADR-001 4.2): scripts/s14_revision_post_restauracion.sh --base-original ${SQL_DB} --base-restaurada ${DB_REST} --punto ${PUNTO}"
marca "Luego verificar AUT-08, AUT-12 y AUT-17 en ${DB_REST}."
