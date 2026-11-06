#!/usr/bin/env bash
# =============================================================================
# s15_purgar_log_acceso.sh - Proyecto APT Cobranza Automatizada
# Purga mensual de cob.LogAcceso (ADR-001 5.9; politica de credenciales B.3; D15).
#
# LO EJECUTA UN HUMANO, miembro de grp-cobranza-sql-admin, el primer dia habil de
# cada mes y solo si el entorno tiene mas de 90 dias de vida. Ningun agente lo
# ejecuta. cob.sp_PurgarLogAcceso no esta otorgado a ninguna identidad administrada.
#
# Uso:
#   scripts/s15_purgar_log_acceso.sh --dias 90 --confirmar [--lote 5000]
#
#   --dias      retencion en dias (minimo 90; el procedimiento rechaza menos con 50071).
#   --confirmar obligatorio; ademas se pide confirmacion interactiva.
#   --lote      filas por lote (DEMO 5000, politica A.11).
#
# Variables: RG y DEPLOY_NAME (por defecto cobranza-main), o SQL_SERVER y SQL_DB.
# Requisitos: acceso de red a SQL (ventana ipOperador), go-sqlcmd.
# Las filas purgadas siguen en los respaldos LTR hasta su vencimiento (ADR-001 5.1).
# Evidencia: total purgado (FilasBorradas) y fecha UTC; la ejecucion queda tambien en
# cob.LogAcceso (PurgaLogAcceso) y en la auditoria de Azure SQL. Sin tee ni set -x.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

DIAS="" LOTE=5000 CONFIRMAR=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dias) DIAS="${2:-}"; shift 2 ;;
    --lote) LOTE="${2:-}"; shift 2 ;;
    --confirmar) CONFIRMAR=si; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $1" ;;
  esac
done

exigir_humano
exigir_sqlcmd
[[ "$DIAS" =~ ^[0-9]+$ ]] || error "--dias es obligatorio (entero)."
[[ "$DIAS" -ge 90 && "$DIAS" -le 36500 ]] || error "--dias debe estar entre 90 y 36500 (retencion minima 90, D15)."
[[ "$LOTE" =~ ^[0-9]+$ && "$LOTE" -ge 1 ]] || error "--lote debe ser un entero mayor o igual a 1."
[[ "$CONFIRMAR" == "si" ]] || error "Falta --confirmar."
RG="${RG:-rg-cobranza-apt}"
resolver_sql

echo "== Estado previo de cob.LogAcceso en ${SQL_DB}"
echo "TotalFilas|FilaMasAntiguaUtc|FilasAPurgar|BaseCreadaUtc"
sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON;
SELECT COUNT_BIG(*),
       CONVERT(varchar(19), MIN(FechaUtc), 126),
       SUM(CASE WHEN FechaUtc < DATEADD(DAY, -${DIAS}, SYSUTCDATETIME()) THEN 1 ELSE 0 END),
       (SELECT CONVERT(varchar(19), create_date, 126) FROM sys.databases WHERE name = DB_NAME())
  FROM cob.LogAcceso;
SQL
echo "Regla: purgar solo si el entorno tiene mas de 90 dias de vida (BaseCreadaUtc)."
confirmar "Purgar las filas de cob.LogAcceso con mas de ${DIAS} dias (lotes de ${LOTE})."

echo "== Purga (sp_PurgarLogAcceso)"
echo "FilasBorradas"
if ! sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC cob.sp_PurgarLogAcceso @DiasRetencion = ${DIAS}, @TamanoLote = ${LOTE};
SQL
then explicar_error_sql; exit 1; fi
echo "Purga terminada $(date -u +%Y-%m-%dT%H:%M:%SZ). Registrar FilasBorradas y la fecha en evidencias/seguridad/."
