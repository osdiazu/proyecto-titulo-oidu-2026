#!/usr/bin/env bash
# =============================================================================
# s12_pruebas_red.sh - Proyecto APT Cobranza Automatizada (Evidencia S12)
# Pruebas de exposicion EJECUTADAS DESDE INTERNET (equipo fuera de la VNet).
# Cada prueba muestra el codigo HTTP o el error obtenido para registrarlo en la
# tabla de pruebas de la evidencia.
# Actualizado el 06-11-2026 por ADR-001 (tabla 6.3): RED-02 y RED-11 a RED-17.
#
# Que envia: solicitudes de lectura y, en RED-11/14/15/16, intentos de login con
# usuarios INEXISTENTES (red11.inexistente, etc.) y contrasenas aleatorias. No
# bloquea cuentas reales (el bloqueo solo aplica a usuarios existentes, ADR 5.2).
# Cada intento queda en cob.LogAcceso como LoginFallido/UsuarioInexistente: es
# esperado y sirve de evidencia de RED-16.
#
# Precondiciones:
#   - RED-02 y RED-11 a RED-16 requieren la API NUEVA publicada (ADR-001 5.11,
#     regla 1: solo con informe de qa APROBADO). Con la API anterior o sin codigo
#     los resultados no son validos.
#   - Mientras rija la transicion (5.11) la Web App solo acepta la IP de
#     ipOperador: RED-02 y RED-11 a RED-16 se ejecutan DESDE ESA IP.
#   - RED-17 se ejecuta desde OTRA red (por ejemplo, datos moviles) con
#     ORIGEN_PRUEBA=externa.
#   - RED-15 y RED-16 consumen el limite por IP (10/min DEMO): el script espera
#     61 s entre ambas y al final.
#
# Variables:
#   WEB_HOST FUNC_HOST KV_NAME   obligatorias
#   WAF_HOST                     dominio del Application Gateway (vacio si no hay WAF)
#   ORIGEN_PRUEBA                operador (por defecto) | externa (solo RED-01/17)
#   PROBAR_SESION                si: pide usuario y contrasena por la terminal para
#                                verificar la cookie de sesion (RED-12b). Lo ejecuta
#                                SOLO un integrante humano en su terminal, nunca un
#                                agente (regla SEG-H01). La contrasena se lee sin eco
#                                y se envia a curl por la entrada estandar.
#   LIMITE_LOGIN                 limite por IP por minuto (DEMO 10, ADR 5.4)
#
# La salida no muestra valores de cookies, tokens, claves ni contrasenas.
# =============================================================================
set -uo pipefail
WEB_HOST="${WEB_HOST:?Definir WEB_HOST (<webapp>.azurewebsites.net)}"
FUNC_HOST="${FUNC_HOST:?Definir FUNC_HOST (<funcapp>.azurewebsites.net)}"
KV_NAME="${KV_NAME:?Definir KV_NAME}"
WAF_HOST="${WAF_HOST:-}"
ORIGEN_PRUEBA="${ORIGEN_PRUEBA:-operador}"
PROBAR_SESION="${PROBAR_SESION:-no}"
LIMITE_LOGIN="${LIMITE_LOGIN:-10}"
API="https://${WEB_HOST}"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

codigo () { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@" || echo "sin respuesta"; }
# res "id" "descripcion" "esperado (regex)" "obtenido"
res () {
  local r="NO CUMPLE"; [[ "$4" =~ ^($3)$ ]] && r="CUMPLE"
  printf '%-7s %-66s esperado %-10s obtenido %-14s %s\n' "$1" "$2" "$3" "$4" "$r"
}
aleatorio () { LC_ALL=C tr -dc "$1" < /dev/urandom | head -c "$2"; }

# Obtiene token antifalsificacion en $TOKEN y la cookie __Host-cobranza-af en el jar $1.
# El token solo se guarda en una variable; nunca se imprime.
TOKEN=""
token_csrf () {
  local cuerpo
  cuerpo=$(curl -s --max-time 15 -c "$1" -b "$1" "${API}/api/v1/auth/antiforgery" || true)
  TOKEN=$(printf '%s' "$cuerpo" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
}
# Intento de login con usuario inexistente; devuelve el codigo HTTP.
login_invalido () {   # login_invalido jar usuario [encabezado extra]
  local clave extra=()
  clave=$(aleatorio 'A-Za-z2-9' 24)
  if [[ -n "${3:-}" ]]; then extra=(-H "$3"); fi
  printf '{"usuario":"%s","clave":"%s"}' "$2" "$clave" | \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 -c "$1" -b "$1" \
      -H 'Content-Type: application/json' -H "X-CSRF-TOKEN: ${TOKEN}" "${extra[@]}" \
      --data-binary @- "${API}/api/v1/auth/login" || echo "sin respuesta"
}
# Escapa barras invertidas y comillas dobles para incluir un texto en JSON.
json_esc () {
  local v="$1" bs='\' dq='"'
  v="${v//"$bs"/"$bs$bs"}"
  v="${v//"$dq"/"$bs$dq"}"
  printf '%s' "$v"
}
# Muestra los atributos de una cookie de Set-Cookie SIN su valor.
atributos_cookie () {   # atributos_cookie archivo_encabezados nombre
  grep -i "^set-cookie: *$2=" "$1" | head -1 | tr -d '\r' | sed -E "s/^[Ss]et-[Cc]ookie: *$2=[^;]*/$2=<oculto>/"
}
RE_PATH=';[[:space:]]*path=/(;|$)'
evaluar_cookie () {   # evaluar_cookie linea -> "ok" o "falta: ..."
  local l="${1,,}" falta=""
  [[ -z "$1" ]] && { echo "sin cookie"; return; }
  [[ "$l" == *"; secure"* ]]           || falta+=" Secure"
  [[ "$l" == *"; httponly"* ]]         || falta+=" HttpOnly"
  [[ "$l" == *"samesite=strict"* ]]    || falta+=" SameSite=Strict"
  [[ "$l" =~ $RE_PATH ]]               || falta+=" Path=/"
  [[ "$l" != *"; domain="* ]]          || falta+=" sin-Domain"
  [[ "$l" == __host-* ]]               || falta+=" prefijo-__Host-"
  if [[ -z "$falta" ]]; then echo "ok"; else echo "falta:${falta}"; fi
}

echo "Pruebas de red $(date -u +%Y-%m-%dT%H:%MZ) - origen declarado: ${ORIGEN_PRUEBA}"

if [[ "$ORIGEN_PRUEBA" == "externa" ]]; then
  # Solo pruebas de exposicion desde una IP distinta de ipOperador.
  echo "RED-01 API directa /salud (con transicion vigente o API cerrada: 403)    -> $(codigo "${API}/salud")"
  c=$(codigo "${API}/")
  res RED-17 "Transicion 5.11: Web App desde IP distinta de ipOperador (/)" "403" "$c"
  c=$(codigo "${API}/api/v1/auth/antiforgery")
  res RED-17b "Transicion 5.11: endpoint anonimo desde IP externa" "403" "$c"
  echo "Fin (origen externo). Ejecutar el resto desde la IP del operador."
  exit 0
fi

echo "RED-01 API directa /salud (esperado con API cerrada: 403; abierta: 200)  -> $(codigo "${API}/salud")"
# RED-02 (ADR 6.3): solo 401. El 302 era la redireccion de Easy Auth (obsoleto).
c=$(codigo -H 'X-Requested-With: XMLHttpRequest' "${API}/api/v1/cartera/indicadores")
res RED-02 "Endpoint protegido sin credenciales" "401" "$c"
echo "RED-03 Function App desde internet (esperado 403)                       -> $(codigo "https://${FUNC_HOST}/")"
echo "RED-04 HTTP sin cifrar a la API (esperado 301 a HTTPS)                   -> $(codigo "http://${WEB_HOST}/salud")"
echo "RED-05 TLS 1.1 contra la API (esperado: fallo de negociacion)"
curl -s -o /dev/null --max-time 15 --tlsv1.1 --tls-max 1.1 "${API}/salud" && echo "   NEGOCIO TLS 1.1 (NO CUMPLE)" || echo "   rechazado (CUMPLE)"
echo "RED-06 Key Vault desde internet (esperado 403 ForbiddenByConnection o similar)"
az keyvault secret list --vault-name "$KV_NAME" -o none 2>&1 | head -2
if [[ -n "$WAF_HOST" ]]; then
  echo "RED-07 WAF /salud (esperado 200)                                         -> $(codigo "https://${WAF_HOST}/salud")"
  echo "RED-08 WAF con patron de inyeccion SQL (esperado 403 por el WAF)         -> $(codigo "https://${WAF_HOST}/api/v1/clientes/1'%20OR%20'1'='1/estado")"
  echo "RED-09 WAF con patron XSS (esperado 403)                                 -> $(codigo "https://${WAF_HOST}/?q=%3Cscript%3Ealert(1)%3C/script%3E")"
  echo "RED-10 WAF HTTP 80 (esperado 301 a HTTPS)                                -> $(codigo "http://${WAF_HOST}/salud")"
else
  echo "RED-07 a RED-10: WAF no desplegado (PENDIENTE D11)"
fi

# ---------------------------------------------------------------------------
# ADR-001 tabla 6.3
# ---------------------------------------------------------------------------
JAR="$TMPD/jar"; HDR="$TMPD/hdr"

# RED-14: POST de login sin token CSRF (ni cookie antifalsificacion) -> 400.
c=$(printf '{"usuario":"red14.inexistente","clave":"%s"}' "$(aleatorio 'A-Za-z2-9' 24)" | \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H 'Content-Type: application/json' \
    --data-binary @- "${API}/api/v1/auth/login" || echo "sin respuesta")
res RED-14 "Login sin token CSRF" "400" "$c"

# RED-12a: atributos de la cookie antifalsificacion (anonima).
curl -s -o /dev/null -D "$HDR" --max-time 15 "${API}/api/v1/auth/antiforgery" || true
linea=$(atributos_cookie "$HDR" "__Host-cobranza-af")
echo "        Set-Cookie: ${linea:-<ausente>}"
res RED-12a "Cookie __Host-cobranza-af: Secure, HttpOnly, SameSite=Strict, __Host-" "ok" "$(evaluar_cookie "$linea")"

# RED-11: login con credenciales invalidas (con CSRF valido) -> 401.
token_csrf "$JAR"
if [[ -z "$TOKEN" ]]; then
  res RED-11 "Login con credenciales invalidas" "401" "sin token CSRF"
else
  res RED-11 "Login con credenciales invalidas" "401" "$(login_invalido "$JAR" red11.inexistente)"
fi

# RED-13: X-Api-Key invalida -> 401 (formato invalido y formato valido inexistente).
c=$(printf 'X-Api-Key: %s\n' "cobk_invalida" | curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H @- \
    "${API}/api/v1/clientes/76555555-8/estado" || echo "sin respuesta")
res RED-13a "X-Api-Key con formato invalido" "401" "$c"
falsa="cobk_$(aleatorio 'a-z2-7' 8)_$(aleatorio 'A-Za-z0-9_-' 43)"
c=$(printf 'X-Api-Key: %s\n' "$falsa" | curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H @- \
    "${API}/api/v1/clientes/76555555-8/estado" || echo "sin respuesta")
unset falsa
res RED-13b "X-Api-Key con formato valido inexistente" "401" "$c"

# RED-12b (opcional, humano): cookie de sesion tras un login correcto.
if [[ "$PROBAR_SESION" == "si" ]]; then
  if [[ ! -r /dev/tty ]]; then
    res RED-12b "Cookie de sesion" "ok" "sin terminal"
  else
    printf 'Usuario DEMO para RED-12b: ' > /dev/tty; IFS= read -r U_SES < /dev/tty
    printf 'Contrasena (sin eco): ' > /dev/tty; IFS= read -rs C_SES < /dev/tty; printf '\n' > /dev/tty
    J2="$TMPD/jar2"; token_csrf "$J2"
    c=$(printf '{"usuario":"%s","clave":"%s"}' "$(json_esc "$U_SES")" "$(json_esc "$C_SES")" | \
        curl -s -o /dev/null -D "$HDR" -w '%{http_code}' --max-time 15 -c "$J2" -b "$J2" \
          -H 'Content-Type: application/json' -H "X-CSRF-TOKEN: ${TOKEN}" \
          --data-binary @- "${API}/api/v1/auth/login" || echo "sin respuesta")
    unset C_SES U_SES
    linea=$(atributos_cookie "$HDR" "__Host-cobranza-sesion")
    echo "        login: ${c}; Set-Cookie: ${linea:-<ausente>}"
    res RED-12b "Cookie __Host-cobranza-sesion: Secure, HttpOnly, SameSite=Strict, __Host-" "ok" "$(evaluar_cookie "$linea")"
    # Cierre de la sesion de prueba (evento Logout).
    curl -s -o /dev/null --max-time 15 -c "$J2" -b "$J2" -H "X-CSRF-TOKEN: ${TOKEN}" -X POST "${API}/api/v1/auth/logout" || true
  fi
else
  echo "RED-12b  Cookie de sesion: NO EJECUTADA (PROBAR_SESION=si, solo un integrante humano)"
fi

# RED-15: mas de LIMITE_LOGIN intentos por minuto desde la misma IP -> 429.
echo "        Esperando 61 s para iniciar RED-15 con la ventana del limitador limpia..."
sleep 61
token_csrf "$JAR"; codigos=""
for i in $(seq 1 $((LIMITE_LOGIN + 2))); do
  codigos+="$(login_invalido "$JAR" "red15.inexistente") "
done
echo "        codigos: ${codigos}"
ultimo=$(awk '{print $NF}' <<<"$codigos")
res RED-15 "Mas de ${LIMITE_LOGIN} intentos de login por minuto (ultimo intento)" "429" "$ultimo"

# RED-16: X-Forwarded-For escrito por el cliente no evade el limitador.
echo "        Esperando 61 s para RED-16..."
sleep 61
token_csrf "$JAR"; codigos=""
for i in $(seq 1 $((LIMITE_LOGIN + 2))); do
  codigos+="$(login_invalido "$JAR" "red16.inexistente" "X-Forwarded-For: 203.0.113.$((i + 10))") "
done
echo "        codigos: ${codigos}"
ultimo=$(awk '{print $NF}' <<<"$codigos")
res RED-16a "X-Forwarded-For rotado por el cliente no evade el limitador" "429" "$ultimo"
echo "RED-16b  IpOrigen en cob.LogAcceso: verificacion MANUAL de un miembro de grp-cobranza-sql-admin."
echo "         Consultar cob.vw_LogAccesoEvidencia para UsuarioIngresado = 'red16.inexistente':"
echo "         esperado: ninguna fila con IP 203.0.113.0 (la red de documentacion RFC 5737); la IP"
echo "         enmascarada debe ser la del operador (<IP_OPERADOR> en la evidencia)."
echo "RED-17   Ejecutar desde otra red con ORIGEN_PRUEBA=externa (esperado 403)."
sleep 61
echo "Fin."
