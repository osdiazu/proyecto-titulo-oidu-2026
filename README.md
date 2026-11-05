# Proyecto APT Cobranza Automatizada - Embotelladora del Pacífico S.A.

Repositorio de la plataforma: Azure Functions y API en .NET 10, scripts de Azure SQL,
plantillas Bicep y scripts de operación. El entorno base (main.bicep y scripts 01/02)
corresponde a la evidencia S6-S8 y debe agregarse a este repositorio en `infra/` y `sql/`.

## Estructura

| Ruta | Contenido | Evidencia |
| --- | --- | --- |
| `sql/00_verificar_esquema.sql` | Compara el esquema esperado con la base desplegada (solo lectura) | S10 |
| `sql/03_origen_simulado.sql` | Fuente simulada de solo lectura `origen_sim` | S10 |
| `sql/04_jobs_bitacoras.sql` | Bitácoras, alertas de vencimiento v2, registro de envíos | S10 |
| `sql/05_automatizacion_desbloqueo.sql` | Sincronización, trigger y liberación v2; bitácora de pedidos | S11 |
| `sql/06_consultas_api.sql` | Procedimientos de lectura de la API | S11 |
| `sql/07_pruebas_desbloqueo.sql` | Pruebas unitarias T-SQL (no dejan datos) | S11 |
| `sql/08_datos_prueba.sql` | Datos DEMO para demostración y pruebas E2E | S11 / S14 |
| `sql/09_verificacion_e2e.sql` | Reporte de estado para las pruebas E2E | S14 |
| `sql/10_marcador_rpo.sql` | Marcadores para medir el RPO en el simulacro | S14 |
| `sql/11_procedimientos_operacion.sql` | Procedimientos administrativos de TI | S15 |
| `src/Cobranza.Comun` | Utilidad de RUT compartida | S10 |
| `src/Cobranza.Functions` | Jobs de sincronización y notificaciones | S10 |
| `src/Cobranza.Api` | API interna y panel web | S11 |
| `infra/modulos/autenticacion_api.bicep` | Easy Auth v2 con Entra ID | S11 / S12 |
| `infra/modulos/seguridad_perimetral.bicep` | Private Endpoint de la API, WAF, auditoría, diagnósticos y alertas | S12 |
| `scripts/` | Configuración, endurecimiento, verificación, simulacro | S10 a S14 |
| `pruebas/carga_api_k6.js` | Prueba de carga de la API | S14 |
| `docs/*.kql` | Consultas de Log Analytics | S10 / S14 |

## Orden de despliegue

1. `dotnet build Cobranza.slnx -c Release` (no se compiló en el entorno de redacción).
2. SQL en modo SQLCMD: 00 (sin hallazgos) -> 03, 04, 05 (`UsuarioFunctionApp`) -> 06 (`UsuarioApi`) -> 07 -> 11.
3. `scripts/s10_configurar_jobs.sh` (publica la Function App).
4. `scripts/s11_registro_entra_id.sh`, `scripts/s11_configurar_api.sh`, `infra/modulos/autenticacion_api.bicep`.
5. `infra/modulos/seguridad_perimetral.bicep` y `scripts/s12_endurecer.sh`; verificar con `scripts/s12_verificar_seguridad.sh` y `scripts/s12_pruebas_red.sh`.
6. Pruebas S14: `sql/08`, `sql/09`, `sql/10`, `scripts/s14_simulacro_pitr.sh`, `pruebas/carga_api_k6.js`.

Validación realizada al redactar: plantillas Bicep compiladas y revisadas (linter) con Bicep CLI 0.48.1 sin errores ni advertencias;
sintaxis de scripts bash (`bash -n`) y JavaScript (`node --check`). El código .NET y los scripts SQL no se compilaron ni ejecutaron.
