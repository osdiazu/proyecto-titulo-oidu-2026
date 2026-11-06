#!/usr/bin/env bash
# =============================================================================
# s14_revision_post_restauracion.sh - Proyecto APT Cobranza Automatizada
# Revision obligatoria posterior a una restauracion PITR o LTR (ADR-001 4.2;
# politica de credenciales C.3). La restauracion NO termina hasta completar esta
# revision y verificar AUT-08, AUT-12 y AUT-17.
#
# LO EJECUTA UN HUMANO (miembro de grp-cobranza-sql-admin con Key Vault Secrets
# Officer), en su propia terminal; ningun agente lo ejecuta (modifica usuarios y
# claves; regla SEG-H01 por extension).
#
# Uso:
#   scripts/s14_revision_post_restauracion.sh --base-original <db> --base-restaurada <db> --punto <AAAA-MM-DDTHH:MM:SSZ>
#   scripts/s14_revision_post_restauracion.sh --base-restaurada <db> --sin-original
#
# Modo normal (la base original existe; caso de scripts/s14_simulacro_pitr.sh):
#   1. Lista en la base ORIGINAL los eventos con FechaUtc >= punto
#      (cob.sp_ListarEventosAccesoDesde; columnas segun sql/12).
#   2. En la base RESTAURADA, con confirmacion de cada grupo:
#      - repite cada RevocacionClaveApi (sp_RevocarClaveApi, idempotente);
#      - aplica el estado (Activo) y el rol actuales de la original a los usuarios con
#        CambioEstadoUsuario o CambioRolUsuario (sp_CambiarEstadoUsuario, sp_CambiarRolUsuario);
#      - lista los usuarios con CambioClave o RestablecimientoClave: hay que restablecerles
#        la contrasena EN PERSONA con scripts/s11_restablecer_clave.sh (SQL_DB=<restaurada>);
#      - deshabilita en Key Vault los secretos de claves dadas de alta despues del punto
#        (AltaClaveApi) que no existen en la restaurada (secretos huerfanos);
#      - lista los AltaUsuario posteriores (volver a crearlos solo si se necesitan).
# Modo --sin-original (LTR, entorno eliminado o base borrada): regla conservadora:
#      revoca todas las claves de la restaurada y deshabilita sus secretos, desactiva a
#      todos los usuarios que no son Admin y lista a todos para restablecer contrasena;
#      hay que emitir claves nuevas con scripts/s11_alta_clave_api.sh.
#   3. En ambos modos: cob.sp_InvalidarTodasLasSesiones en la restaurada.
#
# Variables: SQL_SERVER (o SQL_FQDN) y KV_NAME; o RG y DEPLOY_NAME (cobranza-main) para
# leerlos de las salidas de infra/main.bicep. Acceso de red a SQL y a Key Vault (ventana
# ipOperador abierta). La salida va solo a la terminal (sin tee); la evidencia se registra
# con docs/seguridad/plantilla_revision_post_restauracion.md, sin IP ni identificadores completos.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/comun_operacion.sh
source "$(dirname "$0")/comun_operacion.sh"

BASE_ORIG="" BASE_REST="" PUNTO="" SIN_ORIGINAL=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-original) BASE_ORIG="${2:-}"; shift 2 ;;
    --base-restaurada) BASE_REST="${2:-}"; shift 2 ;;
    --punto) PUNTO="${2:-}"; shift 2 ;;
    --sin-original) SIN_ORIGINAL=si; shift ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) error "Argumento no reconocido: $1" ;;
  esac
done

exigir_humano
exigir_sqlcmd
PATRON_BASE='^[A-Za-z0-9_-]{1,128}$'
[[ "$BASE_REST" =~ $PATRON_BASE ]] || error "--base-restaurada no valida."
if [[ "$SIN_ORIGINAL" == "no" ]]; then
  [[ "$BASE_ORIG" =~ $PATRON_BASE ]] || error "--base-original no valida (o use --sin-original)."
  [[ "$PUNTO" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?$ ]] || error "--punto debe ser AAAA-MM-DDTHH:MM:SSZ (UTC)."
  [[ "$BASE_ORIG" != "$BASE_REST" ]] || error "La base original y la restaurada no pueden ser la misma."
fi
PUNTO_SQL="${PUNTO%Z}"
RG="${RG:-rg-cobranza-apt}"
SQL_DB="$BASE_REST"
resolver_sql
KV_NAME="${KV_NAME:-$(salida keyVaultName)}"
[[ -n "$KV_NAME" ]] || error "Defina KV_NAME o RG/DEPLOY_NAME."

consulta () {   # consulta <base>  (lote por stdin) -> filas sin lineas vacias
  sql_lote "$1" | tr -d '\r' | sed '/^[[:space:]]*$/d'
}
existe_base () {
  [[ "$(echo "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '$1';" | consulta master)" == "1" ]]
}

existe_base "$BASE_REST" || error "La base restaurada ${BASE_REST} no existe en ${SQL_FQDN}."
if [[ "$SIN_ORIGINAL" == "no" ]] && ! existe_base "$BASE_ORIG"; then
  echo "AVISO: la base original ${BASE_ORIG} no existe. Corresponde la regla conservadora: vuelva a ejecutar con --sin-original."
  exit 1
fi

desactivar_secreto () {
  local nombre="$1"
  if az keyvault secret show --vault-name "$KV_NAME" -n "$nombre" --query id -o tsv >/dev/null 2>&1; then
    az keyvault secret set-attributes --vault-name "$KV_NAME" -n "$nombre" --enabled false --output none
    echo "   secreto deshabilitado: ${nombre}"
  else
    echo "   secreto no encontrado (ya eliminado): ${nombre}"
  fi
}

echo "Revision posterior a la restauracion"
echo "  Base restaurada : ${BASE_REST}"
[[ "$SIN_ORIGINAL" == "no" ]] && echo "  Base original   : ${BASE_ORIG}" && echo "  Punto (UTC)     : ${PUNTO}"
[[ "$SIN_ORIGINAL" == "si" ]] && echo "  Modo            : regla conservadora (sin base original)"
echo "  Key Vault       : ${KV_NAME}"
confirmar "Confirma que la base restaurada es la correcta."

if [[ "$SIN_ORIGINAL" == "no" ]]; then
  # ---------------------------------------------------------------------------
  echo "== 1. Eventos en la base original desde el punto (sp_ListarEventosAccesoDesde)"
  echo "LogAccesoId|FechaUtc|Evento|UsuarioId|Usuario|ClaveApiId|Prefijo|Detalle|Actor"
  consulta "$BASE_ORIG" <<SQL
SET NOCOUNT ON;
EXEC cob.sp_ListarEventosAccesoDesde @Desde = '${PUNTO_SQL}';
SQL

  # Tabla temporal con los eventos para filtrarlos por tipo.
  EVENTOS_SQL="SET NOCOUNT ON;
DECLARE @e TABLE (LogAccesoId bigint, FechaUtc datetime2(0), Evento varchar(25), UsuarioId int, Usuario varchar(50),
                  ClaveApiId int, Prefijo char(8), Detalle nvarchar(200), Actor nvarchar(128));
INSERT INTO @e EXEC cob.sp_ListarEventosAccesoDesde @Desde = '${PUNTO_SQL}';"

  # ---------------------------------------------------------------------------
  echo "== 2a. Revocaciones posteriores al punto"
  mapfile -t REVOCAR < <(consulta "$BASE_ORIG" <<SQL
${EVENTOS_SQL}
SELECT DISTINCT Prefijo FROM @e WHERE Evento = 'RevocacionClaveApi' AND Prefijo IS NOT NULL;
SQL
)
  echo "   Prefijos: ${REVOCAR[*]:-(ninguno)}"
  if [[ ${#REVOCAR[@]} -gt 0 ]] && preguntar_paso "Repetir estas revocaciones en ${BASE_REST}?"; then
    for p in "${REVOCAR[@]}"; do
      [[ "$p" =~ $PATRON_PREFIJO ]] || { echo "   prefijo omitido (formato): ${p}"; continue; }
      consulta "$BASE_REST" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
IF EXISTS (SELECT 1 FROM cob.ClaveApi WHERE Prefijo = '${p}') EXEC cob.sp_RevocarClaveApi @Prefijo = '${p}';
SQL
      echo "   revocada en la restaurada: ${p}"
    done
  fi

  # ---------------------------------------------------------------------------
  echo "== 2b. Estado y rol de usuarios cambiados despues del punto (se aplica el valor actual de la original)"
  mapfile -t ESTADOS < <(consulta "$BASE_ORIG" <<SQL
${EVENTOS_SQL}
SELECT DISTINCT u.Usuario + '|' + CONVERT(varchar(1), u.Activo) + '|' + u.Rol
  FROM @e e JOIN cob.UsuarioInterno u ON u.UsuarioId = e.UsuarioId
 WHERE e.Evento IN ('CambioEstadoUsuario', 'CambioRolUsuario');
SQL
)
  printf '   %s\n' "${ESTADOS[@]:-(ninguno)}"
  if [[ ${#ESTADOS[@]} -gt 0 ]] && preguntar_paso "Aplicar estado y rol actuales en ${BASE_REST}?"; then
    for fila in "${ESTADOS[@]}"; do
      IFS='|' read -r u activo rol <<< "$fila"
      [[ "$u" =~ $PATRON_USUARIO && "$activo" =~ ^[01]$ ]] || { echo "   fila omitida: ${fila}"; continue; }
      case "$rol" in Finanzas|Ventas|Admin) ;; *) echo "   rol omitido: ${fila}"; continue ;; esac
      consulta "$BASE_REST" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
IF EXISTS (SELECT 1 FROM cob.UsuarioInterno WHERE Usuario = '${u}' AND Activo <> ${activo})
  EXEC cob.sp_CambiarEstadoUsuario @Usuario = '${u}', @Activo = ${activo};
IF EXISTS (SELECT 1 FROM cob.UsuarioInterno WHERE Usuario = '${u}' AND Rol COLLATE Latin1_General_BIN2 <> '${rol}')
  EXEC cob.sp_CambiarRolUsuario @Usuario = '${u}', @Rol = '${rol}';
SQL
      echo "   aplicado: ${u} (Activo=${activo}, Rol=${rol})"
    done
  fi

  # ---------------------------------------------------------------------------
  echo "== 2c. Usuarios con cambio o restablecimiento de contrasena despues del punto"
  consulta "$BASE_ORIG" <<SQL | sed 's/^/   /'
${EVENTOS_SQL}
SELECT DISTINCT Usuario FROM @e WHERE Evento IN ('CambioClave', 'RestablecimientoClave') AND Usuario IS NOT NULL;
SQL
  echo "   A cada uno: SQL_DB=${BASE_REST} scripts/s11_restablecer_clave.sh --usuario <usuario> (en persona)."

  # ---------------------------------------------------------------------------
  echo "== 2d. Claves dadas de alta despues del punto (secretos huerfanos en Key Vault)"
  mapfile -t HUERFANOS < <(consulta "$BASE_ORIG" <<SQL
${EVENTOS_SQL}
SELECT DISTINCT c.NombreSecretoKv FROM @e e JOIN cob.ClaveApi c ON c.Prefijo = e.Prefijo
 WHERE e.Evento = 'AltaClaveApi';
SQL
)
  echo "   Candidatos: ${HUERFANOS[*]:-(ninguno)}"
  if [[ ${#HUERFANOS[@]} -gt 0 ]] && preguntar_paso "Deshabilitar en Key Vault los que no existen en ${BASE_REST}?"; then
    for s in "${HUERFANOS[@]}"; do
      [[ "$s" =~ ^apikey-[a-z0-9-]{3,50}-[a-z2-7]{8}$ ]] || { echo "   omitido (formato): ${s}"; continue; }
      p="${s: -8}"
      EN_REST="$(echo "SET NOCOUNT ON; SELECT COUNT(*) FROM cob.ClaveApi WHERE Prefijo = '${p}';" | consulta "$BASE_REST")"
      if [[ "$EN_REST" == "0" ]]; then desactivar_secreto "$s"; else echo "   existe en la restaurada (no es huerfano): ${s}"; fi
    done
  fi

  # ---------------------------------------------------------------------------
  echo "== 2e. Usuarios dados de alta despues del punto (no existen en la restaurada)"
  consulta "$BASE_ORIG" <<SQL | sed 's/^/   /'
${EVENTOS_SQL}
SELECT DISTINCT Usuario FROM @e WHERE Evento = 'AltaUsuario' AND Usuario IS NOT NULL;
SQL
  echo "   Volver a crearlos solo si se necesitan: SQL_DB=${BASE_REST} scripts/s11_alta_usuario.sh ..."

else
  # ---------------------------------------------------------------------------
  echo "== 2. Regla conservadora en ${BASE_REST}"
  mapfile -t CLAVES < <(consulta "$BASE_REST" <<SQL
SET NOCOUNT ON;
SELECT Prefijo + '|' + NombreSecretoKv FROM cob.ClaveApi WHERE Activa = 1 AND FechaRevocacion IS NULL;
SQL
)
  echo "   Claves activas: ${#CLAVES[@]}"
  if [[ ${#CLAVES[@]} -gt 0 ]] && preguntar_paso "Revocar TODAS las claves activas y deshabilitar sus secretos?"; then
    for fila in "${CLAVES[@]}"; do
      IFS='|' read -r p s <<< "$fila"
      [[ "$p" =~ $PATRON_PREFIJO ]] || { echo "   omitida: ${fila}"; continue; }
      echo "SET NOCOUNT ON; SET XACT_ABORT ON; EXEC cob.sp_RevocarClaveApi @Prefijo = '${p}';" | consulta "$BASE_REST"
      echo "   revocada: ${p}"
      desactivar_secreto "$s"
    done
  fi
  mapfile -t NO_ADMIN < <(consulta "$BASE_REST" <<SQL
SET NOCOUNT ON;
SELECT Usuario FROM cob.UsuarioInterno WHERE Activo = 1 AND Rol COLLATE Latin1_General_BIN2 <> 'Admin';
SQL
)
  echo "   Usuarios activos que no son Admin: ${#NO_ADMIN[@]}"
  if [[ ${#NO_ADMIN[@]} -gt 0 ]] && preguntar_paso "Desactivar a todos los usuarios que no son Admin?"; then
    for u in "${NO_ADMIN[@]}"; do
      [[ "$u" =~ $PATRON_USUARIO ]] || { echo "   omitido: ${u}"; continue; }
      echo "SET NOCOUNT ON; SET XACT_ABORT ON; EXEC cob.sp_CambiarEstadoUsuario @Usuario = '${u}', @Activo = 0;" | consulta "$BASE_REST"
      echo "   desactivado: ${u}"
    done
  fi
  echo "   Todos los usuarios requieren restablecimiento de contrasena (en persona):"
  echo "SET NOCOUNT ON; SELECT Usuario FROM cob.UsuarioInterno;" | consulta "$BASE_REST" | sed 's/^/     /'
  echo "   Emitir claves nuevas: scripts/s11_alta_clave_api.sh --consumidor ventas-demo --dias 30"
fi

# -----------------------------------------------------------------------------
echo "== 3. Invalidacion de todas las sesiones en ${BASE_REST} (sp_InvalidarTodasLasSesiones)"
if preguntar_paso "Invalidar todas las sesiones?"; then
  echo "SET NOCOUNT ON; SET XACT_ABORT ON; EXEC cob.sp_InvalidarTodasLasSesiones;" | consulta "$BASE_REST"
  echo "   Sesiones invalidadas (evento InvalidacionSesiones)."
else
  echo "   AVISO: sin este paso la restauracion NO se puede dar por terminada (politica C.3)."
fi

echo
echo "Pendiente para cerrar la restauracion: verificar AUT-08, AUT-12 y AUT-17 y registrar"
echo "evidencias/seguridad/<fecha>_revision_post_restauracion.md (plantilla docs/seguridad/plantilla_revision_post_restauracion.md)."
