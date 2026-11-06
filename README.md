# Proyecto APT Cobranza Automatizada - Embotelladora del Pacífico S.A.

Repositorio de la plataforma: Azure Functions y API en .NET 10, scripts de Azure SQL,
plantillas Bicep y scripts de operación.

Estado al 06-11-2026: nada está desplegado en Azure (solo el grupo de recursos vacío
`rg-cobranza-apt` y el grupo Entra `grp-cobranza-sql-admin`). La autenticación de la API es
propia (usuario y contraseña con cookie para el panel, clave de API para Ventas), sin Easy Auth
ni roles de aplicación de Entra ID: ver `docs/adr/ADR-001-autenticacion-propia-sin-entra-usuarios.md`.
Región: `brazilsouth`.

## Estructura

| Ruta | Contenido | Evidencia |
| --- | --- | --- |
| `infra/main.bicep`, `infra/main.bicepparam` | Entorno base (reconstrucción S10) con los cambios de ADR-001: Data Protection, RBAC mínimo, condición ABAC, regla de transición 5.11, TDE explícito | S10 / ADR-001 |
| `infra/entorno.ejemplo.env` | Nombres de las variables de entorno (sin valores); copia local `infra/entorno.local.env` no versionada | — |
| `infra/modulos/seguridad_perimetral.bicep` | Private Endpoint de la API, WAF, auditoría, diagnósticos y alertas | S12 |
| `sql/00_verificar_esquema.sql` | Compara el esquema esperado con la base desplegada (solo lectura) | S10 |
| `sql/01_esquema_cobranza.sql`, `sql/02_identidades_y_permisos.sql` | Esquema `cob` y usuarios de las identidades administradas | S6-S8 / S10 |
| `sql/03_origen_simulado.sql` | Fuente simulada de solo lectura `origen_sim` | S10 |
| `sql/04_jobs_bitacoras.sql` | Bitácoras, alertas de vencimiento v2, registro de envíos (`Limitado`) | S10 |
| `sql/05_automatizacion_desbloqueo.sql` | Sincronización, trigger y liberación v2; bitácora de pedidos | S11 |
| `sql/06_consultas_api.sql` | Procedimientos de lectura de la API | S11 |
| `sql/07_pruebas_desbloqueo.sql` | Pruebas unitarias T-SQL (no dejan datos) | S11 |
| `sql/08_datos_prueba.sql` | Datos DEMO para demostración y pruebas E2E | S11 / S14 |
| `sql/09_verificacion_e2e.sql` | Reporte de estado para las pruebas E2E | S14 |
| `sql/10_marcador_rpo.sql` | Marcadores para medir el RPO en el simulacro | S14 |
| `sql/11_procedimientos_operacion.sql` | Procedimientos administrativos de TI | S15 |
| `sql/12_autenticacion.sql` | `cob.ClaveApi`, `cob.LogAcceso`, procedimientos de autenticación y administrativos | ADR-001 |
| `sql/13_pruebas_autenticacion.sql` | Pruebas T-SQL de autenticación (no dejan datos) | ADR-001 |
| `src/Cobranza.Comun` | Utilidades compartidas (RUT, formato de clave de API) | S10 |
| `src/Cobranza.Functions` | Jobs de sincronización y notificaciones | S10 |
| `src/Cobranza.Api` | API interna y panel web (autenticación propia) | S11 / ADR-001 |
| `src/Cobranza.Herramientas` | `hash-clave` y `nueva-clave-api` (solo las ejecuta un humano, SEG-H01) | ADR-001 |
| `tests/` | Pruebas unitarias de API y Functions | — |
| `scripts/desplegar.sh` | Guía ejecutable del despliegue completo (10 pasos con confirmación) | ADR-001 |
| `scripts/desplegar_sql.sh` | Scripts SQL en orden ADR-001 (08 solo con `--demo`) | ADR-001 |
| `scripts/comun_operacion.sh` | Funciones compartidas (se carga con `source`) | ADR-001 |
| `scripts/s10_configurar_jobs.sh` | Ajustes y publicación de la Function App | S10 |
| `scripts/s11_configurar_api.sh` | Ajustes de la API sin Easy Auth (no publica) | S11 / ADR-001 |
| `scripts/s11_alta_usuario.sh`, `s11_restablecer_clave.sh`, `s11_baja_usuario.sh` | Usuarios del panel (SEG-H01: solo un humano) | ADR-001 |
| `scripts/s11_alta_clave_api.sh`, `s11_revocar_clave_api.sh` | Claves de API (SEG-H01: solo un humano) | ADR-001 |
| `scripts/s12_*` | Endurecimiento, verificación y pruebas de red (responsable: `seguridad`) | S12 / ADR-001 |
| `scripts/s14_simulacro_pitr.sh`, `s14_revision_post_restauracion.sh` | Simulacro PITR y revisión obligatoria posterior a la restauración | S14 / ADR-001 |
| `scripts/s15_purgar_log_acceso.sh` | Purga mensual de `cob.LogAcceso` (90 días) | ADR-001 |
| `scripts/eliminar_entorno.sh` | Eliminación del grupo de recursos (solo un humano) | — |
| `pruebas/carga_api_k6.js`, `pruebas/consumidor_ventas_demo.sh` | Prueba de carga y consumidor DEMO `ventas-demo` | S14 / ADR-001 |
| `docs/*.kql` | Consultas de Log Analytics | S10 / S14 |

Retirados el 06-11-2026 por ADR-001 (siguen en el historial de git): `scripts/s11_registro_entra_id.sh`
e `infra/modulos/autenticacion_api.bicep` (Easy Auth).

## Procedimiento de despliegue

Requisitos en la estación del operador: Azure CLI, Bicep CLI 0.48.1 (`az bicep install --version v0.48.1`),
.NET SDK 10, go-sqlcmd (`winget install sqlcmd`), Python 3 (empaquetado zip) y Git Bash.
El operador debe ser miembro de `grp-cobranza-sql-admin` (sesión `az login`).

Toda acción en Azure requiere aprobación humana explícita (CLAUDE.md regla 5). Siempre `--mode Incremental`.

1. Compilar y probar: `dotnet build Cobranza.slnx -c Release` y `dotnet test Cobranza.slnx`.
2. Variables: copiar `infra/entorno.ejemplo.env` a `infra/entorno.local.env`, completar y cargar:
   `set -a; source infra/entorno.local.env; set +a`.
3. Ejecutar `scripts/desplegar.sh [--demo]` (pide confirmación en cada paso):
   1. Variables, herramientas y suscripción (`SUBSCRIPTION_ID_ESPERADA`).
   2. `az group create` si el grupo no existe.
   3. `bicep build`, `lint`, `build-params` (a carpeta temporal) y `what-if`.
   4. `az deployment group create` con `IP_OPERADOR` (abre la ventana del operador: SQL, Key Vault y la regla `operador-transicion` de la Web App).
   5. `scripts/desplegar_sql.sh`: 01, 02, 03, 04, 05, 06, 12, 11, 00, 07 (10/10), 13 y 08 solo con `--demo`.
   6. Publicación: `dotnet publish` + `az functionapp deploy` y, solo con `APROBACION_QA=<informe qa>` (ADR-001 5.11), `az webapp deploy`. El SCM se abre con `IP_PUBLICACION_SCM` mediante `s12_endurecer.sh` y se cierra al terminar.
   7. `scripts/s10_configurar_jobs.sh` (sin publicar) y `scripts/s11_configurar_api.sh`.
   8. `scripts/s12_endurecer.sh` (obligatorio después de cada despliegue de `main`, regla 7).
   9. Verificación de `https://<api>/salud`.
   10. Cierre de la ventana: despliegue con `IP_OPERADOR` vacío y `s12_endurecer.sh` otra vez; verificar con `scripts/s12_verificar_seguridad.sh`.
4. Altas de usuarios y claves de API (ADR-001 5.9): las ejecuta un integrante humano, en su propia terminal y fuera de Claude Code, con la ventana abierta (`s11_alta_usuario.sh`, `s11_alta_clave_api.sh`, etc.). Registrar la ventana con `docs/seguridad/plantilla_ventana_operador.md`.
5. Pruebas S14: `sql/09`, `sql/10`, `scripts/s14_simulacro_pitr.sh` seguido de `scripts/s14_revision_post_restauracion.sh`, `pruebas/carga_api_k6.js`.

Regla de transición (ADR-001 5.11): mientras no exista un informe de `qa` APROBADO de la implementación,
la API no se publica y la Web App queda con entrada por defecto `Deny` (solo la IP del operador durante la ventana).
