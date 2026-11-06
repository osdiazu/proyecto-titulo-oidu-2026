# ADR-001, parte SQL: autenticación propia, `Limitado` en notificaciones, scripts 12 y 13

- Fecha: 06-11-2026. Agente: `dba`. Origen: `docs/adr/ADR-001-autenticacion-propia-sin-entra-usuarios.md` (secciones 5.1, 5.2, 5.10, 5.12, 6, 7.1 y 7.2) y `docs/seguridad/politica_credenciales_y_accesos.md` (B.3, B.4, B.5, C.3 y D.3).
- Estado: diseñado/escrito y validado con análisis estático. **No se ejecutó en ningún motor SQL** (no hay motor local) **ni contra Azure**. Nada desplegado.
- Nota: la instrucción citaba la sección "Lista definitiva de tareas por agente, Fase A, dba" del ADR. Esa sección no existe en el ADR vigente (lo verifiqué con grep). Usé como lista de tareas la tabla 5.10 (filas `dba`), 7.1 punto 1 y la sección D.3 de la política.
- Archivos modificados: `sql/00_verificar_esquema.sql`, `sql/01_esquema_cobranza.sql`, `sql/02_identidades_y_permisos.sql` (solo comentario), `sql/04_jobs_bitacoras.sql`. Archivos nuevos: `sql/12_autenticacion.sql` y `sql/13_pruebas_autenticacion.sql`. No modifiqué `src/`, `infra/`, `scripts/`, `docs/` ni CLAUDE.md.
- Todos los `.sql` quedan solo en ASCII y con LF, igual que antes.

## 1. Objetos creados o modificados

| Archivo | Objeto | Cambio |
| --- | --- | --- |
| 01 | Protección inicial (55) | También se detiene sin cambios si `cob.UsuarioInterno` tiene `EntraObjectId` (definición anterior) |
| 01 | `cob.LogNotificacion` (159) | `CK_LogNotificacion_EstadoEnvio` admite `Aceptado`, `Fallido`, `Limitado` |
| 01 | Alteración controlada (172-189) | Si la tabla ya existía con el CHECK sin `Limitado`, se elimina y se vuelve a crear con `WITH CHECK` |
| 01 | `cob.UsuarioInterno` (211-) | Definición de ADR 5.1 (13 columnas), con guarda `IF OBJECT_ID ... IS NULL`. Ya no queda ninguna sentencia no idempotente en 01 |
| 04 | `cob.sp_RegistrarNotificacion` (157-189) | Acepta `Limitado`; con `Limitado` suma 0 a `Intentos` (UPDATE) e inserta `Intentos = 0` (INSERT). Rechaza `@EstadoEnvio` NULL. Mensaje 50002: "EstadoEnvio debe ser Aceptado, Fallido o Limitado." |
| 04 | `cob.sp_GenerarAlertasVencimiento` | Sin cambios de código; solo el comentario. Sigue excluyendo los avisos con `Aceptado` o `Intentos >= 3`, así que un aviso `Limitado` vuelve a salir (PA-20) |
| 12 | `cob.ClaveApi` (83) | Nueva (ADR 5.1), con guarda |
| 12 | `cob.LogAcceso` (118) | Nueva (ADR 5.1), con guarda, `IX_LogAcceso_Fecha` e `IX_LogAcceso_Usuario`. Incluye la columna `Detalle` (desviación D-1) |
| 12 | `cob.fn_SanearUsuarioIngresado` (157) | Nueva, auxiliar, sin GRANT |
| 12 | `cob.fn_EnmascararIp` (178) | Nueva, auxiliar, sin GRANT (IPv4 /24, IPv6 /48 con expansión de `::`) |
| 12 | 7 procedimientos con GRANT (244-430) | `sp_ObtenerUsuarioParaLogin`, `sp_ObtenerUsuarioPorId`, `sp_RegistrarLoginFallido`, `sp_RegistrarLoginExitoso`, `sp_RegistrarLogout`, `sp_CambiarClave`, `sp_ValidarClaveApi` |
| 12 | 11 procedimientos administrativos sin GRANT (468-784) | `sp_CrearUsuarioInterno`, `sp_RestablecerClaveUsuario`, `sp_DesbloquearUsuario`, `sp_CambiarEstadoUsuario`, `sp_CambiarRolUsuario`, `sp_RegistrarClaveApi`, `sp_RevocarClaveApi`, `sp_PurgarLogAcceso`, `sp_InvalidarTodasLasSesiones`, `sp_ListarEventosAccesoDesde`, `sp_VerificarCambioClave` |
| 12 | `cob.vw_LogAccesoEvidencia` (822) | Nueva, sin GRANT |
| 12 | GRANT (861-867) | `EXECUTE` a `$(UsuarioApi)` solo sobre los 7 procedimientos de la primera tabla de ADR 5.2 |
| 13 | Pruebas PA-01 a PA-28 | Nuevo. Mismo estilo que 07; resultado esperado 28/28 |
| 00 | Consultas 1 a 5 | Columnas de `UsuarioInterno` (13), `ClaveApi` (11), `LogAcceso` (11), `LogNotificacion.EstadoEnvio/Intentos`; 22 objetos nuevos en la consulta 2; consulta 4 nueva (CHECK con `Limitado`); consulta 5 nueva (permisos no esperados) |
| 02 | Cabecera | Agrega "12 -> UsuarioApi: EXECUTE sobre procedimientos de autenticacion" y la confirmación de que ninguna identidad tiene SELECT sobre `LogAcceso` |

Reglas aplicadas en 12:
- Idempotencia: las tablas llevan guarda, los programables usan `CREATE OR ALTER` y los GRANT se pueden repetir. Una protección inicial detiene el script si `UsuarioInterno` no tiene la definición nueva.
- Ningún procedimiento hace `ROLLBACK` propio. Cada `THROW` ocurre antes de `BEGIN TRAN` o después de `COMMIT`, y con `XACT_ABORT ON` el motor revierte. Así no se rompen transacciones externas como las de 07 y 13 (evita el error 266 y el 3915 dentro de `INSERT ... EXEC`).
- No hay `OUTPUT INTO cob.LogAcceso`, porque la tabla tiene CHECK. Se usa `OUTPUT INTO` sobre una variable de tabla y después un `INSERT`.
- Errores de 12: 50060 a 50076 (ver cabecera de 12). Todos quedan dentro del rango 50060-50079; lo verifica la herramienta.

## 2. Permisos: confirmación de que nadie tiene SELECT sobre `cob.LogAcceso`

Revisé todos los GRANT de 02, 03, 04, 05, 06, 11 y 12. La herramienta los lista en `01_validacion_estatica.txt`, sección "GRANT por principal":
- `UsuarioApi`: solo EXECUTE sobre 5 procedimientos de 06 y 7 de 12.
- `UsuarioFunctionApp`: SELECT sobre `origen_sim.vw_ClientesRegularizados` (03), EXECUTE sobre 4 procedimientos de 04 y 1 de 05, y EXECUTE sobre el tipo `cob.ListaRut` (05).
- 02 no otorga nada. Ningún script otorga permisos a nivel de esquema ni usa `db_datareader` o `db_datawriter`.
- Ningún procedimiento con GRANT lee `cob.LogAcceso`; solo insertan eventos. Los únicos que lo leen (`FROM`/`JOIN`/`DELETE`) son `sp_ListarEventosAccesoDesde`, `sp_PurgarLogAcceso` y `sp_VerificarCambioClave`, que son administrativos y no tienen GRANT. La herramienta marca como hallazgo cualquier GRANT sobre un procedimiento que lea `LogAcceso`; el control negativo lo comprueba.
- Al desplegar, la consulta 5 de 00 lo verifica en la base real.

## 3. Firma exacta de los procedimientos que llama la API (GRANT a `UsuarioApi`)

| Procedimiento | Parámetros (en orden) | Conjunto de resultados | Errores |
| --- | --- | --- | --- |
| `cob.sp_ObtenerUsuarioParaLogin` | `@Usuario varchar(50)` | 0 o 1 fila: `UsuarioId int`, `Usuario varchar(50)`, `Nombre nvarchar(120)`, `Rol varchar(10)`, `Activo bit`, `HashClave varchar(256)`, `DebeCambiarClave bit`, `IntentosFallidos smallint`, `BloqueadoHasta datetime2(0) NULL`, `SelloSeguridad uniqueidentifier`, `FechaCambioClave datetime2(0) NULL` | Ninguno |
| `cob.sp_ObtenerUsuarioPorId` | `@UsuarioId int`, `@IncluirHash bit = 0` | 0 o 1 fila con las mismas 11 columnas y en el mismo orden; `HashClave` es NULL cuando `@IncluirHash = 0` | Ninguno |
| `cob.sp_RegistrarLoginFallido` | `@UsuarioId int` (NULL admitido), `@UsuarioIngresado nvarchar(50)`, `@Motivo varchar(25)`, `@IpOrigen varchar(45)`, `@AgenteUsuario nvarchar(200)`, `@MaxIntentos smallint`, `@MinutosBloqueo int` (sin valores por defecto) | Siempre 1 fila: `BloqueadoHasta datetime2(0) NULL` | 50073 motivo no válido; 50074 `@MaxIntentos`/`@MinutosBloqueo` menores a 1 o NULL (solo se validan con `ClaveIncorrecta` y usuario no nulo) |
| `cob.sp_RegistrarLoginExitoso` | `@UsuarioId int`, `@IpOrigen varchar(45)`, `@AgenteUsuario nvarchar(200)`, `@HashClaveNuevo varchar(256) = NULL` | Ninguno | 50061 si `@UsuarioId` no existe |
| `cob.sp_RegistrarLogout` | `@UsuarioId int`, `@IpOrigen varchar(45)`, `@AgenteUsuario nvarchar(200)` | Ninguno | Ninguno |
| `cob.sp_CambiarClave` | `@UsuarioId int`, `@SelloActual uniqueidentifier`, `@HashClaveNuevo varchar(256)`, `@IpOrigen varchar(45)`, `@AgenteUsuario nvarchar(200)` | 1 fila: `SelloSeguridad uniqueidentifier` (el sello nuevo) | 50060 si no actualiza (usuario inexistente o inactivo, o sello distinto); 50065 hash vacío o NULL |
| `cob.sp_ValidarClaveApi` | `@Prefijo char(8)`, `@HashClave binary(32)` | 0 o 1 fila: `ClaveApiId int`, `Consumidor varchar(50)`, `Rol varchar(10)` | Ninguno |

Comparación con `src/Cobranza.Api/Datos/RepositorioUsuarios.cs`, que el `desarrollador` tiene en curso (leído sin modificarlo el 06-11-2026): nombres, tipos y tamaños de los parámetros coinciden en los 7 procedimientos. `LeerUsuario` acepta que `HashClave` falte o venga en NULL, y `CambiarClaveAsync` captura el 50060. El repositorio usa `ExecuteNonQuery` en `sp_RegistrarLoginFallido` y `sp_CambiarClave`, así que descarta las filas devueltas; esto es compatible.

## 4. Firma de los procedimientos administrativos (insumo para `devops`, scripts `s11_*`, `s14_*`, `s15_*`)

| Procedimiento | Parámetros | Resultado | Errores |
| --- | --- | --- | --- |
| `sp_CrearUsuarioInterno` | `@Usuario varchar(50)`, `@Nombre nvarchar(120)`, `@Rol varchar(10)`, `@HashClave varchar(256)` | Ninguno | 50062, 50066, 50063, 50065, 50064 |
| `sp_RestablecerClaveUsuario` | `@Usuario varchar(50)`, `@HashClave varchar(256)` | Ninguno | 50065, 50061 |
| `sp_DesbloquearUsuario` | `@Usuario varchar(50)` | Ninguno | 50061 |
| `sp_CambiarEstadoUsuario` | `@Usuario varchar(50)`, `@Activo bit` | Ninguno | 50075, 50061 |
| `sp_CambiarRolUsuario` | `@Usuario varchar(50)`, `@Rol varchar(10)` | Ninguno | 50063, 50061 |
| `sp_RegistrarClaveApi` | `@Prefijo char(8)`, `@HashClave binary(32)`, `@Consumidor varchar(50)`, `@Rol varchar(10)`, `@FechaVencimiento datetime2(0)` (UTC), `@NombreSecretoKv varchar(127)` | Ninguno | 50067, 50065, 50063, 50070, 50068 |
| `sp_RevocarClaveApi` | `@Prefijo char(8)` | Ninguno | 50069 si el prefijo no existe (si ya estaba revocada no hay error) |
| `sp_PurgarLogAcceso` | `@DiasRetencion int = 90`, `@TamanoLote int = 5000` | 1 fila: `FilasBorradas bigint` | 50071 (menos de 90 o más de 36500 días), 50072 |
| `sp_InvalidarTodasLasSesiones` | (ninguno) | Ninguno (el total queda en `Detalle`) | Ninguno |
| `sp_ListarEventosAccesoDesde` | `@Desde datetime2(0)` (UTC) | N filas: `LogAccesoId bigint`, `FechaUtc`, `Evento`, `UsuarioId`, `Usuario`, `ClaveApiId`, `Prefijo char(8)`, `Detalle nvarchar(200)`, `Actor nvarchar(128)` | 50076 |
| `sp_VerificarCambioClave` | `@Usuario varchar(50)` | 1 fila: `UsuarioId`, `Usuario`, `FechaEmision`, `FechaCambioClave`, `CambioRealizado bit`, `DebeCambiarClave bit` | 50061 |

Vista `cob.vw_LogAccesoEvidencia`: devuelve `LogAccesoId`, `FechaUtc`, `Evento`, `Motivo`, `UsuarioId`, `UsuarioIngresado`, `ClaveApiId`, `IpEnmascarada`, `AgenteUsuarioReducido` (familia de navegador / sistema operativo), `ActorReducido` y `Detalle`. No expone `IpOrigen`, `AgenteUsuario` ni el `Actor` original.

## 5. Desviaciones del contrato (ADR-001)

| Id | Desviación o precisión | Motivo | Afecta a |
| --- | --- | --- | --- |
| D-1 | Columna nueva `cob.LogAcceso.Detalle nvarchar(200) NULL`, que no figura en ADR 5.1 | ADR 5.7 exige "`PurgaLogAcceso` con el total borrado", pero la tabla no tenía columna para guardarlo. Además RNF-05 pide valor anterior y nuevo en los cambios de estado, y la revisión C.3 necesita saber qué rol o estado se cambió. Contenido: total purgado, `Rol X -> Y`, `Activo 1 -> 0`, usuarios afectados, consumidor/prefijo/vencimiento de la clave. Nunca contiene contraseñas, hashes ni claves | `arquitecto` (actualizar 5.1 y 5.7), `seguridad` (política B/C.3), `devops` (`s14_*` puede usarla). La API no lee ni escribe esta columna |
| D-2 | `sp_ObtenerUsuarioPorId` con `@IncluirHash = 0` devuelve la columna `HashClave` en NULL; no la omite | El texto "sin HashClave" es ambiguo. Una forma estable del conjunto de resultados es más segura para la lectura por nombre | `desarrollador` (ya es compatible) |
| D-3 | Tipos que el ADR no especifica: `@IpOrigen varchar(45)` y `@AgenteUsuario nvarchar(200)` en LoginExitoso, Logout y CambiarClave (iguales a los de LoginFallido); tipos de los parámetros administrativos (tabla 4) | Coherencia con las columnas de 5.1 | `desarrollador` (coincide), `devops` |
| D-4 | Conjuntos de resultados que el ADR no especifica: LoginFallido siempre devuelve 1 fila; CambiarClave devuelve la columna `SelloSeguridad`; los procedimientos administrativos no devuelven filas, salvo Purgar (`FilasBorradas`), Listar y Verificar | Contrato mínimo y estable para los scripts | `devops` |
| D-5 | Códigos 50061-50076 además del 50060 que fija el ADR. `sp_RegistrarLoginExitoso` lanza 50061 si el `UsuarioId` no existe (caso límite; la API respondería 500) | Validación explícita con mensaje claro en lugar de errores genéricos | `desarrollador` (solo el caso límite), `devops` (mensajes de los scripts) |
| D-6 | Los procedimientos validan el rol en forma exacta (`COLLATE Latin1_General_BIN2`): `finanzas` en minúsculas se rechaza con 50063. El CHECK de la tabla sigue CI ("sin cambio" según el ADR) | ASP.NET compara los roles distinguiendo mayúsculas; un `finanzas` guardado dejaría al usuario sin acceso | `devops` (`s11_alta_usuario.sh` debe pasar `Finanzas`/`Ventas`/`Admin` exactos) |
| D-7 | CHECK adicionales: `CK_ClaveApi_NombreSecretoKv` (`NombreSecretoKv = 'apikey-' + Consumidor + '-' + Prefijo`), `CK_ClaveApi_Prefijo` con `LEN = 8` y `CK_LogAcceso_UsuarioIngresado` (patrón o `(formato no valido)`) | Hace cumplir en la tabla los formatos que el ADR solo describe (5.1, SEG-H07) | `devops` (el script de alta debe armar el nombre del secreto exactamente así) |
| D-8 | `sp_RevocarClaveApi` es idempotente: si la clave ya está revocada no da error ni registra otro evento. El 50069 queda solo para un prefijo inexistente | La revisión posterior a una restauración (C.3) repite revocaciones que pueden estar ya aplicadas | `devops`, `seguridad` |
| D-9 | `sp_VerificarCambioClave` determina "posterior" por el orden de `LogAccesoId`, no por `FechaUtc` | `FechaUtc` tiene precisión de 1 segundo; un cambio en el mismo segundo del alta se perdería | Ninguno (comportamiento interno) |
| D-10 | La vista oculta además el dominio del `Actor` (`usuario@***`) | Política B.5.3: evidencias sin identificadores completos | `seguridad` |
| D-11 | `fn_SanearUsuarioIngresado` no convierte a minúsculas: si el texto trae mayúsculas, se guarda `(formato no valido)` | El ADR exige el patrón en minúsculas y la API normaliza antes de llamar (`ServicioAutenticacion.SanitizarUsuario`) | `desarrollador` (ya normaliza) |
| D-12 | Si llega `ClaveIncorrecta` para una cuenta ya bloqueada, se suma 1 y el bloqueo se extiende desde ese momento (se registra otro `CuentaBloqueada`) | Es el único UPDATE atómico que describe el ADR; según 5.7 la API debe usar el motivo `CuentaBloqueada` sin verificar la contraseña. Solo ocurre en una carrera entre solicitudes simultáneas | `desarrollador` (confirmar que usa `CuentaBloqueada`) |
| D-13 | Los casos de 13 se numeran `PA-xx` y no `AUT-xx` | Los AUT-01 a AUT-18 del ADR 6.1 son pruebas de la API; PA-09 cubre la parte SQL de AUT-18 y PA-10 la de AUT-16 | `qa` |

## 6. Validación

### 6.1 Herramienta (análisis estático)

- Motor SQL: ninguno disponible. Comprobado de nuevo el 06-11-2026: `sqlcmd`, `docker`, `podman` y `SqlLocalDB` no se encuentran, y no existe el servicio `MSSQLSERVER`. WSL no se revisó otra vez; la evidencia del 05-11-2026 lo da por no instalado. No se ejecutó nada contra Azure.
- Herramienta: `Microsoft.SqlServer.TransactSql.ScriptDom` 180.140.0 (`TSql160Parser`), .NET SDK 10.0.303. Es la versión v2 de la herramienta del 05-11-2026. Fuente en `herramienta/`; se compiló fuera del repositorio, en `%TEMP%`.
- Novedades de v2:
  - En cada EXEC de `cob.*`, el procedimiento existe, los parámetros con nombre existen y los obligatorios se entregan.
  - En cada GRANT, el objeto existe y no es un procedimiento que lea `cob.LogAcceso`; no se permite GRANT directo sobre `LogAcceso` ni sobre la vista.
  - Los THROW de 12 y 13 quedan en 50060-50079.
  - En los INSERT, el número de columnas coincide con el de valores.
- Orden usado: 01, 02, 03, 04, 05, 06, 12, 11, 00, 07, 13, 08.

| Salida | Resultado |
| --- | --- |
| `01_validacion_estatica.txt` | 12 archivos con sintaxis OK, **0 errores, 0 hallazgos**, código de salida 0 |
| `02_control_negativo.txt` | Sobre copias en `%TEMP%` con 5 errores introducidos a propósito (parámetro mal escrito, evento fuera del CHECK, GRANT sobre un procedimiento que lee LogAcceso, THROW 50090, EXEC sin parámetro obligatorio): **18 hallazgos**, código 1. Se detectaron los 5 tipos |

Limitaciones que la herramienta no cubre y que revisé a mano: columnas en SELECT, valores que llegan por parámetros, CHECK a nivel de tabla, semántica de intercalaciones y comportamiento transaccional en tiempo de ejecución.

### 6.2 Conclusión sobre 07: sigue en 10/10 (estático, no ejecutado)

07 usa `cob.Cliente`, `cob.EstadoMorosidad`, `cob.Pedido`, `cob.LogCambioPedido`, `cob.vw_EstadoActualCliente`, `sp_SincronizarClientesRegularizados`, `sp_LiberarPedidosRetenidos` y el trigger. En esta tarea no se modificó ninguno de esos objetos:
- 01 solo cambió el CHECK de `LogNotificacion` y `UsuarioInterno`.
- 04 solo cambió `sp_RegistrarNotificacion`.
- 12 crea objetos nuevos sin triggers ni dependencias sobre esas tablas.

Por eso la traza de la sección 5 de `evidencias/2026-11-05_sql01_correccion_c01/CAMBIOS.md` sigue vigente: PU-01 a PU-10 dan 10/10. Los riesgos residuales que registra esa evidencia (PU-10 con una transacción no confirmable, y `INSERT ... EXEC` con `sp_getapplock`) no cambian.

### 6.3 Conclusión sobre 13: 28/28 (estático, no ejecutado)

| Caso | Traza resumida | Esperado |
| --- | --- | --- |
| PA-01 | Alta con `DebeCambiarClave = 1` y `FechaCambioClave`; `Activo` e `IntentosFallidos` por DEFAULT; 1 `AltaUsuario` | 1/fecha/0/1/1 |
| PA-02 | `WHERE Usuario = @Usuario`: 1 fila con 11 columnas (INSERT EXEC en una tabla de 11 columnas), 0 para el inexistente | 1/0 |
| PA-03 | `CASE WHEN @IncluirHash = 1` | NULL/hash-ficticio-prueba-1 |
| PA-04 | Cuatro fallos dejan 1..4 sin bloqueo; el quinto da `Nuevo = 5 >= 5`, que fija ahora + 15 min y emite `CuentaBloqueada`; la fila devuelta coincide con la tabla | 4/NULL/5/15min/devuelto/5/1 |
| PA-05 | `@Cuenta = 0`: sin UPDATE; registra `LoginFallido/CuentaBloqueada` | 5/igual/1 |
| PA-06 | `BloqueadoHasta <= @Ahora`, así que `Nuevo = 1` y el bloqueo pasa a NULL | 1/NULL/NULL |
| PA-07 | Desbloqueo sin tocar el sello | 0/NULL/igual/1 |
| PA-08 | `ISNULL(NULLIF(@HashClaveNuevo,''), HashClave)`; el sello no cambia | 0/fecha/hash-ficticio-rehash/igual/1 |
| PA-09 | `Clave$Secreta.2026` ($, mayúsculas), `ab` (largo 2), `Juan.Perez` (BIN2), `juan ` (DATALENGTH distinto de 2*LEN), `jose.mu` + ñ (fuera de a-z en BIN2): todos F; `juan.perez` se conserva | F/juan.perez/F/F/F/F |
| PA-10 | Motivo aceptado; sin UPDATE | 1/0/NULL |
| PA-11 | UPDATE con el sello vigente; `OUTPUT inserted.SelloSeguridad` | distinto/coincide/0/hash-ficticio-nuevo-2/1 |
| PA-12 | `ven`: CambioClave posterior al alta; `adm`: solo el alta | 1/0 |
| PA-13 | `OUTPUT deleted/inserted` alimenta `Detalle`; CONCAT de bit da 1/0 | Finanzas/distinto/0/distinto/Rol Admin -> Finanzas/Activo 1 -> 0 |
| PA-14 | Restablecimiento posterior al CambioClave, así que la verificación vuelve a 0 | 1/0/NULL/distinto/hash-ficticio-temporal-2/1/0 |
| PA-15 | Prefijo y hash coinciden, la clave está activa y vigente; `UltimoUso` era NULL | 1/prueba-13/Ventas/fecha |
| PA-16 | El hash no coincide | 0 |
| PA-17 | A 30 min no cumple `< ahora - 60`; a 61 min sí | igual/actualizado/2 |
| PA-18 | `FechaVencimiento > @Ahora` es falso | 0 |
| PA-19 | Revocación; la segunda llamada no encuentra filas con `FechaRevocacion IS NULL OR Activa = 1` | 1/0/0/fecha/1 |
| PA-20 | INSERT con `@SumaIntento = 0`; el aviso no queda excluido (no está Aceptado y tiene menos de 3 intentos); `Fallido` lo deja en 1; `Limitado` lo mantiene en 1 | 0-Limitado/1/1/1-Limitado/1 |
| PA-21 | `203.0.113.77` da `203.0.113.0`; `2001:db8:abcd:12::1` se expande a `2001:db8:abcd:12:0:0:0:1` y da `2001:db8:abcd::`; `::ffff:198.51.100.9` da `::ffff:198.51.100.0`; agente `Chrome / Windows` | (ver 13) |
| PA-22 | 3 AltaUsuario + 1 CambioClave + 1 Restablecimiento + 1 CambioRol + 1 CambioEstado + 3 AltaClaveApi + 1 Revocación = 11 | 11/0/1 |
| PA-23 | `NEWID()` se evalúa por fila en el UPDATE | hay/0/1 |
| PA-24 | Bucle con lote de 1: borra las 2 filas de hace 100 días y las antiguas reales (que cuenta `@Antiguas`); conserva la de hace 89 días | total/0/1/1 |
| PA-25 | El sello de `ven` cambió en PA-11, PA-14 y PA-23: 0 filas, luego COMMIT y THROW 50060 | 50060 |
| PA-26 | `@DiasRetencion = 89` | 50071 |
| PA-27 | `P` mayúscula en BIN2 | 50062 |
| PA-28 | `Otro` no está en la lista | 50073 |

Mejora respecto de 07: en los casos de error, 13 hace `ROLLBACK` antes de escribir en `@Resultados`, así que no escribe dentro de una transacción no confirmable.

Riesgos residuales que solo una ejecución real despeja:
1. `INSERT ... EXEC` sobre procedimientos con `BEGIN TRAN/COMMIT` y `OUTPUT INTO` sobre una variable de tabla. La sintaxis es válida; no se ha verificado en un motor (mismo tipo de riesgo que en 07).
2. Un `THROW` después de un `COMMIT` anidado (con `@@TRANCOUNT` pasando de 2 a 1) dentro de `TRY` del llamador: se espera que la transacción externa quede no confirmable y que el `ROLLBACK` del bloque la cierre.
3. Datos reales en la base: PA-20 supone que no hay facturas impagas con vencimiento anterior a 31-01-1990, porque usa `TOP 500` ordenado por vencimiento. PA-24 supone que no hay filas reales justo en el límite de 90 días. Ninguna de las dos situaciones ocurre con los datos DEMO de 08.
4. Comportamiento de los rangos `[a-z]` con `Latin1_General_BIN2` sobre `varchar` en la página de códigos de `Modern_Spanish_CI_AS`: se espera que use comparación por punto de código. No verificado.

## 7. Impacto en permisos y en la aplicación

- Permisos: `UsuarioApi` gana EXECUTE sobre 7 procedimientos y nada más. `UsuarioFunctionApp` no cambia. Ninguna identidad tiene permisos sobre tablas, funciones, la vista ni los procedimientos administrativos. Los procedimientos son de `dbo` (esquema `cob`), así que el encadenamiento de propiedad permite escribir en `UsuarioInterno` y `LogAcceso` sin GRANT sobre las tablas, con el mismo criterio que 06.
- API: las firmas de la sección 3 son compatibles con el `RepositorioUsuarios.cs` actual del `desarrollador`.
- Function App: `sp_RegistrarNotificacion` acepta `Limitado`, que es lo que hoy envía `NotificacionesFunction.cs` (constante `EstadoLimitado`). Con esto el hallazgo M-N3 de `qa` (2026-11-06) queda resuelto en la parte SQL; actualizar el ADR y CLAUDE.md D12 le corresponde al orquestador o al `arquitecto`.
- `sql/06` (`AvisosFallidos30d`) y `sql/11` (`sp_ReintentarNotificacion`, solo `Fallido`) no cuentan `Limitado`, tal como dice ADR 5.12. Si el panel debe mostrar los avisos limitados: PENDIENTE de decisión.
- `scripts/desplegar_sql.sh` (no existe en el repositorio; `devops`) debe usar el orden 01, 02, 03, 04, 05, 06, 12, 11, 00, 07, 13, con `-v UsuarioApi=...` para 12 y con `-b`.

## 8. Pendientes

1. Ejecución real de 01-13 en SQL Server 2022 o Azure SQL (con aprobación humana) para confirmar 10/10 en 07 y 28/28 en 13. Las evidencias de la ejecución deben guardarse en `evidencias/dba/AAAA-MM-DD_<script>.txt`.
2. Qué devuelve `ORIGINAL_LOGIN()` para una identidad administrada y para un miembro del grupo administrador en Azure SQL (columna `Actor`): PENDIENTE verificar en Azure.
3. Que el `arquitecto` actualice ADR 5.1, 5.2 y 5.7 con las desviaciones D-1 a D-8, y elimine o corrija la referencia a la "Lista definitiva de tareas por agente, Fase A".
4. Frecuencia de `UltimoUso` (60 min, fija en `sp_ValidarClaveApi`) y vigencia máxima de las claves de API (180 días, no aplicada en SQL): siguen PENDIENTES (ADR 5.4).
5. Observación S-1 del 05-11-2026, sin cambio: `@Destinatario varchar(120)` en `sp_RegistrarNotificacion` frente a `Cliente.Email nvarchar(254)`.
6. D5 (regularización desde Moroso o Suspendido): sin cambios, porque está fuera del alcance de esta tarea.
7. Revisión de `qa`.
