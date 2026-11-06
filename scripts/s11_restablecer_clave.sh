#!/usr/bin/env bash
# =============================================================================
# s11_restablecer_clave.sh - Proyecto APT Cobranza Automatizada (ADR-001 5.9; politica A.10.3)
#
# REGLA SEG-H01: SOLO LO EJECUTA UN HUMANO, nunca un agente de Claude Code.
# Lo ejecuta un integrante miembro de grp-cobranza-sql-admin, en su propia terminal
# y fuera de Claude Code.
#
# Restablece la contrasena de un usuario del panel (nueva contrasena temporal, cambio
# obligatorio, desbloqueo y sello nuevo: cierra las sesiones abiertas) o, con
# --solo-desbloquear, solo desbloquea la cuenta sin cambiar la contrasena.
# La solicitud se hace EN PERSONA; no se aceptan solicitudes por correo ni chat.
#
# Uso:
#   scripts/s11_restablecer_clave.sh --usuario <usuario>
#   scripts/s11_restablecer_clave.sh --usuario <usuario> --solo-desbloquear
#
# Variables: RG y DEPLOY_NAME (por defecto cobranza-main), o SQL_SERVER y SQL_DB.
# Para la revision posterior a una restauracion se usa SQL_DB=<base restaurada>.
# Requisitos: los de scripts/s11_alta_usuario.sh.
#
# ADVERTENCIA (ADR-001 4.2, B-10b): el hash de la contrasena temporal queda en la
# auditoria de Azure SQL (BATCH_COMPLETED_GROUP). No queda en la lista de procesos.
# Sin set -x, sin tee, sin redirigir la salida.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

USUARIO="" SOLO_DESBLOQUEAR=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --usuario) USUARIO="${2:-}"; shift 2 ;;
    --solo-desbloquear) SOLO_DESBLOQUEAR=si; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $1" ;;
  esac
done

exigir_humano
exigir_sqlcmd
[[ "$USUARIO" =~ $PATRON_USUARIO ]] || error "Indique --usuario valido (a-z, 0-9, . _ -; 3 a 50)."
RG="${RG:-rg-cobranza-apt}"
resolver_sql

if [[ "$SOLO_DESBLOQUEAR" == "si" ]]; then
  echo "Desbloqueo SIN cambio de contrasena de ${USUARIO} en ${SQL_DB} (sp_DesbloquearUsuario)."
  confirmar "Confirma que verifico la identidad del solicitante en persona."
  if ! sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC cob.sp_DesbloquearUsuario @Usuario = '${USUARIO}';
SQL
  then explicar_error_sql; exit 1; fi
  echo "Cuenta desbloqueada (evento DesbloqueoManual). Registrar la evidencia."
  exit 0
fi

echo "Restablecimiento de contrasena de ${USUARIO} en ${SQL_DB} (sp_RestablecerClaveUsuario)."
echo "Efectos: contrasena temporal nueva (24 h DEMO), cambio obligatorio, desbloqueo y cierre de sesiones abiertas."
confirmar "Confirma que el usuario esta PRESENTE y que verifico su identidad en persona."

compilar_herramienta
trap 'unset HASH; limpiar_herramienta' EXIT

echo
echo "== Contrasena temporal (solo en pantalla; el usuario la lee ahora):"
if ! HASH="$(dotnet "$HERR" hash-clave)"; then
  error "No se pudo generar la contrasena temporal (sin terminal utilizable; ver src/Cobranza.Herramientas/README.md, seccion 6)."
fi
[[ "$HASH" =~ ^[A-Za-z0-9+/]{40,252}={0,2}$ ]] || error "La herramienta no devolvio un hash con el formato esperado."

if ! sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC cob.sp_RestablecerClaveUsuario @Usuario = '${USUARIO}', @HashClave = '${HASH}';
SQL
then
  unset HASH
  explicar_error_sql
  echo "La contrasena NO se restablecio. La mostrada no sirve; descartela." >&2
  exit 1
fi
unset HASH
echo
echo "Contrasena restablecida (evento RestablecimientoClave)."
read -r -p "Cuando el usuario haya leido la contrasena, presione Enter para limpiar la pantalla..." _
limpiar_pantalla

echo "Restablecimiento registrado para ${USUARIO}."
echo "Siguientes pasos (politica A.10.1, pasos 8 a 10):"
echo "  - El usuario inicia sesion en SU equipo y cambia la contrasena de inmediato."
echo "  - scripts/s11_alta_usuario.sh --verificar ${USUARIO}"
echo "  - Evidencia desde docs/seguridad/plantilla_entrega_credenciales.md (sin contrasena, hash ni IP)."
