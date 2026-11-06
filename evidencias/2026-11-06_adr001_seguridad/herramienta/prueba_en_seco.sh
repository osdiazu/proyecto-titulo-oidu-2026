#!/usr/bin/env bash
# =============================================================================
# prueba_en_seco.sh - Evidencia 2026-11-06_adr001_seguridad
# Ejecuta scripts/s12_endurecer.sh, s12_verificar_seguridad.sh y s12_pruebas_red.sh
# con `az`, `curl` y `sleep` SIMULADOS (archivos en un directorio temporal que se
# antepone a PATH). No contacta Azure ni la API: valida solo la logica de los scripts.
# Las IP usadas son de documentacion (RFC 5737). Uso, desde la raiz del repositorio:
#   bash evidencias/2026-11-06_adr001_seguridad/herramienta/prueba_en_seco.sh <endurecer|verificar|red>
# =============================================================================
set -uo pipefail
RAIZ="$(pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"

case "${1:-}" in
endurecer)
  cat > "$T/bin/az" <<'EOF'
#!/usr/bin/env bash
echo "az $*" >> "$AZ_LOG"
case "$*" in
  *"access-restriction show"*"operador-publicacion"*) echo "${SCM_REGLAS:-0}";;
  *"ipSecurityRestrictions[?action=='Allow'"*) echo "0";;
  *"firewall-rule show"*) exit "${FW_EXISTE:-1}";;
  *"firewall-rule list"*) echo "0";;
  *"network-rule list"*) printf '198.51.100.7\n';;
  *" show "*"--query id"*) echo "/subscriptions/S/resourceGroups/RG/providers/Microsoft.Web/sites/APP";;
esac
exit 0
EOF
  chmod +x "$T/bin/"*
  corre () { env -u IP_OPERADOR PATH="$T/bin:$PATH" AZ_LOG="$T/log" RG=rg WEB_APP=api FUNC_APP=func SQL_SERVER=sql STORAGE=st KV_NAME=kv "$@" bash "$RAIZ/scripts/s12_endurecer.sh"; echo "codigo de salida=$?"; }
  modif () { grep -E "access-restriction (add|remove)|firewall-rule delete|network-rule remove|keyvault update|ipSecurityRestrictionsDefaultAction|storage account update|sql server update" "$T/log" | sed 's#--ids /subscriptions/S/resourceGroups/RG/providers/Microsoft.Web/sites/APP#--ids <sitio>#'; }
  echo "### E1 transicion vigente; regla operador-temporal existe; SCM con 1 regla previa; IP_PUBLICACION_SCM definida"
  : > "$T/log"; corre FW_EXISTE=0 SCM_REGLAS=1 IP_PUBLICACION_SCM=198.51.100.7
  echo "--- llamadas que modifican (az simulado):"; modif
  echo; echo "### E2 publicacion-aprobada con un informe de qa RECHAZADO (evidencias/qa/2026-11-06_revision_precommit.md)"
  corre ESTADO_TRANSICION=publicacion-aprobada APROBACION_QA="evidencias/qa/2026-11-06_revision_precommit.md" 2>&1 | tail -2
  printf '# Informe\n**Veredicto: APROBADO CON OBSERVACIONES**\n' > "$T/qa_ok.md"
  echo; echo "### E3 publicacion-aprobada con informe aprobado e IP_PUBLICACION_SCM"
  : > "$T/log"; corre ESTADO_TRANSICION=publicacion-aprobada APROBACION_QA="$T/qa_ok.md" IP_PUBLICACION_SCM=198.51.100.7 | grep -E "SCM|transicion|salida"
  echo "--- reglas SCM agregadas: $(grep -c 'access-restriction add' "$T/log")"
  printf '| Aprobado por |  |\n' > "$T/lev_vacio.md"; printf '| Aprobado por | Nombre Apellido |\n' > "$T/lev_ok.md"
  echo; echo "### E4 levantada sin aprobador registrado"; corre ESTADO_TRANSICION=levantada APROBACION_LEVANTAMIENTO="$T/lev_vacio.md" 2>&1 | tail -2
  echo; echo "### E5 levantada con aprobador registrado"
  : > "$T/log"; corre ESTADO_TRANSICION=levantada APROBACION_LEVANTAMIENTO="$T/lev_ok.md" | grep -E "transicion|salida"
  echo "--- sitios con Deny forzado (esperado 1, solo la Function App): $(grep -c 'ipSecurityRestrictionsDefaultAction=Deny' "$T/log")"
  echo; echo "### E6 valor invalido de ESTADO_TRANSICION"; corre ESTADO_TRANSICION=abierta 2>&1 | tail -2
  echo; echo "### E7 IP_OPERADOR exportada en la terminal (debe ignorarse)"
  : > "$T/log"; PATH="$T/bin:$PATH" AZ_LOG="$T/log" RG=rg WEB_APP=api FUNC_APP=func SQL_SERVER=sql STORAGE=st KV_NAME=kv IP_OPERADOR=198.51.100.7 \
    bash "$RAIZ/scripts/s12_endurecer.sh" | head -2
  echo "--- reglas agregadas con IP_OPERADOR: $(grep -c 'access-restriction add' "$T/log")"
  ;;
verificar)
  cat > "$T/bin/az" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"keyvault secret list"*) exit 1;;
  *"role assignment list"*) exit 1;;
  *"--query id"*) echo "/subscriptions/S/x";;
  *"principalId"*) echo "pid";;
  *"Deny-VNet-Inbound"*) echo "Deny/4000";;
  *"diagnostic-settings"*) echo "1";;
esac
exit 0
EOF
  chmod +x "$T/bin/"*
  echo "### V1 az simulado: devuelve vacio salvo identidades, NSG y diagnostico; falla role assignment y secret list"
  echo "### (valida que el script recorre todos los controles y clasifica CUMPLE / NO CUMPLE / NO VERIFICADO)"
  (cd "$T" && PATH="$T/bin:$PATH" RG=rg WEB_APP=a FUNC_APP=f SQL_SERVER=s SQL_DB=d KV_NAME=k STORAGE=st bash "$RAIZ/scripts/s12_verificar_seguridad.sh"; echo "codigo de salida=$?")
  ;;
red)
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
f=""; prev=""; for a in "$@"; do [[ "$prev" == "-D" ]] && f="$a"; prev="$a"; done
case "$*" in
  *"--data-binary"*) cat >/dev/null; n=$(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 )); echo $n > "$CNT"; if (( n > 13 )); then printf '429'; else printf '401'; fi;;
  *antiforgery*) [[ -n "$f" ]] && printf 'Set-Cookie: __Host-cobranza-af=VALOR; path=/; secure; samesite=strict; httponly\r\n' > "$f"; [[ "$*" == *"-o /dev/null"* ]] || echo '{"token":"TK"}';;
  *) printf '401';;
esac
EOF
  printf '#!/usr/bin/env bash\necho "ERROR: ForbiddenByConnection (simulado)"\n' > "$T/bin/az"
  chmod +x "$T/bin/"*
  echo "### R1 curl simulado: 401 a todo, 429 desde el intento 14 de login (RED-14 y RED-11 cuentan); cookie af correcta"
  (cd "$T" && CNT="$T/cnt" PATH="$T/bin:$PATH" WEB_HOST=w FUNC_HOST=f KV_NAME=k bash "$RAIZ/scripts/s12_pruebas_red.sh" </dev/null; echo "codigo de salida=$?")
  echo; echo "### R2 ORIGEN_PRUEBA=externa (curl simulado devuelve 401/200: debe marcar NO CUMPLE)"
  (cd "$T" && CNT="$T/c2" PATH="$T/bin:$PATH" WEB_HOST=w FUNC_HOST=f KV_NAME=k ORIGEN_PRUEBA=externa bash "$RAIZ/scripts/s12_pruebas_red.sh" </dev/null; echo "codigo de salida=$?")
  ;;
*) echo "Uso: $0 <endurecer|verificar|red>" >&2; exit 2;;
esac
