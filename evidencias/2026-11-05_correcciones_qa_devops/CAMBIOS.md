# Cambios 05-11-2026: correcciones del informe QA que no dependen de ADR-001

Responsable de la ejecución: agente `devops` (Claude Code), por encargo del orquestador. Base: `evidencias/qa/2026-11-05_revision_whatif_brazilsouth_adr001.md` y `docs/seguridad/politica_credenciales_y_accesos.md`.

Nada se creó, modificó ni eliminó en Azure. Los comandos contra Azure fueron de lectura (`az ad group show`, `az ad signed-in-user show`, `az account show`) y `az deployment group what-if`. No se hizo commit. No se editaron `sql/`, `src/`, `docs/`, CLAUDE.md, el ADR, los scripts `s12_*` ni `infra/modulos/`.

Quedan para la ronda de ADR-001: Data Protection, retiro de Easy Auth (`MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`) y retiro de `raKvApi`.

## 1. Cambios

| Hallazgo | Cambio | Por qué | Archivo |
| --- | --- | --- | --- |
| M-01 | `sqlMaster` (`existing`, base `master`) + `diagSqlMaster` (`diag-auditoria-sql`, `SQLSecurityAuditEvents` hacia Log Analytics). `sqlAuditoria` depende de `diagSqlMaster` | Con auditoría de servidor y destino Azure Monitor, los eventos salen por la base `master`. Sin esto no llegaban a Log Analytics hasta desplegar S12 | `infra/main.bicep` |
| M-01 (no duplicar) | Mismo nombre (`diag-auditoria-sql`), mismo ámbito (`master`) y mismo contenido que `diagSqlMaster` de `infra/modulos/seguridad_perimetral.bicep:540` | Una configuración de diagnóstico se identifica por ámbito + nombre: en Azure queda un solo recurso. Al desplegar el módulo S12 después, ARM aplica el mismo recurso sin cambios, sin duplicar datos y sin el error de "categoría ya enviada al mismo destino" que daría un segundo nombre. Es el mismo criterio que ya se usa con `auditingSettings/default` (declarado igual en ambos archivos). No se editó el módulo (responsabilidad de `seguridad`) | `infra/main.bicep` |
| M-01 (nota) | Comentario en `diag-sqldb`: su `SQLSecurityAuditEvents` solo recibe datos con auditoría a nivel de base (no habilitada), por lo que no duplica | Aclarar las dos fuentes | `infra/main.bicep` |
| SEG-H03 | `diagKv` (`diag-kv`, `categoryGroup: audit` hacia Log Analytics) sobre el Key Vault | Las lecturas de secretos no quedaban auditadas sin el módulo S12 | `infra/main.bicep` |
| SEG-H03 (no duplicar) | Mismo nombre, ámbito y contenido que `diagKv` de `seguridad_perimetral.bicep:557` | Mismo criterio que M-01 | `infra/main.bicep` |
| M-02 | `.gitignore`: `infra/**/*.json` (cubre `infra/main.json` de `build-params`/`build` y las salidas de `infra/modulos/`) | `build-params` sin `--outfile` escribía `infra/main.json` con los Object ID reales y no estaba ignorado | `.gitignore` |
| M-02 | Uso obligatorio de `--outfile` hacia una carpeta temporal (`mktemp -d`) y borrado posterior, documentado en la cabecera del bicepparam y en la plantilla de variables | El `.gitignore` es la segunda barrera, no la principal | `infra/main.bicepparam`, `infra/entorno.ejemplo.env` |
| M-06 / D12 | `maxCorreosPorEjecucion` 10 y `pausaEntreCorreosMs` 15000 (antes 12000). Valores DEMO aprobados por el usuario. 15000 ms deja 4 por minuto (margen frente a 5/min) | Decisión del usuario 05-11-2026 | `infra/main.bicep`, `infra/main.bicepparam` |
| M-06 / D12 | `pausaEntreCorreosMs`: `@minValue(0)` pasa a `@minValue(1)` | Coincidir con `[Range(1, 60000)]` que el `desarrollador` fijó en `OpcionesCobranza.PausaEntreCorreosMs` (aviso del orquestador) | `infra/main.bicep` |
| M-06 | `s10_configurar_jobs.sh`: `MaxCorreosPorEjecucion=10`, `PausaEntreCorreosMs=15000` (antes 90 y 2100) | Los valores anteriores superaban H1 y revertían la plantilla | `scripts/s10_configurar_jobs.sh` |
| M-06 | Se eliminó el paso 1 de s10 (`az communication list-key` + `az keyvault secret set acs-connection-string`), la variable `ACS_NAME` y el requisito de Key Vault Secrets Officer y de la extensión `communication`. Pasos renumerados 1-3 | Redundante: `main.bicep` crea el secreto por el plano de control (`secretAcs`; docs/05 línea 16), que funciona con el vault cerrado. El paso de s10 obligaba a abrir el vault a la IP del operador y creaba una versión nueva del mismo valor | `scripts/s10_configurar_jobs.sh` |
| M-04 | Textos DEMO en el bicepparam con el comentario "valores de demostracion inventados, no entregados por Finanzas (pendiente 3...)": `canalesPagoTexto`, `telefonoContacto`, `correoContacto` (dominio `.example`, RFC 2606) | Aprobados por el usuario para que la Function App arranque en las pruebas. La plantilla sigue sin valor por defecto | `infra/main.bicepparam`, descripciones en `infra/main.bicep` |
| B-04 | `eliminar_entorno.sh`: cabecera "SOLO LO EJECUTA UN HUMANO"; comparación de la suscripción activa con `SUBSCRIPTION_ID_ESPERADA` (si no coincide, sale con 1; sin la variable, el borrado real se niega y `--dry-run` solo avisa); comparación sin distinguir mayúsculas; los ID se muestran truncados; aviso de volver a cargar `infra/entorno.local.env` tras incrementar `CICLO_KV` (indica si la sesión aún tiene el valor anterior); rango de `--help` ajustado | Hallazgo B-04 | `scripts/eliminar_entorno.sh` |
| B-04 | `SUBSCRIPTION_ID_ESPERADA=` (vacío) en la plantilla de variables, con la forma de obtenerlo | El ID real solo va en `infra/entorno.local.env` (ignorado) | `infra/entorno.ejemplo.env` |
| B-05 | Sufijo del Storage: `take(unico, 6)` (antes 8, heredado de S6-S8). Nombre resultante `stcobranzadevyvlgzz` | Alinear con CLAUDE.md sección 3 y docs/05 ("uniqueString(6)"). Nada desplegado: sin impacto | `infra/main.bicep` |
| B-06 | Comentario de `CRON_NOTIFICACIONES`: Chile continental alterna UTC-3 y UTC-4 (12:00 UTC = 09:00 u 08:00) | Comentario incorrecto ("UTC-3") | `infra/main.bicep` |
| B-08 | `ipOperador`: `@maxLength(18)` y normalización con `parseCidr('<ip>/32').network` (solo si tiene valor). La máscara se ignora; siempre /32 | Un valor inválido falla en la validación de plantilla (what-if/preflight), antes de crear recursos. Bicep no tiene expresiones regulares en decoradores; esta es la forma simple | `infra/main.bicep` |
| SEG-H02 | Sin cambio. Comentario en `logAnalytics` que lo marca como decisión PENDIENTE | Retención 30 días < PITR 35 días; ampliarla cambia costos: decide el equipo | `infra/main.bicep` |

Conteo: 31 declaraciones / 49 recursos (antes 29/47; +`diagKv`, +`diagSqlMaster`). `sqlMaster` es `existing` y no se cuenta. What-if: 48 Create con `IP_OPERADOR` vacío (la regla `operador-temporal` es condicional).

## 2. Evidencias de este directorio

| Archivo | Contenido |
| --- | --- |
| `01_versiones.txt` | Azure CLI 2.63.0, Bicep CLI 0.48.1, .NET SDK 10.0.303, bash 5.2.37 |
| `02_bicep_build.txt` | `az bicep build --outfile <temporal>`: exit 0, sin advertencias |
| `03_bicep_lint.txt` | Lint de `main.bicep`: exit 0, sin hallazgos. Lint de `main.bicepparam`: sin variables, BCP427 (esperado); con variables, exit 0 |
| `04_build_params.txt` | `build-params --outfile <temporal>`: exit 0; valores con GUID truncados; ningún `.json` creado en `infra/` |
| `05_whatif_acceso_cerrado.txt` | What-if (`FullResourcePayloads`) con `IP_OPERADOR` vacío y `CICLO_KV=1`: 48 Create, 0 Modify, 0 Delete. `siteConfig` aparece enmascarado por el what-if |
| `06_whatif_ip_documentacion.txt` | What-if con `203.0.113.10/24` (dirección de documentación RFC 5737, no es la del operador): 49 Create; regla y `ipRules` con `203.0.113.10` (/32) |
| `07_whatif_ip_invalida.txt` | `999.1.1`: `InvalidTemplate ... The specified CIDR '999.1.1/32' is not valid` (exit 1). 19 caracteres: BCP332 en compilación (exit 1) |
| `08_validacion_opciones_cobranza.txt` | Valores DEMO contra los atributos de `OpcionesCobranza` (copia de la clase en un proyecto temporal): VÁLIDO; control con textos vacíos: INVÁLIDO |
| `09_bash_n.txt` | `bash -n` OK en `s10_configurar_jobs.sh` y `eliminar_entorno.sh` (LF). ShellCheck no instalado |
| `10_busqueda_ids_ip.txt` | 0 archivos con los ID completos (grupo, operador, suscripción, tenant) o la IP del operador; 0 en el historial git |
| `11_diff.txt` | Diferencias de los 6 archivos modificados |
| `12_whatif_final.txt` | What-if (`ResourceIdOnly`) después de `@minValue(1)`: 48 Create, exit 0. Build, lint y build-params repetidos al final de 02 y 04 |

Las carpetas temporales (JSON compilados, proyecto de validación, script auxiliar de saneamiento) se crearon con `mktemp -d` fuera del repositorio y se borraron al terminar.

## 3. Decisiones pendientes registradas

| Id | Tema | Estado |
| --- | --- | --- |
| SEG-H02 | Retención de Log Analytics (30 días) menor que la ventana PITR (35 días). Opciones: ampliar a 35 o más (costo adicional por GB retenido) o aceptar la brecha con `cob.LogAcceso` a 90 días (política de seguridad, sección B) | PENDIENTE equipo (afecta costos). Sin cambio en la plantilla |
| D12 / M-05 | 10 por ejecución × 6 ejecuciones = 60 correos por día hábil, frente a 111 de promedio simulado (H1). Requiere dominio propio o escalonar envíos. El 429 cuenta como intento fallido | PENDIENTE `arquitecto`, `desarrollador`, `dba` |
| M-04 | Textos DEMO: reemplazar por los oficiales de Finanzas (pendiente 3) | PENDIENTE Finanzas |
