/* =============================================================================
   11_procedimientos_operacion.sql
   Proyecto APT Cobranza Automatizada - Evidencia S15 (Manual de Operacion TI)
   Procedimientos administrativos usados por el area de TI. Solo los ejecuta el
   grupo administrador de Entra ID (no se otorgan a las identidades de la API ni
   de la Function App). Cada ejecucion queda en la auditoria SQL de S12.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* Habilita el reenvio de un aviso que alcanzo 3 intentos fallidos
   (por ejemplo, despues de corregir el correo del cliente). */
CREATE OR ALTER PROCEDURE cob.sp_ReintentarNotificacion
    @FacturaId int,
    @TipoAviso varchar(15)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE cob.LogNotificacion
       SET Intentos = 0,
           Detalle = CONCAT(N'Reintento habilitado manualmente por ', ORIGINAL_LOGIN(), N' el ', CONVERT(nvarchar(20), SYSUTCDATETIME(), 120), N' UTC'),
           FechaActualizacion = SYSUTCDATETIME()
     WHERE FacturaId = @FacturaId AND TipoAviso = @TipoAviso AND EstadoEnvio = 'Fallido';

    IF @@ROWCOUNT = 0
        THROW 50040, N'No existe un aviso Fallido para esa factura y tipo.', 1;
END
GO

/* Cambio manual de estado de un cliente (decision de Finanzas).
   Si el nuevo estado es Regularizado, el trigger libera los pedidos retenidos. */
CREATE OR ALTER PROCEDURE cob.sp_CambiarEstadoClienteManual
    @Rut         varchar(20),
    @EstadoNuevo varchar(15)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @EstadoNuevo NOT IN ('AlDia', 'Moroso', 'Suspendido', 'Regularizado')
        THROW 50041, N'Estado no valido. Use AlDia, Moroso, Suspendido o Regularizado.', 1;

    DECLARE @ClienteId int, @EstadoActual varchar(15);
    SELECT @ClienteId = ClienteId, @EstadoActual = EstadoActual
    FROM cob.vw_EstadoActualCliente
    WHERE cob.fn_NormalizarRut(Rut) = cob.fn_NormalizarRut(@Rut);

    IF @ClienteId IS NULL
        THROW 50042, N'Cliente no encontrado.', 1;
    IF @EstadoActual = @EstadoNuevo
        THROW 50043, N'El cliente ya tiene ese estado.', 1;

    INSERT INTO cob.EstadoMorosidad (ClienteId, FechaCambio, EstadoAnterior, EstadoNuevo, OrigenCambio)
    VALUES (@ClienteId, SYSUTCDATETIME(), @EstadoActual, @EstadoNuevo, 'Manual');

    SELECT ea.Rut, ea.EstadoActual,
           (SELECT COUNT(*) FROM cob.Pedido WHERE ClienteId = @ClienteId AND Estado = 'Retenido') AS PedidosRetenidos
    FROM cob.vw_EstadoActualCliente AS ea WHERE ea.ClienteId = @ClienteId;
END
GO
