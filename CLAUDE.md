# CLAUDE.md — Proyecto APT Cobranza Automatizada

Contexto maestro del proyecto para Claude Code (VS Code). Todo agente y la sesión principal deben leer este archivo antes de actuar.
Última consolidación: 05-11-2026 (revisión 2: región brazilsouth, autenticación propia ADR-001, D12-D17; los valores reemplazados se conservan en el mismo lugar, marcados "Reemplazado 05-11-2026"). Fuentes: carpeta `docs/` (ver `docs/00_INDICE.md`) y `docs/adr/`.

---

## 0. Reglas de trabajo obligatorias

1. Responder y documentar solo en español, sin emojis.
2. No suponer nada. Si un dato no está en este archivo, en `docs/` o en el código del repositorio, se marca `PENDIENTE` y se pregunta al equipo. Nunca inventar valores (Object IDs, nombres de dominio, días de preaviso, cadenas de conexión, endpoints, etc.).
3. Distinguir siempre entre "diseñado/escrito", "validado localmente" y "desplegado/probado en Azure". Al 05-11-2026 solo existen en Azure el grupo de recursos vacío `rg-cobranza-apt` y el grupo Entra `grp-cobranza-sql-admin` (ver sección 7). (Reemplazado 05-11-2026; antes: "Hasta la fecha de este archivo, nada está desplegado en Azure".)
4. Ningún secreto en el repositorio: cadenas de conexión, claves y tokens solo en Azure Key Vault o en variables locales fuera de control de versiones.
5. Acciones que crean, modifican o eliminan recursos en Azure (`az deployment ...`, `az ... delete`, `sqlcmd` contra la base real, scripts de `scripts/`) requieren confirmación explícita de un integrante humano antes de ejecutarse. Primero se ejecuta en modo validación (`what-if`, `--validate`, `bicep build`, `lint`).
6. Cada cambio en infraestructura o base de datos debe registrar: qué cambió, por qué, archivo afectado y evidencia (salida del comando). Las evidencias se guardan en `evidencias/` con fecha.
7. Volver a desplegar `infra/main.bicep` restablece los ajustes de aplicación y la configuración del sitio: después de cada despliegue de `main` se debe reaplicar `scripts/s12_endurecer.sh` (ubicación confirmada el 05-11-2026).
8. Cuando existan dos versiones de un dato en `docs/`, prevalece la más reciente y se deja nota de la anterior (ver sección 9).
9. Ningún agente ni la sesión principal ejecutan scripts que muestren o generen contraseñas o claves (`s11_alta_*`, `s11_restablecer_clave.sh`, `s11_baja_usuario.sh`, `s11_revocar_clave_api.sh`, comandos de `Cobranza.Herramientas`): su salida quedaría en la conversación. Los ejecuta un integrante humano en su propia terminal (SEG-H01, D14; agregada 05-11-2026).

---

## 1. Proyecto

- Nombre: Proyecto Cobranza Automatizada (título definitivo: PENDIENTE; el Informe V1.2 usa título provisorio).
- Asignatura: Portafolio de Título (APT). Carrera: Ingeniería en Infraestructura y Plataformas Tecnológicas. Sede Antonio Varas.
- Cliente (caso de estudio): Embotelladora del Pacífico S.A., Buin, Región Metropolitana. Producción, envasado y distribución de bebidas analcohólicas; 45 colaboradores; clientes B2B (supermercados locales, minimarkets, hoteles, restaurantes).
- Problema: cobranza manual de facturas a crédito (30/60 días), errores humanos, pedidos retenidos de clientes morosos que no se liberan a tiempo.
- Metodología: tradicional en cascada (Waterfall), 15 semanas en la Carta Gantt (Fase 1 S1-S4, Fase 2 S5-S11, Fase 3 S12-S15).
- Competencias del perfil de egreso: seguridad en plataformas tecnológicas; diseño de soluciones de infraestructura; gestión de proyectos de implementación; almacenamiento, respaldo y recuperación.

### Integrantes y roles (según Guía Fase 1, sección Metodología)

| Integrante | Rol declarado en la metodología |
| --- | --- |
| Arnaldo Muñoz González | Líder de Proyecto y Gestión TI |
| Oscar Díaz Ulloa | Especialista en Infraestructura y Servidores |
| Dariel Zúñiga | Especialista en Bases de Datos y Almacenamiento |
| José Cartes Mardones | Especialista en Conectividad e Integración (APIs) |
| Germán Muñoz Manríquez | Especialista en Ciberseguridad y Pruebas (QA) |

Advertencia: el Plan de Trabajo y la Carta Gantt de la misma guía asignan responsables distintos (por ejemplo, Base de Datos a Arnaldo y Seguridad/Pruebas a Dariel). Además el Informe V1.2 presenta diferencias de roles entre su sección 4.2.A, la sección 9 y el Acta. La asignación definitiva es PENDIENTE del equipo; no corregir por cuenta propia.

---

## 2. Alcance funcional vigente

Cambio clave respecto de la Guía Fase 1: se eliminó la pasarela de pago. La propia embotelladora registra en su base de datos a los clientes regularizados; el sistema solo la consulta (solo lectura). Los correos no llevan enlace de pago.

Requerimientos funcionales:
- RF-01 Notificaciones automáticas por correo antes y al vencimiento de facturas 30/60 días.
- RF-02 Sincronización periódica de solo lectura contra la BD de la embotelladora para detectar regularizados.
- RF-03 Actualización automática del estado de mora al detectar regularización.
- RF-04 Liberación automática de pedidos retenidos al pasar de "Suspendido" a "Regularizado" (ver decisión D5).
- RF-05 Logs de notificaciones, sincronizaciones y cambios de estado.
- RF-06 API interna para que Ventas consulte el estado financiero de un cliente.
- RF-07 Panel para Finanzas y Tesorería con estadísticas de morosidad y recaudación (sin procesar pagos).
- RF-08 Actualización periódica de regularizados desde la BD de la embotelladora.

Requerimientos no funcionales:
- RNF-01 Disponibilidad objetivo mayor o igual a 99 %.
- RNF-02 TLS 1.2 o superior en tránsito, TDE en reposo, credenciales en Key Vault.
- RNF-03 Escalabilidad del cómputo sin afectar continuidad.
- RNF-04 Ventana de ejecución acordada para sincronización y notificaciones.
- RNF-05 Auditoría de todo cambio de estado (fecha, origen, valor anterior y nuevo).
- RNF-06 RPO menor a 15 minutos, RTO menor a 4 horas.
- RNF-07 Arquitectura por capas y código versionado.
- RNF-08 Integración de solo lectura con la BD externa.

---

## 3. Arquitectura (Microsoft Azure)

- Región: Brazil South (`brazilsouth`), decisión del equipo del 05-11-2026. Motivo: la suscripción Azure for Students está en el tenant institucional Duoc UC, cuya política "Ubicaciones permitidas" (asignada en el grupo de administración raíz, no eximible por el Owner de la suscripción) solo permite regiones de Brasil y EE. UU. Brazil South tiene zonas de disponibilidad y región pareada (South Central US). (Reemplazado 05-11-2026; antes: "Chile Central (`chilecentral`). Disponible con 3 zonas, sin región pareada".)
- Tenant: institucional Duoc UC. El operador es Owner de la suscripción, sin roles de directorio; el consentimiento de usuario está desactivado en el tenant. El equipo decidió no crear tenants propios ni pedir permisos a TI de Duoc (05-11-2026).
- Grupo de recursos sugerido: `rg-cobranza-apt`. Prefijo `cobranza` más sufijo `uniqueString` de 6 caracteres.
- Red: VNet `vnet-cobranza` 10.20.0.0/16.
  - `snet-app` 10.20.1.0/24, delegada a App Service (integración VNet, IP dinámica), NSG `nsg-app`, gateway 10.20.1.1.
  - `snet-pe` 10.20.2.0/24 para Private Endpoints, NSG `nsg-pe` (permite 1433 y 443 desde snet-app; deny VNet en prioridad 4000), gateway 10.20.2.1.
  - IP fijas de Private Endpoints: sql 10.20.2.4, keyvault 10.20.2.5 (memberName `default`), blob 10.20.2.6, queue 10.20.2.7, table 10.20.2.8. NIC con nombre fijo `nic-pe-<x>-cobranza-dev`.
  - Reservadas por Azure: x.0 a x.3 y x.255. IPv6 no aplica.
- Azure SQL Database `sqldb-cobranza`: Standard S0, intercalación `Modern_Spanish_CI_AS`, autenticación solo Entra ID (grupo administrador `grp-cobranza-sql-admin`), sin acceso público, TLS 1.2, TDE, PITR 35 días, LTR P8W/P12M, redundancia de respaldo Zone, auditoría hacia Azure Monitor.
- Parámetro `ipOperador`: abre temporalmente SQL (regla `operador-temporal`) y Key Vault a la IP del operador; vacío significa cerrado. `operadorObjectId` recibe el rol Key Vault Secrets Officer.
- Key Vault: modelo RBAC, protección de purga. Secreto `acs-connection-string` creado por la plantilla.
- Storage: ZRS, sin clave compartida (uso de Functions).
- Azure Communication Services + Email Service: `AzureManagedDomain`, ubicación de datos United States. Remitente `DoNotReply@<dominio administrado>`. Acceso por cadena de conexión guardada en Key Vault.
- App Service Plan Linux B1 compartido por:
  - Web App (API) `DOTNETCORE|10.0`, sonda de salud `/salud`. Proyecto: `src/Cobranza.Api`.
  - Function App `DOTNET-ISOLATED|10.0` (jobs de sincronización y notificaciones) con ajustes `Cobranza__*`; los textos de Finanzas usan valores DEMO inventados (D17). Proyecto: `src/Cobranza.Functions`. (Reemplazado 05-11-2026; antes: "los valores de Finanzas van como parámetros vacíos. Nombre del proyecto de Functions: PENDIENTE".)
- Observabilidad: Log Analytics + Application Insights.
- Identidad: identidades administradas con RBAC mínimo hacia SQL, Key Vault y Storage (API sin acceso a secretos; Function App solo al secreto `acs-connection-string`); Azure SQL solo Entra ID (grupo `grp-cobranza-sql-admin`). Usuarios del panel y consumidores de la API con autenticación propia de la aplicación (ADR-001, D13): usuario y contraseña con cookie de ASP.NET Core (PBKDF2 de `PasswordHasher`, bloqueo por intentos, roles `Finanzas`, `Ventas`, `Admin` desde `cob.UsuarioInterno`) y clave de API por consumidor en el encabezado `X-Api-Key` (hash SHA-256 en `cob.ClaveApi`, valor en Key Vault; consumidor DEMO `ventas-demo`). Data Protection de la API: contenedor `dataprotection-keys` (con condición ABAC que excluye a la Function App) y clave `dataprotection-cobranza-api` en Key Vault. Easy Auth v2 y los roles de aplicación de Entra ID no se usan. Sin MFA. Estado: diseñado; implementación en curso. (Reemplazado 05-11-2026; antes: "identidades administradas con RBAC mínimo; Easy Auth v2 con roles de aplicación `Ventas.Consulta`, `Finanzas.Consulta`, `TI.Operacion`; Entra ID Free (asignación de roles por usuario, sin grupos)". Motivo: Easy Auth requiere consentimiento de administrador del tenant Duoc.)
- Seguridad perimetral opción B (condicionada, PENDIENTE aprobación): Application Gateway WAF v2 delante de App Service con Private Endpoint de entrada (sexto PE) y sin acceso público.
- Fuente de regularizados: BD real de la embotelladora no definida. Se usa fuente simulada `origen_sim.vw_ClientesRegularizados (Rut, FechaRegularizacion)`.

Plantilla `infra/main.bicep`: el original S10 no estaba en el repositorio ni en el disco. El 05-11-2026 se RECONSTRUYÓ desde la versión S6-S8 (`Entorno_Base_IaC_SQL_S6-S8.zip`) aplicando los cambios C1-C6 de `docs/06`, más `operadorObjectId`, región brazilsouth, parámetros por variables de entorno (`readEnvironmentVariable`, sin IDs en git) y `cicloKeyVault` para redesplegar tras eliminar el RG (protección de purga). Resultado tras las correcciones de qa (diagnósticos de auditoría de SQL `master` y de Key Vault): 31 declaraciones / 49 recursos; `bicep build`, `lint` y `what-if` (48 Create con `ipOperador` vacío) limpios con Bicep 0.48.1. Detalle en `evidencias/2026-11-05_whatif_brazilsouth/CAMBIOS.md` y `evidencias/2026-11-05_correcciones_qa_devops/CAMBIOS.md`. Modelo de uso: desplegar, tomar evidencias, eliminar con `scripts/eliminar_entorno.sh` (solo humano) y redesplegar cuando se requiera. (Reemplazado 05-11-2026; antes: "Plantilla `infra/main.bicep` (versión S10): 28 declaraciones / 46 recursos. Validada con Bicep CLI 0.48.1 sin errores ni advertencias".)

---

## 4. Base de datos

Esquema `cob`:
- Tablas: `Cliente`, `Factura` (vencimiento calculado), `EstadoMorosidad`, `Pedido`, `LogNotificacion` (único por factura y tipo de aviso), `LogSincronizacion`, `UsuarioInterno`, `LogCambioPedido` (sin FK, alimentada con `OUTPUT INTO`).
- Tipo tabla: `cob.ListaRut`.
- Lógica: `sp_SincronizarClientesRegularizados`, `tr_EstadoMorosidad_Liberar`, `sp_LiberarPedidosRetenidos`, `sp_GenerarAlertasVencimiento`. Control de concurrencia con `sp_getapplock`.
- Escritura solo mediante procedimientos almacenados.
- Usuarios de base contenidos: `UsuarioFunctionApp`, `UsuarioApi` (identidades administradas).

Orden de ejecución SQL (`scripts/desplegar_sql.sh`): 01, 02 (UsuarioFunctionApp, UsuarioApi), 03, 04, 05 (UsuarioFunctionApp), 06 (UsuarioApi), 11, 00 (verificación), 07 (pruebas, resultado esperado 10/10). El script 08 carga datos DEMO solo para pruebas.
Nombres conocidos: `sql/01_esquema_cobranza.sql`, `sql/02_identidades_y_permisos.sql`. Los nombres completos de 00 y 03 a 11: confirmar en el repositorio.

---

## 5. Reglas de negocio y decisiones registradas

| Id | Decisión | Estado |
| --- | --- | --- |
| D1 | Sin pasarela de pago; correos sin enlace de pago | Vigente |
| D2 | Notificaciones cada hora entre 12 y 17 UTC, días hábiles | Vigente (validar con Finanzas) |
| D3 | Tipos de aviso: Preaviso, Vencimiento, Mora1, Mora2; los días no tienen valor por defecto | Días PENDIENTE Finanzas |
| D4 | No enviar avisos de mora si el cliente quedó Regularizado después del vencimiento | Validar |
| D5 | Regularización desde Moroso o Suspendido (RF-04 dice solo Suspendido) | Validar |
| D6 | `PuedeTomarPedido` verdadero solo para AlDia y Regularizado | Vigente |
| D7 | Sincronización cada 15 minutos | Propuesta a validar |
| D8 | Jobs en el mismo plan B1 que la API (consumo clásico sin VNet; Flex Consumption no confirmado en Chile Central; con brazilsouth (D16) la disponibilidad de Flex Consumption no se ha reevaluado) | Vigente |
| D9 | Respaldo con redundancia de zona; RA-GRS descartado por no haber región pareada (motivo válido para Chile Central; brazilsouth sí tiene región pareada, South Central US, por lo que D9 debe reevaluarse) | Vigente; reevaluación PENDIENTE (05-11-2026) |
| D10 | Brecha de recuperación ante desastre regional asumida como decisión del equipo | Vigente; reevaluar junto con D9 (05-11-2026) |
| D11 | WAF v2 condicionado a aprobación | PENDIENTE |
| D12 | Job de notificaciones DEMO: máximo 10 por ejecución, pausa 15.000 ms (capacidad 60 por día hábil, sin margen frente al límite de 10 por hora del dominio administrado). Un 429 o rechazo por límite detiene el lote y no cuenta como intento fallido (implementado y probado el 05-11-2026: se registra en Application Insights, EventId 4290; el estado `Limitado` en `cob.LogNotificacion` está diseñado en ADR-001, no implementado). Producción: requiere dominio propio y aumento de límites (H1). Ver ADR-001 sección 5.12. (Reemplazado 05-11-2026; antes: "máximo 90 por ejecución, pausa 2.100 ms", estado "Debe ajustarse".) | Vigente para DEMO (decisión del usuario 05-11-2026); producción PENDIENTE |
| D13 | Autenticación propia en la API: cookie con usuario y contraseña para el panel y clave de API para Ventas sistema a sistema (consumidor DEMO `ventas-demo`); sin Easy Auth ni roles de Entra ID; sin MFA. Ver `docs/adr/ADR-001-autenticacion-propia-sin-entra-usuarios.md` | Vigente (aceptada 05-11-2026); valores DEMO de bloqueo y sesión aprobados (05-11-2026); límite por IP, longitudes de contraseña y vigencia máxima de claves de API: PENDIENTE |
| D14 | Entrega de credenciales temporales: presencial con uso inmediato y cambio obligatorio frente al operador; claves de API leídas de Key Vault por el consumidor DEMO; sin git, correo ni chat. Ningún agente ejecuta scripts de alta o restablecimiento (regla 9). Ver `docs/seguridad/politica_credenciales_y_accesos.md` | Vigente (el usuario delegó el canal en `seguridad` y aprobó sus valores DEMO el 05-11-2026; el ADR y la política aún figuran como Propuesta hasta su revisión) |
| D15 | Retención de `cob.LogAcceso`: 90 días en línea; purga manual mensual por `grp-cobranza-sql-admin` con `cob.sp_PurgarLogAcceso` (mínimo 90 días) | Vigente para el entorno académico (definida por `seguridad`, aprobada 05-11-2026); producción PENDIENTE |
| D16 | Región brazilsouth y tenant Duoc sin permisos adicionales (ver sección 3) | Vigente (05-11-2026) |
| D17 | Textos de Finanzas para la demo (canales de pago, teléfono, correo de contacto): valores inventados rotulados DEMO, fijados en `infra/main.bicepparam` | Vigente para DEMO (05-11-2026); valores reales PENDIENTE Finanzas |

Hallazgo H1 (S10, 17-10-2026): con dominio administrado de ACS los límites son 5 correos por minuto y 10 por hora sin ampliación; los límites 30/min y 100/h corresponden a dominio propio verificado. El volumen simulado es de 2.434 correos al mes (promedio 111 por día hábil). En producción se requiere dominio propio de la embotelladora (SPF, DKIM, DMARC) y solicitud de aumento, o escalonar envíos.

Hallazgo H2: el App Service B1 de una instancia no tiene redundancia de zona ni autoescalado; es el punto débil de continuidad.

---

## 6. Costos (estimación v2, 10-10-2026, USD, pago por uso)

- Producción sin VPN: 493,45 USD/mes (5.921,36 USD/año). El WAF v2 representa cerca del 80 %.
- Producción con VPN S2S (solo si la BD de la embotelladora está en servidores propios): 650,40 USD/mes.
- Detalle en `docs/04_Estimacion_Costos_Azure_ChileCentral.md`.

---

## 7. Estado actual (al 05-11-2026, revisión 2)

- Suscripción de Azure: disponible desde el 05-11-2026, "Azure for Students" en el tenant Duoc UC; el operador (Oscar Díaz Ulloa) es Owner. (Reemplazado 05-11-2026; antes: "no disponible a la fecha de los últimos documentos (17-10-2026)".)
- Objetos creados en Azure y Entra ID (con aprobación, evidencia en `evidencias/2026-11-05_acciones_azure_operador/REGISTRO.md`): grupo de recursos vacío `rg-cobranza-apt` (brazilsouth), grupo `grp-cobranza-sql-admin` (operador como dueño y miembro), proveedores Microsoft.Communication, microsoft.insights, Microsoft.KeyVault y Microsoft.OperationalInsights registrados. Recursos de la solución desplegados: ninguno. (Reemplazado 05-11-2026; antes: "Recursos desplegados en Azure: ninguno".)
- `sql/01` corregido el 05-11-2026 (hallazgo C-01 de qa): compatible con 00 y 03-11 por validación estática; 07 daría 10/10 sin ejecutar (no hay motor SQL local). Ver `evidencias/2026-11-05_sql01_correccion_c01/`.
- Proyecto de Functions: `src/Cobranza.Functions` (confirmado 05-11-2026).
- Código .NET (05-11-2026): `dotnet build` en verde (0 advertencias, `TreatWarningsAsErrors`) y `dotnet test` 23/23 en `tests/Cobranza.Functions.Tests`, sin paquetes vulnerables. Evidencia en `evidencias/2026-11-05_desarrollo_build_429/`. La API todavía usa `EasyAuthHandler` y NO debe publicarse hasta implementar ADR-001 (hallazgo A-01).
- Despliegue y pruebas P01-P37 en Azure: programados para la semana 11 (indicación del equipo, 17-10-2026).
- Entorno de trabajo: desde el 05-11-2026 el equipo trabaja en su máquina local con VS Code y Claude Code, con permisos para compilar y ejecutar herramientas. El sistema operativo y las versiones instaladas deben registrarse en la primera tarea (ver `PRIMERA_TAREA.md`); no suponerlos.
- Código .NET (API y Functions): compilado y probado localmente el 05-11-2026 (ver viñeta siguiente). (Reemplazado 05-11-2026; antes: "escrito, nunca compilado".)
- Bicep: compilado y con lint limpio (0.48.1). Scripts bash: `bash -n` y ShellCheck 0.10.0 sin hallazgos según documentos S10; en la máquina local del 05-11-2026 ShellCheck no está instalado, por lo que los scripts nuevos o modificados solo tienen `bash -n` (ShellCheck NO VERIFICADO). Plan de direccionamiento: 15/15 OK.
- Scripts SQL: revisados, no ejecutados.

### Estructura de repositorio esperada (según entregables S8-S15)

```
infra/main.bicep, infra/main.bicepparam
sql/01_esquema_cobranza.sql, sql/02_identidades_y_permisos.sql, ... (00 a 11)
src/Cobranza.Api/                    API .NET 10
src/Cobranza.Functions/             confirmado 05-11-2026
tests/Cobranza.Functions.Tests/      23 pruebas (05-11-2026)
docs/adr/, docs/seguridad/           ADR-001 y política de credenciales
scripts/desplegar.sh                 8 pasos
scripts/desplegar_sql.sh
scripts/verificar_despliegue.sh      pruebas P01-P32
scripts/validar_direccionamiento.py
scripts/s12_endurecer.sh             ubicación confirmada 05-11-2026
scripts/eliminar_entorno.sh          solo humano (05-11-2026)
docs/GUIA_DESPLIEGUE.md
docs/generar_topologia.py
```

Origen de este código: `Repositorio_Cobranza_Automatizada_S10-S15.zip` e `Implementacion_S10_Anexos.zip`, entregados en conversaciones anteriores. Este paquete NO incluye ese código; debe copiarse en la raíz del repositorio antes de empezar. Si un archivo listado no existe al abrir el repositorio, se informa y no se recrea por iniciativa propia.

---

## 8. Pendientes externos (bloqueantes o condicionantes)

1. Suscripción de Azure y permisos del operador: RESUELTO 05-11-2026 (Azure for Students, Owner; ver sección 3, Tenant). (Antes: bloqueante para el despliegue.)
2. Grupo administrador SQL `grp-cobranza-sql-admin`: RESUELTO 05-11-2026, creado. Su Object ID se entrega por la variable de entorno `SQL_ADMIN_GROUP_OBJECT_ID` (fuera de git). (Antes: Object ID y nombre PENDIENTE.)
3. Valores de Finanzas: días de preaviso y de mora, texto de los correos, canales de pago informados en el correo. Para la demo: días DEMO Preaviso 7, Vencimiento 0, Mora1 3, Mora2 7 y textos DEMO inventados (D17); valores reales PENDIENTE.
4. Dominio de correo propio de la embotelladora (SPF, DKIM, DMARC).
5. BD real de la embotelladora: motor, ubicación, vista y usuario de solo lectura (define si se requiere VPN S2S).
6. Aprobación del WAF v2 (opción B).
7. Número de usuarios simultáneos para la prueba de carga.
8. Tablas 3.2 (estaciones de trabajo) y 3.3 (versiones de herramientas) del documento de implementación.
9. Consumidor de RF-06: simulado (`ventas-demo`) para el entorno académico; sistema real PENDIENTE solo para producción.
10. Valores DEMO de seguridad aprobados (05-11-2026). PENDIENTE: límite de login por IP (10/min), longitud de contraseña (12/128), vigencia máxima de claves de API (180 días), superposición en rotación (1 h), frecuencia de `UltimoUso` (60 min) (ADR-001 sección 5.4).
11. Responsable humano que autoriza altas, bajas y restablecimientos, y qué integrantes son miembros de `grp-cobranza-sql-admin`: PENDIENTE (canal definido en D14).
12. Retención de `cob.LogAcceso` para producción (Ley 19.628 y Ley 21.719) y plazo de conservación de evidencias tras la evaluación (D15): PENDIENTE.
13. Scripts no encontrados en el repositorio ni en el disco: `scripts/desplegar.sh`, `scripts/desplegar_sql.sh`, `scripts/verificar_despliegue.sh` (P01-P32), `scripts/validar_direccionamiento.py`, `docs/GUIA_DESPLIEGUE.md`. Decidir si se recrean.
14. Retención de Log Analytics (30 días) frente a PITR (35 días) (SEG-H02): decisión de costo PENDIENTE.
15. Validación real de SQL (07 = 10/10) en un motor local o en Azure: PENDIENTE.

---

## 9. Inconsistencias conocidas (no corregir sin acuerdo del equipo)

- Guía Fase 1 y Evidencia final mencionan pasarela de pago y links de pago; vigente: sin pasarela (D1).
- Guía y Plan mencionan SMTP; vigente: Azure Communication Services Email.
- Guía menciona PostgreSQL/MySQL; vigente: Azure SQL Database.
- S1-S6 menciona RA-GRS y LTR vía Azure Backup; vigente: ZRS/Zone y LTR nativo de Azure SQL.
- S1-S6 menciona Functions en consumo; vigente: mismo plan B1.
- Límites ACS 30/100 (S6-S8) corregidos a 5/10 con dominio administrado (S10).
- Actividad 6: Plan S8-S11 frente a Gantt S9-S11.
- "Tiempo real" en la Guía frente a sincronización periódica.
- Presupuesto del Informe V1.2 (120-250 USD) frente a estimación 493,45 USD.
- Nombre de Dariel (Zuñiga / Zúñiga / Zuñiga Romero).
- Informe V1.2: secciones 2, 11 y 12 vacías; título provisorio.
- Documentos anteriores al 05-11-2026 (docs/02, docs/04, docs/05, docs/06) indican Chile Central; vigente: brazilsouth (D16). Los costos de docs/04 son de Chile Central y deben recalcularse.
- docs/02 (sección 5) y docs/05 indican Entra ID y Easy Auth v2 para los usuarios; vigente: autenticación propia (D13, ADR-001). docs/04 lista Entra ID P1 "requerido para acceso condicional"; con D13 no aplica al panel.
- `main.bicep` está documentado como "validado S10, 28/46"; el original no existe y el vigente es una reconstrucción 31/49.
- `sql/01` S6-S8 era incompatible con 03-11 (C-01); corregido el 05-11-2026. El original queda en `evidencias/2026-11-05_sql01_correccion_c01/01_original_S6S8.sql`.
- `EasyAuthHandler.cs` cita `s12_registro_entra_id.sh`; el script se llama `s11_registro_entra_id.sh` (ambos obsoletos por D13).
- Archivos de agentes (`.claude/agents/*.md`) y la sección 10 mencionan Easy Auth y Chile Central; vigente: D13 y brazilsouth.
- `OpcionesCobranza.cs`, `local.settings.example.json` y `s10_configurar_jobs.sh` usaban 100/h, 30/min y 90/2100; vigente: H1 (5/10) y D12 DEMO (10/15000).
- `s11_registro_entra_id.sh` (líneas 10-11) dice que se requiere el rol Application Developer; en el tenant Duoc los usuarios pueden crear apps sin ese rol (script obsoleto por D13).

---

## 10. Orquestación con agentes

La sesión principal de Claude Code es el orquestador técnico: lee este archivo, divide la tarea y delega en los agentes de `.claude/agents/`. Los subagentes no pueden invocar a otros subagentes, por lo que toda coordinación pasa por la sesión principal. El responsable humano que aprueba cada paso: PENDIENTE de definición por el equipo.

| Agente | Responsabilidad | Escribe en |
| --- | --- | --- |
| `arquitecto` | Coherencia del diseño, decisiones (ADR), impacto de cambios | `docs/adr/`, este archivo (solo secciones 5, 8, 9 con aprobación) |
| `devops` | Bicep, scripts de despliegue, CI/CD, configuración de App Service y Functions | `infra/`, `scripts/`, `.github/` |
| `desarrollador` | Código .NET 10 de la API y las Functions, pruebas unitarias | `src/`, `tests/` |
| `dba` | Esquema `cob`, procedimientos, permisos, respaldo y restauración | `sql/` |
| `seguridad` | NSG, Private Endpoints, Key Vault, autenticación propia de la API (cookie, claves de API) y política de credenciales, WAF, endurecimiento (antes: "Easy Auth", reemplazado 05-11-2026 por D13) | `infra/` (seguridad), `scripts/s12_*`, `docs/seguridad/` |
| `qa` | Revisión independiente y completa; nunca modifica código | `evidencias/qa/` |

Flujo estándar por cada tarea:
1. `arquitecto` valida que la tarea es coherente con este archivo y lista impactos.
2. Agente especialista implementa.
3. `qa` revisa todo lo cambiado contra este archivo, `docs/` y la evidencia, y emite informe con veredicto (APROBADO / APROBADO CON OBSERVACIONES / RECHAZADO).
4. Un humano confirma antes de cualquier acción en Azure.

Secuencia de despliegue sugerida (semana 11):
1. `desarrollador`: `dotnet build` y `dotnet test` de toda la solución.
2. `devops`: `bicep build`, `lint`, `az deployment group what-if` con parámetros completos (sin PENDIENTE).
3. Humano aprueba; `devops` ejecuta `scripts/desplegar.sh`.
4. `dba`: `scripts/desplegar_sql.sh` en el orden de la sección 4; pruebas 07 deben dar 10/10.
5. `devops` + `desarrollador`: publicación de API y Functions; verificación de `/salud`.
6. `seguridad`: `s12_endurecer.sh` y verificación de exposición pública.
7. `qa`: `scripts/verificar_despliegue.sh` (P01-P32) y casos P33-P37; informe final.
