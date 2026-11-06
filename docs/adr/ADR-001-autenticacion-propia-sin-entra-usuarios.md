# ADR-001: Autenticación propia en la API (sin Easy Auth ni roles de aplicación de Entra ID)

| Campo | Valor |
| --- | --- |
| Estado | Decisión principal (opción C): Aceptada por el equipo (05-11-2026). Revisión 1 (05-11-2026): Propuesta, pendiente de revisión de `qa` y de confirmación humana |
| Aprobó | Decisión principal: usuario de la sesión de Claude Code (operador, Owner de la suscripción Azure for Students), según lo informado por el orquestador el 05-11-2026. Revisión 1: incorpora decisiones del usuario del 05-11-2026 informadas por el orquestador (sección 0.1); la revisión en sí no está aprobada. Nombre del integrante que aprueba: PENDIENTE de registrar (CLAUDE.md sección 10: responsable humano aún no definido) |
| Redactó | Agente `arquitecto` (Claude Code), 05-11-2026 |
| Reemplaza | Decisión "Easy Auth v2 + roles Ventas.Consulta, Finanzas.Consulta, TI.Operacion; Entra ID Free = asignación por usuario" (docs/05, CLAUDE.md sección 3) |
| Relacionado | Cambio de región a `brazilsouth` (decisión del usuario, aplicada por `devops` en `infra/main.bicep`; ver `evidencias/2026-11-05_whatif_brazilsouth/CAMBIOS.md`, N10). Informe `evidencias/qa/2026-11-05_revision_whatif_brazilsouth_adr001.md` (veredicto RECHAZADO por C-01 y A-01). Política `docs/seguridad/politica_credenciales_y_accesos.md` (propuesta de `seguridad`) |
| Requerimientos | RF-01, RF-05, RF-06, RF-07, RNF-02, RNF-05, RNF-06, RNF-07 |

Nota de alcance: este ADR es diseño. Nada de lo descrito está implementado, compilado ni desplegado a la fecha. Ningún agente ejecutó scripts contra Azure ni contra la base para redactarlo.

---

## 0. Historial de revisiones

| Versión | Fecha | Cambios | Origen |
| --- | --- | --- | --- |
| Inicial | 05-11-2026 | Decisión opción C y diseño detallado | Orquestador y operador |
| Revisión 1 | 05-11-2026 | Regla de transición (A-01, sección 5.11); RBAC mínimo y separación de Data Protection (M-07, sección 5.5); encabezados reenviados (M-08b, sección 5.4.1); dependencia de `sql/07` con C-01 (sección 6); lista 5.10 completada; riesgos B-10 (sección 4.2); política de credenciales de `seguridad` (sección D de la política) aplicada en 4.2, 5.1, 5.2, 5.4, 5.7, 5.9, 5.10 y 6.1; regla SEG-H01; D12 DEMO (sección 5.12); textos DEMO de Finanzas (sección 5.12); ediciones propuestas a CLAUDE.md actualizadas (sección 8); valores DEMO de seguridad de A.11 marcados como aprobados por el equipo (05-11-2026) | `qa` (informe del 05-11-2026), `seguridad` (política del 05-11-2026), decisiones del usuario (0.1) |

### 0.1 Decisiones del usuario incorporadas (05-11-2026, informadas por el orquestador)

| Id | Decisión | Dónde se aplica |
| --- | --- | --- |
| U1 | El consumidor de RF-06 es simulado: `ventas-demo`, con datos DEMO (`sql/08_datos_prueba.sql`, `origen_sim`) | 5.1, 5.9 |
| U2 | Las altas de usuarios y claves las hace el propio equipo | 5.9 |
| U3 | La retención de `cob.LogAcceso` la define `seguridad` (definió 90 días) | 5.1, 5.2 |
| U4 | Los textos de Finanzas para la demo son valores inventados, rotulados DEMO; los fija `devops` | 5.12 |
| U5 | D12 DEMO: máximo 10 correos por ejecución, pausa de 15000 ms; un 429 o rechazo por límite se reintenta sin contar como intento fallido | 5.12 |
| U6 | Valores DEMO de seguridad de la política de credenciales (A.11): inicialmente pendientes; aprobados por el equipo el 05-11-2026 (actualización informada por el orquestador durante esta revisión): contraseña temporal de 20 caracteres con vigencia de 24 h, clave `ventas-demo` de 30 días, `carga-demo` de 1 día, aviso de rotación 7 días, lote de purga 5.000, retención de `cob.LogAcceso` 90 días, bloqueo 5/15, sesión 30 min / 8 h, revalidación 5 min y caché de clave 60 s. Los valores de 5.4 que no figuran en A.11 siguen PENDIENTES (ver 5.4) | 5.1, 5.4, 5.9 |

---

## 1. Contexto

Hechos informados por el orquestador y verificados por el operador en la sesión del 05-11-2026:

1. El equipo usará solo el tenant institucional de Duoc UC (suscripción Azure for Students). No se crearán tenants nuevos ni se pedirán permisos a TI de Duoc.
2. El operador es Owner de la suscripción y no tiene roles de directorio en Entra ID.
3. El consentimiento de usuario está desactivado en el tenant de Duoc (la `authorizationPolicy` no incluye permisos `ManagePermissionGrantsForSelf.*`). Por eso ningún usuario podría iniciar sesión en una aplicación con Easy Auth (que pide al menos `openid`/`profile`/`User.Read`) sin consentimiento de administrador, que el equipo no puede otorgar.
4. Además, `scripts/s11_registro_entra_id.sh` necesita un rol de directorio que permita registrar aplicaciones y asignar roles de aplicación (comentario de las líneas 10 y 11 del script); el operador no lo tiene.
5. Lo siguiente sí funciona sin intervención de Duoc y se MANTIENE:
   - Grupo `grp-cobranza-sql-admin` (ya creado).
   - Identidades administradas de la API y la Function App hacia SQL, Key Vault y Storage (con el alcance reducido de la sección 5.5).
   - Azure SQL solo con autenticación Entra ID para esas identidades y para el grupo administrador.
   - RBAC de Azure (plano de control y de datos).
6. Región: `brazilsouth`, porque una política de Duoc (Ubicaciones permitidas) bloquea `chilecentral`. Ya está decidido y lo aplica otro agente.

Estado del código al 05-11-2026 (leído en el repositorio):

- `src/Cobranza.Api/Seguridad/EasyAuthHandler.cs` convierte el encabezado `X-MS-CLIENT-PRINCIPAL` en un `ClaimsPrincipal` sin validarlo y define los roles `Ventas.Consulta`, `Finanzas.Consulta` y `TI.Operacion`, y las políticas `ConsultaCliente` (Ventas o Finanzas), `Cartera` (Finanzas) y `Operacion` (TI o Finanzas).
- `src/Cobranza.Api/Program.cs` registra ese esquema, una política de reserva (fallback) que exige usuario autenticado y llama a `UseStaticFiles` después de `UseAuthorization`.
- `src/Cobranza.Api/wwwroot/panel.js` redirige a `/.auth/login/aad` cuando recibe 401.
- `src/Cobranza.Api/Datos/RepositorioConsultas.cs` lee la cadena `ConnectionStrings:Cobranza`, que en `infra/main.bicep` (línea 524) usa `Authentication=Active Directory Managed Identity`: no es un secreto ni una referencia a Key Vault.
- `sql/01_esquema_cobranza.sql` (línea 106) define `cob.UsuarioInterno` con `EntraObjectId UNIQUEIDENTIFIER NOT NULL UNIQUE`, `Nombre`, `Rol IN ('Finanzas','Ventas','Admin')` y `Activo`. Ningún procedimiento ni código usa esa tabla hoy. Además, según `qa` (C-01), `sql/01` es incompatible con `sql/04`, `05`, `07`, `08` y `11`.
- `sql/06_consultas_api.sql` otorga a `$(UsuarioApi)` solo EXECUTE sobre 5 procedimientos de lectura; la API no tiene SELECT directo sobre tablas ni `db_datawriter` (`sql/02`).
- `infra/main.bicep`:
  - Web App: ajuste `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` (líneas 556-562, referencia a `easyauth-client-secret`), sin restricciones de acceso por IP.
  - `raKvApi` (líneas 800-808): API con `Key Vault Secrets User` sobre todo el vault. Su único uso actual es resolver la referencia a `easyauth-client-secret`.
  - `raKvFunc` (líneas 810-818): Function App con `Key Vault Secrets User` sobre todo el vault. Su único uso es la referencia `Cobranza__AcsConnectionString` al secreto `acs-connection-string` (línea 628).
  - `raStorageFunc` (líneas 831-843): Function App con `Storage Blob Data Owner`, `Storage Queue Data Contributor` y `Storage Table Data Contributor` sobre toda la cuenta.
- `infra/modulos/autenticacion_api.bicep` configura `authsettingsV2`.
- `sql/04_jobs_bitacoras.sql`: `sp_RegistrarNotificacion` acepta solo `Aceptado` y `Fallido` y suma 1 a `Intentos` en cada registro (líneas 160-181); `sp_GenerarAlertasVencimiento` excluye los avisos con `Intentos >= 3` (línea 137). `src/Cobranza.Functions/Funciones/NotificacionesFunction.cs` registra el 429 como `Fallido` (líneas 50-59).

---

## 2. Opciones evaluadas

| Opción | Descripción | Ventajas | Desventajas | Resultado |
| --- | --- | --- | --- | --- |
| A. Easy Auth en el tenant Duoc | Mantener el diseño S11: registro de aplicación, roles de aplicación y `authsettingsV2` | MFA y políticas del tenant; sin contraseñas propias; código ya escrito | Requiere consentimiento de administrador y un rol de directorio para registrar la aplicación y asignar roles. El equipo decidió no pedirlo a TI de Duoc. Sin eso nadie puede iniciar sesión | Descartada (inviable sin Duoc) |
| B. Tenant propio | Crear un tenant Entra ID del equipo (o una cuenta Azure gratuita aparte) donde el operador sea administrador global | Conserva Easy Auth y el diseño S11 completo | El equipo lo descartó explícitamente. Además separa identidades del tenant donde está la suscripción | Descartada por el equipo |
| C. Autenticación propia en la API | Usuario y contraseña con cookie de ASP.NET Core para el panel; clave de API por consumidor para la integración de Ventas | No depende de Duoc; todo bajo control del equipo; se implementa con componentes de ASP.NET Core y Azure ya presentes | Sin MFA; el equipo administra contraseñas, bloqueo, auditoría y rotación; más código propio que mantener y probar | Elegida |
| D. Solo protección por red | Sin autenticación de aplicación; acceso limitado por restricciones de IP, Private Endpoint o WAF | Cero código de autenticación | No identifica al usuario: incumple RNF-05 (auditoría con origen) y no permite separar roles Ventas/Finanzas (RF-06 frente a RF-07). Las IP de usuarios de la embotelladora no están documentadas | Descartada (se conserva como control complementario y como control de transición, sección 5.11) |
| E. Proveedor OIDC externo | Identidad delegada a un proveedor externo (por ejemplo, cuentas personales Microsoft, Google, o un servicio de identidad de terceros) | MFA del proveedor; sin almacenar contraseñas | Introduce un servicio o tenant adicional no contemplado en la arquitectura ni en los costos; cuentas personales no corresponden a usuarios corporativos de la embotelladora; un tenant B2C/External ID equivale en la práctica a la opción B | Descartada |

---

## 3. Decisión

Se adopta la opción C:

1. Panel (RF-07) y consulta interactiva de Ventas: usuario y contraseña con autenticación por cookie de ASP.NET Core.
   - Hash de contraseña con `PasswordHasher<T>` de ASP.NET Core Identity (formato V3, PBKDF2).
   - Bloqueo temporal por intentos fallidos.
   - Roles tomados de `cob.UsuarioInterno.Rol`.
2. API para Ventas sistema a sistema (RF-06): clave de API por consumidor enviada en un encabezado. Para el entorno académico el consumidor es simulado (`ventas-demo`, U1).
   - En la base de datos solo se guarda el hash.
   - El valor real se guarda en Key Vault.
   - La API no lee Key Vault para validar claves: valida contra el hash en SQL (sección 5.3).
3. Easy Auth deja de usarse. Quedan obsoletos `scripts/s11_registro_entra_id.sh`, `infra/modulos/autenticacion_api.bicep`, el secreto `easyauth-client-secret` y el ajuste `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`.
4. Se mantiene todo lo que usa Entra ID sin consentimiento de usuarios: identidades administradas, autenticación solo Entra ID en SQL, grupo `grp-cobranza-sql-admin` y RBAC de Azure. El alcance RBAC de las identidades administradas se reduce (sección 5.5).
5. Regla de transición: la API actual no se publica hasta implementar este ADR (sección 5.11).
6. Regla SEG-H01: ningún agente de Claude Code ejecuta los scripts de alta, restablecimiento, baja o emisión de claves; los ejecuta un integrante humano en su propia terminal (sección 5.9).

---

## 4. Consecuencias

### 4.1 Positivas
- El despliegue y las pruebas de la semana 11 dejan de depender de TI de Duoc.
- Se elimina el secreto de cliente de Easy Auth y su rotación anual (`s11_registro_entra_id.sh`, paso 3).
- La limitación de Entra ID Free (roles solo por usuario, sin grupos) deja de aplicar al panel.
- La API deja de tener acceso de lectura a secretos de Key Vault; la Function App queda limitada a un solo secreto (sección 5.5).
- No hay costo adicional relevante: no se agregan recursos con cargo fijo. El almacenamiento de las claves de Data Protection (un blob) y las operaciones de clave en Key Vault tienen costo por uso marginal; el valor exacto: PENDIENTE calcular en la calculadora de precios de Azure para `brazilsouth` (además, `docs/04` está calculado para Chile Central: B-11).

### 4.2 Negativas y riesgos asumidos
- Sin MFA. Es la principal pérdida de seguridad respecto de Easy Auth con Entra ID. Mitigaciones: bloqueo por intentos, limitación de tasa en el login, contraseñas largas, cookie de corta duración, auditoría de accesos y, si se aprueba D11, WAF delante de la API. Riesgo residual aceptado por el equipo para el entorno académico.
- Contraseñas administradas por el equipo (U2): alta de usuarios, restablecimiento, desbloqueo y baja quedan a cargo de un integrante miembro de `grp-cobranza-sql-admin` mediante procedimientos (sección 5.9). Canal de entrega de contraseñas temporales definido en la política de credenciales (entrega presencial, sección A); responsable humano que autoriza las altas: PENDIENTE.
- Mientras no exista WAF ni cierre de la API pública (`CERRAR_API_PUBLICA=no` en `s12_endurecer.sh`), el formulario de login queda expuesto a Internet con protección solo de aplicación. Esto aplica solo después de implementar este ADR; antes rige la regla de transición (5.11).
- Denegación de servicio por bloqueo (B-10a): quien conozca un nombre de usuario puede bloquear esa cuenta enviando contraseñas incorrectas. Mitigaciones: bloqueo temporal (no permanente), limitador por IP (con la IP correcta, 5.4.1), nombres de usuario no publicados y desbloqueo manual con verificación presencial. Riesgo aceptado para el entorno académico.
- Hash en la línea de comandos y en la auditoría SQL (B-10b, SEG-H06): si el script de alta pasa el hash con `sqlcmd -v`, el hash queda visible en la lista de procesos del equipo del operador y en el texto del lote (`BATCH_COMPLETED_GROUP`). Mitigación: la contraseña temporal es aleatoria de 20 caracteres (DEMO), vence en 24 h (DEMO) y se cambia en el primer acceso. `devops` debe documentarlo en la cabecera del script. Si la auditoría también registra los parámetros de las llamadas RPC de la API: PENDIENTE verificar en Azure.
- Más código propio de seguridad: requiere pruebas unitarias y de integración específicas (sección 7) y revisión de `qa` y `seguridad`.
- Restauración PITR o LTR (RNF-06): restaurar la base a un punto anterior revierte también `cob.UsuarioInterno` y `cob.ClaveApi`. Las claves revocadas, los usuarios desactivados, los roles reducidos y las contraseñas cambiadas después del punto vuelven a su estado anterior, y vuelve el `SelloSeguridad` anterior, de modo que una cookie emitida antes del punto podría volver a ser válida. Tratamiento (política de credenciales, C.3):
  - Revisión obligatoria posterior a la restauración usando `cob.LogAcceso` de la base original: se repiten revocaciones, bajas y reducciones de rol; se restablecen contraseñas cambiadas después del punto; se deshabilitan secretos `apikey-*` huérfanos.
  - Se invalidan todas las sesiones de la base restaurada con `cob.sp_InvalidarTodasLasSesiones`.
  - Si la base original no existe (restauración LTR o entorno eliminado), se aplica la regla conservadora: revocar todas las claves de API, emitir claves nuevas, desactivar a todos los usuarios que no sean `Admin` y restablecer todas las contraseñas.
  - La restauración no termina hasta completar la revisión y verificar AUT-08, AUT-12 y AUT-17.
  - Se implementa en `scripts/s14_simulacro_pitr.sh` (paso nuevo) o en un script aparte `scripts/s14_revision_post_restauracion.sh` (decide `devops`, sección 5.10).
- Log Analytics retiene 30 días y PITR cubre 35 (SEG-H02): la auditoría SQL no cubre toda la ventana de restauración. Por eso la retención de `cob.LogAcceso` es de 90 días (5.1).

### 4.3 RNF-02 (TLS, TDE, credenciales en Key Vault)
- TLS 1.2: sin cambio (App Service `minTlsVersion 1.2`, `httpsOnly`). La cookie se marca `Secure`.
- TDE: los hashes de contraseñas y de claves de API quedan en Azure SQL, cifrados en reposo por TDE (activo por defecto; declararlo explícitamente en `main.bicep` es B-01, `devops`).
- Credenciales en Key Vault: el valor real de cada clave de API se guarda como secreto en Key Vault; en SQL solo su SHA-256. Las contraseñas de usuarios no se guardan en ninguna parte (solo su hash PBKDF2), por lo que no aplica guardarlas en Key Vault. Las claves de Data Protection (que firman y cifran la cookie) se guardan en Blob Storage cifradas con una clave de Key Vault (sección 5.5).
- No se envían contraseñas ni claves en texto plano a SQL: la API y la herramienta de alta calculan el hash antes de llamar a los procedimientos. Esto importa porque la auditoría de SQL (`BATCH_COMPLETED_GROUP`, `infra/modulos/seguridad_perimetral.bicep` y `sqlAuditoria` en `main.bicep`) registra el texto de los lotes ejecutados con `sqlcmd`.

### 4.4 RNF-05 (auditoría)
- Se agrega la bitácora `cob.LogAcceso` con inicios de sesión exitosos y fallidos, bloqueos, cierres de sesión, cambios de contraseña, operaciones administrativas sobre usuarios y claves de API, purgas e invalidaciones masivas de sesión (fecha UTC, evento, usuario, motivo, IP, agente de usuario y principal SQL que escribió).
- La IP registrada es confiable solo si los encabezados reenviados se configuran según 5.4.1.
- Se mantiene la auditoría de Azure SQL hacia Log Analytics para las operaciones del grupo administrador (con la observación M-01 de `qa` sobre la configuración de diagnóstico en `master`, a cargo de `devops`).
- Se agrega el diagnóstico de auditoría de Key Vault en `main.bicep` (SEG-H03) para registrar quién lee los secretos `apikey-*`.

### 4.5 Recomendación para producción
En un despliegue real para Embotelladora del Pacífico S.A., la recomendación es volver a Easy Auth v2 (o a Microsoft Identity Web) en el tenant Entra ID de la embotelladora, con MFA, roles de aplicación y asignación por grupos (Entra ID P1 si se requieren grupos o acceso condicional), y usar identidad administrada o credenciales de cliente de Entra ID para la integración sistema a sistema en lugar de claves de API. La autenticación propia de este ADR es una decisión acotada al entorno académico y al tenant de Duoc. El plazo de retención de `cob.LogAcceso` en producción debe validarse con el área legal de la embotelladora (Ley 19.628 y Ley 21.719: PENDIENTE).

### 4.6 Plazos (Carta Gantt)
- Agrega trabajo de `dba` y `desarrollador` antes del despliegue programado para la semana 11, y trabajo de `devops` (siete scripts nuevos) y `seguridad`. La corrección C-01 de `sql/01` y el build en verde (NU1902/NU1903) son prerrequisitos. Estimación de esfuerzo: PENDIENTE (el equipo debe confirmar si cabe en la semana 11 o desplaza el despliegue).
- La regla de transición (5.11) permite desplegar la plantilla (`az deployment group create`) antes de terminar la implementación, pero no publicar el código de la API.

---

## 5. Diseño detallado

Los valores marcados DEMO son de demostración, no definidos por la embotelladora; se configuran en `appsettings.json`, como ajustes de App Service o como parámetros de script. Los valores DEMO de seguridad de la política A.11 son "valores DEMO aprobados por el equipo (05-11-2026)" (U6); los demás se indican como pendientes en 5.4.

### 5.1 Esquema SQL

Como `sql/01_esquema_cobranza.sql` nunca se ejecutó, se modifica directamente la definición de `cob.UsuarioInterno` en 01 (no se requiere migración). Este cambio se hace junto con la corrección C-01 de `qa` (alinear `cob.Cliente`, `cob.EstadoMorosidad`, `cob.LogNotificacion` y `cob.LogSincronizacion` con lo que esperan 00 y 03-11), que es prerrequisito. Las tablas y procedimientos nuevos van en un script nuevo `sql/12_autenticacion.sql`.

#### cob.UsuarioInterno (reemplaza la definición de 01, línea 106)

| Columna | Tipo | Nulo | Regla |
| --- | --- | --- | --- |
| UsuarioId | INT IDENTITY(1,1) | No | PK `PK_UsuarioInterno` |
| Usuario | VARCHAR(50) | No | `UQ_UsuarioInterno_Usuario` UNIQUE. CHECK: `Usuario = LOWER(Usuario)`, longitud entre 3 y 50, solo `[a-z0-9._-]` (por ejemplo `CHECK (Usuario NOT LIKE '%[^a-z0-9._-]%' COLLATE Latin1_General_BIN)`). Reemplaza a `EntraObjectId` |
| Nombre | NVARCHAR(120) | No | Sin cambio |
| Rol | VARCHAR(10) | No | Sin cambio: `CK_UsuarioInterno_Rol CHECK (Rol IN ('Finanzas','Ventas','Admin'))` |
| Activo | BIT | No | Sin cambio, DEFAULT 1 |
| HashClave | VARCHAR(256) | No | Salida Base64 de `PasswordHasher` V3 (hoy 84 caracteres; margen para versiones futuras) |
| DebeCambiarClave | BIT | No | DEFAULT 1. Obliga a cambiar la contraseña temporal en el primer acceso |
| IntentosFallidos | SMALLINT | No | DEFAULT 0, CHECK `>= 0` |
| BloqueadoHasta | DATETIME2(0) | Sí | UTC. NULL = no bloqueado |
| UltimoAcceso | DATETIME2(0) | Sí | UTC del último login exitoso |
| FechaCambioClave | DATETIME2(0) | Sí | UTC del alta, del último cambio o del último restablecimiento. Con `DebeCambiarClave = 1` marca el inicio de la vigencia de la contraseña temporal (5.4) |
| SelloSeguridad | UNIQUEIDENTIFIER | No | DEFAULT NEWID(). Cambia al cambiar o restablecer la contraseña, desactivar, cambiar el rol o invalidar sesiones; invalida las cookies emitidas antes |
| FechaCreacion | DATETIME2(0) | No | DEFAULT SYSUTCDATETIME() |

Se elimina `EntraObjectId` y `UQ_UsuarioInterno_Oid`. La intercalación de la base (`Modern_Spanish_CI_AS`) hace que la unicidad de `Usuario` sea insensible a mayúsculas; además la API normaliza a minúsculas antes de llamar.

#### cob.ClaveApi (nueva, en 12)

| Columna | Tipo | Nulo | Regla |
| --- | --- | --- | --- |
| ClaveApiId | INT IDENTITY(1,1) | No | PK `PK_ClaveApi` |
| Prefijo | CHAR(8) | No | `UQ_ClaveApi_Prefijo` UNIQUE. Parte pública e identificable de la clave (sección 5.3); CHECK solo `[a-z2-7]` |
| HashClave | BINARY(32) | No | SHA-256 de la clave completa |
| Consumidor | VARCHAR(50) | No | DEMO `ventas-demo` (U1, decisión del 05-11-2026); `carga-demo` para la prueba de carga si el equipo lo aprueba (PENDIENTE). CHECK solo `[a-z0-9-]`, longitud entre 3 y 50, para que el nombre del secreto sea válido en Key Vault. Sistema real de Ventas: PENDIENTE solo para producción |
| Rol | VARCHAR(10) | No | `CK_ClaveApi_Rol CHECK (Rol IN ('Ventas'))`. Solo RF-06; ampliar requiere nuevo ADR |
| Activa | BIT | No | DEFAULT 1 |
| FechaCreacion | DATETIME2(0) | No | DEFAULT SYSUTCDATETIME() |
| FechaVencimiento | DATETIME2(0) | No | UTC. Máximo `Seguridad__DiasVigenciaClaveApi` (DEMO 180); `ventas-demo` 30 días (DEMO); `carga-demo` 1 día (DEMO) |
| FechaRevocacion | DATETIME2(0) | Sí | UTC |
| UltimoUso | DATETIME2(0) | Sí | UTC; se actualiza como máximo una vez por hora (DEMO) para no escribir en cada solicitud |
| NombreSecretoKv | VARCHAR(127) | No | Nombre del secreto en Key Vault que contiene el valor real (referencia, nunca el valor). Formato: `apikey-<consumidor>-<prefijo>` |

Nota: la definición inicial usaba `NVARCHAR(100)` para `Consumidor`; con el patrón `[a-z0-9-]` basta `VARCHAR(50)` y el nombre del secreto (`apikey-` + 50 + `-` + 8 = 66 caracteres) queda dentro de 127.

#### cob.LogAcceso (nueva, en 12; sin FK, igual criterio que `cob.LogCambioPedido`)

| Columna | Tipo | Nulo | Regla |
| --- | --- | --- | --- |
| LogAccesoId | BIGINT IDENTITY(1,1) | No | PK |
| FechaUtc | DATETIME2(0) | No | DEFAULT SYSUTCDATETIME() |
| Evento | VARCHAR(25) | No | CHECK IN (`LoginExitoso`, `LoginFallido`, `CuentaBloqueada`, `Logout`, `CambioClave`, `AltaUsuario`, `RestablecimientoClave`, `DesbloqueoManual`, `CambioEstadoUsuario`, `CambioRolUsuario`, `AltaClaveApi`, `RevocacionClaveApi`, `PurgaLogAcceso`, `InvalidacionSesiones`) |
| Motivo | VARCHAR(25) | Sí | CHECK IN (`ClaveIncorrecta`, `UsuarioInexistente`, `UsuarioInactivo`, `CuentaBloqueada`, `ClaveTemporalVencida`) o NULL |
| UsuarioId | INT | Sí | NULL si el usuario no existe o si el evento es masivo |
| UsuarioIngresado | NVARCHAR(50) | Sí | Texto ingresado en el login (permite detectar enumeración). Solo se guarda si cumple el patrón de usuario (`[a-z0-9._-]`, entre 3 y 50 caracteres); en caso contrario se guarda `(formato no valido)`, para no guardar una contraseña escrita por error en el campo de usuario (SEG-H07). La API sanitiza y el procedimiento vuelve a sanitizar (defensa en profundidad) |
| ClaveApiId | INT | Sí | Para eventos de claves de API |
| IpOrigen | VARCHAR(45) | Sí | IPv4 o IPv6 textual, obtenida según 5.4.1 |
| AgenteUsuario | NVARCHAR(200) | Sí | Truncado a 200 |
| Actor | NVARCHAR(128) | No | DEFAULT ORIGINAL_LOGIN(): identidad de la API o miembro del grupo admin que escribió |

Índices: `IX_LogAcceso_Fecha (FechaUtc)` e `IX_LogAcceso_Usuario (UsuarioId, FechaUtc DESC)`.

Retención (U3, definida por `seguridad`): 90 días en línea; purga con `cob.sp_PurgarLogAcceso` (política de credenciales, sección B). Aprobada por el equipo (05-11-2026) junto con los valores DEMO de A.11; pendiente de revisión de `qa`. Para producción: PENDIENTE (4.5). Las filas purgadas siguen existiendo en los respaldos LTR hasta su vencimiento; se acepta y se declara.

La IP y el agente de usuario se tratan como datos personales (política, B.4): solo los consulta `grp-cobranza-sql-admin`; ningún procedimiento con GRANT a `UsuarioApi` o `UsuarioFunctionApp` lee `cob.LogAcceso`; en las evidencias exportadas la IP se enmascara (IPv4 al /24, IPv6 al /48) mediante la vista `cob.vw_LogAccesoEvidencia`.

Los usos válidos de claves de API no se registran en SQL (volumen); quedan en Application Insights (solicitudes con el prefijo de la clave como dimensión personalizada). Los rechazos de claves de API se registran en Application Insights como advertencia con el prefijo, nunca con la clave.

### 5.2 Procedimientos almacenados (sql/12)

Todos en el esquema `cob`, propietario `dbo`, de modo que el encadenamiento de propiedad permite a `UsuarioApi` ejecutarlos sin permisos sobre tablas. Se respeta "escritura solo mediante procedimientos" y el criterio de `sql/02` y `sql/06` (EXECUTE por objeto, sin `db_datareader` ni `db_datawriter`).

Con GRANT EXECUTE a `$(UsuarioApi)`:

| Procedimiento | Parámetros | Comportamiento |
| --- | --- | --- |
| `sp_ObtenerUsuarioParaLogin` | `@Usuario VARCHAR(50)` | Devuelve 0 o 1 fila: UsuarioId, Usuario, Nombre, Rol, Activo, HashClave, DebeCambiarClave, IntentosFallidos, BloqueadoHasta, SelloSeguridad, FechaCambioClave. Solo lectura |
| `sp_ObtenerUsuarioPorId` | `@UsuarioId INT, @IncluirHash BIT = 0` | Igual que el anterior; sin HashClave cuando `@IncluirHash = 0`. Se usa en la revalidación periódica de la cookie y en el cambio de contraseña |
| `sp_RegistrarLoginFallido` | `@UsuarioId INT NULL, @UsuarioIngresado NVARCHAR(50), @Motivo VARCHAR(25), @IpOrigen VARCHAR(45), @AgenteUsuario NVARCHAR(200), @MaxIntentos SMALLINT, @MinutosBloqueo INT` | Si `@UsuarioId` no es NULL y `@Motivo = 'ClaveIncorrecta'`: un solo UPDATE atómico que reinicia el contador si `BloqueadoHasta` ya venció, suma 1 y, si llega a `@MaxIntentos`, fija `BloqueadoHasta = DATEADD(MINUTE, @MinutosBloqueo, SYSUTCDATETIME())`. Inserta `LoginFallido` en `cob.LogAcceso` y, si bloqueó, también `CuentaBloqueada`. Con otros motivos (incluido `ClaveTemporalVencida`) solo registra. Sanitiza `@UsuarioIngresado` (5.1). Devuelve `BloqueadoHasta` |
| `sp_RegistrarLoginExitoso` | `@UsuarioId INT, @IpOrigen, @AgenteUsuario, @HashClaveNuevo VARCHAR(256) = NULL` | `IntentosFallidos = 0`, `BloqueadoHasta = NULL`, `UltimoAcceso = SYSUTCDATETIME()`; si `@HashClaveNuevo` no es NULL actualiza el hash (re-hash cuando `PasswordHasher` devuelve `SuccessRehashNeeded`). Inserta `LoginExitoso` |
| `sp_RegistrarLogout` | `@UsuarioId INT, @IpOrigen, @AgenteUsuario` | Inserta `Logout` |
| `sp_CambiarClave` | `@UsuarioId INT, @SelloActual UNIQUEIDENTIFIER, @HashClaveNuevo VARCHAR(256), @IpOrigen, @AgenteUsuario` | Actualiza solo si el usuario está activo y `SelloSeguridad = @SelloActual` (evita carreras); fija `DebeCambiarClave = 0`, `FechaCambioClave`, nuevo `SelloSeguridad = NEWID()`. Inserta `CambioClave`. Devuelve el sello nuevo. Si no actualiza filas: `THROW 50060` |
| `sp_ValidarClaveApi` | `@Prefijo CHAR(8), @HashClave BINARY(32)` | Devuelve 0 o 1 fila (ClaveApiId, Consumidor, Rol) si existe con ese prefijo, el hash coincide, `Activa = 1`, `FechaRevocacion IS NULL` y `FechaVencimiento > SYSUTCDATETIME()`. Actualiza `UltimoUso` si es NULL o tiene más de 60 minutos (DEMO) |

Sin GRANT (los ejecuta solo un miembro de `grp-cobranza-sql-admin`, igual que `sql/11`); cada uno inserta su evento en `cob.LogAcceso` con `Actor = ORIGINAL_LOGIN()`:

| Procedimiento | Parámetros | Comportamiento |
| --- | --- | --- |
| `sp_CrearUsuarioInterno` | `@Usuario, @Nombre, @Rol, @HashClave` | Inserta con `DebeCambiarClave = 1` y `FechaCambioClave = SYSUTCDATETIME()` (inicio de la vigencia de la contraseña temporal). Evento `AltaUsuario` |
| `sp_RestablecerClaveUsuario` | `@Usuario, @HashClave` | Nuevo hash temporal, `DebeCambiarClave = 1`, `FechaCambioClave = SYSUTCDATETIME()`, desbloquea, nuevo sello. Evento `RestablecimientoClave` |
| `sp_DesbloquearUsuario` | `@Usuario` | `IntentosFallidos = 0`, `BloqueadoHasta = NULL`. Evento `DesbloqueoManual` |
| `sp_CambiarEstadoUsuario` | `@Usuario, @Activo BIT` | Cambia `Activo`, nuevo sello. Evento `CambioEstadoUsuario`. La baja no borra la fila (trazabilidad) |
| `sp_CambiarRolUsuario` | `@Usuario, @Rol` | Cambia `Rol`, nuevo sello. Evento `CambioRolUsuario` |
| `sp_RegistrarClaveApi` | `@Prefijo, @HashClave BINARY(32), @Consumidor, @Rol, @FechaVencimiento, @NombreSecretoKv` | Inserta. Evento `AltaClaveApi` |
| `sp_RevocarClaveApi` | `@Prefijo` | `Activa = 0`, `FechaRevocacion`. Evento `RevocacionClaveApi` |
| `sp_PurgarLogAcceso` (nuevo, revisión 1) | `@DiasRetencion INT = 90, @TamanoLote INT = 5000` (5000 DEMO) | Si `@DiasRetencion < 90`: `THROW` (rango 50060-50079). Borra en lotes `WHERE FechaUtc < DATEADD(DAY, -@DiasRetencion, SYSUTCDATETIME())` usando `IX_LogAcceso_Fecha`. Inserta `PurgaLogAcceso` y devuelve el total borrado. No se otorga a ninguna identidad administrada: un job con permiso de borrado permitiría a una identidad comprometida borrar su rastro |
| `sp_InvalidarTodasLasSesiones` (nuevo, revisión 1) | — | Asigna `SelloSeguridad = NEWID()` a todos los usuarios. Inserta un evento `InvalidacionSesiones` con `UsuarioId` NULL. Se usa en la revisión posterior a una restauración (4.2) |
| `sp_ListarEventosAccesoDesde` (nuevo, revisión 1) | `@Desde DATETIME2(0)` | Lista eventos de tipo `RevocacionClaveApi`, `CambioEstadoUsuario`, `CambioRolUsuario`, `CambioClave`, `RestablecimientoClave`, `AltaUsuario` y `AltaClaveApi` con `FechaUtc >= @Desde`. Solo lectura; insumo de la revisión posterior a restauración |
| `sp_VerificarCambioClave` (nuevo, revisión 1) | `@Usuario` | Indica si existe `CambioClave` del usuario posterior a su último `AltaUsuario` o `RestablecimientoClave`. Cierra el alta (5.9, paso 9) |

Vista nueva sin GRANT: `cob.vw_LogAccesoEvidencia`, con la IP enmascarada (IPv4 al /24, IPv6 al /48) y el agente de usuario reducido u omitido, para exportar evidencias.

Los mensajes de error usan el rango 50060-50079 (sql/05 y sql/11 ya usan 50020 y 50040-50043). `dba` debe confirmar que `sql/02` y `sql/06` no otorgan SELECT sobre `cob.LogAcceso` a ninguna identidad administrada.

### 5.3 Algoritmos

Contraseñas:
- `Microsoft.AspNetCore.Identity.PasswordHasher<TUser>` con `PasswordHasherOptions.CompatibilityMode = V3` (valor por defecto). Según la documentación oficial, el número de iteraciones por defecto de PBKDF2 es 100.000 (ver fuentes). No se cambia `IterationCount` en la API ni en la herramienta de alta, para que ambas produzcan y verifiquen el mismo formato.
- El tipo está en `Microsoft.Extensions.Identity.Core`. El `desarrollador` debe confirmar al compilar si ya está disponible por el framework compartido `Microsoft.AspNetCore.App` o si se agrega el paquete; no suponerlo.
- Para un usuario inexistente o bloqueado se ejecuta igualmente una verificación contra un hash ficticio generado al iniciar la aplicación, para que el tiempo de respuesta no revele si el usuario existe.
- Contraseña temporal (alta y restablecimiento): 20 caracteres (DEMO) generados con `RandomNumberGenerator`, sin caracteres ambiguos (`0`, `O`, `1`, `l`, `I`). Es más larga que el mínimo de 12 (DEMO) porque su hash queda en la auditoría SQL (4.2).

Claves de API:
- Formato: `cobk_<prefijo>_<secreto>`. `prefijo` = 8 caracteres Base32 en minúsculas (`[a-z2-7]`, 5 bytes aleatorios); `secreto` = 32 bytes de `RandomNumberGenerator` codificados en Base64url sin relleno (43 caracteres). Longitud total 57.
- Hash almacenado: SHA-256 de la clave completa en UTF-8 (`BINARY(32)`).
- Validación: la API separa el prefijo, calcula SHA-256 y llama a `sp_ValidarClaveApi`. Un formato inválido se rechaza con 401 sin consultar la base. La API no lee Key Vault en ningún punto de la validación: el valor en Key Vault existe solo para que el consumidor lo lea (5.9).
- Por qué no PBKDF2 para las claves: PBKDF2 (o cualquier función lenta) existe para encarecer la búsqueda exhaustiva de secretos de baja entropía elegidos por personas. Una clave con 32 bytes aleatorios tiene 256 bits de entropía; recorrer ese espacio es inviable aunque cada intento cueste un solo SHA-256, y no hay diccionario ni tabla precalculada útil porque cada valor es único y aleatorio (por la misma razón no requiere sal). En cambio, una función lenta en cada solicitud consumiría CPU del plan B1 compartido con las Functions, afectaría el KPI de respuesta menor a 2 s de la prueba de carga (`pruebas/carga_api_k6.js`) y facilitaría la denegación de servicio. SHA-256 permite además buscar por igualdad exacta en SQL.
- Caché: el resultado de una validación correcta se guarda en memoria 60 s (DEMO), con clave el hash. Consecuencia: una revocación tarda como máximo ese tiempo en aplicarse.

### 5.4 Parámetros de bloqueo, sesión y contraseña

Todos son DEMO. Estado de aprobación por valor (U6):

| Parámetro (ajuste `Seguridad__*`) | Valor DEMO | Estado |
| --- | --- | --- |
| `Seguridad__MaxIntentosFallidos` | 5 | Valor DEMO aprobado por el equipo (05-11-2026) |
| `Seguridad__MinutosBloqueo` | 15 | Valor DEMO aprobado por el equipo (05-11-2026) |
| `Seguridad__LoginPorIpPorMinuto` (limitador de tasa en memoria, ventana fija) | 10 | PENDIENTE (no figura en A.11) |
| `Seguridad__LongitudMinimaClave` | 12 | PENDIENTE (no figura en A.11; la política lo cita como referencia) |
| `Seguridad__LongitudMaximaClave` | 128 | PENDIENTE (ídem) |
| `Seguridad__MinutosInactividadSesion` | 30 | Valor DEMO aprobado por el equipo (05-11-2026) |
| `Seguridad__HorasMaximasSesion` | 8 | Valor DEMO aprobado por el equipo (05-11-2026) |
| `Seguridad__MinutosRevalidacionSesion` | 5 | Valor DEMO aprobado por el equipo (05-11-2026) |
| `Seguridad__SegundosCacheClaveApi` | 60 | Valor DEMO aprobado por el equipo (05-11-2026) |
| `Seguridad__DiasVigenciaClaveApi` (máximo; lo aplica el script de alta) | 180 | PENDIENTE (A.11 solo lo menciona como valor del ADR) |
| `Seguridad__HorasVigenciaClaveTemporal` (nuevo, revisión 1) | 24 | Valor DEMO aprobado por el equipo (05-11-2026) |
| `Seguridad__SaltosProxyConfiables` (nuevo, revisión 1; ver 5.4.1) | 1 sin WAF; 2 con WAF (D11) | No es una preferencia: lo determina la topología (5.4.1). Revisión de `qa` |

Otros valores DEMO de la política de credenciales (A.11), aprobados por el equipo (05-11-2026): longitud de la contraseña temporal 20; vigencia de la clave `ventas-demo` 30 días; vigencia de la clave `carga-demo` 1 día; aviso de rotación 7 días antes del vencimiento; lote de purga 5.000 filas; retención de `cob.LogAcceso` 90 días. La superposición máxima de claves en rotación (1 hora, política C.2) y la frecuencia de actualización de `UltimoUso` (60 min, 5.2) no figuran en A.11: PENDIENTE. Si el orquestador confirma que "etc." incluye los valores marcados PENDIENTE en esta sección, basta con cambiar su estado.

Reglas de contraseña: longitud entre mínimo y máximo, distinta del nombre de usuario y distinta de la actual. No se exigen reglas de composición (se privilegia la longitud). El limitador de tasa en memoria es válido porque hay una sola instancia B1; si se escala a más instancias (RNF-03) deja de ser global.

Vigencia de la contraseña temporal: si `DebeCambiarClave = 1` y `FechaCambioClave` es anterior a `SYSUTCDATETIME() - HorasVigenciaClaveTemporal`, la API rechaza el login con el mismo 401 genérico, no verifica la contraseña y registra `LoginFallido` con motivo `ClaveTemporalVencida` (sin incrementar el contador). Solo se recupera con un restablecimiento nuevo.

#### 5.4.1 Encabezados reenviados (M-08b)

Problema: la IP de origen alimenta el limitador por IP y la columna `IpOrigen` de `cob.LogAcceso` (RNF-05). Si el middleware de encabezados reenviados acepta valores de `X-Forwarded-For` escritos por el cliente, un atacante evade el limitador rotando el encabezado y escribe IP falsas en la bitácora.

Hechos de la documentación oficial (fuente 9.4, consultada el 05-11-2026):
- El middleware procesa los valores de derecha a izquierda; `ForwardLimit` por defecto es 1, es decir, solo se toma el valor de más a la derecha.
- Por defecto solo se confía en proxies de loopback (`KnownProxies`/`KnownNetworks`); una conexión desde otra dirección no se procesa.
- En Linux no hay configuración automática equivalente a IIS. La variable `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true` habilita el middleware con ajustes "para entornos de nube" y, según la advertencia de la documentación, no restringe desde qué IP se aceptan los reenviadores.

Reglas obligatorias:

1. Una sola configuración, en código. `Program.cs` configura `ForwardedHeadersOptions` explícitamente y llama a `UseForwardedHeaders()` como primer middleware (antes de HSTS, archivos estáticos, limitador de tasa, autenticación y autorización). El ajuste de App Service `ASPNETCORE_FORWARDEDHEADERS_ENABLED` se fija en `false` en `infra/main.bicep`, para que la plataforma o la imagen no agreguen una segunda instancia del middleware. Motivo: si el middleware se ejecuta dos veces, la segunda pasada consume el siguiente valor de la lista, que puede ser uno escrito por el cliente. Si App Service Linux define esa variable por defecto: PENDIENTE verificar en Azure (Kudu, `env`) durante el despliegue; la regla aplica en ambos casos.
2. `ForwardedHeaders = XForwardedFor | XForwardedProto`. No se procesa `X-Forwarded-Host` (la API no lo necesita y evita inyección del encabezado Host).
3. `ForwardLimit = Seguridad__SaltosProxyConfiables`:
   - Sin WAF (topología actual): 1. El valor de más a la derecha lo agrega el front-end de App Service; los valores a su izquierda (incluidos los que escriba el cliente) se ignoran.
   - Con WAF (D11, opción B): 2. Cadena esperada: cliente, luego Application Gateway (agrega la IP del cliente), luego front-end de App Service (agrega la IP del gateway). Solo es válido si la Web App queda sin acceso público y con entrada únicamente por el Private Endpoint desde el gateway, como exige la opción B; si la Web App siguiera pública, un cliente directo podría controlar el segundo valor. `devops` cambia el valor en el mismo despliegue que active D11.
4. `KnownProxies`/`KnownNetworks` (en .NET 10 la propiedad de redes puede llamarse `KnownIPNetworks`; el `desarrollador` usa la que compile sin advertencias de obsolescencia): las direcciones internas del front-end de App Service no están documentadas como fijas. Se vacían ambas listas y la confianza se acota con `ForwardLimit` (regla 3). Es aceptable porque el contenedor de la Web App solo recibe tráfico a través del front-end de App Service (la integración VNet de `snet-app` es solo de salida). Si durante el despliegue se observa un rango estable del front-end, `seguridad` puede proponer fijarlo en `KnownNetworks`: PENDIENTE de observación en Azure. Con WAF, si se define la subred del gateway (hoy no existe en el plan de direccionamiento: PENDIENTE D11), se valida además que el segundo valor desde la derecha pertenezca a esa subred.
5. El valor puede venir con puerto (`ip:puerto`). El `desarrollador` verifica que `RemoteIpAddress` quede sin puerto antes de usarlo como partición del limitador y antes de escribirlo en `IpOrigen`.
6. Prueba obligatoria (RED-16, sección 6): una solicitud con `X-Forwarded-For: 203.0.113.10` escrito por el cliente no cambia la IP registrada en `cob.LogAcceso` ni la partición del limitador; 11 intentos por minuto rotando ese encabezado siguen recibiendo 429.

### 5.5 Política de cookie, CSRF y Data Protection

Cookie de autenticación (`AddCookie`):
- Nombre `__Host-cobranza-sesion` (el prefijo `__Host-` obliga a `Secure`, `Path=/` y sin `Domain`).
- `HttpOnly = true`, `SecurePolicy = Always`, `SameSite = Strict`, `IsEssential = true`.
- `ExpireTimeSpan` = 30 min con `SlidingExpiration = true`; duración absoluta 8 h controlada con un claim `emitida_utc` validado en `OnValidatePrincipal`. Sin "recordarme" (cookie de sesión, `IsPersistent = false`).
- `OnValidatePrincipal`: cada 5 min llama a `sp_ObtenerUsuarioPorId`; rechaza la cookie si el usuario está inactivo, bloqueado o si `SelloSeguridad` o `Rol` cambiaron.
- `OnRedirectToLogin` y `OnRedirectToAccessDenied` devuelven 401 y 403 (no redirecciones 302); `panel.js` redirige a `/login.html` al recibir 401.

CSRF:
- `SameSite=Strict` bloquea el envío de la cookie en solicitudes iniciadas desde otros sitios, pero se agrega además antifalsificación de ASP.NET Core en todas las solicitudes que cambian estado (login, logout, cambio de contraseña), incluido el login (CSRF de inicio de sesión).
- `AddAntiforgery`: cookie `__Host-cobranza-af` (`Secure`, `HttpOnly`, `SameSite=Strict`), encabezado `X-CSRF-TOKEN`.
- `GET /api/v1/auth/antiforgery` (anónimo) entrega el token en JSON; `panel.js` y `login.js` lo envían en el encabezado. Los endpoints POST con cuerpo JSON validan con `IAntiforgery.ValidateRequestAsync` (la validación automática de Minimal APIs aplica a formularios).
- Las solicitudes con clave de API no usan cookies, por lo que no están expuestas a CSRF; los endpoints de autenticación rechazan principales autenticados por clave de API.

Telemetría: no se registran en Application Insights ni en los logs de la API los cuerpos de `/api/v1/auth/*`, los encabezados `X-Api-Key`, `Authorization` y `Cookie`, los valores de cookies ni los tokens CSRF. El `desarrollador` verifica la configuración real de la telemetría; no se supone el comportamiento por defecto (PENDIENTE verificar también en Azure).

Claves de Data Protection (protegen la cookie y los tokens antifalsificación):
- Comportamiento por defecto en App Service: las claves se guardan en `%HOME%\ASP.NET\DataProtection-Keys`, almacenamiento de red persistente y compartido por las instancias del mismo slot, pero sin protección en reposo (fuente 9.1). Con una sola instancia B1 esto funciona y sobrevive reinicios y redespliegues de código; las claves son legibles por quien tenga acceso al sitio SCM/Kudu o al sistema de archivos del sitio, y con ellas se podría falsificar una cookie de cualquier rol.
- Decisión recomendada: `PersistKeysToAzureBlobStorage` en un contenedor dedicado de la cuenta de Storage existente, con la identidad administrada del sistema de la API, más `ProtectKeysWithAzureKeyVault` con una clave RSA en el Key Vault existente (identificador sin versión), y `SetApplicationName("cobranza-api")`.
  - Conviene porque: cifra las claves en reposo con Key Vault (coherente con RNF-02), separa las claves del ciclo de vida del sitio, permite escalar a más instancias o slots (RNF-03) sin cerrar sesiones y queda controlado por RBAC auditable. La cuenta de Storage ya es ZRS, sin clave compartida, con Private Endpoint de blob (10.20.2.6), y el Key Vault ya tiene Private Endpoint (10.20.2.5); la API sale por la VNet (`vnetRouteAllEnabled`).
  - Paquetes: `Azure.Extensions.AspNetCore.DataProtection.Blobs`, `Azure.Extensions.AspNetCore.DataProtection.Keys` y `Azure.Identity` (versiones a confirmar con `dotnet list package --outdated`).
  - Nombres propuestos: contenedor `dataprotection-keys`, blob `keys.xml`, clave Key Vault `dataprotection-cobranza-api`. Ajustes: `DataProtection__BlobUri` y `DataProtection__KeyIdentifier` (valores los produce la plantilla; no se escriben a mano).
  - Impacto de pérdida: si se pierden las claves (por ejemplo, al eliminar el grupo de recursos con `eliminar_entorno.sh`), solo se invalidan las sesiones abiertas; no hay datos persistentes protegidos con Data Protection.
- Alternativa aceptable si `devops` no alcanza a agregar los recursos antes de la semana 11: dejar el comportamiento por defecto de `%HOME%` y registrar el riesgo. Como `%HOME%` es propio de cada sitio, la Function App no tiene acceso a esas claves. Requiere aprobación explícita del equipo (PENDIENTE si se usa).

#### 5.5.1 RBAC mínimo de las identidades administradas (M-07, revisión 1)

Análisis de necesidades reales (leído en `infra/main.bicep` y `src/`, 05-11-2026):
- La API no necesita leer ningún secreto de Key Vault: la cadena de SQL usa identidad administrada (sin secreto), la cadena de Application Insights es un ajuste normal, la referencia a `easyauth-client-secret` desaparece con este ADR y la validación de claves de API se hace contra el hash en SQL (5.3). Con `raKvApi` vigente, la API podría leer `acs-connection-string` y todos los secretos `apikey-*`, lo que convierte un compromiso de la API en un compromiso del correo y de todos los consumidores.
- La Function App solo necesita leer `acs-connection-string` (referencia de `Cobranza__AcsConnectionString`).
- La Function App necesita `Storage Blob Data Owner` para `AzureWebJobsStorage`: según la documentación oficial (fuente 9.5) es el rol mínimo para la conexión de almacenamiento del host; los temporizadores toman bloqueos con blobs mediante esa conexión, y `Storage Table Data Contributor` se recomienda para los eventos de diagnóstico del host. La documentación no indica que el rol pueda acotarse a contenedores específicos del host (el host crea sus contenedores). Acotarlo por alcance de contenedor: NO VERIFICADO, no se adopta.
- Con ese rol sobre toda la cuenta, la Function App podría leer, reemplazar o eliminar `dataprotection-keys/keys.xml`. El cifrado con Key Vault impide leer las claves, pero reemplazar el anillo corta todas las sesiones (denegación de servicio) y no se puede descartar que el anillo acepte un elemento de clave insertado sin cifrar, lo que permitiría falsificar cookies de cualquier rol (NO VERIFICADO; se trata como posible).

Decisión de alcances:

| Identidad | Rol | Alcance | Cambio respecto de `main.bicep` actual |
| --- | --- | --- | --- |
| API | `Key Vault Secrets User` | — | Se retira `raKvApi` |
| API | `Key Vault Crypto User` | Clave `dataprotection-cobranza-api` | Nuevo (la documentación indica Get, Wrap Key y Unwrap Key) |
| API | `Storage Blob Data Contributor` | Contenedor `dataprotection-keys` | Nuevo |
| Function App | `Key Vault Secrets User` | Secreto `acs-connection-string` (no el vault) | `raKvFunc` cambia de alcance |
| Function App | `Storage Blob Data Owner` | Cuenta, con condición de asignación (ABAC) que niega las acciones de datos de blob cuando el contenedor es `dataprotection-keys` | `raStorageFunc` (blob) agrega condición |
| Function App | `Storage Queue Data Contributor`, `Storage Table Data Contributor` | Cuenta | Sin cambio en este ADR; `devops` revisa si Queue es necesario para Functions solo con temporizadores (B-09) |
| Operador | `Key Vault Secrets Officer` | Vault | Sin cambio (crea y revoca `apikey-*`); se actualiza el comentario de `raKvOperador` |
| Lector humano de `apikey-ventas-demo-*` distinto del operador | `Key Vault Secrets User` | Solo ese secreto | Lo crea el script de alta, nunca con alcance en el vault |

Condición ABAC de la Function App:
- La documentación oficial (fuente 9.6) indica que las condiciones de asignación están disponibles (GA) para `Storage Blob Data Owner` y que se aplican a acciones de datos (DataActions), no a acciones de administración.
- Expresión: la escribe `devops` en formato de condición versión 2.0, de modo que las acciones de datos de lectura, escritura, eliminación y etiquetas de blob se permitan solo si `@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name]` es distinto de `dataprotection-keys`. La sintaxis exacta se valida con `bicep build`, `what-if` y una prueba negativa en Azure (SEG-DP-03, sección 6); no se supone que funcione hasta probarla.
- Riesgo residual: las acciones de administración de contenedores incluidas en el rol (por ejemplo, eliminar el contenedor) no admiten condiciones. Un compromiso de la Function App podría eliminar el contenedor y cerrar todas las sesiones (denegación de servicio), pero no leer ni insertar claves. Se acepta para el entorno académico.

Opciones descartadas para la separación:
- Cuenta de Storage separada para Data Protection: requiere un sexto Private Endpoint de blob con IP fija nueva (cambia el plan de direccionamiento validado 15/15 y la lista de IP de CLAUDE.md sección 3) y un recurso más. Necesitaría su propio ADR.
- Aceptar el riesgo sin condición: descartado porque el costo de la condición es nulo y elimina el riesgo de falsificación.

### 5.6 Esquemas de autenticación y mapeo de roles

Esquemas en `Program.cs`:
- `Cookies` (panel).
- `ClaveApi`: manejador nuevo que lee el encabezado `X-Api-Key`.
- Esquema de política por defecto (`AddPolicyScheme`) que reenvía a `ClaveApi` si la solicitud trae `X-Api-Key` y a `Cookies` en caso contrario.

Claims emitidos:
- Usuario: `NameIdentifier` = UsuarioId, `Name` = Usuario, `nombre` = Nombre, `Role` = Rol de la tabla, `sello` = SelloSeguridad, `emitida_utc`, y `debe_cambiar_clave = 1` si corresponde.
- Clave de API: `NameIdentifier` = `clave:<ClaveApiId>`, `Name` = `api:<Consumidor>`, `Role` = Rol de `cob.ClaveApi`, `prefijo_clave`.

Mapeo de roles (se conservan exactamente los permisos actuales de las políticas):

| Rol actual en código (Easy Auth) | Rol en `cob.UsuarioInterno` / `cob.ClaveApi` | Constante nueva |
| --- | --- | --- |
| `Ventas.Consulta` | `Ventas` | `Roles.Ventas = "Ventas"` |
| `Finanzas.Consulta` | `Finanzas` | `Roles.Finanzas = "Finanzas"` |
| `TI.Operacion` | `Admin` | `Roles.Admin = "Admin"` (reemplaza a `Roles.Operacion`) |

| Política | Antes | Después | Endpoints |
| --- | --- | --- | --- |
| `ConsultaCliente` | Ventas.Consulta, Finanzas.Consulta | Ventas, Finanzas | `/api/v1/clientes/{rut}/estado`, `/api/v1/clientes/{rut}/pedidos` |
| `Cartera` | Finanzas.Consulta | Finanzas | `/api/v1/cartera/indicadores` |
| `Operacion` | TI.Operacion, Finanzas.Consulta | Admin, Finanzas | `/api/v1/sincronizaciones` |
| `SoloSesionPanel` (nueva) | — | Usuario autenticado por `Cookies` | `/api/v1/auth/logout`, `/api/v1/auth/cambiar-clave` |

Todas las políticas de negocio exigen además que no exista el claim `debe_cambiar_clave = 1`. Se mantiene la política de reserva que exige usuario autenticado. `Admin` no obtiene acceso a consulta de clientes ni a cartera, igual que `TI.Operacion` hoy; si el equipo quiere que `Admin` vea todo: PENDIENTE decidir. La administración de usuarios no se expone por la API (se hace por SQL, sección 5.9).

Archivos estáticos: hoy `UseStaticFiles` va después de `UseAuthorization`, por lo que la política de reserva también se aplicaría a `login.html`, `login.js` y `panel.css` y bloquearía el login. `UseDefaultFiles` y `UseStaticFiles` deben moverse antes de `UseAuthentication` (y después de `UseForwardedHeaders`, 5.4.1). `wwwroot` no contiene datos (los datos vienen de la API protegida); `qa` debe confirmarlo.

### 5.7 Auditoría (RNF-05)

| Situación | Registro |
| --- | --- |
| Login exitoso | `LoginExitoso` en `cob.LogAcceso` (sp_RegistrarLoginExitoso) |
| Contraseña incorrecta | `LoginFallido`, motivo `ClaveIncorrecta`; si alcanza el máximo, además `CuentaBloqueada` |
| Usuario inexistente | `LoginFallido`, motivo `UsuarioInexistente`, `UsuarioId` NULL, `UsuarioIngresado` sanitizado (5.1) |
| Usuario inactivo | `LoginFallido`, motivo `UsuarioInactivo` |
| Intento con cuenta bloqueada | `LoginFallido`, motivo `CuentaBloqueada` (no incrementa el contador ni verifica la contraseña) |
| Contraseña temporal vencida | `LoginFallido`, motivo `ClaveTemporalVencida` (no incrementa el contador ni verifica la contraseña) |
| Solicitud rechazada por el limitador de tasa | Solo Application Insights (429), sin escritura en SQL |
| Logout | `Logout` |
| Cambio de contraseña | `CambioClave` (también cierra el alta, 5.9) |
| Operaciones administrativas | Evento correspondiente con `Actor = ORIGINAL_LOGIN()` y auditoría de Azure SQL |
| Purga de la bitácora | `PurgaLogAcceso` con el total borrado |
| Invalidación masiva de sesiones | `InvalidacionSesiones` |
| Clave de API rechazada | Application Insights (advertencia con el prefijo) |
| Lectura de secretos `apikey-*` | Auditoría de Key Vault (`AuditEvent`) hacia Log Analytics (SEG-H03) |

La respuesta al usuario es siempre la misma para todas las causas de login fallido: 401 con "Usuario o contraseña incorrectos". El motivo real queda solo en la bitácora.

Nunca se registra, en ninguna bitácora ni en evidencias: contraseñas, hashes de contraseña, claves de API completas o sus hashes, valores de cookies, tokens CSRF, encabezados `X-Api-Key`, `Authorization` o `Cookie`, cuerpos de `/api/v1/auth/*` ni cadenas de conexión.

### 5.8 Endpoints nuevos y cambios

| Método y ruta | Autorización | Entrada | Respuesta |
| --- | --- | --- | --- |
| `GET /api/v1/auth/antiforgery` | Anónimo | — | 200 `{ "token": "..." }` y cookie antifalsificación |
| `POST /api/v1/auth/login` | Anónimo, limitador de tasa, CSRF | JSON `{ "usuario": "...", "clave": "..." }` | 200 `{ "nombre", "roles", "debeCambiarClave" }` y cookie de sesión; 401 genérico; 400 si falta un campo; 429 si supera la tasa |
| `POST /api/v1/auth/logout` | `SoloSesionPanel`, CSRF | — | 204; elimina la cookie y registra `Logout` |
| `POST /api/v1/auth/cambiar-clave` | `SoloSesionPanel` (permitido con `debe_cambiar_clave`), CSRF | JSON `{ "claveActual": "...", "claveNueva": "..." }` | 204 y cookie reemitida con el sello nuevo y sin `debe_cambiar_clave`; 400 si la nueva no cumple la política; 401 si la actual es incorrecta (cuenta como intento fallido) |
| `GET /api/v1/yo` (existente) | Autenticado | — | Agrega `debeCambiarClave` y `tipoAutenticacion` (`Cookies` o `ClaveApi`) |
| `GET /salud` (existente) | Anónimo | — | Sin cambio |

Panel: nueva página `wwwroot/login.html` con `login.js`; `index.html` agrega botón de cierre de sesión y formulario de cambio de contraseña; `panel.js` reemplaza la redirección a `/.auth/login/aad` por `/login.html` y envía `X-CSRF-TOKEN` en los POST.

### 5.9 Alta de usuarios y de claves de API (sin contraseñas en git)

Las altas las hace el equipo (U2). Detalle operativo completo en `docs/seguridad/politica_credenciales_y_accesos.md`, sección A.

Regla SEG-H01 (obligatoria): ningún agente de Claude Code ejecuta `s11_alta_usuario.sh`, `s11_restablecer_clave.sh`, `s11_baja_usuario.sh`, `s11_alta_clave_api.sh`, `s11_revocar_clave_api.sh` ni los comandos de `Cobranza.Herramientas`. Los ejecuta un integrante humano, miembro de `grp-cobranza-sql-admin`, en su propia terminal y fuera de Claude Code. Motivo: la salida de la terminal del agente queda en la conversación, lo que equivale a pasar el secreto por chat. Los scripts piden confirmación interactiva; un mecanismo para detectar que corren dentro de Claude Code: PENDIENTE de verificación por `devops` (no suponer una variable de entorno).

Herramienta: proyecto de consola nuevo `src/Cobranza.Herramientas` (net10.0), agregado a `Cobranza.slnx`, con dos comandos:
- `hash-clave`: genera una contraseña temporal aleatoria de 20 caracteres (DEMO, 5.3) y la escribe directamente en la terminal, no en la salida estándar (`/dev/tty` en Linux y Git Bash; la consola en Windows). La salida estándar lleva solo el hash V3, que el script captura en una variable. Usa la misma configuración de `PasswordHasher` que la API. Cómo abrir la terminal en Git Bash para Windows sin pasar por stdout: PENDIENTE de verificación por el `desarrollador`; si no se puede garantizar, el comando falla en lugar de escribir la contraseña en stdout.
- `nueva-clave-api --consumidor <nombre> --salida-archivo <ruta>`: genera la clave con el formato de 5.3, la escribe solo en el archivo indicado y deja en la salida estándar solo el prefijo y el hash SHA-256 en hexadecimal.

Procedimiento de alta de usuario del panel (script nuevo `scripts/s11_alta_usuario.sh`):
1. Se registra la solicitud (usuario, rol, quién autoriza: responsable PENDIENTE).
2. El destinatario está presente.
3. El operador ejecuta `s11_alta_usuario.sh --usuario <u> --nombre "<n>" --rol <Finanzas|Ventas|Admin>`; el script valida el patrón del usuario y el rol.
4. `hash-clave` muestra la contraseña temporal en la terminal; el script captura solo el hash (nada se escribe en disco).
5. `sqlcmd` autenticado con Entra ID (cuenta del operador miembro del grupo) ejecuta `EXEC cob.sp_CrearUsuarioInterno`. Si el hash se pasa con `sqlcmd -v`, la cabecera del script lo advierte (4.2).
6. Canal de entrega: presencial con uso inmediato (política A.3). El destinatario lee la contraseña en la pantalla del operador; el operador presiona Enter y el script limpia la pantalla y el historial visible (`clear` y `\033[3J`). Sin `set -x`, `tee` ni redirecciones de esa salida. No se aceptan correo, chat, videollamada, pantalla compartida, papel ni fotografías. Si no hay presencia física, el alta se posterga.
7. El destinatario inicia sesión en su equipo y cambia la contraseña de inmediato (`DebeCambiarClave = 1`; vigencia máxima 24 h DEMO).
8. El operador ejecuta `s11_alta_usuario.sh --verificar <u>` (usa `sp_VerificarCambioClave`). El alta se da por cerrada con el evento `CambioClave`.
9. La evidencia `evidencias/seguridad/<fecha>_entrega_credenciales.md` registra usuario, rol, operación, fecha y hora UTC, operador, canal "presencial", confirmación del destinatario y hora del `CambioClave`; nunca la contraseña, el hash ni la IP del operador (`<IP_OPERADOR>`).

Restablecimiento (`scripts/s11_restablecer_clave.sh --usuario <u> [--solo-desbloquear]`): solicitud en persona; `sp_RestablecerClaveUsuario` (o `sp_DesbloquearUsuario` con `--solo-desbloquear`); luego pasos 6 a 9.

Baja (`scripts/s11_baja_usuario.sh --usuario <u>`): `sp_CambiarEstadoUsuario @Activo = 0`; evidencia.

Procedimiento de alta de clave de API (script nuevo `scripts/s11_alta_clave_api.sh --consumidor ventas-demo --dias 30 [--lector-object-id <OID>]`):
1. Valida el patrón del consumidor y que `--dias` no supere `Seguridad__DiasVigenciaClaveApi`.
2. Ejecuta `nueva-clave-api --salida-archivo <tmp>` con un archivo de `mktemp` en el perfil del usuario; `trap` lo elimina también ante error. En Git Bash para Windows `chmod 600` no aplica sobre NTFS; la protección real es la ACL del perfil.
3. Guarda la clave en Key Vault como secreto `apikey-<consumidor>-<prefijo>` con `az keyvault secret set --file <tmp> --encoding utf-8 --expires <FechaVencimiento> --content-type api-key --tags consumidor=<c> ambiente=DEMO prefijo=<p>`. El atributo `exp` es informativo según la documentación de Key Vault (SEG-H09; verificar en Azure); la vigencia real se controla en SQL. El operador ya tiene `Key Vault Secrets Officer` (`raKvOperador`).
4. Registra prefijo y hash con `EXEC cob.sp_RegistrarClaveApi`.
5. Si se indica un lector distinto del operador, crea `Key Vault Secrets User` con alcance en ese secreto. Leer desde una IP distinta de `ipOperador`: PENDIENTE (requiere aprobación, porque abre otra IP en Key Vault).
6. La salida muestra solo prefijo, nombre del secreto y vencimiento. Evidencia en `evidencias/seguridad/<fecha>_claves_api.md` (sin clave ni hash).

Entrega de la clave al consumidor: no hay entrega. El consumidor DEMO `ventas-demo` (U1) es el script `pruebas/consumidor_ventas_demo.sh`, que lee la clave de Key Vault en tiempo de ejecución (`az keyvault secret show ... --query value -o tsv` a una variable), la envía por la entrada estándar de curl (`printf 'X-Api-Key: %s\n' "$CLAVE" | curl -H @- ...`) para que no aparezca en la lista de procesos, ejecuta AUT-10, AUT-11 y un caso de formato inválido (401), y termina con `unset CLAVE`. La evidencia registra prefijo, código HTTP y hora.

Rotación (`ventas-demo`): 7 días antes del vencimiento (DEMO), de inmediato ante sospecha de exposición, después de toda restauración y al cambiar el integrante que ejecuta el consumidor. Pasos: alta de la clave nueva, el consumidor pasa a usar el secreto nuevo, prueba AUT-10, revocación de la anterior con `s11_revocar_clave_api.sh`, verificación AUT-12, evidencia. Superposición máxima 1 hora (DEMO).

Revocación (`scripts/s11_revocar_clave_api.sh --prefijo <p>`): `sp_RevocarClaveApi`, luego `az keyvault secret set-attributes --enabled false`, eliminación del secreto y de la asignación del lector si existe; verifica 401 pasados 60 s (AUT-12). El secreto eliminado queda 90 días en soft-delete y no se puede purgar (protección de purga).

Cierre del entorno: antes de `eliminar_entorno.sh` se revocan todas las claves y se desactivan todos los usuarios, y se exportan las evidencias de `cob.LogAcceso` mediante `cob.vw_LogAccesoEvidencia` a `evidencias/<fecha>_log_acceso/`.

Purga mensual (`scripts/s15_purgar_log_acceso.sh --dias 90 --confirmar`): la ejecuta un miembro de `grp-cobranza-sql-admin` el primer día hábil de cada mes, solo si el entorno tiene más de 90 días de vida.

### 5.10 Archivos que cambian y archivos obsoletos

Cambian (en orden de dependencia dentro de cada agente; el orden entre agentes está en la sección 7):

| Archivo | Cambio | Agente |
| --- | --- | --- |
| `sql/01_esquema_cobranza.sql` | Corrección C-01 (prerrequisito) y nueva definición de `cob.UsuarioInterno` (5.1) | dba |
| `sql/04_jobs_bitacoras.sql` | `sp_RegistrarNotificacion` acepta `EstadoEnvio = 'Limitado'` sin incrementar `Intentos` (5.12) | dba |
| `sql/12_autenticacion.sql` (nuevo) | `cob.ClaveApi`, `cob.LogAcceso`, procedimientos y vista de 5.2, GRANT a `$(UsuarioApi)` solo de la primera tabla de 5.2 | dba |
| `sql/13_pruebas_autenticacion.sql` (nuevo) | Pruebas T-SQL sin dejar datos (estilo de `sql/07`): bloqueo, desbloqueo, sello, claves vencidas y revocadas, purga rechaza menos de 90 días, purga borra solo lo antiguo, invalidación cambia todos los sellos, motivo `ClaveTemporalVencida` aceptado, sanitización de `UsuarioIngresado`, `Limitado` no incrementa `Intentos` | dba |
| `sql/02_identidades_y_permisos.sql` | Solo comentario de cabecera: "12 -> UsuarioApi: EXECUTE sobre procedimientos de autenticación" | dba |
| `sql/00_verificar_esquema.sql` | Columnas y objetos de autenticación esperados; `EstadoEnvio {Aceptado, Fallido, Limitado}` | dba |
| `src/Cobranza.Api/Seguridad/EasyAuthHandler.cs` | Se retira como primer cambio de la implementación (A-01, 5.11) | desarrollador |
| `src/Cobranza.Api/Program.cs` | Encabezados reenviados (5.4.1), esquemas `Cookies` y `ClaveApi`, selector, políticas con roles nuevos, antifalsificación, limitador de tasa, Data Protection, orden de `UseStaticFiles`, endpoints de 5.8, exclusión de telemetría sensible | desarrollador |
| `src/Cobranza.Api/Seguridad/Roles.cs` (nuevo) | `Roles` y `Politicas` movidos desde `EasyAuthHandler.cs` con los valores nuevos | desarrollador |
| `src/Cobranza.Api/Seguridad/ClaveApiHandler.cs` (nuevo) | Manejador del encabezado `X-Api-Key` | desarrollador |
| `src/Cobranza.Api/Seguridad/ServicioAutenticacion.cs` (nuevo) | Verificación de contraseña, hash ficticio, bloqueo, vigencia de contraseña temporal, sanitización de `UsuarioIngresado`, emisión y revalidación de cookie | desarrollador |
| `src/Cobranza.Api/Seguridad/OpcionesSeguridad.cs` (nuevo) | Opciones `Seguridad__*` de 5.4 | desarrollador |
| `src/Cobranza.Api/Datos/RepositorioUsuarios.cs` (nuevo) | Llamadas a los procedimientos con GRANT de 5.2 | desarrollador |
| `src/Cobranza.Api/appsettings.json` | Sección `Seguridad` con valores DEMO y sección `DataProtection` con marcadores PENDIENTE (los valores reales los define la plantilla) | desarrollador |
| `src/Cobranza.Api/Cobranza.Api.csproj` | Paquetes de Data Protection, Azure.Identity y, si hace falta, Identity.Core | desarrollador |
| `src/Cobranza.Api/wwwroot/login.html`, `login.js` (nuevos), `index.html`, `panel.js` | Login, logout, cambio de contraseña, token CSRF, redirección a `/login.html` | desarrollador |
| `src/Cobranza.Herramientas/` (nuevo) y `Cobranza.slnx` | Herramienta de 5.9 (`hash-clave` a la terminal, `nueva-clave-api --salida-archivo`) | desarrollador |
| `src/Cobranza.Functions/Funciones/NotificacionesFunction.cs` | 429 o rechazo por límite: registrar `Limitado`, detener el lote, sin contar intento (5.12) | desarrollador |
| `src/Cobranza.Functions/Modelos/OpcionesCobranza.cs`, `local.settings.example.json` | Comentarios y valores de ejemplo alineados con H1 y D12 DEMO (B-06) | desarrollador |
| `tests/` (proyecto de pruebas: no existe hoy; nombre PENDIENTE) | Pruebas unitarias e integración de 7.2 | desarrollador |
| `pruebas/carga_api_k6.js` | Reemplazar `COOKIE` (`AppServiceAuthSession`) y `TOKEN` por `API_KEY` tomada del entorno (no con `-e`) en el encabezado `X-Api-Key` | desarrollador |
| `pruebas/consumidor_ventas_demo.sh` (nuevo) | Consumidor DEMO de 5.9 | desarrollador |
| `infra/main.bicep` | Retirar `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` (líneas 556-562) y el comentario de la línea 820; retirar `raKvApi` (líneas 800-808); `raKvFunc` con alcance en `secretAcs`; condición ABAC en la asignación `Storage Blob Data Owner` de `raStorageFunc`; contenedor `dataprotection-keys`, clave `dataprotection-cobranza-api`, asignaciones `Storage Blob Data Contributor` (contenedor) y `Key Vault Crypto User` (clave) para la API; ajustes `DataProtection__*`, `Seguridad__SaltosProxyConfiables` y `ASPNETCORE_FORWARDEDHEADERS_ENABLED=false`; restricción de acceso de transición de la Web App (5.11); diagnóstico de auditoría de Key Vault (SEG-H03); valores D12 DEMO (5.12) | devops |
| `infra/main.bicepparam` | Textos DEMO de Finanzas rotulados (5.12) y D12 DEMO | devops |
| `scripts/s10_configurar_jobs.sh` | Alinear con la plantilla: quitar `90`/`2100` (M-06) | devops |
| `scripts/s11_configurar_api.sh` | Retirar el ajuste `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` y el orden de la línea 5; no publicar mientras rija 5.11 | devops |
| `scripts/s11_alta_usuario.sh`, `s11_restablecer_clave.sh`, `s11_baja_usuario.sh`, `s11_alta_clave_api.sh`, `s11_revocar_clave_api.sh` (nuevos) | Procedimientos de 5.9 (cabecera con regla SEG-H01; `set -euo pipefail`; sin `set -x` ni `tee`; confirmación interactiva) | devops |
| `scripts/s14_simulacro_pitr.sh` (existente) o `scripts/s14_revision_post_restauracion.sh` (nuevo) | Revisión posterior a restauración (4.2, política C.3) con `--base-original`, `--base-restaurada`, `--punto` | devops |
| `scripts/s15_purgar_log_acceso.sh` (nuevo) | Purga mensual de 5.9 | devops |
| `scripts/desplegar_sql.sh` | Orden: 01, 02, 03, 04, 05, 06, 12, 11, 00, 07, 13. El archivo no existe en el repositorio: si se crea o se copia desde el paquete S10-S15, PENDIENTE de decisión humana (CLAUDE.md sección 7) | devops |
| `README.md` | Filas de estructura y paso 4 del orden de despliegue | devops |
| `scripts/s12_endurecer.sh` | Línea 55: "protegida por Entra ID" pasa a "protegida por autenticación propia (sin MFA)"; cerrar Key Vault y eliminar sus `ipRules`; eliminar la regla `operador-temporal`; mantener o levantar la restricción de transición según 5.11 (SEG-H08) | seguridad |
| `scripts/s12_verificar_seguridad.sh` | SEG-05 (sección 6) y controles nuevos de RBAC y Key Vault (sección 6) | seguridad |
| `scripts/s12_pruebas_red.sh` | RED-02 y pruebas nuevas RED-11 a RED-17 (sección 6) | seguridad |
| `docs/seguridad/` | Plantillas sin datos `entrega_credenciales.md`, `claves_api.md`, `revision_post_restauracion.md` (las evidencias reales van en `evidencias/seguridad/`) | seguridad |

Quedan obsoletos (eliminar o mover a una carpeta de históricos; el equipo decide, el historial de git los conserva):

| Archivo o elemento | Motivo |
| --- | --- |
| `src/Cobranza.Api/Seguridad/EasyAuthHandler.cs` | Reemplazado por `Roles.cs`, `ClaveApiHandler.cs` y autenticación por cookie; además es el origen del riesgo A-01 |
| `scripts/s11_registro_entra_id.sh` | Requiere rol de directorio y consentimiento de administrador |
| `infra/modulos/autenticacion_api.bicep` | Easy Auth (`authsettingsV2`) no se usa |
| Secreto `easyauth-client-secret` y ajuste `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` | Sin Easy Auth |
| Asignación `raKvApi` (`Key Vault Secrets User` de la API sobre el vault) | La API no necesita secretos (5.5.1) |
| Archivo `asignaciones_roles.csv` (entrada de s11_registro_entra_id.sh) | Sin roles de aplicación de Entra ID |

### 5.11 Regla de transición (A-01, revisión 1)

Riesgo: `EasyAuthHandler.cs` acepta sin validar el encabezado `X-MS-CLIENT-PRINCIPAL`. App Service solo elimina ese encabezado cuando Easy Auth está habilitado, y con este ADR no se habilita. Si se publica la API actual, cualquiera puede enviar un principal con rol `Finanzas.Consulta` y leer la cartera y el estado de todos los clientes (RF-06, RF-07, RNF-02).

Reglas:
1. No se publica `src/Cobranza.Api` en Azure (paso 5 de la secuencia de despliegue, `s11_configurar_api.sh` o cualquier `zip deploy`) hasta que este ADR esté implementado, compilado, con pruebas en verde y con informe de `qa` APROBADO o APROBADO CON OBSERVACIONES.
2. El primer cambio de código de la implementación es retirar `EasyAuthHandler.cs` y su registro en `Program.cs`, aunque el resto no esté listo. Desde ese commit, ninguna compilación de la API confía en `X-MS-CLIENT-PRINCIPAL`.
3. Mientras rija la transición, la Web App tiene `ipSecurityRestrictionsDefaultAction = Deny` en `infra/main.bicep`, con una sola regla de permiso para `ipOperador` cuando tiene valor (vacío significa sin reglas de permiso). Esto cubre también el caso en que alguien publique por error. Si la sonda de salud `/salud` de App Service queda afectada por la restricción: PENDIENTE verificar en Azure; si lo está, `devops` lo informa antes de cambiar nada. Si el sitio SCM hereda o no la restricción (`scmIpSecurityRestrictionsUseMain`): lo decide `seguridad`, considerando que la publicación del operador usa SCM.
4. La restricción se levanta solo cuando se cumplan las condiciones de la regla 1 y un humano lo apruebe; queda registrado en `evidencias/` con fecha. Con D11 aprobado, la restricción se reemplaza por el cierre del acceso público de la opción B.
5. La regla no bloquea `az deployment group create` de la plantilla (la plantilla no publica código).

### 5.12 Notificaciones DEMO: D12 revisado y textos de Finanzas (revisión 1)

D12 DEMO (U5):
- `Cobranza__MaxCorreosPorEjecucion = 10` y `Cobranza__PausaEntreCorreosMs = 15000` (DEMO). Se fijan en `infra/main.bicep`/`main.bicepparam` y en `scripts/s10_configurar_jobs.sh` (M-06), sin otros valores en otros archivos.
- Efecto frente a H1 (5 por minuto y 10 por hora con dominio administrado): 15000 ms da como máximo 4 envíos por ventana de 60 s, con margen frente al límite por minuto. Por hora no hay margen: 10 por ejecución horaria iguala el límite y, si ACS mide la hora como ventana deslizante, el comienzo de una ejecución puede coincidir con el final de la anterior dentro de la misma ventana y recibir 429. Cómo mide ACS la ventana: PENDIENTE verificar.
- Capacidad diaria: 10 × 6 ejecuciones (12 a 17 UTC) = 60 correos por día hábil, frente al promedio simulado de 111 (H1). Con el volumen de producción la cola crecería; con los datos DEMO de `sql/08` se usa solo para demostrar el flujo. Producción sigue condicionada a dominio propio verificado y solicitud de aumento (H1, pendiente 4 de CLAUDE.md).
- Regla del 429 (U5): una respuesta HTTP 429, o un rechazo de ACS que indique límite de envío, no cuenta como intento fallido.
  - La Function registra el aviso con `EstadoEnvio = 'Limitado'` (RF-05: el evento queda en la bitácora) y detiene el lote de esa ejecución.
  - `sp_RegistrarNotificacion` acepta `Limitado` y no incrementa `Intentos` (en el INSERT, `Intentos = 0`). `sp_GenerarAlertasVencimiento` no cambia: excluye solo `Aceptado` o `Intentos >= 3`, así que el aviso queda elegible en la siguiente ejecución.
  - Qué códigos de error de ACS, además del 429, indican límite: PENDIENTE de verificación por el `desarrollador` en la documentación del SDK; no se suponen.
  - Los demás errores siguen contando como `Fallido` (máximo 3 intentos).
  - `sql/06` (`AvisosFallidos30d`) y `sql/11` (reintento manual de `Fallido`) no cuentan `Limitado`. Si el panel debe mostrar los avisos limitados: PENDIENTE decidir.

Textos de Finanzas DEMO (U4, M-04):
- `devops` fija en `infra/main.bicepparam` valores inventados para `canalesPagoTexto`, `telefonoContacto` y `correoContacto`, rotulados DEMO en el valor o en un comentario junto al valor (igual que los días DEMO). `correoContacto` debe pasar la validación `[EmailAddress]`; se recomienda un dominio reservado para documentación (`example.com`, RFC 2606) para no apuntar a una persona real.
- Así la Function App arranca (`ValidateOnStart`) y los jobs pueden probarse en la semana 11. Los valores reales siguen PENDIENTES de Finanzas (pendiente 3 de CLAUDE.md).
- Antes de ejecutar el job contra ACS, `qa` confirma que los correos de los clientes DEMO de `sql/08` son direcciones controladas por el equipo, para no enviar correos a terceros (PENDIENTE revisar `sql/08`).

---

## 6. Pruebas y scripts de verificación afectados

Búsqueda realizada en `scripts/`, `docs/`, `pruebas/` y `sql/` el 05-11-2026.

| Elemento | Dependencia de Easy Auth | Cambio |
| --- | --- | --- |
| `scripts/s12_verificar_seguridad.sh`, SEG-05 "API: autenticacion Entra ID activa" (línea 30, espera `true` en `az webapp auth show ... platform.enabled`) | Directa | Renombrar a "API: Easy Auth deshabilitado (autenticación propia)" con esperado `false` (si Easy Auth quedara activo interceptaría las solicitudes). Controles nuevos en la tabla 6.2 |
| `scripts/s12_pruebas_red.sh`, RED-02 (línea 17, espera 401/302/403) | Indirecta (302 era la redirección de Easy Auth) | Esperado solo 401. Pruebas nuevas RED-11 a RED-17 (tabla 6.3) |
| `scripts/s12_endurecer.sh`, línea 55 | Texto | Ver 5.10 |
| `pruebas/carga_api_k6.js` (P de carga de S14) | Directa (cookie `AppServiceAuthSession` o token Bearer de Entra ID) | Usar `X-Api-Key` con una clave de rol Ventas creada para la prueba y revocada al terminar (`carga-demo` o `ventas-demo`: PENDIENTE del equipo) |
| `scripts/s11_configurar_api.sh` | Directa (ajuste del secreto) | Ver 5.10 |
| `scripts/s14_simulacro_pitr.sh` | Ninguna | Paso nuevo de revisión posterior a restauración (4.2) o llamada al script aparte |
| `.claude/agents/qa.md`, punto 6 "Easy Auth activo" | Directa | Cambiar por "autenticación propia activa: login, bloqueo, cookie y claves de API" y agregar las revisiones de la política D.7 (archivo de configuración: requiere aprobación humana) |
| `scripts/verificar_despliegue.sh` (P01-P32) y casos P33-P37 | Desconocida | El script y la definición de P33-P37 no están en el repositorio. Qué pruebas dependen de Easy Auth: PENDIENTE hasta que se copie el script (CLAUDE.md sección 7) |
| `sql/07_pruebas_desbloqueo.sql` (10/10) | Ninguna con la autenticación | Condicionado: `sql/07` puede dar 10/10 solo después de la corrección C-01 de `sql/01` que hace el `dba`; con el `sql/01` actual no puede dar 10/10 (informe de `qa`, C-01). El cambio de `cob.UsuarioInterno` no lo afecta, porque `sql/07` no usa esa tabla. El 10/10 se confirma solo al ejecutarlo (localmente o en Azure con aprobación humana); hasta entonces es NO VERIFICADO |
| `docs/consultas_kql_s10.kql`, `docs/consultas_kql_s14.kql` | Ninguna encontrada | Opcional: consulta de 401/429 en `/api/v1/auth/login` |

### 6.1 Casos de prueba de autenticación (AUT)

| Id | Caso | Esperado |
| --- | --- | --- |
| AUT-01 | Login correcto de usuario Finanzas | 200, cookie, `LoginExitoso` |
| AUT-02 | Contraseña incorrecta | 401 genérico, `LoginFallido`/`ClaveIncorrecta` |
| AUT-03 | Usuario inexistente | 401 genérico con tiempo similar a AUT-02, `UsuarioInexistente` |
| AUT-04 | 5 fallos seguidos (DEMO) | `CuentaBloqueada`; el sexto intento con la contraseña correcta da 401 |
| AUT-05 | Login tras vencer el bloqueo | 200 y contador en 0 |
| AUT-06 | Primer acceso con `DebeCambiarClave` | Solo `/yo`, `/auth/cambiar-clave` y `/auth/logout`; el resto 403 |
| AUT-07 | Cambio de contraseña | 204; una cookie anterior copiada deja de servir en a lo más 5 min (DEMO) |
| AUT-08 | Desactivación de usuario con sesión abierta | Sesión rechazada en a lo más 5 min |
| AUT-09 | Rol Ventas consulta `/cartera/indicadores` | 403 |
| AUT-10 | Clave de API válida rol Ventas en `/clientes/{rut}/estado` con RUT DEMO | 200 |
| AUT-11 | Clave de API en `/cartera/indicadores` | 403 |
| AUT-12 | Clave revocada o vencida | 401 (revocada: en a lo más 60 s DEMO) |
| AUT-13 | POST sin token CSRF | 400 |
| AUT-14 | Logout | 204, cookie eliminada, `Logout` |
| AUT-15 | Reinicio de la Web App con sesión abierta | La sesión sigue válida (claves de Data Protection persistidas) |
| AUT-16 (nuevo) | Contraseña temporal vencida (más de 24 h DEMO) | 401 genérico, motivo `ClaveTemporalVencida`, contador sin cambio |
| AUT-17 (nuevo) | Clave revocada antes de un simulacro de restauración | Tras la revisión posterior a la restauración, la clave sigue revocada en la base restaurada |
| AUT-18 (nuevo) | Login con una contraseña escrita en el campo de usuario | `UsuarioIngresado = (formato no valido)` |

### 6.2 Controles nuevos en `s12_verificar_seguridad.sh`

| Id propuesto | Control | Esperado |
| --- | --- | --- |
| SEG-05 | Easy Auth deshabilitado | `false` |
| SEG-DP-01 | API con `Storage Blob Data Contributor` en el contenedor `dataprotection-keys` | Existe, alcance contenedor |
| SEG-DP-02 | API con `Key Vault Crypto User` en la clave `dataprotection-cobranza-api` | Existe, alcance clave |
| SEG-DP-03 | Identidad de la Function App no puede leer ni escribir blobs en `dataprotection-keys` | 403 (prueba negativa de la condición ABAC) |
| SEG-KV-01 | La API no tiene ningún rol de secretos en Key Vault | Sin asignaciones |
| SEG-KV-02 | La Function App tiene `Key Vault Secrets User` solo en `acs-connection-string` | Alcance secreto, no vault |
| SEG-KV-03 | Ningún usuario humano con `Key Vault Secrets User` sobre el vault completo | Sin asignaciones |
| SEG-KV-04 | Ningún secreto `apikey-*` sin expiración ni habilitado con la expiración vencida | Ninguno |
| SEG-KV-05 | Diagnóstico de auditoría de Key Vault activo | Existe |
| SEG-KV-06 | Key Vault sin `ipRules` y sin regla `operador-temporal` en SQL al cerrar la ventana | Ninguna |
| SEG-TR-01 | Mientras rija 5.11: Web App con `ipSecurityRestrictionsDefaultAction = Deny` | `Deny` |
| SEG-FH-01 | Ajuste `ASPNETCORE_FORWARDEDHEADERS_ENABLED = false` en la Web App | `false` |

### 6.3 Pruebas nuevas en `s12_pruebas_red.sh`

| Id | Prueba | Esperado |
| --- | --- | --- |
| RED-02 | Endpoint protegido sin credenciales | 401 (solo) |
| RED-11 | Login con credenciales inválidas | 401 |
| RED-12 | `Set-Cookie` del login | `Secure`, `HttpOnly`, `SameSite=Strict`, prefijo `__Host-` |
| RED-13 | `X-Api-Key` inválida | 401 |
| RED-14 | POST de login sin token CSRF | 400 |
| RED-15 | Más de 10 intentos de login por minuto (DEMO) | 429 |
| RED-16 | `X-Forwarded-For` escrito por el cliente | No cambia `IpOrigen` ni evade el limitador (5.4.1) |
| RED-17 | Mientras rija 5.11: acceso a la Web App desde una IP distinta de `ipOperador` | 403 |

---

## 7. Plan de ejecución por agente

### 7.1 Orden
1. `dba`: C-01 (prerrequisito), 5.1, 5.2, `sql/04` (`Limitado`), `sql/13`, `sql/00`, `sql/02`. Validación local o revisión sin ejecutar contra Azure.
2. `desarrollador`: build en verde (NU1902/NU1903), retiro de `EasyAuthHandler` (5.11), luego 5.3 a 5.9 en `src/`, `tests/` y `pruebas/`, y el cambio de 429 en la Function (5.12); `dotnet build` y `dotnet test` con evidencia.
3. `devops`: cambios de `infra/main.bicep` y `main.bicepparam` (puede empezar en paralelo con 1 y 2); scripts nuevos después de que `dba` fije los nombres de procedimientos y `desarrollador` fije la interfaz de `Cobranza.Herramientas`; `bicep build`, `lint`, `what-if` en `brazilsouth`.
4. `seguridad`: scripts `s12_*` y plantillas de `docs/seguridad/`, después de `devops` (verifica nombres de recursos y asignaciones).
5. `qa`: revisión independiente de todo lo anterior contra este ADR, la política de credenciales y CLAUDE.md.
6. Humano aprueba antes de cualquier despliegue, publicación o ejecución SQL contra la base real. Ningún agente ejecuta los scripts de 5.9 (SEG-H01).

### 7.2 Qué revisa qa
- Que `sql/12` no otorgue a `UsuarioApi` permisos sobre tablas, sobre `cob.LogAcceso`, sobre la vista de evidencias ni sobre los procedimientos administrativos.
- Que `sql/07` dé 10/10 después de C-01 (al ejecutarse) y que `sql/13` no deje datos.
- Que ningún archivo del repositorio contenga contraseñas, hashes de usuarios reales ni claves de API; que las evidencias no contengan IP completas ni Object IDs completos.
- Que la API nunca envíe contraseñas o claves en texto plano a SQL ni las escriba en logs o Application Insights.
- Que los mensajes de login fallido sean idénticos para todas las causas.
- Atributos de cookie, CSRF en todos los POST, orden de middlewares (encabezados reenviados primero; archivos estáticos antes de autenticación) y una sola instancia del middleware de encabezados reenviados.
- Que las políticas conserven exactamente los permisos de la tabla de 5.6.
- Que `infra/main.bicep` no contenga `raKvApi`, que `raKvFunc` tenga alcance de secreto y que exista la condición ABAC.
- Que `EasyAuthHandler.cs` no exista en el código publicado y que la restricción de transición esté en la plantilla.
- Que `hash-clave` no escriba la contraseña en stdout y que `nueva-clave-api` no escriba la clave en stdout.
- Que ningún agente haya ejecutado los scripts de 5.9 (SEG-H01).
- Casos AUT-01 a AUT-18, controles SEG de 6.2 y pruebas RED de 6.3.
- Que los textos de Finanzas y los valores de D12 estén rotulados DEMO y que los correos DEMO de `sql/08` sean direcciones controladas.

---

## 8. Ediciones propuestas a CLAUDE.md y docs/ (no aplicadas)

Estas ediciones las aplica el orquestador o el `arquitecto` solo cuando un humano las apruebe. Las secciones 0, 3, 7 y 10 de CLAUDE.md están fuera de lo que el `arquitecto` puede editar; se proponen para que las aplique quien corresponda.

### 8.1 CLAUDE.md sección 3, viñeta "Identidad" (reemplazo)

> - Identidad: identidades administradas con RBAC mínimo hacia SQL, Key Vault y Storage (API sin acceso a secretos; Function App solo al secreto `acs-connection-string`); Azure SQL solo Entra ID (grupo `grp-cobranza-sql-admin`). Usuarios del panel y consumidores de la API con autenticación propia de la aplicación (ADR-001, D13): usuario y contraseña con cookie de ASP.NET Core (PBKDF2 de `PasswordHasher`, bloqueo por intentos, roles `Finanzas`, `Ventas`, `Admin` desde `cob.UsuarioInterno`) y clave de API por consumidor en el encabezado `X-Api-Key` (hash SHA-256 en `cob.ClaveApi`, valor en Key Vault; consumidor DEMO `ventas-demo`). Easy Auth v2 y los roles de aplicación de Entra ID no se usan (requieren consentimiento de administrador en el tenant Duoc). Sin MFA.

En la misma sección, agregar a Storage y Key Vault: "contenedor `dataprotection-keys` (con condición ABAC que excluye a la Function App) y clave `dataprotection-cobranza-api` para Data Protection de la API (ADR-001)".

Región (M-09 de `qa`, fuera de este ADR): reemplazar Chile Central por `brazilsouth` con la nota de la política "Ubicaciones permitidas" de Duoc; se recomienda un ADR propio de región (ADR-002) antes de editar.

### 8.2 CLAUDE.md sección 5

Nueva fila D13:

> | D13 | Autenticación propia en la API: cookie con usuario y contraseña para el panel y clave de API para Ventas sistema a sistema (consumidor DEMO `ventas-demo`); sin Easy Auth ni roles de Entra ID; sin MFA. Ver `docs/adr/ADR-001-autenticacion-propia-sin-entra-usuarios.md` | Vigente (aceptada 05-11-2026); parámetros de bloqueo y sesión: valores DEMO aprobados por el equipo (05-11-2026); límite por IP, longitudes de contraseña y vigencia máxima de claves de API: PENDIENTE |

Fila D12 (reemplazo):

> | D12 | Job de notificaciones DEMO: máximo 10 por ejecución, pausa 15.000 ms (capacidad 60 por día hábil, sin margen frente al límite de 10 por hora del dominio administrado). Un 429 o rechazo por límite se registra como `Limitado`, detiene el lote y no cuenta como intento fallido. Producción: requiere dominio propio y aumento de límites (H1). Ver ADR-001 sección 5.12 | Vigente para DEMO (decisión del usuario 05-11-2026); valores de producción PENDIENTE |

Nuevas filas propuestas por `seguridad` (política de credenciales, D.2):

> | D14 | Entrega de credenciales temporales: presencial con uso inmediato y cambio obligatorio frente al operador; claves de API leídas de Key Vault por el consumidor DEMO `ventas-demo`; sin git, correo ni chat. Ningún agente ejecuta los scripts de alta o restablecimiento (SEG-H01). Ver `docs/seguridad/politica_credenciales_y_accesos.md` | Propuesta |
> | D15 | Retención de `cob.LogAcceso`: 90 días en línea; purga manual mensual por `grp-cobranza-sql-admin` con `cob.sp_PurgarLogAcceso` (mínimo 90 días) | Vigente para el entorno académico: definida por `seguridad` por delegación del usuario y aprobada por el equipo (05-11-2026); producción PENDIENTE |

Nota en la fila D3 o en el pendiente 3: "Textos de Finanzas DEMO (inventados y rotulados) fijados por `devops` para la demo; valores reales PENDIENTE Finanzas".

### 8.3 CLAUDE.md sección 8

- Punto 2, reemplazo: "Grupo administrador SQL `grp-cobranza-sql-admin`: creado. Su Object ID se entrega por la variable de entorno `SQL_ADMIN_GROUP_OBJECT_ID` (fuera de git)."
- Punto 3, agregar al final: "Para la demo se usan textos DEMO (ADR-001 sección 5.12)."
- Nuevo 9: "Consumidor de RF-06: simulado (`ventas-demo`) para el entorno académico; sistema real PENDIENTE solo para producción."
- Nuevo 10: "Valores DEMO de seguridad de la política A.11 aprobados por el equipo (05-11-2026). Pendiente: límite de login por IP (10/min), longitud mínima y máxima de contraseña (12/128), vigencia máxima de claves de API (180 días), superposición en rotación (1 h) y frecuencia de `UltimoUso` (60 min) (ADR-001 sección 5.4)."
- Nuevo 11: "Responsable humano de autorizar altas, bajas y restablecimientos: PENDIENTE. Canal: definido (D14). Qué integrantes son miembros de `grp-cobranza-sql-admin`: PENDIENTE."
- Nuevo 12: "Plazo de retención de `cob.LogAcceso` para producción según Ley 19.628 y Ley 21.719, y plazo de conservación de evidencias tras la evaluación (D15)."

### 8.4 CLAUDE.md sección 9, nuevas viñetas

- "Informe S1-S6 (docs/02, sección 5) y evidencias S10-S15 (docs/05) indican autenticación con Entra ID y Easy Auth v2; vigente: autenticación propia (D13, ADR-001)."
- "docs/04 lista Entra ID P1 como no incluido 'requerido para acceso condicional'; con D13 el acceso condicional no aplica al panel."
- "`EasyAuthHandler.cs` cita `s12_registro_entra_id.sh`; el script se llama `s11_registro_entra_id.sh` (archivo obsoleto por D13)."
- "Archivos de agentes (`.claude/agents/arquitecto.md`, `seguridad.md`, `desarrollador.md`, `qa.md`) y CLAUDE.md sección 10 mencionan Easy Auth v2 y Chile Central; vigente: D13 y `brazilsouth`."
- "`OpcionesCobranza.cs`, `local.settings.example.json` y `s10_configurar_jobs.sh` usan 100/h, 30/min y 90/2100; vigente: H1 (5/10) y D12 DEMO (10/15000)."
- "`main.bicep` usa 8 caracteres de `uniqueString` en el nombre de Storage; CLAUDE.md sección 3 dice 6 (B-05)."

### 8.5 CLAUDE.md secciones 0, 7 y 10 (fuera del alcance de edición del arquitecto)

- Sección 0, nueva regla (política D.2, punto 3): "Ningún agente ejecuta scripts que muestren o generen contraseñas o claves (`s11_alta_*`, `s11_restablecer_clave.sh`, `s11_baja_usuario.sh`, `s11_revocar_clave_api.sh`, comandos de `Cobranza.Herramientas`); los ejecuta un integrante humano en su propia terminal."
- Sección 7, estructura del repositorio: agregar `docs/seguridad/politica_credenciales_y_accesos.md`, `docs/adr/`, `src/Cobranza.Functions` (nombre ya confirmado en el repositorio), `src/Cobranza.Herramientas`, `sql/12`, `sql/13`, `pruebas/consumidor_ventas_demo.sh` y los scripts nuevos de 5.10. Sección 7, estado: "Recursos desplegados en Azure: grupo de recursos `rg-cobranza-apt` (vacío) y grupo Entra `grp-cobranza-sql-admin`" (M-09).
- Sección 10, fila `seguridad`: reemplazar "Easy Auth" por "autenticación propia de la API (cookie, claves de API) y política de credenciales".

### 8.6 docs/

- `docs/00_INDICE.md`, nuevas filas: "| adr/ADR-001-autenticacion-propia-sin-entra-usuarios.md | Autenticación propia de la API, reemplaza Easy Auth | 05-11-2026 |" y "| seguridad/politica_credenciales_y_accesos.md | Entrega, retención y rotación de credenciales (ADR-001) | 05-11-2026 |".
- `docs/05_Evidencias_S10-S15_Resumen.md`, línea 41: agregar a continuación "(Reemplazado el 05-11-2026 por autenticación propia; ver docs/adr/ADR-001.)". No se reescribe el texto original.
- `docs/02_...S1-S6.md`: sin cambios (documento histórico); la diferencia queda en la sección 9 de CLAUDE.md.

---

## 9. Fuentes consultadas

| N.º | Fuente | Uso | Fecha de consulta |
| --- | --- | --- | --- |
| 9.1 | Data Protection key management and lifetime in ASP.NET Core: https://learn.microsoft.com/en-us/aspnet/core/security/data-protection/configuration/default-settings | Comportamiento en App Service (`%HOME%\ASP.NET\DataProtection-Keys`, "Keys aren't protected at rest") | 05-11-2026 |
| 9.2 | Configure ASP.NET Core Data Protection: https://learn.microsoft.com/en-us/aspnet/core/security/data-protection/configuration/overview?view=aspnetcore-10.0 | `PersistKeysToAzureBlobStorage`, `ProtectKeysWithAzureKeyVault`, paquetes, rol Key Vault Crypto User (Get, Wrap Key, Unwrap Key), `SetApplicationName` | 05-11-2026 |
| 9.3 | PasswordHasherOptions.IterationCount: https://learn.microsoft.com/en-us/dotnet/api/microsoft.aspnetcore.identity.passwordhasheroptions.iterationcount | PBKDF2, 100.000 iteraciones por defecto en V3 | 05-11-2026 |
| 9.4 | Configure ASP.NET Core to work with proxy servers and load balancers: https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer?view=aspnetcore-10.0 | Procesamiento de derecha a izquierda, `ForwardLimit` por defecto 1, solo loopback por defecto, `ASPNETCORE_FORWARDEDHEADERS_ENABLED` sin restricción de `KnownProxies`, sin configuración automática en Linux | 05-11-2026 (revisión 1) |
| 9.5 | Configure connections to remote services in Azure Functions (pestaña Host required y Bindings): https://learn.microsoft.com/en-us/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host | `Storage Blob Data Owner` como mínimo para `AzureWebJobsStorage`; `Storage Table Data Contributor` para eventos de diagnóstico; temporizador usa bloqueos de blob | 05-11-2026 (revisión 1) |
| 9.6 | Authorize access to Azure Blob Storage using Azure role assignment conditions: https://learn.microsoft.com/en-us/azure/storage/blobs/storage-auth-abac | Condiciones GA sobre `Storage Blob Data Owner`; aplican a DataActions, no a Actions de administración | 05-11-2026 (revisión 1) |

No se consultó documentación oficial sobre la política de consentimiento de Duoc: el hecho fue verificado por el operador en el tenant y lo informó el orquestador. Los hechos sobre Key Vault (`exp` informativo) provienen de la política de `seguridad`, que cita "About Azure Key Vault secrets"; el arquitecto no los reverificó.
