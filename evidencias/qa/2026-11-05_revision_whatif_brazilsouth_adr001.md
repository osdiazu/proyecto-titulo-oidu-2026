# Informe QA 05-11-2026: reconstrucción de main.bicep, what-if en brazilsouth, SQL 01/02, eliminar_entorno.sh y ADR-001

Revisor: agente `qa` (revisión independiente). No se modificó ningún archivo del proyecto. Solo se ejecutaron comandos de lectura y validación (`az bicep build/lint/build-params` sobre una copia en un directorio temporal, `az deployment group what-if`, `az ... show/list`, `bash -n`, `git check-ignore`, `git diff`, `dotnet build`).

## 1. Alcance revisado

Cambios sin commit sobre `main` (base `9dc69de`):

| Archivo | Estado git |
| --- | --- |
| `.gitignore` | Modificado |
| `infra/main.bicep`, `infra/main.bicepparam`, `infra/entorno.ejemplo.env` | Nuevos |
| `sql/01_esquema_cobranza.sql`, `sql/02_identidades_y_permisos.sql` | Nuevos |
| `scripts/eliminar_entorno.sh` | Nuevo |
| `docs/adr/ADR-001-autenticacion-propia-sin-entra-usuarios.md` | Nuevo |
| `evidencias/2026-11-05_whatif_brazilsouth/` (12 archivos) | Nuevos |

Contrastados con: `CLAUDE.md`, `docs/05`, `docs/06`, `sql/00`, `sql/03`-`sql/11`, `scripts/s10_*`, `s11_*`, `s12_*`, `s14_*`, `infra/modulos/*.bicep`, `src/Cobranza.Api`, `src/Cobranza.Functions`.

Recursos de Azure consultados (solo lectura): suscripción `b492…` (Azure for Students, tenant `72fd…`); grupo de recursos `rg-cobranza-apt` (brazilsouth, `Succeeded`, 0 recursos, 0 despliegues); grupo Entra `grp-cobranza-sql-admin` (`7074…e6be`, seguridad, el operador `bf48…f2fe` es miembro: `true`); proveedores Microsoft.Communication, microsoft.insights, Microsoft.KeyVault, Microsoft.OperationalInsights, Network, Storage, Sql y Web: todos `Registered`; sin Key Vault eliminados `kv-cobranza*`; runtimes `DOTNETCORE:10.0` y `DOTNET-ISOLATED|10.0` disponibles; B1 Linux disponible en Brazil South.

Decisiones del usuario aceptadas como legítimas (no se tratan como desviación): región brazilsouth, solo tenant Duoc, reconstrucción de `main.bicep` desde S6-S8, modelo desplegar/eliminar/redesplegar, días DEMO 7/0/3/7, grupo/RG/proveedores ya creados, ADR-001 aún sin implementar (referencia a `easyauth-client-secret` esperada).

## 2. Validaciones reejecutadas por QA

| Comando | Resultado QA | Evidencia del devops | Coincide |
| --- | --- | --- | --- |
| `az bicep version` | 0.48.1 | 0.48.1 | Sí |
| `az bicep build --file main.bicep` | exit 0, sin advertencias | exit 0 | Sí |
| `az bicep lint --file main.bicep` | exit 0, salida vacía | exit 0 | Sí |
| `az bicep build-params` sin variables | BCP427 en líneas 13 y 14 | BCP427 | Sí |
| `az bicep build-params` con GUID ficticios | exit 0 | exit 0 | Sí |
| `az bicep lint --file main.bicepparam` | exit 0 | exit 0 | Sí |
| `az bicep build` de `modulos/seguridad_perimetral.bicep` y `autenticacion_api.bicep` | exit 0 | (no registrado) | — |
| Conteo sobre el JSON compilado | 29 declaraciones; 24 simples + 4 bucles de 5 + 1 bucle de 3 = 47 | 29 / 47 | Sí |
| `az deployment group what-if` (IP_OPERADOR vacío, CICLO_KV=1) | `Succeeded`, 46 Create, 0 Modify, 0 Delete; nombres `*-yvlgzz`, `kv-cobranza-dev-ahfg2w`, `stcobranzadevyvlgzznj` | 46 Create | Sí |
| `bash -n scripts/eliminar_entorno.sh` | OK; fin de línea LF (`.gitattributes`) | OK | Sí |
| ShellCheck | No instalado en el equipo | No instalado | NO VERIFICADO |
| `dotnet build` (solución) | 4 errores NU1902/NU1903 (`System.Security.Cryptography.Pkcs` 9.0.0), ya registrados en `evidencias/desarrollo/` | — | Fuera del cambio |

Efecto secundario observado: con el comando por defecto, `az bicep build-params --file main.bicepparam` escribe `main.json` junto al bicepparam (no `main.parameters.json`). Ver hallazgo M-02.

## 3. Resultados por punto de la lista de revisión

| # | Punto | Resultado | Evidencia |
| --- | --- | --- | --- |
| 1 | Trazabilidad | CUMPLE | `CAMBIOS.md` relaciona C1-C6 (docs/06), N1-N13 y SQL-02 con su motivo y archivo. Cabeceras de `main.bicep` (líneas 6-11) y `main.bicepparam` (líneas 3-4) declaran la reconstrucción |
| 2 | Coherencia con la arquitectura y decisiones | CUMPLE CON OBSERVACIONES | Nombres, IP, SKU, intercalación, PITR/LTR/Zone, ACS United States y runtimes coinciden con la sección 3. Sin regresiones a pasarela de pago, SMTP, PostgreSQL/MySQL, RA-GRS ni Functions de consumo. Observaciones: M-01, M-09, B-05 |
| 3 | Código .NET (configuración) | CUMPLE CON OBSERVACIONES | Las 18 claves `Cobranza__*` y `CRON_*` de `main.bicep` (líneas 604-671) coinciden con `OpcionesCobranza.cs` y `%CRON_*%`. `ValidateOnStart` impide el arranque sin textos de Finanzas (M-04). El build de la solución falla por un motivo ajeno a este cambio |
| 4 | Bicep y scripts | CUMPLE CON OBSERVACIONES | Build y lint limpios, sin `--mode Complete`, parámetros sin valores inventados (Finanzas vacíos; días marcados DEMO). ShellCheck NO VERIFICADO (B-03). `s10_configurar_jobs.sh` contradice N4 (M-06) |
| 5 | SQL | NO CUMPLE | `sql/01` (S6-S8 sin cambios) es incompatible con 04, 05, 07, 08 y 11: falla 04 y 07 no puede dar 10/10 (C-01). `sql/02` correcto (CUMPLE) |
| 6 | Seguridad | CUMPLE CON OBSERVACIONES | Sin acceso público salvo `ipOperador`; 5 PE con IP fijas y DNS; Key Vault RBAC con purga; SQL solo Entra ID y TLS 1.2; Storage sin clave compartida. Observaciones: A-01 (encabezado falsificable si se publica la API actual), M-01 (auditoría), M-07 (RBAC con ADR-001). Easy Auth: NO APLICA (reemplazado por ADR-001, no implementado) |
| 7 | Continuidad | CUMPLE | PITR 35 (líneas 400-406), LTR P8W/P12M (410-417), `requestedBackupStorageRedundancy: Zone` (396). Costo de LTR tras eliminar el RG documentado. H2 (B1 sin redundancia) sigue documentado en CLAUDE.md |
| 8 | Documentación y evidencias | NO CUMPLE (parcial) | La reconstrucción está declarada y las salidas están guardadas. Faltan evidencias de las acciones de escritura en Azure (grupo, RG, proveedores) y `10_proveedores.txt` quedó desactualizado (M-03). Idioma español sin emojis: CUMPLE |
| 9 | Pruebas de despliegue P01-P37 | NO APLICA | Nada desplegado. `scripts/verificar_despliegue.sh` no existe en el repositorio |

## 4. Revisión detallada por tema

### 4.1 `infra/main.bicep` y `main.bicepparam`

- Sección 3 de CLAUDE.md (sin contar la región): VNet `vnet-cobranza` 10.20.0.0/16; `snet-app` .1.0/24 delegada a `Microsoft.Web/serverFarms` con `nsg-app`; `snet-pe` .2.0/24 con `nsg-pe` (100: 1433, 110: 443 desde snet-app, 4000 `Deny-VNet-Inbound`); `cidrHost(prefijoSnetPe, 3..7)` produce .4 a .8; NIC `nic-pe-<x>-cobranza-dev`; memberName `default` para el vault. CUMPLE.
- C1-C6: C1, C2, C3, C4 y C6 implementados. C5 declarado, pero queda incompleto (M-01).
- Seguridad: SQL `publicNetworkAccess` y Key Vault `Disabled` cuando `ipOperador` está vacío (líneas 322 y 347); regla `operador-temporal` condicional (360-367); Key Vault `defaultAction: Deny` con `ipRules` solo para la IP. TLS 1.2 en SQL, Storage y sitios. TDE no se declara (B-01).
- RBAC: API y Function con Key Vault Secrets User sobre el vault; operador con Secrets Officer; Function con Blob Data Owner, Queue Data Contributor y Table Data Contributor sobre la cuenta. Es mínimo para el diseño actual. Con ADR-001 deja de serlo (M-07).
- Salidas que consumen otros archivos: `s10` (FUNC_APP, KV_NAME, ACS_NAME, SQL_SERVER, SQL_DB, REMITENTE), `s11` (WEB_APP, KV_NAME, SQL_*), `s12` (WEB_APP, FUNC_APP, SQL_SERVER, STORAGE), `s14` (SQL_*, FQDN, WEB_APP, FUNC_APP) y los parámetros de `seguridad_perimetral.bicep` (vnetName, webAppName, functionAppName, sqlServerName, sqlDatabaseName, keyVaultName, acsName, logAnalyticsName, `snet-pe`, `nsg-pe`). Todas existen (líneas 849-872). CUMPLE.
- Conteo 29/47: confirmado. La justificación "+1 = raKvOperador, no incluido en S10" no se puede demostrar (B-02).

### 4.2 Secretos e identificadores

- Búsqueda en todo el árbol de trabajo (excepto `.git`, `bin`, `obj`), incluidos `evidencias/` y `.claude/`: no aparece ningún GUID completo que empiece por `7074`, `bf48`, `b492` o `72fd`. Los únicos GUID completos son los ID públicos de roles integrados (`main.bicep` 794-798 y `seguridad_perimetral.bicep` 305). No hay IPv4 públicas, `AccountKey=`, `Password=`, SAS ni cadenas de ACS. En el historial de git (`git log --all -p`) tampoco hay coincidencias. CUMPLE.
- `git check-ignore -v`: `infra/entorno.local.env` queda ignorado por `.gitignore:15`; `infra/entorno.ejemplo.env` entra por la negación `.gitignore:17` (`git status` lo muestra como `??`). `infra/main.parameters.json` queda ignorado por `.gitignore:19`. `infra/main.json` NO queda ignorado (M-02).

### 4.3 SQL

- `sql/02`: usa `$(UsuarioFunctionApp)` y `$(UsuarioApi)`. `CREATE USER` es idempotente (`DATABASE_PRINCIPAL_ID ... IS NULL`). No contiene GRANT. CUMPLE.
- Permisos frente al código:

| Consumidor | Objetos que usa el código | GRANT | Resultado |
| --- | --- | --- | --- |
| Function App | `SELECT` sobre la vista de `Cobranza__VistaOrigen` (`OrigenRegularizadosSql.cs:30`) | 03:54 | OK |
| Function App | `sp_IniciarSincronizacion`, `sp_FinalizarSincronizacion`, `sp_GenerarAlertasVencimiento`, `sp_RegistrarNotificacion` | 04:226-229 | OK |
| Function App | `sp_SincronizarClientesRegularizados` + TVP `cob.ListaRut` | 05:185-186 | OK |
| API | `sp_ConsultarEstadoCliente`, `sp_ListarPedidosCliente`, `sp_IndicadoresCartera`, `sp_ListarSincronizaciones`, `sp_Salud` | 06:119-123 | OK |

  Quitar `db_datareader`, `EXECUTE ON SCHEMA::cob` e `INSERT ON cob.LogNotificacion` no deja sin permisos a ningún acceso del código. El encadenamiento de propiedad (todo es de `dbo`) cubre las tablas, el trigger y la llamada interna a `sp_LiberarPedidosRetenidos`. CUMPLE.
- Incompatibilidad de `sql/01` (reportada por el arquitecto): confirmada y más amplia de lo reportado (C-01).

### 4.4 Ajustes de la Function App

- Las claves coinciden 1 a 1 con `OpcionesCobranza` (sección `Cobranza`) y con `%CRON_SINCRONIZACION%` y `%CRON_NOTIFICACIONES%`. `Cobranza__AcsConnectionString` es una referencia `SecretUri` al secreto que crea la plantilla. CUMPLE.
- D12 frente a H1: con 10 correos y 12.000 ms se respeta nominalmente 10/h y 5/min, pero en el límite exacto y con déficit de capacidad (M-05).
- `ValidateOnStart`: `[Required]` sin `AllowEmptyStrings` rechaza `""` en `CanalesPagoTexto` y `TelefonoContacto`, y `CorreoContacto` también falla `[EmailAddress]`. Con los parámetros vacíos del bicepparam (líneas 42-44), el worker lanza `OptionsValidationException` al iniciar. El comportamiento es el esperado, pero bloquea las pruebas de los jobs (M-04). El arranque real en Azure queda NO VERIFICADO.

### 4.5 `scripts/eliminar_entorno.sh` (no ejecutado)

- Confirmación: hay que escribir el nombre exacto del grupo (líneas 80-84). `--dry-run` sale en la línea 75, antes de cualquier borrado. CUMPLE.
- Alcance: el único comando destructivo es `az group delete -n "$RG" --yes` (línea 87). No toca el grupo Entra, los registros de aplicación, LTR ni los vaults eliminados; solo los lista. CUMPLE.
- `CICLO_KV`: se incrementa solo después de un borrado exitoso (`set -e`), con validación numérica, y se agrega si falta (89-107). CUMPLE. Observaciones en B-04.
- `bash -n` OK. ShellCheck NO VERIFICADO.

### 4.6 ADR-001

- RF-06 (clave de API rol Ventas y cookie Ventas), RF-07 (cookie Finanzas), RNF-02 (TLS, TDE, hash; valores de las claves en Key Vault; Data Protection cifrada con Key Vault) y RNF-05 (`cob.LogAcceso` con actor, IP y motivo) están cubiertos en el diseño. Es coherente con CLAUDE.md: escritura solo por procedimientos, EXECUTE por objeto y sin cambios en las identidades administradas.
- Fortalezas: PBKDF2 V3 sin cambiar `IterationCount`; hash ficticio contra la enumeración por tiempo; bloqueo atómico en un solo UPDATE; sello de seguridad para invalidar cookies; `__Host-`, `HttpOnly`, `SameSite=Strict` y 30 min deslizantes con 8 h absolutas; antifalsificación también en el login; claves de API con 256 bits y SHA-256 (justificado); alta del primer administrador sin contraseñas en git y con cambio obligatorio; riesgo de PITR sobre revocaciones identificado.
- Riesgos no cubiertos o incompletos: A-01 (transición), M-07 (RBAC del vault y del Storage), M-08b (encabezados reenviados), B-10 (bloqueo como denegación de servicio y hash visible en la línea de comandos).
- Lista de archivos por agente (5.10): incompleta. Falta `scripts/s14_simulacro_pitr.sh` (lo exige la sección 4.2 del propio ADR), falta retirar `raKvApi` en `main.bicep`, y la fila de `sql/07` (línea 392, "Sin cambio") no considera C-01.

### 4.7 Evidencias (regla 6)

- `CAMBIOS.md` registra qué cambió, por qué y en qué archivo, y las salidas están en 01-11. La reconstrucción está declarada en tres lugares. Los GUID aparecen truncados y la IP reemplazada. CUMPLE en lo que cubre.
- No cumple en: la línea 3 afirma que el único comando de escritura fue `what-if`, pero el grupo `grp-cobranza-sql-admin`, el RG y el registro de los 4 proveedores existen en Azure (verificado) y no tienen evidencia fechada. `10_proveedores.txt` muestra `NotRegistered` y hoy están `Registered` (M-03).

## 5. Hallazgos

### Crítica

**C-01. `sql/01` (S6-S8 sin cambios) es incompatible con los scripts S10-S15. El despliegue SQL falla y `sql/07` no puede dar 10/10.** Corrige: `dba`.

| Ubicación en 01 | Definición en 01 | Valores que usan los scripts posteriores | Efecto |
| --- | --- | --- | --- |
| `sql/01:57` `CK_EstadoMorosidad_Origen` | `JobSincronizacion`, `JobVencimiento`, `UsuarioFinanzas` | `SincronizacionAutomatica` (05:167), `Manual` (07:53-57, 08:64-68, 11:54) | La sincronización real (RF-02/03/04) falla por CHECK en cada ejecución con cambios; 11 y 08 fallan |
| `sql/01:22` `CK_Cliente_Segmento` | Supermercado, Minimarket, Hotel, Restaurante, Almacen, Distribuidor | `Tradicional`, `Digital` (07:37-49, 08:46-56) | Fallan los INSERT de clientes de 07 y 08 |
| `sql/01:76-89` `cob.LogNotificacion` | Sin `ClienteId`; `ResultadoEnvio` NOT NULL sin DEFAULT; `CK_LogNotificacion_Tipo` (`PreVencimiento`, `Vencimiento`, `PostVencimiento`) | 04:178-181 inserta `ClienteId` y no `ResultadoEnvio`; tipos `Preaviso`, `Mora1`, `Mora2` (04:119-122); 08:37 filtra por `ClienteId`; 00:44 espera `ClienteId` | 04 no agrega `ClienteId` porque la tabla ya existe (04:27), así que `CREATE OR ALTER PROCEDURE cob.sp_RegistrarNotificacion` falla con error 207 (columna inválida en tabla existente) y la sección 6 de 04 falla con él. Aunque se agregara la columna, el INSERT fallaría por NOT NULL y por CHECK |
| `sql/01:93-102` `cob.LogSincronizacion` | `Resultado` NOT NULL sin DEFAULT con CHECK (`Exito`, `Error`); `RegistrosLeidos`, `ClientesRegularizados` | 04:194 inserta solo `FechaInicio, Estado`; 04 agrega `ClientesLeidos`, `ClientesActualizados` y `Estado` (`EnCurso`, `Exitosa`, `Fallida`) | `sp_IniciarSincronizacion` falla en cada ejecución por NOT NULL; quedan columnas duplicadas con semántica distinta |

Efecto sobre `sql/07`: con `SET XACT_ABORT OFF`, el primer INSERT de cliente (07:36-37) falla por `CK_Cliente_Segmento` y `@A` queda NULL. Después fallan los INSERT de estados por `CK_EstadoMorosidad_Origen`, y `sp_SincronizarClientesRegularizados` (si 05 llegó a ejecutarse) no encuentra clientes. Resultado estimado por análisis estático: a lo sumo PU-05/PU-10 en estados indeterminados; en ningún caso 10/10. No se ejecutó contra la base.

Acción: el `dba` debe alinear 01 con el esquema que esperan 00 y 03-11. Las opciones son recuperar el `sql/01` de S10 (CLAUDE.md sección 7: `Codigo_Evidencia_S10.zip` lo incluía) o escribir un ajuste documentado de CHECK y columnas. Después, revisión de `qa`. No inventar valores: los conjuntos válidos ya están en 00:86-89.

### Alta

**A-01. Si se publica la API actual sin Easy Auth, cualquiera puede falsificar la identidad.** `src/Cobranza.Api/Seguridad/EasyAuthHandler.cs:27-48` acepta sin validar el encabezado `X-MS-CLIENT-PRINCIPAL`. App Service solo elimina ese encabezado cuando Easy Auth está habilitado (el propio comentario de las líneas 14-15 lo condiciona). Con ADR-001, Easy Auth no se configurará. La Web App queda pública (`main.bicep:526-566` y `s12_endurecer.sh` mantiene la entrada pública con `CERRAR_API_PUBLICA=no`). Si se ejecuta el paso 5 de la secuencia (`s11_configurar_api.sh`, publicación) antes de implementar ADR-001, un tercero puede enviar un principal con rol `Finanzas.Consulta` y leer la cartera completa y el estado de todos los clientes (RF-06/RF-07, RNF-02). El ADR no trata esta transición.
Acción: `arquitecto` agrega al ADR la regla "no publicar `src/Cobranza.Api` hasta implementar ADR-001". Si hace falta publicar antes, `seguridad` y `devops` aplican `ipSecurityRestrictionsDefaultAction=Deny` en la Web App (solo IP del operador) y `desarrollador` retira `EasyAuthHandler` como primer paso de la implementación. No bloquea `az deployment group create` (la plantilla no publica código), pero sí la publicación.

### Media

**M-01. Auditoría SQL hacia Azure Monitor incompleta (C5).** `main.bicep:370-386` habilita `isAzureMonitorTargetEnabled`, pero la auditoría de servidor con destino Azure Monitor necesita una configuración de diagnóstico `SQLSecurityAuditEvents` en la base `master`, como indica `infra/modulos/seguridad_perimetral.bicep:539-552`. `main.bicep:419-435` solo la crea sobre `sqldb-cobranza`. Hasta desplegar el módulo S12, los eventos de auditoría no llegan a Log Analytics (RNF-05; P de auditoría). Agente: `devops` (agregar `existing` master y `diagnosticSettings`, o declarar explícitamente que C5 depende de S12). Efecto en Azure: NO VERIFICADO.

**M-02. `.gitignore` no cubre la salida por defecto de `build-params`.** `az bicep build-params --file infra/main.bicepparam` sin `--outfile` escribe `infra/main.json` con los Object ID reales. `.gitignore:19` solo ignora `infra/*.parameters.json` y `git check-ignore infra/main.json` devuelve 1 (no ignorado). Agente: `devops` (ignorar `infra/main.json` o documentar el uso obligatorio de `--outfile infra/main.parameters.json` o `--stdout`).

**M-03. Acciones de escritura en Azure sin evidencia y evidencia desactualizada (regla 6).** La creación de `grp-cobranza-sql-admin` (y la membresía del operador), del RG `rg-cobranza-apt` en brazilsouth y el registro de 4 proveedores están verificados en Azure, pero no tienen archivo fechado en `evidencias/`. `CAMBIOS.md:3` puede leerse como que no hubo otras escrituras, y `10_proveedores.txt` muestra `NotRegistered`. Agente: `devops` u orquestador (agregar evidencia con fecha, comando, aprobación del usuario y salida con ID truncados, y una nota en `CAMBIOS.md`).

**M-04. La Function App no arrancará con los parámetros actuales.** `main.bicepparam:42-44` deja vacíos `canalesPagoTexto`, `telefonoContacto` y `correoContacto`. `OpcionesCobranza.cs:35-37` los exige y `Program.cs:61` aplica `ValidateOnStart`. Es intencional (no inventar valores de Finanzas), pero impide las pruebas de jobs y notificaciones de la semana 11. Agente: `arquitecto` con el equipo: definir textos DEMO con aprobación humana, rotulados como DEMO igual que los días, o esperar a Finanzas y dejar registrado que esas pruebas quedan PENDIENTE.

**M-05. D12 frente a H1: capacidad insuficiente y margen nulo.** `main.bicep:111-119`. (a) 10 correos por ejecución × 6 ejecuciones (12-17 UTC) = 60 por día hábil, frente a un promedio simulado de 111 por día hábil (H1): la cola crece y los avisos llegan atrasados. (b) 12.000 ms deja exactamente 5 envíos por ventana de 60 s, sin margen ante la medición de ACS. (c) `NotificacionesFunction.cs:50-59` registra un 429 como `Fallido`, lo que suma 1 a `Intentos`, y `sp_GenerarAlertasVencimiento` (04:137) excluye el aviso al tercer intento. Con límites tan bajos, un aviso puede perderse por 429 repetidos, no por errores reales. Agentes: `arquitecto` (D12: dejar por escrito la capacidad diaria y la condición de dominio propio), `desarrollador` y `dba` (no contar el 429 como intento o tratarlo aparte). Valores definitivos: PENDIENTE equipo.

**M-06. `scripts/s10_configurar_jobs.sh` revierte N4 y duplica la plantilla.** Las líneas 56-57 fijan `MaxCorreosPorEjecucion=90` y `PausaEntreCorreosMs=2100`, contrarios a H1 y N4. Las líneas 36-37 recrean `acs-connection-string` por el plano de datos, lo que exige abrir el vault. Si se ejecuta después de `main`, deja la configuración que H1 descarta. Agente: `devops` (alinear s10 con la plantilla o dejarlo solo para la publicación).

**M-07. ADR-001: RBAC que deja de ser mínimo y separación de claves de Data Protection.** (a) `raKvApi` (`main.bicep:800-808`) otorga a la API Key Vault Secrets User sobre todo el vault. Sin Easy Auth, la API no necesita ningún secreto y, con el diseño 5.9, podría leer `acs-connection-string` y todos los secretos `apikey-*`. El ADR (línea 249) lo menciona, pero no propone retirarlo. (b) La Function App tiene Storage Blob Data Owner sobre toda la cuenta (`main.bicep:831-843`). Con 5.5, el contenedor `dataprotection-keys` va en esa misma cuenta, así que la identidad de la Function App podría leer o reemplazar el anillo de claves. El cifrado con Key Vault reduce la lectura, pero no impide reemplazar el anillo. Agente: `arquitecto` (actualizar 5.5 y 5.10: retirar `raKvApi`; cuenta o alcance separado para Data Protection, o riesgo aceptado por escrito) y `devops`.

**M-08. Riesgos del diseño ADR-001 y de SQL no cubiertos.** (a) `CREATE USER ... FROM EXTERNAL PROVIDER` (`sql/02:35-41`) resuelve la identidad en Graph con el token del operador. En el tenant Duoc, con restricciones de directorio, puede fallar. NO VERIFICADO; como alternativa conviene preparar `CREATE USER [...] WITH SID = <appId>, TYPE = E`. Agente: `dba`. (b) ADR 5.4 (línea 227): si los encabezados reenviados se configuran sin `KnownProxies`/`KnownNetworks` o sin `ForwardLimit`, un cliente puede falsificar `X-Forwarded-For`, evadir el limitador por IP y escribir una IP falsa en `cob.LogAcceso` (RNF-05). Agente: `arquitecto` (fijar la regla en el ADR) y `desarrollador`.

**M-09. Decisiones del 05-11 no reflejadas en el contexto maestro.** La región brazilsouth figura en `CAMBIOS.md` N10, en `main.bicep:20` y en ADR-001 §1, pero no en CLAUDE.md (secciones 3, 5 y 9 siguen con `chilecentral`) ni en un ADR propio. La sección 7 aún dice "Recursos desplegados en Azure: ninguno", y ya existen el RG y el grupo. D13 (ADR-001) solo está propuesto (ADR §8). Agente: `arquitecto`, con aprobación humana (regla 8 y sección 10).

### Baja

- **B-01** `main.bicep:388-398`: TDE no se declara. Está activo por defecto en bases nuevas y `seguridad_perimetral.bicep:513-519` lo fija, pero no queda explícito en `main` (RNF-02). `devops`.
- **B-02** `CAMBIOS.md:45` y `09_conteo_recursos.txt`: la diferencia +1/+1 se atribuye a `raKvOperador` "no incluido en S10", pero `docs/05:15` y CLAUDE.md sección 3 describen `operadorObjectId` con Secrets Officer como parte de S10. Sin el original, el origen de la diferencia es NO VERIFICADO; conviene registrarlo así. `devops`.
- **B-03** ShellCheck no se ejecutó (`11_bash_n_eliminar_entorno.txt`). CLAUDE.md sección 7 exige ShellCheck 0.10.0 sin hallazgos. `devops`.
- **B-04** `eliminar_entorno.sh:45-47`: muestra la suscripción, pero no la compara con una esperada. Si `CICLO_KV` está exportada en la sesión actual, el script actualiza el archivo pero no la variable, y debería indicar que hay que volver a cargar `entorno.local.env`. `.claude/agents/devops.md:21` prohíbe al agente ejecutar `az group delete`: dejar escrito en la cabecera que el script lo ejecuta solo un humano. `devops`.
- **B-05** `main.bicep:441`: el nombre de Storage usa 8 caracteres de `uniqueString` (CLAUDE.md dice 6; heredado de S6-S8). Registrarlo como diferencia. `devops`/`arquitecto`.
- **B-06** Comentarios desactualizados: `OpcionesCobranza.cs:28-31` (100/h, 30/min), `local.settings.example.json` (90/2100) y `main.bicep:609` ("UTC-3"; Chile alterna UTC-3 y UTC-4 y el SP usa `Pacific SA Standard Time`). `desarrollador`/`devops`.
- **B-07** `sql/01` no es idempotente (`CREATE TABLE` sin guardas, líneas 17-116). Es aceptable con el modelo de base nueva por ciclo, pero va contra el punto 5 de la lista. `dba`.
- **B-08** `main.bicep:51,139`: `ipOperador` no valida el formato IPv4. Un valor erróneo falla recién al desplegar. `devops`.
- **B-09** Table Data Contributor y el PE de table pueden no ser necesarios para Functions que solo usan temporizadores. Revisar el mínimo. NO VERIFICADO. `devops`.
- **B-10** ADR-001: (a) el bloqueo por cuenta permite que un tercero bloquee a usuarios conocidos (denegación de servicio); conviene documentarlo como riesgo aceptado. (b) 5.9 paso 2 pasa el hash por `sqlcmd -v`, que queda visible en la lista de procesos y en `BATCH_COMPLETED_GROUP`; es bajo porque la contraseña temporal es aleatoria y se cambia en el primer acceso. `arquitecto`.
- **B-11** `docs/04` estima costos para Chile Central; con brazilsouth los precios cambian. PENDIENTE recalcular. `arquitecto`.
- **Fuera de alcance (informativo):** `dotnet build` falla con 4 errores NU1902/NU1903 (ya registrados en `evidencias/desarrollo/`). Bloquea la publicación de la API y de las Functions, no la plantilla. `desarrollador`.

## 6. Qué bloquea cada acción

### 6.1 `az deployment group create` de `infra/main.bicep`

Técnicamente no hay bloqueos: el what-if reejecutado por QA da `Succeeded` con 46 Create, los proveedores están registrados, el RG existe y está vacío, y el grupo administrador existe con el operador como miembro. Faltan:

1. Confirmación humana explícita (CLAUDE.md regla 5).
2. Antes del create, recomendado: M-02 (evitar un commit accidental de Object ID) y M-03 (evidencia de las acciones previas).
3. Aceptar o corregir M-01 (sin el arreglo, la auditoría no llega a Log Analytics hasta desplegar S12).
4. Después del create: reaplicar `s12_endurecer.sh` (regla 7) y no publicar la API actual (A-01).

### 6.2 Pasos posteriores de la semana 11 (no son el create)

- SQL (`desplegar_sql.sh`, que no existe en el repositorio): bloqueado por C-01 y en riesgo por M-08a.
- Publicación de la API: bloqueada por A-01 y por el build fallido.
- Jobs: bloqueados por M-04; capacidad condicionada por M-05 y M-06.

### 6.3 Implementación de ADR-001

1. C-01: el `dba` debe corregir `sql/01` antes de, o junto con, el cambio de `cob.UsuarioInterno`. La afirmación del ADR (línea 392) de que 07 conserva 10/10 hoy es falsa.
2. A-01: incorporar la regla de transición al ADR.
3. M-07 y M-08b: ajustar el diseño (RBAC del vault, separación de Data Protection, encabezados reenviados).
4. Completar la lista 5.10 con `scripts/s14_simulacro_pitr.sh` y el retiro de `raKvApi`.
5. Build de la solución en verde (NU1902/NU1903) antes de agregar código nuevo.
6. Registro de D13 y de la región en CLAUDE.md con aprobación humana (M-09), y actualizar `.claude/agents/qa.md` punto 6 (requiere aprobación humana, ADR §6).
7. PENDIENTE del equipo: sistema consumidor de RF-06, canal de entrega de contraseñas temporales, valores DEMO de bloqueo y sesión.

## 7. Veredicto

**RECHAZADO.**

Motivo: C-01 (Crítica, `sql/01` incompatible con 04/05/07/08/11) y A-01 (Alta, riesgo de suplantación al publicar la API actual sin Easy Auth). `infra/main.bicep` y `main.bicepparam` por sí solos quedan en condición de APROBADO CON OBSERVACIONES (M-01, M-02, B-01, B-02, B-05, B-08, B-09): la plantilla es coherente, compila sin advertencias, no contiene identificadores y su what-if es reproducible. `sql/02`, `.gitignore` (salvo M-02) y `eliminar_entorno.sh` (salvo B-03 y B-04) no tienen hallazgos de severidad alta.
