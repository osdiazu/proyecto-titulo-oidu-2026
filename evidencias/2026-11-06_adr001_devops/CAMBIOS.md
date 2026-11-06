# Cambios 06-11-2026: ADR-001 (infraestructura y scripts), agente `devops`

Responsable de la ejecución: agente `devops` (Claude Code), por encargo del orquestador. Contrato: `docs/adr/ADR-001-autenticacion-propia-sin-entra-usuarios.md` (tabla 5.10, secciones 5.4.1, 5.5, 5.5.1, 5.9, 5.11), `docs/seguridad/politica_credenciales_y_accesos.md` (D.5, A.10, B.3, C.3), firmas de `sql/12` (`evidencias/2026-11-06_adr001_sql/CAMBIOS.md`, sección 4) e interfaz de `src/Cobranza.Herramientas/README.md`.

Nada se creó, modificó ni eliminó en Azure. Comandos contra Azure: lectura (`az ad group show`, `az ad signed-in-user show`, `az account show`) y `az deployment group what-if`. No se ejecutó ningún script de `scripts/` (ni los de SEG-H01, ni `desplegar.sh`, ni `desplegar_sql.sh`). No se hizo commit. No se editaron `sql/`, `src/`, `docs/`, CLAUDE.md ni `scripts/s12_*`.

Estado: diseñado/escrito y validado localmente (Bicep y `bash -n`). Nada desplegado ni probado en Azure.

## 1. `infra/main.bicep` y `infra/main.bicepparam`

| Id | Cambio | Por qué | Archivo |
| --- | --- | --- | --- |
| A1 | Se retira el ajuste `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` (referencia a `easyauth-client-secret`) | ADR 3.3 y 5.10: sin Easy Auth | `main.bicep` |
| A2 | Se retira `raKvApi` (API con Key Vault Secrets User sobre el vault) | ADR 5.5.1: la API no necesita secretos | `main.bicep` |
| A3 | `raKvFunc`: alcance en el secreto `acs-connection-string` (`scope: secretAcs`), nombre `guid(secretAcs.id, funcApp.id, rol)` | ADR 5.5.1 | `main.bicep` |
| A4 | `raStorageFunc` se separa: `raBlobFunc` (Storage Blob Data Owner, cuenta) con `conditionVersion 2.0` y condición ABAC; Queue y Table siguen en el bucle `raStorageFunc` | ADR 5.5.1 | `main.bicep` |
| A5 | Condición ABAC: las acciones de datos `blobs/read`, `write`, `delete`, `add/action`, `move/action`, `deleteBlobVersion/action`, `permanentDelete/action`, `tags/read`, `tags/write` solo se permiten si `@Resource[...containers:name] StringNotEquals 'dataprotection-keys'`. El what-if muestra la expresión evaluada (`08_whatif_ip_documentacion.txt`) | ADR 5.5.1. NO VERIFICADO en Azure: requiere la prueba negativa SEG-DP-03 | `main.bicep` |
| A6 | `blobServices/default` + contenedor `dataprotection-keys` (`publicAccess: None`) | ADR 5.5 | `main.bicep` |
| A7 | Clave `dataprotection-cobranza-api`: RSA 2048, `wrapKey`/`unwrapKey`, no exportable. ARM la crea solo si no existe (no genera versiones nuevas al redesplegar) | ADR 5.5 | `main.bicep` |
| A8 | `raKvCryptoApi`: API con Key Vault Crypto User sobre la clave; `raBlobApi`: API con Storage Blob Data Contributor sobre el contenedor | ADR 5.5.1 | `main.bicep` |
| A9 | Web App, ajustes nuevos: `DataProtection__BlobUri` (`<blob endpoint>dataprotection-keys/keys.xml`), `DataProtection__KeyIdentifier` (`keyUri` sin versión), `Seguridad__SaltosProxyConfiables` (parámetro `saltosProxyConfiables`, 1 a 2, valor 1), `ASPNETCORE_FORWARDEDHEADERS_ENABLED=false` | ADR 5.4.1 y 5.5; valores confirmados por el desarrollador | `main.bicep`, `main.bicepparam` |
| A10 | Web App: `ipSecurityRestrictionsDefaultAction: Deny`; `ipSecurityRestrictions` = una regla **`operador-transicion`** (Allow, `<ipOperador>/32`, prioridad 100) solo si `ipOperador` tiene valor; vacío = sin reglas de permiso | ADR 5.11 regla 3; nombre de la regla registrado por SEG-H11 | `main.bicep` |
| A11 | Web App y Function App: `scmIpSecurityRestrictionsUseMain: false` y `scmIpSecurityRestrictionsDefaultAction: Deny`. Function App: además `ipSecurityRestrictionsDefaultAction: Deny` | Pedido de `seguridad`: que `main` no deje el SCM abierto por herencia ni reabra la Function App al redesplegar; mismo estado que deja `s12_endurecer.sh` | `main.bicep` |
| A12 | `sqlTde` (`transparentDataEncryption/current`, `Enabled`) | B-01 (ADR 4.3) | `main.bicep` |
| A13 | Comentario de `raKvOperador`: "claves de API (ADR-001)" en lugar de `easyauth-client-secret` | Política D.5 punto 2 | `main.bicep` |
| A14 | Salidas nuevas: `dataProtectionBlobUri`, `dataProtectionKeyId`, `dataProtectionContainer`, `saltosProxyConfiables` | Las usa `s11_configurar_api.sh` | `main.bicep` |
| A15 | `param saltosProxyConfiables = 1` explícito, con comentario (2 solo con D11) | Visibilidad del valor de topología | `main.bicepparam` |

Ya presentes antes de esta tarea (sin cambio): `diagKv` (SEG-H03), D12 DEMO 10/15000 y textos DEMO de Finanzas en el bicepparam.

### 1.1 Sonda `/salud` con la restricción de transición

No verificado. La plantilla mantiene `healthCheckPath: '/salud'`. Si la restricción `Deny` afecta a la sonda de App Service queda PENDIENTE de verificar en Azure (ADR 5.11 regla 3). No se cambió nada por esto. Hechos relevantes:
- Con una sola instancia B1, la sonda no reemplaza instancias: solo informa el estado.
- Mientras rija 5.11, la API no se publica, así que `/salud` no responde aunque la sonda llegue. Lo esperado es que el sitio figure como no saludable hasta que se publique.

Verificación propuesta en el despliegue: métrica `HealthCheckStatus` y `az webapp show --query siteConfig.healthCheckPath`.

## 2. Scripts

| Script | Estado | Notas |
| --- | --- | --- |
| `scripts/comun_operacion.sh` (nuevo) | Escrito | Funciones compartidas: `exigir_humano` (SEG-H01), `confirmar`, `sql_lote` (sqlcmd `-b -x`, Entra `ActiveDirectoryDefault`, lote por stdin), lectura de salidas, compilación de la herramienta, `desplegar_main`/`whatif_main` (siempre `--mode Incremental`) |
| `s11_alta_usuario.sh`, `s11_restablecer_clave.sh`, `s11_baja_usuario.sh`, `s11_alta_clave_api.sh`, `s11_revocar_clave_api.sh` (nuevos) | Escritos, NO ejecutados | Cabecera "SOLO LO EJECUTA UN HUMANO, nunca un agente"; `set -euo pipefail`; sin `set -x` ni `tee`; confirmación escribiendo `si`; firmas exactas de `sql/12`; rol exacto `Finanzas`/`Ventas`/`Admin` (D-6); secreto `apikey-<consumidor>-<prefijo>` (D-7); revocación idempotente (D-8); interfaz de la herramienta según su README (DLL en carpeta temporal, `cygpath -w`, salida `<prefijo> <HEX>`) |
| `s14_revision_post_restauracion.sh` (nuevo) | Escrito, NO ejecutado | `--base-original`, `--base-restaurada`, `--punto` o `--sin-original` (regla conservadora). Usa `sp_ListarEventosAccesoDesde` (columnas de `sql/12`), `sp_RevocarClaveApi`, `sp_CambiarEstadoUsuario`, `sp_CambiarRolUsuario` y `sp_InvalidarTodasLasSesiones`. Deshabilita secretos huérfanos. Los restablecimientos de contraseña se dejan al humano con `s11_restablecer_clave.sh` |
| `s14_simulacro_pitr.sh` | Una línea al final | Recuerda el paso obligatorio de revisión posterior a la restauración |
| `s15_purgar_log_acceso.sh` (nuevo) | Escrito, NO ejecutado | `--dias` (90 a 36500), `--confirmar`, `--lote` (5000 DEMO); muestra el estado previo y `FilasBorradas` |
| `s11_configurar_api.sh` | Reescrito | Sin Easy Auth. Deshabilita Easy Auth si estuviera activo, borra `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` y aplica los ajustes de ADR-001 desde las salidas de la plantilla. **Ya no publica** la API |
| `s10_configurar_jobs.sh` | `OMITIR_PUBLICACION=si` | Lo usa `desplegar.sh` porque publica antes, con la ventana SCM abierta |
| `desplegar_sql.sh` (nuevo) | Escrito, NO ejecutado | Orden 01, 02, 03, 04, 05, 06, 12, 11, 00, 07, 13, y 08 solo con `--demo`. Usa `sqlcmd -b`, Entra `ActiveDirectoryDefault`, servidor y `-v UsuarioFunctionApp`/`UsuarioApi` de las salidas. Verifica que la ventana esté abierta; `--abrir-ventana` y `--cerrar-ventana` (cierra con redespliegue vacío + `s12_endurecer.sh`). Registro en `evidencias/<fecha>_despliegue_sql/` |
| `desplegar.sh` (nuevo) | Escrito, NO ejecutado | 10 pasos con confirmación (ver sección 4). La publicación abre el SCM con `IP_PUBLICACION_SCM` mediante `s12_endurecer.sh` y lo cierra al terminar (`docs/seguridad/plantilla_ventana_operador.md`). La API solo se publica con `APROBACION_QA` (5.11) |
| `s11_registro_entra_id.sh`, `infra/modulos/autenticacion_api.bicep` | `git rm` (sin commit) | Antes se revisaron las referencias: solo quedaban en README (actualizado), `s11_configurar_api.sh` (reescrito), `main.bicep` (comentario retirado) y en textos históricos de CLAUDE.md y `docs/` (no editables; describen el retiro) |
| `README.md` | Actualizado | Estructura y procedimiento de despliegue |

### 2.1 Detección de Claude Code (SEG-H01, pendiente de la política D.5)

Verificado el 06-11-2026 en esta estación, dentro de la sesión del agente:
- La sesión exporta `CLAUDECODE` y `CLAUDE_CODE_ENTRYPOINT`, entre otras. Se registraron solo los nombres, no los valores.
- La entrada estándar del shell del agente no es una terminal.

`exigir_humano` rechaza la ejecución si encuentra cualquiera de esas variables o si no hay terminal (código 3). Es una barrera complementaria, no una garantía, porque el entorno se puede limpiar. La regla sigue siendo organizativa.

## 3. Validación (salida completa en este directorio)

| Archivo | Resultado |
| --- | --- |
| `01_versiones.txt` | Azure CLI 2.63.0, Bicep CLI 0.48.1, .NET SDK 10.0.303, bash 5.2.37, Python 3.14.7. **sqlcmd, ShellCheck y zip no instalados** |
| `02_bicep_build.txt` | exit 0, sin advertencias |
| `03_bicep_lint.txt` | `main.bicep` y `main.bicepparam`: exit 0, sin hallazgos |
| `04_build_params.txt` | exit 0 con `--outfile` temporal (borrado); GUID truncados; 0 `.json` en `infra/` |
| `05_conteo_recursos.txt` | 37 declaraciones (sin `existing`); bucles de 5 PE y 2 asignaciones; 1 condicional |
| `06_sitios_compilado.txt` | Ajustes y restricciones de ambos sitios en el ARM compilado (el what-if enmascara `siteConfig` con `*******`) |
| `07_whatif_ventana_cerrada.txt` | `IP_OPERADOR` vacío: **53 Create, 0 Modify, 0 Delete**, exit 0 |
| `08_whatif_ip_documentacion.txt` | `IP_OPERADOR=203.0.113.10` (RFC 5737, no es la del operador): **54 Create** (agrega `operador-temporal`), 0 Modify, 0 Delete |
| `09_bash_n.txt` | `bash -n` OK en los 17 scripts de `scripts/` y en `pruebas/consumidor_ventas_demo.sh`; 0 con CRLF; sin `set -x`/`tee` en los SEG-H01; cabecera SEG-H01 en los 5 |
| `10_diff.txt` | Diferencias de los archivos versionados modificados, retirados y nuevos |

Diferencia con el what-if del 05-11 (48 Create): +6 (`sqlTde`, `blobService`, `dpContainer`, `dpKey`, `raKvCryptoApi`, `raBlobApi`) y −1 (`raKvApi`) = 53.

Búsqueda de datos sensibles: 0 archivos del repositorio (fuera de `.git`, `bin`, `obj`) con el Object ID completo del grupo, del operador, de la suscripción o del tenant; 0 GUID completos en esta evidencia (los ID de roles integrados de Azure también se truncaron en `10_diff.txt`). IPv4 en la evidencia y en los archivos modificados: solo `10.20.0.0` (prefijo de diseño) y `203.0.113.10` (documentación). Los archivos temporales (`%TEMP%\devops_adr001`) se borraron al terminar.

## 4. Secuencia de `scripts/desplegar.sh`

1. Variables, herramientas y suscripción.
2. `az group create` si el grupo no existe.
3. `bicep build`, `lint`, `build-params` y `what-if`, con salida saneada en `evidencias/<fecha>_despliegue/`.
4. `create` con `IP_OPERADOR`: abre la ventana para SQL, Key Vault y `operador-transicion`.
5. `desplegar_sql.sh`.
6. Publicación:
   - `dotnet publish` y empaquetado zip con Python.
   - Apertura del SCM: `s12_endurecer.sh` con `IP_PUBLICACION_SCM=$IP_OPERADOR` y `ESTADO_TRANSICION=vigente` (o `publicacion-aprobada` con `APROBACION_QA`).
   - `az functionapp deploy` y, solo con aprobación de `qa`, `az webapp deploy`.
   - Cierre del SCM: `s12_endurecer.sh` sin la variable.
7. `s10` (sin publicar, con los valores leídos de la Function App) y `s11_configurar_api.sh`.
8. `s12_endurecer.sh`.
9. `curl /salud` desde la IP del operador.
10. Cierre de la ventana: redespliegue con `IP_OPERADOR` vacío y `s12_endurecer.sh`.

Efecto colateral: el paso 6 ejecuta `s12_endurecer.sh` completo, que también cierra SQL y Key Vault. Por eso el SQL va en el paso 5. Las altas de usuarios requieren volver a abrir la ventana (política A.10).

## 5. Pendientes y riesgos

- La sintaxis de la condición ABAC solo pasó por el what-if. ARM la valida al crear la asignación, y SEG-DP-03 (prueba negativa) está pendiente en Azure. La acción `blobs/filter/action` (búsqueda por etiquetas a nivel de cuenta) no está en la lista. Riesgo residual: un compromiso de la Function App podría ver nombres o etiquetas de blobs, pero no su contenido.
- Lectura del lote SQL desde stdin con go-sqlcmd: PENDIENTE de verificar en la estación del operador (sqlcmd no está instalado aquí). Si falla, los scripts SEG-H01 no escriben nada en la base.
- Escritura de la contraseña en la terminal de Git Bash (`hash-clave`, código 2 en mintty sin ConPTY): PENDIENTE de verificación humana (README de la herramienta, sección 6).
- `/salud` con `Deny`: PENDIENTE de verificar en Azure (sección 1.1).
- ShellCheck no instalado: solo se hizo `bash -n`.
- B-09 (si Queue Data Contributor hace falta con solo temporizadores): sin cambio.
- Redesplegar `main` restablece los ajustes y la configuración del sitio: reaplicar `s12_endurecer.sh` (regla 7). `desplegar.sh` lo hace en los pasos 6, 8 y 10.
