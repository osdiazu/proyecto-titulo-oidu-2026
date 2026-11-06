# Corrección C-01: alineación de `sql/01` con 00 y 03-11, y alternativa M-08a en `sql/02`

- Fecha: 05-11-2026. Agente: `dba`. Origen: hallazgo C-01 y M-08a en `evidencias/qa/2026-11-05_revision_whatif_brazilsouth_adr001.md`.
- Estado: diseñado/escrito y validado con análisis estático. **No se ejecutó en ningún motor SQL** (ni local ni Azure). Nada desplegado.
- Archivos modificados: `sql/01_esquema_cobranza.sql`, `sql/02_identidades_y_permisos.sql`. No se tocaron `sql/00`, `03` a `11`, `src/`, `infra/`, `scripts/`, `docs/` ni CLAUDE.md.

## 1. Entorno de validación

| Elemento | Resultado |
| --- | --- |
| sqlcmd, SqlLocalDB, servicio MSSQL en Windows | No instalados |
| Docker / Podman (Windows y WSL Ubuntu) | No instalados |
| SQL Server en WSL (`/opt/mssql`) | No instalado |
| Validación usada | Estática: (a) analizador sintáctico oficial `Microsoft.SqlServer.TransactSql.ScriptDom` 180.140.0 (`TSql160Parser`) con .NET SDK 10.0.303, más verificación cruzada automática de INSERT/UPDATE contra las definiciones de tablas y los CHECK de tipo `IN`; (b) ejecución mental de 01, 02, 03, 04, 05, 06, 11, 00, 07 y 08 |

La herramienta se compiló en un directorio temporal fuera del repositorio; su fuente queda en `herramienta/` para reproducir el análisis. Simula las guardas `IF OBJECT_ID ... IS NULL` (la primera definición de una tabla gana) y los `ALTER TABLE ADD` condicionados de 04. No verifica SELECT (revisados a mano, sección 4) ni valores que llegan por parámetros (revisados a mano).

Nota: `sql/01` no estaba bajo control de versiones (`git status`: sin seguimiento) y no existe otra copia en disco. La versión S6-S8 se reconstruyó de forma literal desde la lectura previa a la edición en `01_original_S6S8.sql`, para trazabilidad y para la prueba de control.

## 2. Resultado

| Salida | Archivo | Resultado |
| --- | --- | --- |
| Control: 01 original S6-S8 + 02..11 | `01_control_01_original.txt` | 0 errores de sintaxis, **25 hallazgos** (reproduce C-01 completo y lo amplía) |
| Validación: 01 corregido + 02..11 | `02_validacion_01_corregido.txt` | 0 errores de sintaxis, **0 hallazgos**, código de salida 0 |

Hallazgos del control (resumen): 04:178 `ClienteId` inexistente y falta `ResultadoEnvio` NOT NULL; 04:194 falta `Resultado` NOT NULL; 05:167 `SincronizacionAutomatica` rechazado por CHECK; 11:54, 07:53-57 y 08:64-68 `Manual` rechazado; 07:37-49 y 08:47-59 `Tradicional`/`Digital` rechazados por CHECK.

## 3. Cambios en `sql/01_esquema_cobranza.sql`

Líneas referidas a la versión nueva (210 líneas). Original: `01_original_S6S8.sql` (233 líneas).

| # | Objeto | Antes (original) | Ahora (nuevo) | Motivo |
| --- | --- | --- | --- | --- |
| 1 | Cabecera | 1-7 | 1-31 | Registro del cambio, intercalación heredada de la base, recomendación `sqlcmd -b` |
| 2 | Protección contra estructura S6-S8 | No existía | 38-54 | Idempotencia controlada: si detecta columnas o CHECK de S6-S8, emite error y `SET NOEXEC ON` (no altera nada); `SET NOEXEC OFF` al final (209) |
| 3 | Guardas `IF OBJECT_ID(...) IS NULL` en todas las tablas y `IF TYPE_ID` en `cob.ListaRut` | Sin guardas (B-07) | 60, 80, 100, 118, 138, 165, 195 | Regla de idempotencia del DBA. Excepción: `cob.UsuarioInterno` (fila 13) |
| 4 | `cob.Cliente.EstadoActual` | 27-28 (columna con DEFAULT y CHECK) | Retirada | El estado vigente es el último registro de `cob.EstadoMorosidad` (`cob.vw_EstadoActualCliente`, 04:67-79). 00:28-30 no la espera; ningún script 03-11 ni `src/` la usa; 05 nunca la actualizaría y quedaría desfasada |
| 5 | `CK_Cliente_Segmento` | 22: Supermercado, Minimarket, Hotel, Restaurante, Almacen, Distribuidor | 66: `Tradicional`, `Digital` | Valores usados por 07:37-49 y 08:47-59. Dominio definitivo PENDIENTE de confirmar con el equipo (ver pendientes) |
| 6 | `CK_Factura_Estado` | 43: incluye `Anulada` | 90: `Pendiente`, `Vencida`, `Pagada` | 00:86. 04:114 y 06:41,82-85 tratan toda factura distinta de `Pagada` como adeudada: una `Anulada` recibiría avisos de cobranza y sumaría a la deuda |
| 7 | `CK_EstadoMorosidad_Origen` | 57: JobSincronizacion, JobVencimiento, UsuarioFinanzas | 110: `SincronizacionAutomatica`, `Manual` | 00:87; usados por 05:167, 11:54, 07:53-57, 08:64-68 |
| 8 | `CK_EstadoMorosidad_Anterior` | No existía | 106 | RNF-05 (auditoría con valor anterior válido). Todos los escritores (05:156, 11:44, 07, 08) usan uno de los 4 estados |
| 9 | `cob.LogNotificacion` | 76-89 | 138-157 | Columnas que usan 00:43-44, 04:38-44 y 168-181, 06:88-89, 08:37, 09:30-34, 11:19-23: se agregan `ClienteId` (FK, NOT NULL), `EstadoEnvio`, `Intentos` (DEFAULT 0), `FechaRegistro` (DEFAULT), `FechaActualizacion`; se retiran `FechaEnvio` y `ResultadoEnvio`; `Destinatario` pasa a NULL (como en 04:38) conservando `NVARCHAR(254)` |
| 10 | `CK_LogNotificacion_Tipo` | 80: PreVencimiento, Vencimiento, PostVencimiento | 144: `Preaviso`, `Vencimiento`, `Mora1`, `Mora2` | D3, 00:88, 04:119-122, `src/Cobranza.Functions/Servicios/PlantillaCorreo.cs` |
| 11 | `CK_LogNotificacion_EstadoEnvio` | `CK_LogNotificacion_Resultado` (Aceptado, Entregado, Fallido, Limitado) | 147: `Aceptado`, `Fallido` | 00:89, 04:160 |
| 12 | Restricción única y nombres | `UQ_LogNotificacion_Aviso` | 154: `UQ_LogNotificacion_Factura_Tipo` (FacturaId, TipoAviso); índice `IX_LogNotificacion_Cliente` (156) | Se mantiene "único por factura y tipo de aviso" (CLAUDE.md 4) con el mismo nombre que 04:34; índice para la FK y el borrado por cliente de 08:37 |
| 13 | `cob.UsuarioInterno` | 106-112 | 184-190, **sin cambios** | Instrucción del orquestador: su rediseño lo define el ADR-001. Es la única sentencia no idempotente: al reejecutar 01 da error 2714 (con `sqlcmd -b` detiene el script) |
| 14 | `cob.LogSincronizacion` | 93-102 | 165-177 | Columnas de 04:54-60 y 189-221, 06:90-91 y 103-104, 09:37-38: `ClientesLeidos`, `ClientesActualizados`, `PedidosLiberados` (NULL), `Estado` con DEFAULT `EnCurso` y CHECK `EnCurso`/`Exitosa`/`Fallida`; `FechaInicio` con DEFAULT. Se retiran `RegistrosLeidos`, `ClientesRegularizados`, `Resultado` |
| 15 | Procedimientos y trigger v1 (`sp_LiberarPedidosRetenidos`, `tr_EstadoMorosidad_Liberar`, `sp_SincronizarClientesRegularizados`, `sp_GenerarAlertasVencimiento`) | 119-233 | Retirados; nota en 199-206 | Referenciaban columnas retiradas (`Cliente.EstadoActual`, `RegistrosLeidos`, `Resultado`) y fallarían al crearse (error 207). 04 y 05 crean la versión vigente con `CREATE OR ALTER`; 00 (que se ejecuta después de 11) verifica que existan |

Sin cambios: `cob.Pedido` (salvo guarda), `cob.Factura` (salvo CHECK de estado y guarda), `cob.ListaRut` (una columna `Rut VARCHAR(12)`), FK, índices, `CK_Cliente_Convenio`, `CK_Pedido_Estado`.

## 4. Ejecución mental en el orden de despliegue

| Paso | Resultado esperado |
| --- | --- |
| 01 | Crea esquema, 7 tablas, `UsuarioInterno` y `cob.ListaRut`. Sin lógica |
| 02 | Crea los 2 usuarios contenidos (Azure SQL con Entra ID). Sin cambios de permisos |
| 03 | `origen_sim`, tabla y vista; SELECT solo sobre la vista para la Function App |
| 04 | Las guardas de 04:27 y 04:47 se omiten y los 14 `ALTER TABLE ADD` no se ejecutan (las columnas ya existen con los mismos nombres de restricción). La vista y los 4 procedimientos compilan: todas las columnas referenciadas existen. GRANT EXECUTE a la Function App |
| 05 | Crea `cob.LogCambioPedido` (sin FK ni CHECK, destino de OUTPUT INTO), `fn_NormalizarRut`, v2 de `sp_LiberarPedidosRetenidos`, trigger y `sp_SincronizarClientesRegularizados`. GRANT EXECUTE y sobre el tipo |
| 06 | 5 procedimientos de consulta; columnas existentes; GRANT EXECUTE a la API |
| 11 | `sp_ReintentarNotificacion` (usa `Intentos`, `EstadoEnvio`, `FechaActualizacion`, `Detalle`) y `sp_CambiarEstadoClienteManual` (`Manual` admitido) |
| 00 | Consulta 1: las 33 columnas esperadas existen, 0 filas. Consulta 2: los 4 objetos existen (creados en 04 y 05), 0 filas. Consulta 3: `ListaRut` con 1 columna, 0 filas |
| 07 | Ver sección 5 |
| 08 | Los 5 INSERT de clientes, el historial (`Manual`), las facturas (`Pendiente`/`Vencida`/`Pagada`), los pedidos y la fuente simulada cumplen los CHECK. El DELETE por `ClienteId` en `LogNotificacion` (08:37) es válido. La verificación final devuelve 4 filas DEMO (Preaviso, Vencimiento, Mora1, Mora2) si `DiasMora1 < DiasMora2` (lo exige 04:104) |

## 5. Conclusión sobre 07: 10/10 esperado (estático, no ejecutado)

Datos: A Suspendido con 2 retenidos y 1 despachado; B sin historial (AlDia); C Suspendido con 1 retenido; D Moroso sin pedidos; E Suspendido con 1 retenido, fuera de la lista. Lista: A, B, C con formato `76.500.005-k`, D y un RUT inexistente.

| Caso | Traza | Esperado | Obtenido (estático) |
| --- | --- | --- | --- |
| PU-01 | A pasa a Regularizado; el trigger libera A-001 y A-002 | Regularizado / 2 | Regularizado / 2 |
| PU-02 | El UPDATE de 05 filtra `Estado = 'Retenido'` | Despachado | Despachado |
| PU-03 | OUTPUT INTO registra A-001, A-002, C-001 con origen `TriggerRegularizacion` | 3 | 3 |
| PU-06 | 5 normalizados, 1 no encontrado, 3 cambios (A, C, D), 3 retenidos antes y 0 después | 5/1/3/3 | 5/1/3/3 |
| PU-05 | B no está en Moroso/Suspendido; la vista devuelve `AlDia` por ISNULL | AlDia | AlDia |
| PU-07 | `fn_NormalizarRut` iguala `76.500.005-k` y `76500005-K` | Regularizado / Liberado | Regularizado / Liberado |
| PU-08 | D Moroso pasa a Regularizado (sin pedidos) | Regularizado | Regularizado |
| PU-09 | Última fila de A: `SincronizacionAutomatica`, admitido ahora por `CK_EstadoMorosidad_Origen` | SincronizacionAutomatica | SincronizacionAutomatica |
| PU-04 | 2a ejecución: A, C, D ya Regularizado; 0 cambios; el trigger recibe 0 filas; historial de A = 2 manuales + 1 | 0/0/3 | 0/0/3 |
| PU-10 | E sigue Suspendido; `sp_LiberarPedidosRetenidos` lanza 50020, capturado por TRY/CATCH | 50020 | 50020 |

Por qué antes no podía dar 10/10: con el 01 original fallaban los INSERT de clientes (Segmento) y del historial (OrigenCambio) de 07, y además el INSERT de 05:166 por CHECK.

Riesgos residuales que solo una ejecución real despeja:
1. PU-10 deja la transacción no confirmable (`XACT_ABORT ON` dentro del procedimiento). Después se hace `INSERT @Resultados`. Se espera que funcione porque las variables de tabla no participan en la transacción del usuario, pero no se ha verificado en un motor.
2. `INSERT @Salida EXEC` con `BEGIN TRAN/COMMIT`, `sp_getapplock` y un trigger con cursor anidado. Sintácticamente es válido y se espera que funcione, pero no se ha verificado.
3. La herramienta no evalúa valores que llegan por parámetros. Se revisaron a mano: `@EstadoEnvio` (04:160) y `@Estado` (04:209) se validan antes de escribir; si llegara un `@TipoAviso` inválido, lo rechaza el CHECK con el error 547.

## 6. Revisión de `src/` contra SQL (sin cambios en `src/`)

Coinciden los nombres de procedimientos, parámetros, columnas devueltas y tipos leídos (`GetInt32`/`GetInt64`/`GetDecimal`/`GetDateTime` sobre int/bigint/decimal/date/datetime2), los valores `Aceptado`/`Fallido`, `Exitosa`/`Fallida`, los tipos de aviso de `PlantillaCorreo.cs` y el TVP `cob.ListaRut` con una columna `Rut`. Hay incompatibilidades o riesgos que corresponden al desarrollador (y a 04):

| Id | Ubicación | Observación |
| --- | --- | --- |
| S-1 | `src/Cobranza.Functions/Servicios/RepositorioCobranza.cs:111` y `sql/04:151` | `@Destinatario` es `VarChar(120)`, pero `cob.Cliente.Email` es `NVARCHAR(254)`. Un correo de más de 120 caracteres se trunca sin aviso y los caracteres no ASCII se pierden. Propuesta: `NVarChar(254)` en ambos lados. 04 no se modificó, por la instrucción de preferir cambios en 01 |
| S-2 | `src/Cobranza.Functions/Funciones/NotificacionesFunction.cs` (comentario) | Mencionaba límites ACS de 30/min y 100/h. En la versión actual, modificada en paralelo por `desarrollador`, ya dice 5/10 (H1). Cerrado; solo se deja registro |
| S-3 | `RepositorioConsultas.cs:7` y `Modelos.cs:10` | `Segmento` se trata como opcional, aunque en la base es NOT NULL. Es inocuo; solo se informa |

## 7. Cambio en `sql/02_identidades_y_permisos.sql` (M-08a)

- Se agregó en las líneas 44-97 un bloque comentado: la alternativa `CREATE USER [...] WITH SID = <sid>, TYPE = E` para ambas identidades. No cambia el comportamiento actual.
- El SID se forma con el **client ID (appId)** de la identidad administrada, no con el object ID (principalId). Se obtiene con `CONVERT(varbinary(16), CAST(N'<clientId>' AS uniqueidentifier))`. El bloque arma la sentencia con SQL dinámico porque `WITH SID` solo acepta un literal binario.
- Formas de obtener el clientId: `az ad sp show --id <principalId> --query appId`, que requiere lectura de directorio; la API ARM `.../providers/Microsoft.ManagedIdentity/identities/default`, que no se ha verificado; o el claim `appid`/`azp` de un token de la identidad. Después se verifica con `CAST(sid AS uniqueidentifier)` en `sys.database_principals`.
- El bloque no usa `$(...)` ni `GO`. sqlcmd sustituye variables también dentro de comentarios y exigiría definirlas, y un `GO` podría cortar el lote dentro del comentario. Esto no se ha verificado con go-sqlcmd.
- No se escribieron IDs reales. Para activar el bloque se reemplazan los marcadores `<...>`.

## 8. Impacto en permisos y en la aplicación

- Permisos: sin cambios. Siguen las mismas concesiones EXECUTE mínimas de 03-06. Ninguna identidad recibe permisos de escritura directa ni `db_datareader`/`db_datawriter`.
- Aplicación: el contrato de los procedimientos no cambia, porque 04, 05 y 06 no se modificaron. Al retirar `Cliente.EstadoActual` no se afecta a `src/`, que lee el estado desde los procedimientos (vista).

## 9. Pendientes

1. **Ejecución local real** de 01-11 y 07 en SQL Server 2022 (contenedor o LocalDB) con intercalación `Modern_Spanish_CI_AS`. En 02, `FROM EXTERNAL PROVIDER` se reemplaza localmente por `CREATE USER ... WITHOUT LOGIN`. Requiere instalar Docker o SQL Server; decisión del equipo.
2. Dominio de `Cliente.Segmento`: `Tradicional`/`Digital` (07/08) frente al tipo de negocio de S6-S8 (Supermercado, Minimarket, etc.). Confirmar con el equipo si debe existir una segunda columna.
3. `cob.UsuarioInterno`: pendiente del ADR-001 (arquitecto). Al rediseñarla, agregarle una guarda de idempotencia.
4. D5: 05 regulariza desde Moroso **o** Suspendido y el trigger libera ante cualquier paso a Regularizado (PU-08 lo prueba); RF-04 dice solo Suspendido. No se modificó.
5. Brechas funcionales (arquitecto): ningún procedimiento carga o actualiza `cob.Cliente`, `cob.Factura` ni `cob.Pedido` desde la embotelladora, nada pasa automáticamente un cliente a Moroso/Suspendido (solo 11, manual) y nada marca facturas `Vencida` o `Pagada`. Con la regla "escritura solo mediante procedimientos", hacen falta procedimientos de carga.
6. `scripts/desplegar_sql.sh` no existe en el repositorio (devops). Debe ejecutar sqlcmd con `-b` y en el orden de CLAUDE.md sección 4.
7. `sql/10` contiene `$(Minutos)` y `$(Simulacro)` dentro de comentarios. Con sqlcmd podría exigir `-v` aunque solo se cree la tabla (no verificado).
8. Propuesta (no implementada): unicidad del RUT normalizado (`Cliente.Rut` es único solo en su forma literal; 05, 06 y 11 comparan normalizado).
9. Revisión de `qa` de este cambio.
