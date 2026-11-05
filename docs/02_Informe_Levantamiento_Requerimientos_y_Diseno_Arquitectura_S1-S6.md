# Informe de Levantamiento de Requerimientos y Diseño de Arquitectura
## Proyecto APT: Cobranza Automatizada — Embotelladora del Pacífico S.A.
Evidencia de Avance — Fase 1 y 2 (Semanas 1 a 6) — Asignatura Portafolio de Título

- Carrera: Ingeniería en Infraestructura y Plataformas Tecnológicas — Sede Antonio Varas
- Integrantes: José Cartes Mardones, Oscar Díaz Ulloa, Arnaldo Muñoz González, Germán Muñoz Manríquez, Dariel Zúñiga
- Responsable de esta evidencia: Oscar Díaz Ulloa (Especialista en Infraestructura y Servidores)
- Fecha: 15 de septiembre de 2026
- Entregable descargable: Informe_Levantamiento_Requerimientos_y_Diseno_Arquitectura_S1-S6.docx (enviado en la conversación), con 3 figuras: diagrama de arquitectura con iconografía oficial de Microsoft Azure, diagrama de flujo del proceso y modelo entidad-relación.

## 1. Introducción

Evidencia de avance del Proyecto de Título "Cobranza Automatizada" para Embotelladora del Pacífico S.A. (Buin, Región Metropolitana), que consolida el levantamiento de requerimientos y el diseño de arquitectura correspondientes a las semanas 1 a 6 de la Carta Gantt (cierre de Fase 1 e inicio de Fase 2). El proyecto automatiza la cobranza de facturas a crédito (30/60 días) de clientes B2B mediante notificaciones automáticas por correo y liberación automática de pedidos retenidos cuando la propia embotelladora registra al cliente como regularizado en su base de datos.

## 2. Alcance de esta evidencia (semanas 1 a 6)

| Actividad | Semanas | Responsable |
| --- | --- | --- |
| Levantamiento de requerimientos y planificación general | S1-S3 | José Cartes M. |
| Diseño de arquitectura de integración y conectividad API | S3-S5 | Oscar Díaz U. |
| Modelado de base de datos y políticas de respaldo | S4-S6 | Arnaldo Muñoz G. |
| Despliegue y configuración de servidores backend (inicio) | S6-S8 | Oscar Díaz U. |

Quedan fuera de esta evidencia: módulo de notificaciones/correo (S7-S10), automatización de desbloqueo de pedidos (S8-S11), seguridad perimetral (S10-S12) y pruebas integrales (S12-S14).

## 3. Requerimientos funcionales

RF-01 Envío automático de notificaciones por correo antes y al vencimiento de facturas a 30/60 días. RF-02 Sincronización periódica de solo lectura contra la BD de la embotelladora para detectar clientes regularizados. RF-03 Actualización automática del estado de mora del cliente al detectarse regularización. RF-04 Liberación automática de pedidos retenidos al pasar de "Suspendido" a "Regularizado". RF-05 Registro de logs de notificaciones, sincronizaciones y cambios de estado para auditoría. RF-06 API interna para que Ventas consulte el estado financiero de un cliente. RF-07 Panel para Finanzas y Tesorería con estadísticas de morosidad y recaudación (sin procesar pagos). RF-08 Soporte de actualización periódica de clientes regularizados desde la BD de la embotelladora.

## 4. Requerimientos no funcionales

RNF-01 Disponibilidad objetivo ≥99% (SLA de servicios PaaS Azure). RNF-02 Cifrado en tránsito (TLS 1.2+) y en reposo (TDE); credenciales en Azure Key Vault. RNF-03 Escalabilidad de los componentes de cómputo sin afectar continuidad. RNF-04 Ventana de ejecución acordada para sincronización y notificaciones. RNF-05 Auditabilidad de todo cambio de estado (fecha, origen, valores anterior/nuevo). RNF-06 Cumplimiento de RPO/RTO definidos en la sección de respaldo. RNF-07 Arquitectura por capas con código versionado. RNF-08 Integración de solo lectura con la BD externa de la embotelladora.

## 5. Diseño de arquitectura (Microsoft Azure)

Decisiones técnicas confirmadas: infraestructura 100% en Microsoft Azure; base de datos Azure SQL Database (SQL Server PaaS); backend en .NET 10 sobre Azure App Service; envío de correos con Azure Communication Services (Email); sin integración de pasarela de pago — la propia Embotelladora del Pacífico S.A. registra en su BD a los clientes ya regularizados, y el sistema del proyecto solo la consulta.

Componentes: Azure App Service (.NET 10, API interna de Cobranza), Azure Functions con Timer Trigger (job de sincronización de regularizados y job de notificaciones de vencimiento), Azure SQL Database (clientes, facturas, morosidad, pedidos, logs), BD externa de la embotelladora (consulta de solo lectura), Azure Communication Services (Email), Azure Key Vault (secretos y credenciales), Azure Monitor + Application Insights (observabilidad), Azure Virtual Network + NSG + Private Endpoints (segmentación de red), Microsoft Entra ID (autenticación de Finanzas y Ventas).

Flujo: (1) el job de sincronización consulta periódicamente la BD de la embotelladora; (2) al detectar un cliente regularizado, actualiza el estado de morosidad y libera los pedidos retenidos; (3) en paralelo, el job de notificaciones detecta facturas por vencer/vencidas y solicita el envío de correo vía Azure Communication Services; (4) la API interna entrega a Ventas el estado de clientes y a Finanzas un panel de estadísticas; (5) todo evento queda registrado en logs de auditoría.

Consideraciones preliminares de seguridad (la configuración detallada corresponde a semanas 10-12): segmentación con VNet/NSG, Private Endpoints para la base de datos, secretos centralizados en Key Vault, autenticación con Entra ID.

El diagrama de arquitectura (Figura 1, con iconografía oficial de Microsoft Azure Public Service Icons V24) y el diagrama de flujo del proceso completo (Figura 2, con la lógica de decisión desde la emisión de la factura hasta la liberación del pedido) están incluidos en el documento .docx entregado.

## 6. Modelo de datos relacional (Azure SQL Database)

Entidades principales: CLIENTE (ClienteId PK, RUT, RazonSocial, Segmento, Email, Telefono, TipoConvenio 30/60 días, FechaRegistro), FACTURA (FacturaId PK, ClienteId FK, NumeroFactura, MontoTotal, FechaEmision, FechaVencimiento, PlazoDias, Estado), ESTADO_MOROSIDAD (EstadoId PK, ClienteId FK, FechaCambio, EstadoAnterior, EstadoNuevo [AlDia/Moroso/Suspendido/Regularizado], OrigenCambio), PEDIDO (PedidoId PK, ClienteId FK, NumeroPedido, FechaCreacion, Estado [Retenido/Liberado/Despachado], FechaLiberacion), LOG_NOTIFICACION y LOG_SINCRONIZACION (bitácoras de auditoría), USUARIO_INTERNO (acceso de Finanzas/Ventas/Admin).

Relaciones: Cliente 1:N Factura, Cliente 1:N EstadoMorosidad, Cliente 1:N Pedido, Factura 1:N LogNotificacion.

Lógica de automatización propuesta: trigger sobre ESTADO_MOROSIDAD que invoca sp_LiberarPedidosRetenidos al pasar a "Regularizado"; sp_SincronizarClientesRegularizados ejecutado por el job de sincronización; sp_GenerarAlertasVencimiento para identificar facturas próximas a vencer.

El diagrama entidad-relación completo está incluido en el documento .docx entregado (Figura 3).

## 7. Políticas de respaldo y recuperación (Azure SQL Database)

Backups automáticos nativos (completos semanales, diferenciales cada 12 h, log cada 5-10 min); restauración a un punto en el tiempo (PITR) con retención de 35 días; retención de largo plazo (LTR) adicional vía Azure Backup; redundancia geográfica (RA-GRS); objetivos RPO <15 minutos y RTO <4 horas; cifrado TDE en reposo y TLS 1.2+ en tránsito; simulacros de restauración planificados para la etapa de pruebas integrales (semanas 12-14).

## 8. Estado de avance y próximos pasos

Al cierre de la semana 6 se completó el levantamiento de requerimientos, el diseño de arquitectura en Azure y el modelo de datos con sus políticas de respaldo, conforme al Plan de Trabajo y la Carta Gantt. Próximos pasos: despliegue de servidores backend en App Service (S6-S8, Oscar Díaz U.), desarrollo del job de sincronización y módulo de notificaciones (S7-S10, Germán Muñoz M.), automatización del desbloqueo de pedidos (S8-S11, Arnaldo Muñoz G.), y configuración de seguridad perimetral (S10-S12, Dariel Zúñiga).

## 9. Nota técnica sobre los diagramas

El diagrama de arquitectura usa íconos oficiales del paquete Microsoft Azure Public Service Icons V24, provistos directamente por el usuario (Oscar Díaz Ulloa) desde su equipo, ya que este entorno de trabajo no tiene salida a internet hacia los repositorios públicos donde se distribuyen. Se descartó reutilizar un archivo .html de referencia (exportación de draw.io) porque correspondía a una plantilla genérica de "Azure Enterprise Landing Zone" de otro proyecto, no a los componentes específicos de esta arquitectura de Cobranza Automatizada.
