#!/usr/bin/env bash
# =============================================================================
# s11_alta_usuario.sh - Proyecto APT Cobranza Automatizada (ADR-001 5.9; politica A.10.1)
#
# REGLA SEG-H01: SOLO LO EJECUTA UN HUMANO, nunca un agente de Claude Code.
# Lo ejecuta un integrante miembro de grp-cobranza-sql-admin, en su propia terminal
# y fuera de Claude Code. La salida de la terminal de un agente queda en la
# conversacion: equivale a pasar la contrasena por chat.
#
# Alta de un usuario del panel con contrasena temporal (20 caracteres DEMO, vigencia
# 24 h DEMO, cambio obligatorio en el primer acceso).
#
# Uso:
#   scripts/s11_alta_usuario.sh --usuario <usuario> --nombre "<nombre>" --rol <Finanzas|Ventas|Admin>
#   scripts/s11_alta_usuario.sh --verificar <usuario>     (cierra el alta: CambioClave registrado)
#
# Variables: RG y DEPLOY_NAME (por defecto cobranza-main) para leer el servidor y la base
# de las salidas de infra/main.bicep, o SQL_SERVER y SQL_DB.
# Requisitos: az login con una cuenta miembro de grp-cobranza-sql-admin; acceso de red a
# Azure SQL (ventana ipOperador abierta, docs/seguridad/plantilla_ventana_operador.md);
# go-sqlcmd; .NET SDK 10 (compila src/Cobranza.Herramientas en una carpeta temporal).
#
# Entrega (politica A.3/A.4): presencial con uso inmediato. La contrasena aparece SOLO en
# esta terminal (la herramienta la escribe en la consola, no en la salida estandar); el
# destinatario la lee en la pantalla del operador; al presionar Enter se limpia la
# pantalla y el historial visible. Prohibido: correo, chat, videollamada, pantalla
# compartida, papel, fotografias. No usar set -x, tee ni redirigir la salida.
#
# ADVERTENCIA (ADR-001 4.2, B-10b): el hash PBKDF2 de la contrasena temporal viaja en el
# texto del lote SQL. No queda en la lista de procesos (el lote va por stdin), pero SI en
# la auditoria de Azure SQL (BATCH_COMPLETED_GROUP, Log Analytics). Mitigacion: contrasena
# aleatoria de 20 caracteres, vigencia 24 h y cambio obligatorio en el primer acceso.
#
# Evidencia: copiar docs/seguridad/plantilla_entrega_credenciales.md a
# evidencias/seguridad/<fecha>_entrega_credenciales.md. Nunca la contrasena, el hash ni la IP.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

USUARIO="" NOMBRE="" ROL="" VERIFICAR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --usuario) USUARIO="${2:-}"; shift 2 ;;
    --nombre) NOMBRE="${2:-}"; shift 2 ;;
    --rol) ROL="${2:-}"; shift 2 ;;
    --verificar) VERIFICAR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $1" ;;
  esac
done

exigir_humano
exigir_sqlcmd
RG="${RG:-rg-cobranza-apt}"
resolver_sql

# --- Modo verificacion (paso 9 de A.10.1) ------------------------------------
if [[ -n "$VERIFICAR" ]]; then
  [[ "$VERIFICAR" =~ $PATRON_USUARIO ]] || error "Usuario no valido (a-z, 0-9, . _ -; 3 a 50)."
  echo "== Verificacion del cambio de contrasena de ${VERIFICAR} (sp_VerificarCambioClave)"
  echo "Columnas: UsuarioId|Usuario|FechaEmision|FechaCambioClave|CambioRealizado|DebeCambiarClave"
  if ! sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON;
EXEC cob.sp_VerificarCambioClave @Usuario = '${VERIFICAR}';
SQL
  then explicar_error_sql; exit 1; fi
  echo "El alta se cierra solo si CambioRealizado = 1. Registrar la hora del CambioClave en la evidencia."
  exit 0
fi

# --- Validaciones -------------------------------------------------------------
[[ -n "$USUARIO" && -n "$NOMBRE" && -n "$ROL" ]] || error "Faltan --usuario, --nombre o --rol (ver --help)."
[[ "$USUARIO" =~ $PATRON_USUARIO ]] || error "Usuario no valido: minusculas, 3 a 50, solo a-z 0-9 . _ -"
case "$ROL" in Finanzas|Ventas|Admin) ;; *) error "Rol no valido. Exacto (distingue mayusculas): Finanzas, Ventas o Admin." ;; esac
[[ ${#NOMBRE} -le 120 ]] || error "El nombre supera 120 caracteres."
[[ "$NOMBRE" != *'$'* && "$NOMBRE" != *$'\n'* && "$NOMBRE" != *$'\r'* ]] || error "El nombre contiene caracteres no permitidos."
NOMBRE_SQL="$(sql_literal "$NOMBRE")"

echo "Alta de usuario del panel"
echo "  Usuario : ${USUARIO}"
echo "  Nombre  : ${NOMBRE}"
echo "  Rol     : ${ROL}"
echo "  Base    : ${SQL_DB}"
echo "Condiciones (politica A.10.1): solicitud registrada con quien autoriza; destinatario PRESENTE."
confirmar "Confirma que el destinatario esta presente y que la solicitud esta autorizada."

compilar_herramienta
trap 'unset HASH; limpiar_herramienta' EXIT

# --- Contrasena temporal: se muestra en la terminal; se captura solo el hash -----
echo
echo "== Contrasena temporal (solo en pantalla; el destinatario la lee ahora):"
if ! HASH="$(dotnet "$HERR" hash-clave)"; then
  error "No se pudo generar la contrasena temporal (sin terminal utilizable; ver src/Cobranza.Herramientas/README.md, seccion 6)."
fi
[[ "$HASH" =~ ^[A-Za-z0-9+/]{40,252}={0,2}$ ]] || error "La herramienta no devolvio un hash con el formato esperado."

if ! sql_lote "$SQL_DB" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC cob.sp_CrearUsuarioInterno @Usuario = '${USUARIO}', @Nombre = N'${NOMBRE_SQL}', @Rol = '${ROL}', @HashClave = '${HASH}';
SQL
then
  unset HASH
  explicar_error_sql
  echo "El usuario NO se creo. La contrasena mostrada no sirve; descartela." >&2
  exit 1
fi
unset HASH
echo
echo "Usuario creado (evento AltaUsuario). La contrasena vence en 24 h (DEMO) y debe cambiarse en el primer acceso."
read -r -p "Cuando el destinatario haya leido la contrasena, presione Enter para limpiar la pantalla..." _
limpiar_pantalla

echo "Alta registrada para ${USUARIO} (${ROL})."
echo "Siguientes pasos (politica A.10.1, pasos 8 a 10):"
echo "  8. El destinatario inicia sesion en SU equipo y cambia la contrasena de inmediato."
echo "  9. scripts/s11_alta_usuario.sh --verificar ${USUARIO}"
echo " 10. Evidencia desde docs/seguridad/plantilla_entrega_credenciales.md (sin contrasena, hash ni IP)."
