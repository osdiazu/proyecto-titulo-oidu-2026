/* =============================================================================
   06_consultas_api.sql
   Proyecto APT Cobranza Automatizada - Evidencia S11
   Procedimientos de solo lectura usados por la API interna (RF-06, RF-07).
   La identidad administrada del App Service solo recibe EXECUTE sobre estos
   procedimientos; no tiene SELECT directo sobre las tablas.

   Variables SQLCMD:
     UsuarioApi : usuario de BD de la identidad administrada del App Service (API).
   ============================================================================= */
SET NOCOUNT ON;
GO

/* Estado financiero de un cliente para la fuerza de ventas (RF-06).
   PuedeTomarPedido = 1 solo si el estado actual es AlDia o Regularizado
   (seccion 3.2 del informe: un cliente en mora tiene sus nuevas ordenes bloqueadas). */
CREATE OR ALTER PROCEDURE cob.sp_ConsultarEstadoCliente
    @Rut varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Hoy date = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Pacific SA Standard Time' AS date);
    DECLARE @RutNorm varchar(20) = cob.fn_NormalizarRut(@Rut);

    SELECT c.ClienteId, c.Rut, c.RazonSocial, c.Segmento, c.TipoConvenio,
           ea.EstadoActual, ea.FechaUltimoCambio,
           CAST(CASE WHEN ea.EstadoActual IN ('AlDia', 'Regularizado') THEN 1 ELSE 0 END AS bit) AS PuedeTomarPedido,
           ISNULL(f.FacturasPendientes, 0) AS FacturasPendientes,
           ISNULL(f.FacturasVencidas, 0)   AS FacturasVencidas,
           ISNULL(f.MontoPendiente, 0)     AS MontoPendiente,
           ISNULL(f.MontoVencido, 0)       AS MontoVencido,
           ISNULL(p.PedidosRetenidos, 0)   AS PedidosRetenidos
    FROM cob.Cliente AS c
    JOIN cob.vw_EstadoActualCliente AS ea ON ea.ClienteId = c.ClienteId
    OUTER APPLY (
        SELECT COUNT(*) AS FacturasPendientes,
               SUM(CASE WHEN fa.FechaVencimiento < @Hoy THEN 1 ELSE 0 END) AS FacturasVencidas,
               SUM(fa.MontoTotal) AS MontoPendiente,
               SUM(CASE WHEN fa.FechaVencimiento < @Hoy THEN fa.MontoTotal ELSE 0 END) AS MontoVencido
        FROM cob.Factura AS fa
        WHERE fa.ClienteId = c.ClienteId AND fa.Estado <> 'Pagada') AS f
    OUTER APPLY (
        SELECT COUNT(*) AS PedidosRetenidos
        FROM cob.Pedido AS pe
        WHERE pe.ClienteId = c.ClienteId AND pe.Estado = 'Retenido') AS p
    WHERE cob.fn_NormalizarRut(c.Rut) = @RutNorm;
END
GO

/* Pedidos de un cliente, opcionalmente filtrados por estado */
CREATE OR ALTER PROCEDURE cob.sp_ListarPedidosCliente
    @Rut    varchar(20),
    @Estado varchar(15) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RutNorm varchar(20) = cob.fn_NormalizarRut(@Rut);

    SELECT p.PedidoId, p.NumeroPedido, p.FechaCreacion, p.Estado, p.FechaLiberacion
    FROM cob.Pedido AS p
    JOIN cob.Cliente AS c ON c.ClienteId = p.ClienteId
    WHERE cob.fn_NormalizarRut(c.Rut) = @RutNorm
      AND (@Estado IS NULL OR p.Estado = @Estado)
    ORDER BY p.FechaCreacion DESC;
END
GO

/* Indicadores de cartera para el panel de Finanzas y Tesoreria (RF-07) */
CREATE OR ALTER PROCEDURE cob.sp_IndicadoresCartera
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Hoy date = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Pacific SA Standard Time' AS date);
    DECLARE @Hace30 datetime2(0) = DATEADD(day, -30, SYSUTCDATETIME());

    SELECT
        TotalClientes          = (SELECT COUNT(*) FROM cob.vw_EstadoActualCliente),
        ClientesAlDia          = (SELECT COUNT(*) FROM cob.vw_EstadoActualCliente WHERE EstadoActual = 'AlDia'),
        ClientesMorosos        = (SELECT COUNT(*) FROM cob.vw_EstadoActualCliente WHERE EstadoActual = 'Moroso'),
        ClientesSuspendidos    = (SELECT COUNT(*) FROM cob.vw_EstadoActualCliente WHERE EstadoActual = 'Suspendido'),
        ClientesRegularizados  = (SELECT COUNT(*) FROM cob.vw_EstadoActualCliente WHERE EstadoActual = 'Regularizado'),
        MontoPorVencer         = ISNULL((SELECT SUM(MontoTotal) FROM cob.Factura WHERE Estado <> 'Pagada' AND FechaVencimiento >= @Hoy), 0),
        MontoVencido1a30       = ISNULL((SELECT SUM(MontoTotal) FROM cob.Factura WHERE Estado <> 'Pagada' AND DATEDIFF(day, FechaVencimiento, @Hoy) BETWEEN 1 AND 30), 0),
        MontoVencido31a60      = ISNULL((SELECT SUM(MontoTotal) FROM cob.Factura WHERE Estado <> 'Pagada' AND DATEDIFF(day, FechaVencimiento, @Hoy) BETWEEN 31 AND 60), 0),
        MontoVencidoMas60      = ISNULL((SELECT SUM(MontoTotal) FROM cob.Factura WHERE Estado <> 'Pagada' AND DATEDIFF(day, FechaVencimiento, @Hoy) > 60), 0),
        PedidosRetenidos       = (SELECT COUNT(*) FROM cob.Pedido WHERE Estado = 'Retenido'),
        PedidosLiberados30d    = (SELECT COUNT(*) FROM cob.LogCambioPedido WHERE EstadoNuevo = 'Liberado' AND FechaCambio >= @Hace30),
        AvisosAceptados30d     = (SELECT COUNT(*) FROM cob.LogNotificacion WHERE EstadoEnvio = 'Aceptado' AND FechaRegistro >= @Hace30),
        AvisosFallidos30d      = (SELECT COUNT(*) FROM cob.LogNotificacion WHERE EstadoEnvio = 'Fallido'  AND FechaRegistro >= @Hace30),
        UltimaSincronizacion   = (SELECT MAX(FechaInicio) FROM cob.LogSincronizacion),
        EstadoUltimaSincronizacion = (SELECT TOP (1) Estado FROM cob.LogSincronizacion ORDER BY LogSincronizacionId DESC);
END
GO

/* Historial de ejecuciones del job de sincronizacion (operacion TI / Finanzas) */
CREATE OR ALTER PROCEDURE cob.sp_ListarSincronizaciones
    @Top int = 20
AS
BEGIN
    SET NOCOUNT ON;
    IF @Top NOT BETWEEN 1 AND 200 SET @Top = 20;

    SELECT TOP (@Top) LogSincronizacionId, FechaInicio, FechaFin, Estado,
           ClientesLeidos, ClientesActualizados, PedidosLiberados, Detalle
    FROM cob.LogSincronizacion
    ORDER BY LogSincronizacionId DESC;
END
GO

/* Prueba de conectividad usada por el endpoint /salud */
CREATE OR ALTER PROCEDURE cob.sp_Salud
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(1 AS bit) AS Ok, SYSUTCDATETIME() AS FechaUtc;
END
GO

GRANT EXECUTE ON OBJECT::cob.sp_ConsultarEstadoCliente  TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_ListarPedidosCliente    TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_IndicadoresCartera      TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_ListarSincronizaciones  TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_Salud                   TO [$(UsuarioApi)];
GO
