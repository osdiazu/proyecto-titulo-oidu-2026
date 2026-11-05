# CLAUDE.md — Proyecto APT Cobranza Automatizada

Contexto maestro del proyecto para Claude Code (VS Code). Todo agente y la sesión principal deben leer este archivo antes de actuar.
Última consolidación: 05-11-2026. Fuentes: carpeta `docs/` (ver `docs/00_INDICE.md`).

---

## 0. Reglas de trabajo obligatorias

1. Responder y documentar solo en español, sin emojis.
2. No suponer nada. Si un dato no está en este archivo, en `docs/` o en el código del repositorio, se marca `PENDIENTE` y se pregunta al equipo. Nunca inventar valores (Object IDs, nombres de dominio, días de preaviso, cadenas de conexión, endpoints, etc.).
3. Distinguir siempre entre "diseñado/escrito", "validado localmente" y "desplegado/probado en Azure". Hasta la fecha de este archivo, nada está desplegado en Azure.
4. Ningún secreto en el repositorio: cadenas de conexión, claves y tokens solo en Azure Key Vault o en variables locales fuera de control de versiones.
5. Acciones que crean, modifican o eliminan recursos en Azure (`az deployment ...`, `az ... delete`, `sqlcmd` contra la base real, scripts de `scripts/`) requieren confirmación explícita de un integrante humano antes de ejecutarse. Primero se ejecuta en modo validación (`what-if`, `--validate`, `bicep build`, `lint`).
6. Cada cambio en infraestructura o base de datos debe registrar: qué cambió, por qué, archivo afectado y evidencia (salida del comando). Las evidencias se guardan en `evidencias/` con fecha.
7. Volver a desplegar `infra/main.bicep` restablece los ajustes de aplicación y la configuración del sitio: después de cada despliegue de `main` se debe reaplicar `s12_endurecer.sh` (ubicación exacta: PENDIENTE confirmar en el repositorio).
8. Cuando existan dos versiones de un dato en `docs/`, prevalece la más reciente y se deja nota de la anterior (ver sección 9).

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

- Región: Chile Central (`chilecentral`). Disponible con 3 zonas, sin región pareada.
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
  - Function App `DOTNET-ISOLATED|10.0` (jobs de sincronización y notificaciones) con ajustes `Cobranza__*`; los valores de Finanzas van como parámetros vacíos. Nombre del proyecto de Functions en `src/`: PENDIENTE confirmar en el repositorio.
- Observabilidad: Log Analytics + Application Insights.
- Identidad: identidades administradas con RBAC mínimo; Easy Auth v2 con roles de aplicación `Ventas.Consulta`, `Finanzas.Consulta`, `TI.Operacion`; Entra ID Free (asignación de roles por usuario, sin grupos).
- Seguridad perimetral opción B (condicionada, PENDIENTE aprobación): Application Gateway WAF v2 delante de App Service con Private Endpoint de entrada (sexto PE) y sin acceso público.
- Fuente de regularizados: BD real de la embotelladora no definida. Se usa fuente simulada `origen_sim.vw_ClientesRegularizados (Rut, FechaRegularizacion)`.

Plantilla `infra/main.bicep` (versión S10): 28 declaraciones / 46 recursos. Validada con Bicep CLI 0.48.1 (`bicep build`, `lint`, `build-params`) sin errores ni advertencias.

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
| D8 | Jobs en el mismo plan B1 que la API (consumo clásico sin VNet; Flex Consumption no confirmado en Chile Central) | Vigente |
| D9 | Respaldo con redundancia de zona; RA-GRS descartado por no haber región pareada | Vigente |
| D10 | Brecha de recuperación ante desastre regional asumida como decisión del equipo | Vigente |
| D11 | WAF v2 condicionado a aprobación | PENDIENTE |
| D12 | Job de notificaciones: máximo 90 por ejecución, pausa 2.100 ms | Debe ajustarse (ver hallazgo H1) |

Hallazgo H1 (S10, 17-10-2026): con dominio administrado de ACS los límites son 5 correos por minuto y 10 por hora sin ampliación; los límites 30/min y 100/h corresponden a dominio propio verificado. El volumen simulado es de 2.434 correos al mes (promedio 111 por día hábil). En producción se requiere dominio propio de la embotelladora (SPF, DKIM, DMARC) y solicitud de aumento, o escalonar envíos.

Hallazgo H2: el App Service B1 de una instancia no tiene redundancia de zona ni autoescalado; es el punto débil de continuidad.

---

## 6. Costos (estimación v2, 10-10-2026, USD, pago por uso)

- Producción sin VPN: 493,45 USD/mes (5.921,36 USD/año). El WAF v2 representa cerca del 80 %.
- Producción con VPN S2S (solo si la BD de la embotelladora está en servidores propios): 650,40 USD/mes.
- Detalle en `docs/04_Estimacion_Costos_Azure_ChileCentral.md`.

---

## 7. Estado actual (al 05-11-2026)

- Suscripción de Azure: no disponible a la fecha de los últimos documentos (17-10-2026). Disponibilidad actual: PENDIENTE confirmar.
- Recursos desplegados en Azure: ninguno.
- Despliegue y pruebas P01-P37 en Azure: programados para la semana 11 (indicación del equipo, 17-10-2026).
- Entorno de trabajo: desde el 05-11-2026 el equipo trabaja en su máquina local con VS Code y Claude Code, con permisos para compilar y ejecutar herramientas. El sistema operativo y las versiones instaladas deben registrarse en la primera tarea (ver `PRIMERA_TAREA.md`); no suponerlos.
- Código .NET (API y Functions): escrito, nunca compilado. Primer paso: `dotnet restore`, `dotnet build`, `dotnet test` y registrar errores.
- Bicep: compilado y con lint limpio (0.48.1). Scripts bash: `bash -n` y ShellCheck 0.10.0 sin hallazgos. Plan de direccionamiento: 15/15 OK.
- Scripts SQL: revisados, no ejecutados.

### Estructura de repositorio esperada (según entregables S8-S15)

```
infra/main.bicep, infra/main.bicepparam
sql/01_esquema_cobranza.sql, sql/02_identidades_y_permisos.sql, ... (00 a 11)
src/Cobranza.Api/                    API .NET 10
src/<proyecto Functions>/            nombre PENDIENTE confirmar
scripts/desplegar.sh                 8 pasos
scripts/desplegar_sql.sh
scripts/verificar_despliegue.sh      pruebas P01-P32
scripts/validar_direccionamiento.py
s12_endurecer.sh                     ubicación PENDIENTE confirmar
docs/GUIA_DESPLIEGUE.md
docs/generar_topologia.py
```

Origen de este código: `Repositorio_Cobranza_Automatizada_S10-S15.zip` e `Implementacion_S10_Anexos.zip`, entregados en conversaciones anteriores. Este paquete NO incluye ese código; debe copiarse en la raíz del repositorio antes de empezar. Si un archivo listado no existe al abrir el repositorio, se informa y no se recrea por iniciativa propia.

---

## 8. Pendientes externos (bloqueantes o condicionantes)

1. Suscripción de Azure y permisos del operador (bloqueante para el despliegue).
2. Object ID y nombre del grupo administrador SQL en Entra ID (`grp-cobranza-sql-admin`).
3. Valores de Finanzas: días de preaviso y de mora, texto de los correos, canales de pago informados en el correo.
4. Dominio de correo propio de la embotelladora (SPF, DKIM, DMARC).
5. BD real de la embotelladora: motor, ubicación, vista y usuario de solo lectura (define si se requiere VPN S2S).
6. Aprobación del WAF v2 (opción B).
7. Número de usuarios simultáneos para la prueba de carga.
8. Tablas 3.2 (estaciones de trabajo) y 3.3 (versiones de herramientas) del documento de implementación.

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

---

## 10. Orquestación con agentes

La sesión principal de Claude Code es el orquestador técnico: lee este archivo, divide la tarea y delega en los agentes de `.claude/agents/`. Los subagentes no pueden invocar a otros subagentes, por lo que toda coordinación pasa por la sesión principal. El responsable humano que aprueba cada paso: PENDIENTE de definición por el equipo.

| Agente | Responsabilidad | Escribe en |
| --- | --- | --- |
| `arquitecto` | Coherencia del diseño, decisiones (ADR), impacto de cambios | `docs/adr/`, este archivo (solo secciones 5, 8, 9 con aprobación) |
| `devops` | Bicep, scripts de despliegue, CI/CD, configuración de App Service y Functions | `infra/`, `scripts/`, `.github/` |
| `desarrollador` | Código .NET 10 de la API y las Functions, pruebas unitarias | `src/`, `tests/` |
| `dba` | Esquema `cob`, procedimientos, permisos, respaldo y restauración | `sql/` |
| `seguridad` | NSG, Private Endpoints, Key Vault, Easy Auth, WAF, endurecimiento | `infra/` (seguridad), `scripts/s12_*`, `docs/seguridad/` |
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
