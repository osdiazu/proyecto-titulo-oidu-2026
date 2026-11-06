#!/usr/bin/env bash
# =============================================================================
# comun_operacion.sh - Proyecto APT Cobranza Automatizada (ADR-001, 06-11-2026)
# Funciones compartidas por los scripts de operacion. NO se ejecuta solo: lo
# cargan con "source" scripts/desplegar.sh, desplegar_sql.sh, s11_alta_usuario.sh,
# s11_restablecer_clave.sh, s11_baja_usuario.sh, s11_alta_clave_api.sh,
# s11_revocar_clave_api.sh, s14_revision_post_restauracion.sh y
# s15_purgar_log_acceso.sh.
#
# No contiene identificadores, IP ni secretos. No usa set -x ni tee.
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "comun_operacion.sh se carga con 'source'; no se ejecuta directamente." >&2
  exit 2
fi

RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_NAME="${DEPLOY_NAME:-cobranza-main}"

# Nombre de usuario del panel (ADR-001 5.1): minusculas, digitos, punto, guion y guion bajo; 3 a 50.
PATRON_USUARIO='^[a-z0-9._-]{3,50}$'
# Consumidor de clave de API (ADR-001 5.1): minusculas, digitos y guion; 3 a 50.
PATRON_CONSUMIDOR='^[a-z0-9-]{3,50}$'
# Prefijo de clave de API (ADR-001 5.3): 8 caracteres Base32 en minusculas.
PATRON_PREFIJO='^[a-z2-7]{8}$'
PATRON_GUID='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

error () { echo "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Regla SEG-H01: los scripts que muestran o generan credenciales los ejecuta un
# humano en su propia terminal, nunca un agente de Claude Code.
# Verificacion hecha por devops el 06-11-2026 en la estacion del operador: una
# sesion de Claude Code exporta, entre otras, CLAUDECODE y CLAUDE_CODE_ENTRYPOINT,
# y su shell no tiene terminal (stdin no es tty). Es una barrera tecnica
# complementaria, NO una garantia: un proceso podria limpiar el entorno. La regla
# sigue siendo organizativa (ADR-001 5.9).
# -----------------------------------------------------------------------------
exigir_humano () {
  if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    echo "ERROR (SEG-H01): este script parece ejecutarse dentro de una sesion de Claude Code." >&2
    echo "Lo ejecuta SOLO un integrante humano, en su propia terminal y fuera de Claude Code." >&2
    exit 3
  fi
  exigir_terminal
}

exigir_terminal () {
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "ERROR: se requiere una terminal interactiva (entrada y salida estandar sin redirigir)." >&2
    exit 3
  fi
}

# confirmar "texto": exige escribir exactamente "si".
confirmar () {
  local resp
  read -r -p "$1 Escriba 'si' para continuar: " resp
  [[ "$resp" == "si" ]] || { echo "Cancelado por el operador."; exit 1; }
}

# preguntar_paso "texto": devuelve 0 si se ejecuta, 1 si se omite; "salir" termina.
preguntar_paso () {
  local resp
  while true; do
    read -r -p "$1 [si / omitir / salir]: " resp
    case "$resp" in
      si) return 0 ;;
      omitir) echo "   Paso omitido."; return 1 ;;
      salir) echo "Fin por decision del operador."; exit 0 ;;
      *) echo "   Responda si, omitir o salir." ;;
    esac
  done
}

# Muestra un identificador truncado (evidencias sin GUID completos).
truncar () { local v="$1"; if [[ ${#v} -gt 8 ]]; then echo "${v:0:4}...${v: -4}"; else echo "$v"; fi; }

# Convierte una ruta de Git Bash a formato Windows para ejecutables nativos.
ruta_nativa () { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }

# Escapa comillas simples para un literal T-SQL.
sql_literal () { local v="$1"; echo "${v//\'/\'\'}"; }

# -----------------------------------------------------------------------------
# Salidas del despliegue de infra/main.bicep (nombre DEPLOY_NAME en el grupo RG)
# -----------------------------------------------------------------------------
salida () {   # salida <nombre> -> valor de la salida de la plantilla
  az deployment group show -g "$RG" -n "$DEPLOY_NAME" --query "properties.outputs.$1.value" -o tsv 2>/dev/null | tr -d '\r'
}

# Completa SQL_FQDN y SQL_DB desde las variables o desde las salidas de la plantilla.
resolver_sql () {
  if [[ -z "${SQL_FQDN:-}" ]]; then
    if [[ -n "${SQL_SERVER:-}" ]]; then
      SQL_FQDN="${SQL_SERVER}.database.windows.net"
    else
      SQL_FQDN="$(salida sqlServerFqdn)"
    fi
  fi
  SQL_DB="${SQL_DB:-$(salida sqlDatabaseName)}"
  [[ -n "$SQL_FQDN" && -n "$SQL_DB" ]] || error "Defina SQL_SERVER y SQL_DB, o RG y DEPLOY_NAME para leerlos de las salidas de la plantilla."
}

exigir_sqlcmd () {
  command -v sqlcmd >/dev/null 2>&1 || error "sqlcmd (go-sqlcmd) no esta instalado. Instalar: winget install sqlcmd"
}

# sql_lote <base>: ejecuta el lote T-SQL leido de la entrada estandar.
#  - Autenticacion Entra ID (ActiveDirectoryDefault = sesion de az login del operador,
#    miembro de grp-cobranza-sql-admin).
#  - -b: termina con error si el lote falla. -x: sin sustitucion de variables $(...).
#  - El lote viaja por stdin y no por la linea de comandos: no queda en la lista de
#    procesos. SI queda en la auditoria de Azure SQL (BATCH_COMPLETED_GROUP), ADR-001 4.2.
#  - PENDIENTE verificar en la estacion del operador que la version instalada de
#    sqlcmd lee el lote desde una tuberia (go-sqlcmd lo admite segun su documentacion;
#    no se pudo probar: sqlcmd no esta instalado en la estacion donde se escribio).
sql_lote () {
  local base="$1"
  sqlcmd -S "tcp:${SQL_FQDN},1433" -d "$base" --authentication-method ActiveDirectoryDefault \
         -b -x -h -1 -W -s '|'
}

# Los procedimientos de sql/12 informan errores con THROW 50060-50076 y un mensaje en
# espanol, que sqlcmd muestra tal cual (ej.: 50061 "Usuario no encontrado.", 50063 rol no
# valido, 50064 "El usuario ya existe.", 50068 prefijo ya registrado, 50069 clave de API
# no encontrada). Referencia: evidencias/2026-11-06_adr001_sql/CAMBIOS.md, seccion 4.
explicar_error_sql () {
  echo "El lote SQL fallo. Revise el mensaje de sqlcmd (codigos 50060-50076 de sql/12; ver evidencias/2026-11-06_adr001_sql/CAMBIOS.md, seccion 4). No se reintenta automaticamente." >&2
}

# -----------------------------------------------------------------------------
# Herramienta Cobranza.Herramientas (src/Cobranza.Herramientas/README.md)
# -----------------------------------------------------------------------------
HERR_DIR=""
HERR=""
compilar_herramienta () {
  HERR_DIR="$(mktemp -d)"
  echo "== Compilando Cobranza.Herramientas en una carpeta temporal"
  dotnet build "$(ruta_nativa "${RAIZ_REPO}/src/Cobranza.Herramientas/Cobranza.Herramientas.csproj")" \
         -c Release -o "$(ruta_nativa "$HERR_DIR")" >/dev/null \
    || error "No se pudo compilar src/Cobranza.Herramientas."
  HERR="$(ruta_nativa "${HERR_DIR}/Cobranza.Herramientas.dll")"
  [[ -f "${HERR_DIR}/Cobranza.Herramientas.dll" ]] || error "No se encontro Cobranza.Herramientas.dll."
}
limpiar_herramienta () { [[ -n "$HERR_DIR" && -d "$HERR_DIR" ]] && rm -rf "$HERR_DIR"; HERR_DIR=""; }

# Limpia la pantalla y el historial visible del terminal (ADR-001 5.9, paso 6).
limpiar_pantalla () { clear; printf '\033[3J'; }

# -----------------------------------------------------------------------------
# Despliegue de infra/main.bicep (siempre Incremental; nunca Complete)
# -----------------------------------------------------------------------------
# desplegar_main <ip|vacio>: despliega con IP_OPERADOR = <ip> (vacio = ventana cerrada).
# Volver a desplegar main restablece ajustes y configuracion del sitio: despues se
# debe reaplicar scripts/s12_endurecer.sh (CLAUDE.md regla 7).
desplegar_main () {
  local ip="$1"
  IP_OPERADOR="$ip" az deployment group create -g "$RG" -n "$DEPLOY_NAME" \
    --parameters "$(ruta_nativa "${RAIZ_REPO}/infra/main.bicepparam")" \
    --mode Incremental --output none
}

whatif_main () {
  local ip="$1"
  IP_OPERADOR="$ip" az deployment group what-if -g "$RG" -n "$DEPLOY_NAME" \
    --parameters "$(ruta_nativa "${RAIZ_REPO}/infra/main.bicepparam")" \
    --result-format ResourceIdOnly
}

# Variables que necesita scripts/s12_endurecer.sh, desde las salidas de la plantilla.
exportar_nombres_recursos () {
  WEB_APP="$(salida apiAppName)"; FUNC_APP="$(salida funcAppName)"
  SQL_SERVER="$(salida sqlServerName)"; STORAGE="$(salida storageName)"
  KV_NAME="$(salida keyVaultName)"
  [[ -n "$WEB_APP" && -n "$FUNC_APP" && -n "$SQL_SERVER" && -n "$STORAGE" && -n "$KV_NAME" ]] \
    || error "No se pudieron leer las salidas del despliegue ${DEPLOY_NAME} en ${RG}."
  export RG WEB_APP FUNC_APP SQL_SERVER STORAGE KV_NAME
}
