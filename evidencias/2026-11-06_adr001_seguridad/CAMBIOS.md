# Registro de cambios: ADR-001 Fase B de seguridad y SEG-H08 (06-11-2026)

Agente: `seguridad` (Claude Code), por encargo del orquestador. Rama `s11-brazilsouth-autenticacion-propia`. Sin commit.

Estado: escrito y validado localmente (`bash -n` y pruebas en seco con `az`, `curl` y `sleep` simulados). No se ejecutó nada contra Azure, la API ni la base. No se editaron `infra/`, `src/`, `sql/`, el ADR, CLAUDE.md ni scripts distintos de `s12_*`.

Base: ADR-001 secciones 5.5, 5.5.1, 5.10 (filas de `seguridad`), 5.11, 6, 6.2 y 6.3; política de credenciales D.6 y SEG-H08; informe de `qa` `evidencias/qa/2026-11-06_revision_precommit.md` (B-N6, M-N2). El encargo cita la sección "Lista definitiva de tareas por agente" del ADR, pero esa sección no existe en el ADR al 06-11-2026. Se usaron 5.10, 6.2, 6.3 y D.6.

## 1. Cambios

| Archivo | Qué cambió | Por qué |
| --- | --- | --- |
| `scripts/s12_endurecer.sh` | Key Vault: `publicNetworkAccess Disabled`, `defaultAction Deny` y eliminación de todas las `ipRules` (sin mostrar las IP) | SEG-H08 |
| | SQL: elimina `operador-temporal` si existe; avisa si quedan otras reglas (no las borra) | SEG-H08 |
| | Regla de transición 5.11 con `ESTADO_TRANSICION` (`vigente` por defecto, `publicacion-aprobada` o `levantada`). Mientras no está `levantada`, la Web App queda con entrada `Deny`. `publicacion-aprobada` exige `APROBACION_QA` con un informe de veredicto APROBADO. `levantada` exige `APROBACION_LEVANTAMIENTO` con la fila "Aprobado por" completa. El script nunca abre la Web App | ADR 5.11, reglas 1, 3 y 4 |
| | Sitio SCM: `scmIpSecurityRestrictionsUseMain=false` y `Deny` en ambos sitios. Siempre elimina `operador-publicacion` y solo la vuelve a crear con `IP_PUBLICACION_SCM`. Con la transición `vigente`, el SCM de la Web App queda sin reglas de permiso | ADR 5.11, regla 3 (decisión de `seguridad`, sección 2) |
| | Ignora `IP_OPERADOR` y avisa si viene exportada | Evita abrir Kudu con la variable de `entorno.local.env` |
| | Texto "protegida por Entra ID" reemplazado por "protegida por autenticación propia (sin MFA)" | ADR 5.10 |
| | Storage: agrega `--public-network-access Disabled --default-action Deny` (igual que `main.bicep`) | Reaplicación después de un despliegue |
| `scripts/s12_verificar_seguridad.sh` | Se conservan los id SEG-01 a SEG-22. SEG-05 pasa a "Easy Auth deshabilitado" (`authsettingsV2`, esperado `false`). Se agrega el estado NO VERIFICADO | ADR 6 y 6.2 |
| | Nuevos: SEG-DP-01, SEG-DP-02, SEG-DP-03a (condición ABAC), SEG-DP-03b (manual), SEG-KV-01, SEG-KV-02, SEG-KV-02b, SEG-KV-03, SEG-KV-04, SEG-KV-05, SEG-KV-06a/b/c, SEG-KV-07 (opcional), SEG-KV-08, SEG-TR-01, SEG-TR-02, SEG-FH-01, SEG-EA-02 | ADR 6.2, D.6 |
| | Nuevos: SEG-23 (Storage sin acceso público), SEG-24 a SEG-28 (SCM), SEG-29 a SEG-31 (`nsg-pe`), SEG-DNS-01 a SEG-DNS-05 (registros A 10.20.2.4 a 10.20.2.8) | Alcance del agente (exposición pública, DNS privado) |
| | La matriz no incluye Object IDs, IP ni nombres de secretos: solo conteos y estados | Política B.4, B.5 |
| `scripts/s12_pruebas_red.sh` | RED-02 espera solo 401. Nuevos: RED-11, RED-12a (cookie antifalsificación), RED-12b (cookie de sesión, opcional y solo para una persona), RED-13a/b, RED-14, RED-15, RED-16a (automática), RED-16b (manual en SQL), RED-17/17b (`ORIGEN_PRUEBA=externa`) | ADR 6.3 |
| | Los logins de prueba usan usuarios inexistentes y contraseñas aleatorias: no bloquean cuentas. La contraseña de RED-12b se lee sin eco desde `/dev/tty` y se envía por stdin. No se imprimen cookies, tokens ni claves | SEG-H01, política A.4 |
| `docs/seguridad/politica_credenciales_y_accesos.md` | Estado "Aprobada por el equipo (05-11-2026)". Nuevo historial. Sección 0: `diagKv` está en `main.bicep` (B-N6) y fila actualizada de `s12_endurecer.sh`. Actualizados A.2(a)6, A.8, A.10 (cierre de la ventana), D.5.1, D.6 (aplicada), E (SEG-H03, SEG-H08) y F.9 | M-N2, B-N6, D.6 |
| `docs/seguridad/plantilla_entrega_credenciales.md` (nuevo) | Plantilla sin datos | D.6, punto 3 |
| `docs/seguridad/plantilla_claves_api.md` (nuevo) | Plantilla sin datos | D.6, punto 3 |
| `docs/seguridad/plantilla_revision_post_restauracion.md` (nuevo) | Plantilla sin datos | D.6, punto 3 |
| `docs/seguridad/plantilla_levantamiento_transicion.md` (nuevo) | Condiciones y aprobación para levantar 5.11; la usa `s12_endurecer.sh` | ADR 5.11, regla 4 |
| `docs/seguridad/plantilla_prueba_negativa_abac.md` (nuevo) | Procedimiento manual de SEG-DP-03b (supuestos marcados PENDIENTE) | ADR 6.2 |
| `docs/seguridad/plantilla_ventana_operador.md` (nuevo) | Apertura y cierre de la ventana `ipOperador` | Regla de cierre de sesión del agente |

## 2. Decisión sobre el sitio SCM (ADR 5.11, regla 3)

El SCM no hereda las reglas del sitio principal (`scmIpSecurityRestrictionsUseMain=false`), tiene acción por defecto `Deny` y solo admite la regla `operador-publicacion` durante una publicación.

- Por qué no hereda: si heredara, levantar la transición (o dejar la API pública detrás de autenticación propia) abriría también Kudu. Kudu permite leer el sistema de archivos del sitio (incluidas las claves de Data Protection en `%HOME%` si se usara la alternativa de 5.5) y las variables de entorno.
- Por qué se cierra el SCM de la Web App durante la transición: la regla 1 de 5.11 prohíbe publicar la API. Sin permiso en el SCM, `az webapp deploy` no puede llegar al sitio, lo que agrega un control técnico al de procedimiento. El SCM de la Function App sí puede abrirse para publicar los jobs.
- Por qué `IP_PUBLICACION_SCM` y no `IP_OPERADOR`: `IP_OPERADOR` queda exportada al cargar `infra/entorno.local.env`, y el script abriría Kudu sin que nadie lo decidiera.
- Riesgo residual: entre la publicación y la siguiente ejecución del script, el SCM queda abierto a la IP del operador. Mitigación: la plantilla de ventana exige cerrarlo en la misma sesión y verificar SEG-27 y SEG-28.

## 3. Evidencias

| Archivo | Contenido |
| --- | --- |
| `01_versiones.txt` | bash 5.2.37, curl 8.12.1, Azure CLI 2.63.0 (solo la versión local). ShellCheck y jq no están instalados: ShellCheck NO VERIFICADO |
| `02_bash_n.txt` | `bash -n` OK en los tres scripts y en el arnés; 0 bytes CR (`.gitattributes` exige LF) |
| `03_prueba_seco_endurecer.txt` | E1 a E7: cierre de Key Vault, SQL y SCM; rechazo de un informe de qa RECHAZADO; rechazo de un levantamiento sin aprobador; valor inválido; `IP_OPERADOR` ignorada |
| `04_prueba_seco_verificar.txt` | Recorre los 54 controles y clasifica CUMPLE / NO CUMPLE / NO VERIFICADO con `az` simulado. Los NO CUMPLE son esperables: el simulador devuelve vacío |
| `05_prueba_seco_pruebas_red.txt` | Flujo completo con `curl` simulado. RED-14 da NO CUMPLE porque el simulador devuelve 401 a todo: demuestra que la evaluación detecta la desviación |
| `06_busqueda_cadenas.txt` | Sin secretos, GUID completos ni IPv4 fuera del plan y de RFC 5737. La única coincidencia es la fila de la política que lista los patrones de búsqueda (falso positivo) |
| `07_diff.txt` | `git diff` de los archivos modificados y lista de archivos nuevos |
| `herramienta/prueba_en_seco.sh` | Arnés reproducible: `bash evidencias/2026-11-06_adr001_seguridad/herramienta/prueba_en_seco.sh <endurecer|verificar|red>` |

Además se probaron por separado, con datos simulados, `evaluar_cookie` (detecta la falta de SameSite, Path=/ y la presencia de Domain), `json_esc` y `clasificar`/`es_ancestro_o_vault` (alcance de contenedor, de clave y amplio; usuario con Secrets User en el grupo de recursos detectado por SEG-KV-03).

## 4. Dependencias con `devops` (cambios en paralelo)

Al 06-11-2026, `infra/main.bicep` todavía tiene `raKvApi`, `raKvFunc` con alcance en todo el vault, `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`, ninguna restricción de transición ni condición ABAC, y no tiene `dataprotection-keys`, `dataprotection-cobranza-api` ni `ASPNETCORE_FORWARDEDHEADERS_ENABLED`. Contra esa plantilla, SEG-DP-01/02/03a, SEG-KV-01/02, SEG-TR-01, SEG-FH-01 y SEG-EA-02 darían NO CUMPLE. Es lo esperado hasta que `devops` termine. Los scripts usan los nombres del ADR: contenedor `dataprotection-keys`, clave `dataprotection-cobranza-api`, secreto `acs-connection-string`, regla `operador-temporal` y `ipSecurityRestrictionsDefaultAction`. El nombre de la regla de permiso de la Web App para `ipOperador` no está en el ADR: los scripts no dependen de él (cuentan las reglas Allow).

## Hallazgos informados a la sesión principal (transcritos el 06-11-2026 por el orquestador)

Estos hallazgos se entregaron en el informe final de `seguridad` a la sesión principal y no habían quedado en este archivo. Se transcriben sin cambios de fondo para que las citas de `infra/main.bicep` y de la evidencia de `devops` tengan respaldo.

| Id | Severidad | Hallazgo | Tratamiento |
| --- | --- | --- | --- |
| SEG-H10 | Alta | La plantilla de ese momento todavía tenía `raKvApi`, `raKvFunc` sobre todo el vault y `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`, y no tenía la restricción de transición, la condición ABAC ni los recursos de Data Protection | Corregido por `devops` el 06-11-2026 (`evidencias/2026-11-06_adr001_devops/CAMBIOS.md`); volver a correr la verificación tras el despliegue |
| SEG-H11 | Media | El nombre de la regla de permiso de la Web App para `ipOperador` no estaba en el ADR | `devops` lo fijó como `operador-transicion` (Allow, /32, prioridad 100); los scripts `s12_*` no dependen del nombre (cuentan reglas Allow) |
| SEG-H12 | Media | Mientras se publica, el SCM queda abierto a la IP del operador hasta que se vuelve a correr `s12_endurecer.sh` | Cerrarlo en la misma sesión con `plantilla_ventana_operador.md` y verificar SEG-27 y SEG-28; `desplegar.sh` lo cierra en los pasos 8 y 10 |
| SEG-H13 | Baja | SEG-KV-04 necesita acceso al plano de datos de Key Vault, cerrado fuera de la ventana | Correrla con la ventana abierta; fuera de ella sale NO VERIFICADO |
| SEG-H14 | Baja | ShellCheck no está instalado | Instalarlo y pasarlo antes del despliegue |

Nota: la prueba en seco que `seguridad` relanzó al final de su sesión (verificar y pruebas de red con simulados) fue detenida por falta de memoria del equipo y luego el agente alcanzó el límite de uso; los resultados válidos son los archivos 03 a 05 de esta carpeta.
