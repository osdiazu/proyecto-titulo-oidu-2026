# Política de credenciales y accesos (autenticación propia, ADR-001)

| Campo | Valor |
| --- | --- |
| Estado | Propuesta del agente `seguridad`, 05-11-2026. Pendiente de revisión de `qa` y de aprobación humana |
| Redactó | Agente `seguridad` (Claude Code), 05-11-2026 |
| Aprueba | PENDIENTE (CLAUDE.md sección 10: responsable humano no definido) |
| Base | `docs/adr/ADR-001-autenticacion-propia-sin-entra-usuarios.md` (aceptada 05-11-2026); decisiones del usuario del 05-11-2026 (consumidor DEMO "ventas-demo", altas por el propio equipo, retención definida por seguridad) |
| Región | `brazilsouth` |
| Requerimientos | RF-05, RF-06, RF-07, RNF-02, RNF-05, RNF-06 |

Nota de alcance: este documento es diseño. Nada de lo descrito está implementado, ejecutado ni desplegado. Los scripts que se nombran no existen todavía en el repositorio (salvo los indicados como existentes). Los valores marcados DEMO son de demostración y no fueron definidos por el equipo ni por la embotelladora.

---

## 0. Hechos verificados en el repositorio (05-11-2026)

Lo siguiente se leyó en el repositorio; las recomendaciones se apoyan en estos hechos.

| Hecho | Fuente |
| --- | --- |
| Key Vault con RBAC, soft-delete de 90 días y protección de purga; acceso público `Disabled` salvo cuando `ipOperador` tiene valor (entonces `Enabled` con `defaultAction Deny` e `ipRules` con una sola IP) | `infra/main.bicep`, recurso `keyVault` |
| El operador recibe `Key Vault Secrets Officer` sobre todo el vault (`raKvOperador`); la API y la Function App reciben `Key Vault Secrets User` sobre todo el vault | `infra/main.bicep`, sección 9 |
| SQL: acceso público solo con `ipOperador` (regla `operador-temporal`); auditoría con `BATCH_COMPLETED_GROUP` hacia Log Analytics | `infra/main.bicep`, `sqlServer`, `sqlAuditoria` |
| Log Analytics con `retentionInDays: 30` | `infra/main.bicep`, `logAnalytics` |
| PITR 35 días; LTR `P8W` / `P12M`; los LTR sobreviven a la eliminación del grupo de recursos | `infra/main.bicep`, `sqlPitr`, `sqlLtr`; `scripts/eliminar_entorno.sh` |
| El diagnóstico de auditoría de Key Vault (`categoryGroup: audit`) solo existe en el módulo `infra/modulos/seguridad_perimetral.bicep`, no en `main.bicep` | `grep diagnosticSettings` |
| `s12_endurecer.sh` deshabilita el acceso público de SQL, pero no modifica Key Vault ni elimina la regla `operador-temporal` | `scripts/s12_endurecer.sh` |
| `s14_simulacro_pitr.sh` restaura como base nueva en el mismo servidor; la base original sigue existiendo | `scripts/s14_simulacro_pitr.sh` |
| RUT DEMO disponibles: 76555555-8, 76666666-3, 77777777-7, 78888888-0, 76123456-0 | `sql/08_datos_prueba.sql` |
| `.gitignore` excluye `*.env`, `infra/entorno.local.env`, `local.settings.json` e `infra/*.parameters.json` | `.gitignore` |
| Búsqueda de cadenas sospechosas (`AccountKey=`, `SharedAccessSignature`, `accesskey=`, `cobk_<prefijo>_`, `-----BEGIN`, `password = '...'`, `client_secret =`): sin coincidencias | `grep -rn -I -E ...` sobre el repositorio, excluidos `.git`, `bin`, `obj` |

---

## A. Canal de entrega de credenciales temporales

### A.1 Qué se entrega y a quién

| Credencial | Destinatario | Se guarda en | Requiere entrega |
| --- | --- | --- | --- |
| Contraseña temporal de usuario del panel (alta o restablecimiento) | Integrante del equipo que actúa como usuario DEMO de Finanzas, Ventas o Admin | En ninguna parte (en SQL solo el hash PBKDF2, ADR 4.3) | Sí |
| Clave de API del consumidor `ventas-demo` | Script o cliente de prueba que simula el sistema de Ventas (RF-06), ejecutado por un integrante | Key Vault, secreto `apikey-ventas-demo-<prefijo>` (ADR 5.9) | No se "entrega": el script la lee de Key Vault en tiempo de ejecución |

### A.2 Evaluación de opciones

| Opción | Descripción | Ventajas | Desventajas y riesgos | Resultado |
| --- | --- | --- | --- | --- |
| a. Secreto en Key Vault con expiración corta | El operador guarda la contraseña temporal como secreto; el destinatario la lee con `az keyvault secret show` y luego se elimina | Sin costo relevante; RBAC por secreto; auditable si el diagnóstico de Key Vault está activo | 1) Red: Key Vault solo acepta la IP de `ipOperador` (una sola IP). El destinatario debe estar en esa misma IP pública o habría que agregar otra regla de IP, lo que es relajar una regla y requiere aprobación y registro. 2) RBAC: el destinatario necesita `Key Vault Secrets User` con alcance en ese secreto y una cuenta del tenant Duoc; la asignación la crea el Owner y puede tardar minutos en propagarse. 3) Según la documentación de Key Vault ("About Azure Key Vault secrets"), el atributo `exp` de un secreto es informativo y no impide la operación get; hay que deshabilitarlo o eliminarlo. Verificar en el despliegue. 4) Con protección de purga, el secreto eliminado queda en soft-delete 90 días y no se puede purgar: quien tenga `Secrets Officer` lo puede recuperar. 5) El valor queda en la salida de la terminal del destinatario. 6) La lectura solo queda auditada si se despliega el diagnóstico de Key Vault (hoy solo en `seguridad_perimetral.bicep`) | Descartada para contraseñas. Es el canal adecuado para la clave de API (A.5) |
| b. Mostrar una sola vez en la terminal del operador y entregar en persona | La herramienta genera la contraseña, la muestra una vez y el destinatario, presente, la usa de inmediato | Sin costo; no cambia la red ni el RBAC; no pasa por git, correo ni chat; el destinatario cambia la contraseña frente al operador, así que la vigencia real es de minutos | Requiere presencia física; el operador conoce la contraseña temporal (se mitiga con el cambio obligatorio inmediato); riesgo de que quede en el historial de la terminal (se mitiga en A.4) | Recomendada |
| c. Correo por ACS | Envío desde `DoNotReply@<dominio administrado>` | Automatizable | Contraseña en texto plano en buzones y servidores intermedios; límite H1 (5 por minuto y 10 por hora con dominio administrado); el dominio administrado no es de la embotelladora | Descartada |
| d1. El destinatario escribe su propia contraseña inicial en la terminal del operador (lectura sin eco, comando `hash-clave` del ADR 5.9) | Nadie más conoce la contraseña | El operador no ve la contraseña | El texto del lote de `sqlcmd` (que incluye el hash) queda en la auditoría SQL (`BATCH_COMPLETED_GROUP`, ADR 4.3). Una contraseña elegida por una persona tiene menos entropía que una aleatoria, así que el hash es más fácil de atacar fuera de línea si se filtra Log Analytics | Descartada como opción principal. Se acepta solo como variante si el equipo la aprueba |
| d2. Videollamada o pantalla compartida | Se muestra la contraseña por video | Sin presencia física | Equivale a chat: la plataforma puede grabar o transcribir y queda fuera del control del equipo | Descartada |
| d3. Papel o fotografía | Se anota o se fotografía la contraseña | — | Queda una copia persistente fuera de control | Prohibida |

### A.3 Recomendación

- Contraseñas temporales del panel: opción b, entrega presencial con uso inmediato.
  - El destinatario está presente cuando se ejecuta el alta.
  - Lee la contraseña en la pantalla del operador e inicia sesión de inmediato en su propio equipo.
  - Cambia la contraseña en ese momento (`DebeCambiarClave = 1`).
  - El alta se da por cerrada cuando `cob.LogAcceso` muestra el evento `CambioClave` de ese usuario.
- Si no es posible la presencia física, no se entrega la contraseña y el alta se posterga. Usar la opción a con una segunda IP solo se admite con aprobación humana explícita y registro en `evidencias/seguridad/`, porque relaja la regla de red de Key Vault.
- Clave de API de `ventas-demo`: no hay entrega. El script consumidor DEMO la lee de Key Vault en el momento de la llamada (A.5). Esto aprovecha el diseño del ADR (el valor ya vive en Key Vault) y evita mover la clave.

Justificación: no tiene costo, no requiere nada de TI de Duoc, no cambia la red ni el RBAC, y la contraseña nunca pasa por git, correo ni chat. Además, la contraseña temporal deja de servir en minutos porque se cambia en el primer acceso, frente al operador.

### A.4 Reglas obligatorias del canal

1. Los scripts de alta, restablecimiento y emisión de claves (`s11_alta_usuario.sh`, `s11_restablecer_clave.sh`, `s11_alta_clave_api.sh`) los ejecuta un integrante humano en su propia terminal. Ningún agente de Claude Code los ejecuta, porque la salida de la terminal del agente queda en la conversación y eso equivale a pasar el secreto por chat (hallazgo SEG-H01).
2. La herramienta (`src/Cobranza.Herramientas`, comando `hash-clave`) escribe la contraseña temporal directamente en la terminal (`/dev/tty` o la consola en Windows), no en la salida estándar. La salida estándar solo lleva el hash, que el script captura en una variable.
3. Tras mostrar la contraseña, el script espera Enter y limpia la pantalla y el historial visible de la terminal (`clear` y la secuencia `\033[3J`). Los scripts no usan `set -x`, `tee` ni redirecciones a archivo de la salida que contiene la contraseña.
4. Contraseña temporal generada al azar con `RandomNumberGenerator`, de 20 caracteres (DEMO), sin caracteres ambiguos (`0`, `O`, `1`, `l`, `I`). Es más larga que el mínimo `Seguridad__LongitudMinimaClave = 12` (DEMO) porque su hash queda en la auditoría SQL (ADR 4.3).
5. No se escribe la contraseña en papel, notas, gestores compartidos, capturas de pantalla, correo ni chat.
6. Videollamadas, pantalla compartida y fotografías no son canales válidos.

### A.5 Clave de API del consumidor DEMO `ventas-demo`

- El consumidor es simulado (decisión del usuario del 05-11-2026). No existe un sistema real de Ventas.
- Los datos consultados son los RUT DEMO de `sql/08_datos_prueba.sql` y la fuente simulada `origen_sim`.
- El script consumidor DEMO (nombre propuesto: `pruebas/consumidor_ventas_demo.sh`) hace lo siguiente:
  1. Lee la clave con `az keyvault secret show --vault-name "$KV_NAME" -n "$NOMBRE_SECRETO" --query value -o tsv` y la guarda en una variable, sin imprimirla.
  2. Envía el encabezado `X-Api-Key` por la entrada estándar de curl (`printf 'X-Api-Key: %s\n' "$CLAVE" | curl -H @- ...`), para que la clave no aparezca en la lista de procesos.
  3. Ejecuta los casos AUT-10 (200 en `/api/v1/clientes/{rut}/estado` con un RUT DEMO) y AUT-11 (403 en `/api/v1/cartera/indicadores`). También prueba una clave con formato inválido, que debe dar 401.
  4. Al terminar ejecuta `unset CLAVE`. La evidencia registra el prefijo, el código HTTP y la hora, nunca la clave.
- Quién la lee:
  - Por defecto, el mismo operador desde su equipo. Ya tiene `Key Vault Secrets Officer` y su IP es `ipOperador`.
  - Otro integrante solo si está en la misma IP pública y se le asigna `Key Vault Secrets User` con alcance en ese secreto.
  - Desde otra IP: PENDIENTE (requiere aprobación, porque implica abrir otra IP).
- Prueba de carga (`pruebas/carga_api_k6.js`): se recomienda una clave distinta (por ejemplo, consumidor `carga-demo`, DEMO) con vigencia de 1 día, revocada al terminar, como indica el ADR en la sección 6. Si se usa la de `ventas-demo` o una dedicada: PENDIENTE de decisión del equipo. La clave se pasa a k6 como variable de entorno exportada en la sesión, no con `-e`, para que no quede en la línea de comandos.

### A.6 Cambio obligatorio en el primer acceso (`DebeCambiarClave`)

- `sp_CrearUsuarioInterno` y `sp_RestablecerClaveUsuario` dejan `DebeCambiarClave = 1` (ADR 5.2).
- Con `debe_cambiar_clave = 1`, la sesión solo puede usar `/api/v1/yo`, `/api/v1/auth/cambiar-clave` y `/api/v1/auth/logout`; el resto responde 403 (ADR 5.6, AUT-06).
- La contraseña nueva debe ser distinta de la temporal y del nombre de usuario, y su longitud debe estar entre 12 y 128 caracteres (DEMO, ADR 5.4).
- Al cambiarla, `sp_CambiarClave` deja `DebeCambiarClave = 0`, actualiza `FechaCambioClave` y genera un `SelloSeguridad` nuevo. El evento `CambioClave` es la prueba de que la entrega se completó.

### A.7 Vigencia de la contraseña temporal

- Vigencia DEMO: 24 horas desde el alta o el restablecimiento. Ajuste propuesto: `Seguridad__HorasVigenciaClaveTemporal = 24`.
- Con entrega presencial y uso inmediato, la vigencia real es de minutos. Las 24 horas son el máximo para el caso en que el primer acceso falle o se posponga.
- Implementación propuesta (no existe en el ADR; ver la sección D):
  - `sp_CrearUsuarioInterno` también fija `FechaCambioClave = SYSUTCDATETIME()`.
  - `sp_ObtenerUsuarioParaLogin` devuelve `FechaCambioClave`.
  - Si `DebeCambiarClave = 1` y `FechaCambioClave` es anterior al límite de vigencia, la API rechaza el login con el mismo 401 genérico y registra `LoginFallido` con un motivo nuevo, `ClaveTemporalVencida`.
- Una contraseña temporal vencida solo se recupera con un restablecimiento nuevo (A.10.3).

### A.8 Qué queda registrado

| Registro | Contenido | Nunca contiene |
| --- | --- | --- |
| `cob.LogAcceso` | `AltaUsuario`, `RestablecimientoClave`, `CambioClave`, `LoginExitoso` y `LoginFallido` (con motivo), `CambioEstadoUsuario`, `CambioRolUsuario`, `AltaClaveApi`, `RevocacionClaveApi`, con `Actor = ORIGINAL_LOGIN()`, fecha UTC, IP y agente de usuario | Contraseñas, hashes, claves de API |
| Auditoría de Azure SQL (Log Analytics, 30 días) | Texto de los lotes `sqlcmd` del grupo administrador | Contraseñas en texto plano. Sí contiene el hash de la contraseña temporal y el hash SHA-256 de la clave de API (ADR 4.3); por eso la contraseña temporal es aleatoria y larga |
| Auditoría de Key Vault (`AuditEvent`, solo si se despliega `seguridad_perimetral.bicep` o se agrega a `main.bicep`) | Quién leyó o modificó `apikey-*` y cuándo | Valores de secretos |
| `evidencias/seguridad/<fecha>_entrega_credenciales.md` (versionado en git) | Usuario, rol, tipo de operación (alta, restablecimiento o baja), fecha y hora UTC, operador, canal "presencial", confirmación del destinatario (nombre e iniciales) y hora del evento `CambioClave` | Contraseña, hash, IP pública del operador (se usa `<IP_OPERADOR>`, igual que en `evidencias/2026-11-05_whatif_brazilsouth/`) |
| `evidencias/seguridad/<fecha>_claves_api.md` | Consumidor, prefijo, nombre del secreto, fecha de vencimiento, operador y, si existe, el Object ID del lector truncado (`xxxx…xxxx`) | Clave completa o hash |

### A.9 Revocación

| Qué | Cómo | Efecto |
| --- | --- | --- |
| Contraseña temporal no usada o posiblemente expuesta | Se emite otra con `sp_RestablecerClaveUsuario`; si no se va a entregar, se desactiva el usuario con `sp_CambiarEstadoUsuario @Activo = 0` | El sello nuevo invalida sesiones en 5 minutos como máximo (DEMO, `Seguridad__MinutosRevalidacionSesion`) |
| Usuario | `sp_CambiarEstadoUsuario @Activo = 0` (no se borra la fila para conservar la trazabilidad en `cob.LogAcceso`) | Login rechazado (`UsuarioInactivo`); sesiones invalidadas en 5 minutos como máximo |
| Clave de API | `sp_RevocarClaveApi @Prefijo`, después `az keyvault secret set-attributes --enabled false`, eliminación del secreto y eliminación de la asignación `Key Vault Secrets User` del lector, si existe | Rechazo en 60 segundos como máximo (caché DEMO). El secreto eliminado queda 90 días en soft-delete y no se puede purgar |

### A.10 Flujos paso a paso

Condiciones previas comunes:
- Lo ejecuta un integrante humano, miembro de `grp-cobranza-sql-admin` (PENDIENTE confirmar qué integrantes son miembros), en su propia terminal y fuera de Claude Code.
- Tiene acceso de red a SQL y a Key Vault con `IP_OPERADOR`. Abrir ese acceso es un despliegue de `main.bicep` que requiere confirmación humana (CLAUDE.md, reglas 5 y 7).
- Orden recomendado dentro de una ventana de trabajo: despliegue con `IP_OPERADOR`, luego `desplegar_sql.sh`, luego las altas de esta sección, luego el despliegue con `IP_OPERADOR` vacío y por último `s12_endurecer.sh`. Hay que considerar que `s12_endurecer.sh` deshabilita el acceso público de SQL: después de endurecer, las altas requieren volver a abrir el acceso.
- Al cerrar la sesión: `ipOperador` vacío, sin la regla `operador-temporal` y Key Vault con `publicNetworkAccess Disabled`. Se verifica con `s12_verificar_seguridad.sh`.

#### A.10.1 Alta de usuario del panel

1. Se registra la solicitud: quién, qué rol (`Finanzas`, `Ventas` o `Admin`) y quién la autoriza (responsable: PENDIENTE).
2. El destinatario está presente.
3. El operador ejecuta `scripts/s11_alta_usuario.sh --usuario <usuario> --nombre "<nombre>" --rol <Rol>`.
4. El script valida el nombre de usuario (`[a-z0-9._-]`, entre 3 y 50 caracteres) y el rol.
5. La herramienta genera la contraseña temporal (A.4, regla 4) y la muestra en la terminal. El script captura solo el hash.
6. El script ejecuta `sqlcmd` con `EXEC cob.sp_CrearUsuarioInterno`. Queda el evento `AltaUsuario`.
7. El destinatario lee la contraseña en la pantalla. El operador presiona Enter y la pantalla se limpia.
8. El destinatario inicia sesión en su equipo y cambia la contraseña (evento `CambioClave`).
9. El operador ejecuta `scripts/s11_alta_usuario.sh --verificar <usuario>`, que confirma el `CambioClave` consultando `cob.LogAcceso` con una consulta de administrador.
10. El operador registra la evidencia (A.8).

#### A.10.2 Alta de la clave de API de `ventas-demo`

1. El operador ejecuta `scripts/s11_alta_clave_api.sh --consumidor ventas-demo --dias 30 [--lector-object-id <OID>]`.
2. El comando `nueva-clave-api` escribe la clave en un archivo temporal dentro del perfil del usuario (`mktemp` en `$TMPDIR` o `%TEMP%`). En Git Bash para Windows, `chmod 600` no se aplica sobre NTFS; la protección real es la ACL del perfil del usuario.
3. El script guarda la clave en Key Vault con `az keyvault secret set --vault-name "$KV_NAME" -n apikey-ventas-demo-<prefijo> --file <tmp> --encoding utf-8 --expires <FechaVencimiento> --content-type api-key --tags consumidor=ventas-demo ambiente=DEMO prefijo=<prefijo>`.
4. El script borra el archivo temporal (con `trap` también en caso de error).
5. El script ejecuta `EXEC cob.sp_RegistrarClaveApi` con el prefijo, el hash, `Consumidor = 'ventas-demo'`, `Rol = 'Ventas'`, la fecha de vencimiento y el nombre del secreto. Queda el evento `AltaClaveApi`.
6. Si se indicó un lector, el script ejecuta `az role assignment create --role "Key Vault Secrets User" --assignee-object-id <OID> --assignee-principal-type User --scope <id del vault>/secrets/apikey-ventas-demo-<prefijo>`.
7. La salida muestra solo el prefijo, el nombre del secreto y el vencimiento.
8. Se ejecuta `pruebas/consumidor_ventas_demo.sh` (A.5) y se registra la evidencia.

#### A.10.3 Restablecimiento de contraseña

1. El usuario la solicita en persona. La identidad se verifica por presencia; no se aceptan solicitudes por correo ni chat.
2. El operador ejecuta `scripts/s11_restablecer_clave.sh --usuario <usuario>`. El procedimiento `sp_RestablecerClaveUsuario` genera un hash temporal nuevo, deja `DebeCambiarClave = 1`, desbloquea la cuenta y genera un sello nuevo. Queda el evento `RestablecimientoClave`.
3. Desde aquí se siguen los pasos 7 a 10 de A.10.1.
4. Desbloqueo sin cambio de contraseña (el usuario la recuerda): `sp_DesbloquearUsuario`, solo con verificación presencial.

#### A.10.4 Baja

- Usuario: `scripts/s11_baja_usuario.sh --usuario <usuario>` ejecuta `sp_CambiarEstadoUsuario @Activo = 0`. Queda el evento `CambioEstadoUsuario` y se registra la evidencia.
- Clave de API: `scripts/s11_revocar_clave_api.sh --prefijo <prefijo>` aplica A.9 y queda el evento `RevocacionClaveApi`. Luego el script verifica que la clave responde 401 pasados 60 segundos (AUT-12).
- Cierre del entorno: antes de `eliminar_entorno.sh`, se revocan todas las claves y se desactivan todos los usuarios. Así, si la base se restaura desde un LTR, las claves ya figuran revocadas en los respaldos semanales posteriores. Los respaldos anteriores siguen teniendo las claves activas; ese caso se cubre en C.3.

### A.11 Valores DEMO de esta política

| Valor | DEMO | Origen |
| --- | --- | --- |
| Consumidor `ventas-demo` | Sí | Decisión del usuario, 05-11-2026 |
| Consumidor `carga-demo` para k6 | Sí (propuesto) | Este documento |
| Longitud de la contraseña temporal: 20 | Sí | Este documento |
| Vigencia de la contraseña temporal: 24 h | Sí | Este documento |
| Vigencia de la clave `ventas-demo`: 30 días (el ADR deja 180 por defecto) | Sí | Este documento |
| Vigencia de la clave `carga-demo`: 1 día | Sí | Este documento |
| Aviso de rotación: 7 días antes del vencimiento | Sí | Este documento |
| Lote de purga: 5.000 filas | Sí | Este documento |
| Nombres de usuario de prueba (por ejemplo, con sufijo `.demo`) | Sí | Ejemplo; los define el equipo |
| Bloqueo 5/15, sesión 30 min / 8 h, revalidación 5 min, caché de clave 60 s | Sí | ADR 5.4 |
| RUT de prueba | Sí | `sql/08_datos_prueba.sql` |
| Retención de `cob.LogAcceso`: 90 días | No es DEMO: decisión de seguridad para el entorno académico. Para producción: PENDIENTE | Sección B |

---

## B. Retención de `cob.LogAcceso`

### B.1 Plazo elegido

90 días en línea dentro de la base. Las filas con `FechaUtc` anterior a 90 días se purgan.

### B.2 Justificación

| Criterio | Análisis |
| --- | --- |
| RNF-05 (auditoría de cambios con fecha, origen, valor anterior y nuevo) | No fija un plazo. 90 días cubren el ciclo completo de pruebas y evidencias del semestre (despliegue en la semana 11 y pruebas hasta la semana 15) |
| PITR 35 días | La revisión posterior a una restauración (C.3) necesita los eventos desde el punto de restauración hasta el momento de restaurar. El punto puede estar hasta 35 días atrás, así que la retención debe ser de al menos 35 días. Con 90 días queda margen |
| Log Analytics 30 días | La auditoría SQL y la de Key Vault solo cubren 30 días, menos que la ventana PITR. `cob.LogAcceso` es la única fuente que cubre los 35 días completos (hallazgo SEG-H02) |
| LTR P8W / P12M | La purga no borra los respaldos: una fila purgada sigue en los LTR hasta su vencimiento (8 semanas los semanales y 12 meses los mensuales). Se acepta y se declara. Eliminarlos al cerrar el proyecto es una decisión del equipo (`eliminar_entorno.sh` los lista) |
| Modelo de costos (desplegar, tomar evidencias, eliminar) | Con entornos de vida corta, la purga casi nunca se activa: el fin real de los datos es la eliminación del entorno. El volumen es mínimo (un usuario DEMO genera decenas de filas al día) y no afecta el almacenamiento de S0. Más de 90 días no aporta valor en un entorno que se elimina; menos de 35 días rompería C.3 |
| Minimización de datos personales | La IP y el agente de usuario se tratan como datos personales (B.4); un plazo acotado reduce la exposición |
| Producción | El plazo para la embotelladora debe validarse con su área legal frente a la Ley 19.628 y su modificación por la Ley 21.719 (aplicabilidad y plazos: PENDIENTE de validación por el equipo o el docente) |

### B.3 Purga

- Procedimiento nuevo propuesto: `cob.sp_PurgarLogAcceso @DiasRetencion INT = 90, @TamanoLote INT = 5000` (la cifra 5000 es DEMO), en `sql/12_autenticacion.sql`.
  - Si `@DiasRetencion < 90`, falla con `THROW` (mensaje en el rango 50060-50079). Así se evita borrar la bitácora por error o de forma intencional.
  - Borra en lotes `WHERE FechaUtc < DATEADD(DAY, -@DiasRetencion, SYSUTCDATETIME())` usando `IX_LogAcceso_Fecha`.
  - Inserta un evento nuevo `PurgaLogAcceso` con `Actor = ORIGINAL_LOGIN()` y devuelve el total de filas borradas.
  - Sin GRANT: no se otorga a `UsuarioApi` ni a `UsuarioFunctionApp`. Un job automático con permiso de borrado sobre la bitácora permitiría que una identidad comprometida borrara su propio rastro.
- Quién y cuándo: un miembro de `grp-cobranza-sql-admin`, con el script `scripts/s15_purgar_log_acceso.sh --dias 90`, el primer día hábil de cada mes, solo si el entorno tiene más de 90 días de vida. El script guarda la evidencia del total purgado. La ejecución también queda en la auditoría SQL.
- Lo que nunca se registra, ni en `cob.LogAcceso` ni en Application Insights ni en los logs de la API:
  - Contraseñas (temporal, actual o nueva).
  - Hashes de contraseña.
  - Claves de API completas y sus hashes. Basta con `ClaveApiId` o el prefijo.
  - Valores de cookies (`__Host-cobranza-sesion`, `__Host-cobranza-af`) y tokens CSRF.
  - Encabezados `X-Api-Key` y `Authorization`.
  - Cuerpos de las solicitudes a `/api/v1/auth/*`.
  - Cadenas de conexión.
- `UsuarioIngresado`: en un login fallido con `UsuarioInexistente`, el texto solo se guarda si cumple el patrón de usuario (`[a-z0-9._-]`, entre 3 y 50 caracteres). Si no lo cumple, se guarda `(formato no valido)`. Así se evita guardar una contraseña escrita por error en el campo de usuario (hallazgo SEG-H07).

### B.4 IP y agente de usuario

- La IP de origen se trata como dato personal, porque puede identificar indirectamente a una persona.
- El agente de usuario se trata igual cuando va junto a la IP y al usuario, porque permite identificar el equipo.
- En este entorno corresponden a los integrantes del equipo.
- Tratamiento:
  1. Se registran solo para seguridad: detección de fuerza bruta, enumeración y revisión de incidentes.
  2. Solo los consulta `grp-cobranza-sql-admin`. Ningún procedimiento con GRANT a `UsuarioApi` lee `cob.LogAcceso`.
  3. Retención de 90 días (B.1).
  4. En toda evidencia que se exporta o se versiona, la IPv4 se enmascara al /24 (`a.b.c.0`) y la IPv6 al /48. El agente de usuario se reduce a familia de navegador y sistema operativo, o se omite.
  5. La IP pública del operador se reemplaza por `<IP_OPERADOR>`.

### B.5 Evidencias exportadas antes de eliminar el entorno

1. Antes de `eliminar_entorno.sh`, un miembro de `grp-cobranza-sql-admin` exporta:
   - Un resumen: conteo por día, `Evento` y `Motivo`.
   - Una muestra de los eventos que respaldan los casos AUT-01 a AUT-15, con la IP enmascarada y sin agente de usuario completo.
   - Se guarda en `evidencias/<fecha>_log_acceso/`.
2. Se propone una vista de solo administrador, `cob.vw_LogAccesoEvidencia`, que entregue el enmascaramiento ya aplicado, para no depender de que cada operador lo haga a mano.
3. Las evidencias versionadas en git no contienen contraseñas, hashes, claves, IP completas ni Object IDs completos. Antes del commit se ejecuta la búsqueda de cadenas sospechosas de la sección 0.
4. Las evidencias exportadas se conservan mientras dure la evaluación del Portafolio de Título. El plazo posterior: PENDIENTE (lo define el equipo según las normas de la asignatura).
5. Después de eliminar el entorno, los datos de `cob.LogAcceso` siguen existiendo en:
   - Los LTR, hasta 12 meses.
   - El Log Analytics eliminado, recuperable 14 días.
   - El Key Vault en soft-delete, 90 días, que guarda los valores de las claves de API.
   La eliminación de los LTR al cierre del proyecto es una decisión del equipo (PENDIENTE).

---

## C. Rotación y revocación

### C.1 Vigencia de las claves de API

- Vigencia máxima: `Seguridad__DiasVigenciaClaveApi` (DEMO 180, ADR 5.4). El script acepta `--dias` y no permite superar ese máximo.
- `ventas-demo`: 30 días (DEMO). `carga-demo`: 1 día (DEMO).
- Se valida en la base (`FechaVencimiento > SYSUTCDATETIME()` en `sp_ValidarClaveApi`). El atributo `exp` del secreto en Key Vault es solo informativo.
- Cada redespliegue desde cero (base nueva, Key Vault nuevo por `CICLO_KV`) obliga a emitir claves nuevas: el ciclo de despliegue funciona como rotación natural.

### C.2 Rotación del consumidor demo

- Cuándo se rota:
  - 7 días antes del vencimiento (DEMO).
  - Ante sospecha de exposición: de inmediato, revocando primero.
  - Después de toda restauración de la base (C.3).
  - Al cambiar el integrante que ejecuta el script.
- Pasos:
  1. Alta de la clave nueva (A.10.2).
  2. `pruebas/consumidor_ventas_demo.sh` pasa a usar el nombre del secreto nuevo, que recibe como parámetro.
  3. Se prueba con la clave nueva (AUT-10).
  4. Se revoca la anterior con `s11_revocar_clave_api.sh` (A.9).
  5. Se verifica el 401 de la anterior (AUT-12).
  6. Se registra la evidencia.
- La superposición de ambas claves vigentes no supera 1 hora (DEMO).
- El script de rotación alerta si `ventas-demo` tiene más de dos claves activas.

### C.3 Revisión posterior a una restauración (PITR o LTR)

Riesgo (ADR 4.2): la restauración revierte `cob.UsuarioInterno` y `cob.ClaveApi`. Las claves revocadas, los usuarios desactivados, los roles reducidos y las contraseñas cambiadas después del punto restaurado vuelven a su estado anterior. También vuelve el `SelloSeguridad` anterior, así que una cookie emitida antes del punto (dentro de las 8 h DEMO) podría volver a ser válida.

Paso obligatorio, que se agrega al final de `s14_simulacro_pitr.sh` o se implementa como script aparte `scripts/s14_revision_post_restauracion.sh --base-original <db> --base-restaurada <db> --punto <ISO UTC>`:

1. Si la base original existe (caso de `s14_simulacro_pitr.sh`), se listan sus eventos con `FechaUtc >= @Punto` de los tipos `RevocacionClaveApi`, `CambioEstadoUsuario`, `CambioRolUsuario`, `CambioClave`, `RestablecimientoClave`, `AltaUsuario` y `AltaClaveApi`.
2. En la base restaurada:
   - Se repite cada `RevocacionClaveApi` (`sp_RevocarClaveApi`).
   - Se repite cada desactivación y cada reducción de rol.
   - Cada usuario con `CambioClave` o `RestablecimientoClave` posterior al punto recupera su contraseña anterior: se le aplica `sp_RestablecerClaveUsuario` y se le entrega una contraseña nueva en persona.
   - Para cada `AltaClaveApi` posterior, el secreto existe en Key Vault pero no en la base: se deshabilita el secreto huérfano.
   - Para cada `AltaUsuario` posterior: se vuelve a crear el usuario si se necesita.
3. Se invalidan todas las sesiones de la base restaurada. Para eso se propone un procedimiento nuevo de solo administrador, `cob.sp_InvalidarTodasLasSesiones`, que asigna un `SelloSeguridad` nuevo a todos los usuarios y registra el evento.
4. Si la base original no existe (restauración LTR, entorno eliminado o base borrada), no hay bitácora completa y la auditoría de Log Analytics cubre solo 30 días. En ese caso se aplica la regla conservadora:
   - Se revocan todas las claves de API presentes.
   - Se emiten claves nuevas.
   - Se desactivan todos los usuarios que no sean `Admin`.
   - Se restablecen las contraseñas de todos.
5. Se registra la evidencia en `evidencias/seguridad/<fecha>_revision_post_restauracion.md`: punto, eventos revisados, acciones aplicadas y quién las ejecutó.
6. La restauración no termina hasta completar esta revisión y verificar AUT-08 y AUT-12 en la base restaurada.

---

## D. Cambios propuestos (no aplicados)

Los aplica cada agente o el orquestador solo con aprobación humana. Los archivos `.claude/agents/*.md` y CLAUDE.md son configuración y requieren aprobación humana explícita.

### D.1 ADR-001 (agente `arquitecto`)

1. En 5.9, paso 3, reemplazar "canal: PENDIENTE" por: "Canal: entrega presencial con uso inmediato y cambio obligatorio frente al operador (`docs/seguridad/politica_credenciales_y_accesos.md`, A.3). Los scripts de alta no los ejecuta ningún agente de Claude Code."
2. En 5.9, paso 4, reemplazar el PENDIENTE de entrega por: "Consumidor DEMO `ventas-demo`. El script consumidor lee la clave de Key Vault en tiempo de ejecución (política A.5). Lector distinto del operador: `Key Vault Secrets User` con alcance en el secreto."
3. En 5.1 (`cob.ClaveApi.Consumidor`), cambiar "PENDIENTE: identificar el sistema de Ventas" por "DEMO `ventas-demo` (decisión del 05-11-2026). Patrón `[a-z0-9-]` para que el nombre del secreto sea válido en Key Vault."
4. En 5.1 (`cob.LogAcceso`), cambiar "Retención: PENDIENTE" por "Retención: 90 días en línea; purga con `cob.sp_PurgarLogAcceso` (política B)." Agregar a `Evento` el valor `PurgaLogAcceso` y a `Motivo` el valor `ClaveTemporalVencida`.
5. En 5.1 (`UsuarioIngresado`), agregar: "Solo si cumple el patrón de usuario; en caso contrario, `(formato no valido)`."
6. En 5.2, agregar:
   - `sp_CrearUsuarioInterno` fija `FechaCambioClave`.
   - `sp_ObtenerUsuarioParaLogin` devuelve `FechaCambioClave`.
   - Procedimientos nuevos sin GRANT: `sp_PurgarLogAcceso` y `sp_InvalidarTodasLasSesiones`.
   - Vista de administrador `cob.vw_LogAccesoEvidencia`.
7. En 5.4, nueva fila: `Seguridad__HorasVigenciaClaveTemporal` = 24 (DEMO).
8. En 4.2, párrafo PITR: agregar "y LTR". Agregar también la invalidación de sesiones y la regla conservadora cuando no exista la base original (política C.3).
9. En 4.2, cambiar "quién custodia la entrega de contraseñas temporales (PENDIENTE)" por "canal definido en la política A; responsable humano PENDIENTE".
10. En 5.9 (herramienta), agregar:
    - `hash-clave` genera una contraseña de 20 caracteres (DEMO) y la escribe en la terminal, no en stdout.
    - `nueva-clave-api` acepta `--salida-archivo`.

### D.2 CLAUDE.md (orquestador, con aprobación humana)

1. En la sección 5, nuevas filas:
   - "D14 | Entrega de credenciales temporales: presencial con uso inmediato; claves de API leídas de Key Vault por el consumidor DEMO `ventas-demo`; sin git, correo ni chat (`docs/seguridad/politica_credenciales_y_accesos.md`) | Propuesta."
   - "D15 | Retención de `cob.LogAcceso`: 90 días; purga manual mensual por `grp-cobranza-sql-admin` | Propuesta."
2. En la sección 8, punto 11 propuesto por el ADR: cambiar a "Responsable de alta, baja y restablecimiento: PENDIENTE. Canal: definido (D14)". Punto 9 propuesto por el ADR: "Consumidor de RF-06: simulado (`ventas-demo`) para el entorno académico; sistema real PENDIENTE solo para producción."
3. En la sección 0, nueva regla: "Ningún agente ejecuta scripts que muestren o generen contraseñas o claves (`s11_alta_*`, `s11_restablecer_clave.sh`); los ejecuta un integrante humano en su propia terminal."
4. En la sección 7, estructura del repositorio: agregar `docs/seguridad/politica_credenciales_y_accesos.md`.

### D.3 `dba` (`sql/12_autenticacion.sql`, `sql/13_pruebas_autenticacion.sql`, `sql/00`)

1. CHECK de `Evento`: agregar `PurgaLogAcceso`. CHECK de `Motivo`: agregar `ClaveTemporalVencida`.
2. `sp_CrearUsuarioInterno`: fijar `FechaCambioClave = SYSUTCDATETIME()`. `sp_ObtenerUsuarioParaLogin`: devolver `FechaCambioClave`.
3. Procedimientos nuevos sin GRANT:
   - `sp_PurgarLogAcceso` (mínimo de 90 días con `THROW`).
   - `sp_InvalidarTodasLasSesiones`.
   - Una consulta de administrador de eventos posteriores a un punto, para C.3 (por ejemplo `sp_ListarEventosAccesoDesde @Desde`).
   - `sp_VerificarCambioClave @Usuario` para A.10.1, paso 9.
4. Vista `cob.vw_LogAccesoEvidencia` sin GRANT: IP enmascarada (/24 o /48) y agente de usuario reducido.
5. Sanitización de `UsuarioIngresado` en `sp_RegistrarLoginFallido` (defensa en profundidad, además de la API).
6. En `sql/13`, pruebas nuevas:
   - La purga rechaza menos de 90 días.
   - La purga borra solo lo antiguo.
   - La invalidación cambia todos los sellos.
   - El nuevo motivo es aceptado.
7. Confirmar que `sql/02` y `sql/06` no otorgan SELECT sobre `cob.LogAcceso` a ninguna identidad administrada.

### D.4 `desarrollador` (`src/`, `tests/`, `pruebas/`)

1. `Cobranza.Herramientas`:
   - `hash-clave` escribe la contraseña en la terminal (`/dev/tty` o consola) y el hash en stdout.
   - Longitud de 20 caracteres, sin caracteres ambiguos.
   - `nueva-clave-api --salida-archivo <ruta>` escribe la clave en un archivo y deja en stdout solo el prefijo y el hash.
2. API:
   - Vigencia de la contraseña temporal (`Seguridad__HorasVigenciaClaveTemporal`), con 401 genérico y motivo `ClaveTemporalVencida`.
   - Sanitización de `UsuarioIngresado`.
   - No registrar cuerpos de `/api/v1/auth/*` ni los encabezados `X-Api-Key`, `Authorization` y `Cookie` en Application Insights. Verificar la configuración de telemetría: no suponer el comportamiento por defecto.
3. Pruebas unitarias: la contraseña temporal vencida se rechaza, la sanitización funciona y la herramienta no escribe la contraseña en stdout.
4. `pruebas/consumidor_ventas_demo.sh` (nuevo; autor `desarrollador` o `devops`, según decida el orquestador): A.5. También `pruebas/carga_api_k6.js` con `API_KEY` tomada del entorno.

### D.5 `devops` (`scripts/`, `infra/`)

Scripts nuevos. Todos con `set -euo pipefail`, sin `set -x` y sin `tee`, y con verificación de que no corren dentro de Claude Code. Cómo detectarlo (por ejemplo, con una variable de entorno de la sesión del agente): PENDIENTE que `devops` lo verifique, sin suponerlo. Como mínimo, el script pide confirmación interactiva.

| Script | Parámetros | Variables de entorno | Roles RBAC y permisos del ejecutor |
| --- | --- | --- | --- |
| `s11_alta_usuario.sh` | `--usuario`, `--nombre`, `--rol {Finanzas,Ventas,Admin}`; modo `--verificar <usuario>` | `RG`, `SQL_SERVER`, `SQL_DB` | Miembro de `grp-cobranza-sql-admin`; acceso de red a SQL (`IP_OPERADOR`) |
| `s11_restablecer_clave.sh` | `--usuario`; `--solo-desbloquear` (opcional) | Las mismas | Las mismas |
| `s11_baja_usuario.sh` | `--usuario` | Las mismas | Las mismas |
| `s11_alta_clave_api.sh` | `--consumidor` (patrón `[a-z0-9-]`), `--dias` (no mayor que el máximo; 30 para `ventas-demo`), `--lector-object-id` (opcional) | Las anteriores más `KV_NAME` | Lo anterior más `Key Vault Secrets Officer` en el vault (ya existe: `raKvOperador`). Para asignar el rol al lector: Owner, User Access Administrator o Role Based Access Control Administrator (el operador es Owner) |
| `s11_revocar_clave_api.sh` | `--prefijo` | Las mismas | Las mismas |
| `s14_revision_post_restauracion.sh` (o un paso nuevo en `s14_simulacro_pitr.sh`) | `--base-original`, `--base-restaurada`, `--punto` | `RG`, `SQL_SERVER`, `KV_NAME` | Miembro de `grp-cobranza-sql-admin`; `Key Vault Secrets Officer` |
| `s15_purgar_log_acceso.sh` | `--dias` (mínimo 90), `--confirmar` | `RG`, `SQL_SERVER`, `SQL_DB` | Miembro de `grp-cobranza-sql-admin` |

Lector de la clave (integrante distinto del operador): solo `Key Vault Secrets User` con alcance `<vault>/secrets/apikey-ventas-demo-<prefijo>`. Nunca con alcance en el vault completo.

Cambios en `infra/`:

1. Agregar a `main.bicep` el diagnóstico de auditoría de Key Vault (`categoryGroup: audit` hacia Log Analytics), que hoy solo está en `seguridad_perimetral.bicep` (hallazgo SEG-H03).
2. Actualizar el comentario de `raKvOperador` ("easyauth-client-secret en S11") a "claves de API (ADR-001)".
3. Si se usa `sqlcmd -v` para pasar el hash, documentar en el script que el hash queda en la auditoría SQL (ADR 4.3).

### D.6 `seguridad` (`scripts/s12_*`, `docs/seguridad/`; se aplica en una tarea posterior, cuando `qa` termine y el orquestador lo autorice)

1. `s12_endurecer.sh`:
   - Cerrar también Key Vault: `az keyvault update --public-network-access Disabled` y eliminar sus `ipRules`.
   - Eliminar la regla `operador-temporal` si existe.
   - Cambiar el texto de la línea 55 según el ADR 5.10.
   (Hallazgo SEG-H08.)
2. `s12_verificar_seguridad.sh`, controles nuevos:
   - Sin regla `operador-temporal`.
   - Key Vault sin `ipRules`.
   - Ningún secreto `apikey-*` sin fecha de expiración.
   - Ningún secreto `apikey-*` habilitado con la expiración vencida.
   - Ninguna asignación `Key Vault Secrets User` a un usuario humano con alcance en el vault completo.
   - Diagnóstico de auditoría de Key Vault activo.
   - Además, SEG-05 según el ADR 6.
3. En `docs/seguridad/`, plantillas sin datos para `entrega_credenciales.md`, `claves_api.md` y `revision_post_restauracion.md` (las evidencias reales van en `evidencias/seguridad/`).

### D.7 `qa` (`.claude/agents/qa.md`, con aprobación humana)

1. Agregar a la revisión:
   - Ningún agente ejecutó scripts `s11_alta_*` ni `s11_restablecer_clave.sh`.
   - Las evidencias de credenciales no contienen contraseñas, hashes, claves, IP completas ni Object IDs completos.
   - La revisión posterior a la restauración se hizo en todo simulacro S14.
   - La purga rechaza menos de 90 días.
2. Casos nuevos propuestos:
   - AUT-16: contraseña temporal vencida, 401 y motivo `ClaveTemporalVencida`.
   - AUT-17: tras una restauración, la clave revocada antes de restaurar sigue revocada después de la revisión.
   - AUT-18: login con una contraseña escrita en el campo de usuario, guardada como `(formato no valido)`.

### D.8 `.claude/agents/seguridad.md` (con aprobación humana)

En "Alcance", línea de identidad, reemplazar "Easy Auth v2 con roles `Ventas.Consulta`, `Finanzas.Consulta`, `TI.Operacion`; Entra ID Free (asignación por usuario)" por "autenticación propia de la API (cookie y claves de API, ADR-001) y política de credenciales (`docs/seguridad/politica_credenciales_y_accesos.md`)". Agregar: "Región `brazilsouth`".

---

## E. Hallazgos

| Id | Severidad | Hallazgo | Evidencia | Recomendación |
| --- | --- | --- | --- | --- |
| SEG-H01 | Alta | Si un agente de Claude Code ejecuta los scripts de alta, la contraseña temporal y la clave de API (que la herramienta del ADR 5.9 escribe en stdout) quedan en la conversación, lo que equivale a un canal de chat | ADR 5.9: `hash-clave` "escribe por salida estándar ... la contraseña temporal" y `nueva-clave-api` "escribe ... la clave completa" | A.4, reglas 1 y 2; D.2, punto 3; D.4, punto 1 |
| SEG-H02 | Media | Log Analytics retiene 30 días y PITR cubre 35: la auditoría SQL no cubre toda la ventana de restauración | `retentionInDays: 30` y `retentionDays: 35` en `infra/main.bicep` | Retención de `cob.LogAcceso` de 90 días (B.1); C.3 se apoya en la base original |
| SEG-H03 | Media | Sin diagnóstico de auditoría de Key Vault en `main.bicep`: las lecturas de `apikey-*` no quedan auditadas si no se despliega el módulo S12 | El diagnóstico `diagKv` solo está en `infra/modulos/seguridad_perimetral.bicep` | D.5, cambios en `infra/`, punto 1 |
| SEG-H04 | Media | Restaurar desde un LTR (hasta 12 meses, sobrevive a la eliminación del entorno) reactiva claves de API cuyo valor sigue recuperable del Key Vault en soft-delete (90 días, sin purga) | `sqlLtr` P12M; `enablePurgeProtection: true`; `eliminar_entorno.sh` | C.3, punto 4 (regla conservadora); A.10.4 (revocar todo antes de eliminar el entorno) |
| SEG-H05 | Media | El esquema del ADR no permite exigir la vigencia de la contraseña temporal (sin campo de fecha de emisión en el alta ni motivo de rechazo) | ADR 5.1 y 5.2 | A.7; D.1, puntos 4, 6 y 7; D.3, punto 2 |
| SEG-H06 | Baja | El hash de la contraseña temporal queda en la auditoría SQL (`BATCH_COMPLETED_GROUP`) por el uso de `sqlcmd -v` | ADR 4.3; `sqlAuditoria` en `main.bicep` | Contraseña temporal aleatoria de 20 caracteres (DEMO) y de vida corta. Si las llamadas de la API por RPC registran los valores de sus parámetros en la auditoría: PENDIENTE verificar en Azure |
| SEG-H07 | Baja | `UsuarioIngresado` puede guardar una contraseña escrita por error en el campo de usuario | ADR 5.1 | B.3 (sanitización) |
| SEG-H08 | Media | `s12_endurecer.sh` cierra SQL pero no Key Vault ni elimina `operador-temporal`. Si se endurece con `ipOperador` todavía con valor, Key Vault queda abierto a esa IP | `scripts/s12_endurecer.sh` | D.6, punto 1 |
| SEG-H09 | Baja | El atributo `exp` de los secretos de Key Vault no impide la lectura (según la documentación; verificar en Azure) | Documentación "About Azure Key Vault secrets" | La vigencia se controla en SQL; al revocar, se deshabilita y se elimina el secreto (A.9) |

---

## F. Pendientes

1. Responsable humano que autoriza altas, bajas y restablecimientos (CLAUDE.md, sección 10).
2. Qué integrantes son miembros de `grp-cobranza-sql-admin`.
3. Si la clave de k6 es `ventas-demo` o una dedicada (`carga-demo`).
4. Lectura de la clave de API desde una IP distinta de `ipOperador` (requiere aprobación).
5. Plazo de conservación de las evidencias después de la evaluación y eliminación de los LTR al cierre del proyecto.
6. Plazo de retención para producción según la Ley 19.628 y la Ley 21.719 (validación del equipo o del docente).
7. Verificaciones en Azure durante el despliegue:
   - Comportamiento de `exp` en los secretos.
   - Si la auditoría SQL registra los parámetros de las llamadas RPC.
   - Telemetría de encabezados y cuerpos en Application Insights.
8. Mecanismo para que los scripts detecten que se ejecutan dentro de Claude Code (D.5).
9. Aprobación de los valores DEMO de A.11.
