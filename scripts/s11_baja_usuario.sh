#!/usr/bin/env bash
# =============================================================================
# s11_baja_usuario.sh - Proyecto APT Cobranza Automatizada (ADR-001 5.9; politica A.10.4)
#
# REGLA SEG-H01: SOLO LO EJECUTA UN HUMANO, nunca un agente de Claude Code.
# Lo ejecuta un integrante miembro de grp-cobranza-sql-admin, en su propia terminal
# y fuera de Claude Code.
#
# Baja de un usuario del panel: sp_CambiarEstadoUsuario @Activo = 0. La fila no se
# borra (trazabilidad); el sello cambia y las sesiones abiertas se rechazan en a lo
# mas 5 min (DEMO, AUT-08). Evento CambioEstadoUsuario.
#
# Uso:
#   scripts/s11_baja_usuario.sh --usuario <usuario>
#
# Variables: RG y DEPLOY_NAME (por defecto cobranza-main), o SQL_SERVER y SQL_DB.
# Requisitos: az login (miembro de grp-cobranza-sql-admin), acceso de red a SQL, go-sqlcmd.
# Sin set -x, sin tee. Evidencia en evidencias/seguridad/ sin IP ni identificadores completos.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

USUARIO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --usuario) USUARIO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $1" ;;
  esac
done

exigir_humano
exigir_sqlcmd
[[ "$USUARIO" =~ $PATRON_USUARIO ]] || error "Indique --usuario valido (a-z, 0-9, . _ -; 3 a 50)."
RG="${RG:-rg-cobranza-apt}"
resolver_sql

echo "Baja (desactivacion) de ${USUARIO} en ${SQL_DB}."
confirmar "Confirma la baja autorizada de ${USUARIO}."
if ! sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC cob.sp_CambiarEstadoUsuario @Usuario = '${USUARIO}', @Activo = 0;
SQL
then explicar_error_sql; exit 1; fi
echo "Usuario ${USUARIO} desactivado (evento CambioEstadoUsuario). Verificar AUT-08 y registrar la evidencia."
