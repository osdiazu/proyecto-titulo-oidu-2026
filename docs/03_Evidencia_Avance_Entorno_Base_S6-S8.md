# Evidencia de Avance: Prototipeo y Despliegue de Entorno Base (S6-S8)
Proyecto APT Cobranza Automatizada - Embotelladora del Pacífico S.A. - Responsable: Oscar Díaz Ulloa - 30 de septiembre de 2026

Entregables enviados en la conversación: Evidencia_Avance_Entorno_Base_S6-S8.docx (11 páginas, 2 figuras) y Entorno_Base_IaC_SQL_S6-S8.zip (infra/main.bicep, infra/main.bicepparam, sql/01_esquema_cobranza.sql, sql/02_identidades_y_permisos.sql).

## Estado real
Sin suscripción de Azure al cierre de S8: no hay recursos creados ni capturas. Se completó la preparación: plantilla Bicep validada (bicep build y lint sin errores ni advertencias, Bicep CLI 0.47.16), scripts SQL revisados manualmente (no ejecutados), diseño del job de notificaciones. Tres parámetros quedan PENDIENTE: Object ID y nombre del grupo admin SQL en Entra ID, y ubicación de datos de ACS.

## Decisiones y correcciones respecto de S1-S6
- Región candidata Chile Central (GA, 3 zonas, sin región pareada); validar servicios por región antes de crear el grupo.
- Respaldo: RA-GRS de S1-S6 no queda garantizado sin región pareada; plantilla usa redundancia de zona (parámetro). PITR 35 días; LTR 8 semanales y 12 mensuales (propuesta a validar con Finanzas). Desastre regional: evaluar replicación a otra región en S12-S14.
- Jobs en el mismo plan App Service Linux (B1) que la API, porque el consumo clásico no tiene VNet y Flex Consumption no está confirmado en Chile Central.
- .NET 10: Functions aislado GA (soporte hasta 14-11-2028); App Service DOTNETCORE|10.0.
- ACS Email: límites iniciales 30/min y 100/h; aumentos solo con dominio propio verificado. Dev con dominio administrado; producción con dominio de la embotelladora (SPF, DKIM, DMARC). Correos sin enlace de pago.

## Entorno base (plantilla)
VNet 10.20.0.0/16 con snet-app 10.20.1.0/24 (delegada) y snet-pe 10.20.2.0/24; NSG nsg-app y nsg-pe (permitir 1433 y 443 desde snet-app, denegar resto). Azure SQL (solo Entra ID, sin acceso público, Modern_Spanish_CI_AS, S0), Key Vault (RBAC, purga protegida), Storage ZRS sin clave compartida, 5 Private Endpoints y zonas DNS privadas, ACS Email, Log Analytics + App Insights, identidades administradas con RBAC mínimo. Sincronización cada 15 min y avisos días hábiles 12:00 UTC (propuestas a validar).

## Base de datos
Esquema cob: Cliente, Factura (vencimiento calculado), EstadoMorosidad, Pedido, LogNotificacion (único por factura y tipo de aviso), LogSincronizacion, UsuarioInterno; tipo cob.ListaRut; sp_SincronizarClientesRegularizados, tr_EstadoMorosidad_Liberar, sp_LiberarPedidosRetenidos, sp_GenerarAlertasVencimiento. Escritura solo vía procedimientos.

## Pendientes
Suscripción (bloqueante); motor, vista y usuario de solo lectura de la BD de la embotelladora; días de preaviso, texto y canales de pago (Finanzas); diferencia de semanas de la actividad 6 entre Plan (S8-S11) y Gantt (S9-S11).
