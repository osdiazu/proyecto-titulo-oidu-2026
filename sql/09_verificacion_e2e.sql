/* =============================================================================
   09_verificacion_e2e.sql
   Proyecto APT Cobranza Automatizada - Evidencia S14
   Reporte de solo lectura del estado de los datos DEMO (08_datos_prueba.sql).
   Ejecutar antes y despues de cada paso de las pruebas E2E y adjuntar el resultado.
   ============================================================================= */
SET NOCOUNT ON;

PRINT '--- 1. Estado actual de clientes DEMO';
SELECT c.Rut, c.RazonSocial, ea.EstadoActual, ea.FechaUltimoCambio
FROM cob.Cliente AS c JOIN cob.vw_EstadoActualCliente AS ea ON ea.ClienteId = c.ClienteId
WHERE c.RazonSocial LIKE 'DEMO %' ORDER BY c.Rut;

PRINT '--- 2. Historial de estados DEMO';
SELECT c.Rut, em.FechaCambio, em.EstadoAnterior, em.EstadoNuevo, em.OrigenCambio
FROM cob.EstadoMorosidad AS em JOIN cob.Cliente AS c ON c.ClienteId = em.ClienteId
WHERE c.RazonSocial LIKE 'DEMO %' ORDER BY c.Rut, em.FechaCambio;

PRINT '--- 3. Pedidos DEMO';
SELECT c.Rut, p.NumeroPedido, p.Estado, p.FechaLiberacion
FROM cob.Pedido AS p JOIN cob.Cliente AS c ON c.ClienteId = p.ClienteId
WHERE c.RazonSocial LIKE 'DEMO %' ORDER BY p.NumeroPedido;

PRINT '--- 4. Bitacora de cambios de pedidos DEMO';
SELECT c.Rut, l.PedidoId, l.EstadoAnterior, l.EstadoNuevo, l.OrigenCambio, l.FechaCambio
FROM cob.LogCambioPedido AS l JOIN cob.Cliente AS c ON c.ClienteId = l.ClienteId
WHERE c.RazonSocial LIKE 'DEMO %' ORDER BY l.FechaCambio;

PRINT '--- 5. Notificaciones DEMO';
SELECT c.Rut, f.NumeroFactura, n.TipoAviso, n.EstadoEnvio, n.Intentos, n.IdOperacionAcs, n.FechaRegistro, n.Detalle
FROM cob.LogNotificacion AS n
JOIN cob.Factura AS f ON f.FacturaId = n.FacturaId
JOIN cob.Cliente AS c ON c.ClienteId = n.ClienteId
WHERE c.RazonSocial LIKE 'DEMO %' ORDER BY n.FechaRegistro;

PRINT '--- 6. Ultimas 10 sincronizaciones';
SELECT TOP (10) LogSincronizacionId, FechaInicio, FechaFin, DATEDIFF(second, FechaInicio, FechaFin) AS DuracionSeg,
       Estado, ClientesLeidos, ClientesActualizados, PedidosLiberados, Detalle
FROM cob.LogSincronizacion ORDER BY LogSincronizacionId DESC;

PRINT '--- 7. KPI desbloqueo: pedidos retenidos de clientes regularizados (debe ser 0 filas)';
SELECT ea.Rut, p.NumeroPedido
FROM cob.vw_EstadoActualCliente AS ea JOIN cob.Pedido AS p ON p.ClienteId = ea.ClienteId
WHERE ea.EstadoActual = 'Regularizado' AND p.Estado = 'Retenido';

PRINT '--- 8. Fuente simulada';
SELECT Rut, Regularizado, FechaRegularizacion, FechaActualizacion
FROM origen_sim.ClienteRegularizacion ORDER BY Rut;
