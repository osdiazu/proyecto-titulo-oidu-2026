# Evidencias S10 a S15 - Resumen y estado
Proyecto APT Cobranza Automatizada - generadas el 15-10-2026 a partir del Avance Informe Final V1.2 (Semana 9). Actualizado el 15-10-2026 10:30.

## Estado real (corrección del usuario, 15-10-2026)
- NO hay nada desplegado en Azure. El supuesto inicial de "entorno base desplegado" era incorrecto.
- Se entregó la infraestructura completa como código en S10: infra/main.bicep + main.bicepparam (27 recursos), sql/01_esquema_cobranza.sql, sql/02_identidades_y_permisos.sql, scripts/desplegar_sql.sh y docs/GUIA_DESPLIEGUE.md. La evidencia S10 se actualizó en consecuencia.
- Nada ejecutado aún: todos los resultados quedan PENDIENTE.
- BD de la embotelladora no definida: fuente simulada origen_sim.vw_ClientesRegularizados (Rut, FechaRegularizacion).
- Código .NET no compilado (sin SDK en el entorno); Bicep compilado y revisado con CLI 0.48.1 sin errores ni advertencias.

## main.bicep (nombres y configuración)
- Grupo sugerido rg-cobranza-apt, región chilecentral, prefijo cobranza + sufijo uniqueString(6).
- VNet vnet-cobranza 10.20.0.0/16; snet-app 10.20.1.0/24 (delegada) con nsg-app; snet-pe 10.20.2.0/24 con nsg-pe (1433 y 443 desde snet-app, deny VNet prioridad 4000).
- SQL S0 sqldb-cobranza, Modern_Spanish_CI_AS, solo Entra ID (grupo grp-cobranza-sql-admin), TLS 1.2, PITR 35 días, LTR P8W/P12M, TDE, respaldo Zone.
- Parámetro ipOperador abre temporalmente SQL (regla de firewall) y Key Vault a la IP del operador; vacío = cerrado. operadorObjectId recibe Key Vault Secrets Officer.
- Key Vault RBAC + purga; secreto acs-connection-string creado por la plantilla (plano de control).
- Storage ZRS sin clave compartida; 5 PE (sql, kv, blob, queue, table) con zonas DNS.
- ACS + Email Service con AzureManagedDomain, ubicación de datos United States; remitente DoNotReply@<dominio administrado> cargado automáticamente.
- Plan Linux B1; Web App DOTNETCORE|10.0 (salud /salud); Function App DOTNET-ISOLATED|10.0 con todos los ajustes Cobranza__ (valores de Finanzas como parámetros vacíos).
- Advertencia: volver a desplegar main restablece ajustes y configuración del sitio; reaplicar s12_endurecer.sh después.

## Orden de SQL (scripts/desplegar_sql.sh)
01, 02 (UsuarioFunctionApp, UsuarioApi), 03, 04, 05 (UsuarioFunctionApp), 06 (UsuarioApi), 11, 00 (verificación), 07 (pruebas 10/10). 08 datos DEMO al probar.

## Entregables
- S10 Evidencia_S10_Jobs_Sincronizacion_Notificaciones.docx + Codigo_Evidencia_S10.zip (incluye main.bicep, 01, 02, guía)
- S11 Evidencia_S11_Desbloqueo_API_Plataforma.docx + Codigo_Evidencia_S11.zip (API en src/Cobranza.Api)
- S12 Evidencia_S12_Seguridad_Perimetral.docx + Codigo_Evidencia_S12.zip
- S14 Evidencia_S14_Pruebas_E2E_Continuidad_TI.docx + Codigo_Evidencia_S14.zip
- S15 Manual_Operacion_TI, Manual_Usuario_Ventas_Finanzas, Complemento_Informe_Final, presentación de defensa (artifact Slides)
- Repositorio_Cobranza_Automatizada_S10-S15.zip (todo)

## Decisiones tomadas en estas evidencias
- Notificaciones cada hora 12-17 UTC días hábiles; máx. 90 por ejecución, pausa 2.100 ms.
- Tipos de aviso Preaviso, Vencimiento, Mora1, Mora2; días sin valor por defecto (PENDIENTE Finanzas).
- Avisos de mora no se envían si el cliente quedó Regularizado después del vencimiento (validar).
- Regularización desde Moroso o Suspendido (validar; RF-04 dice solo Suspendido).
- PuedeTomarPedido solo AlDia y Regularizado.
- cob.LogCambioPedido sin FK (OUTPUT INTO); sp_getapplock.
- ACS por cadena de conexión en Key Vault.
- Easy Auth v2 + roles Ventas.Consulta, Finanzas.Consulta, TI.Operacion; Entra ID Free = asignación por usuario.
- WAF condicionado (USD 400,15/mes); brecha DR regional como decisión del equipo.

## Inconsistencias del Informe V1.2 (detalle en S15_Complemento_Informe_Final)
Título provisorio; fecha; roles 4.2.A vs 9 vs Acta; nombre Dariel; "tiempo real"; RA-GRS vs ZRS; LTR/Azure Backup; presupuesto 120-250 vs 493,45; Functions consumo vs B1; SMTP vs ACS; competencias sección 7; semanas 6.1/6.4; evidencia final con links de pago; secciones 2, 11 y 12 vacías.

## Pendientes externos
Valores de Finanzas, dominio de correo propio, BD real de la embotelladora, aprobación WAF, usuarios simultáneos para prueba de carga.
