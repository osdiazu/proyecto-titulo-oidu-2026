/* =============================================================================
   05_automatizacion_desbloqueo.sql
   Proyecto APT Cobranza Automatizada - Evidencia S11
   Actividad 6 de la Carta Gantt: automatizacion de actualizacion de estados y
   desbloqueo de pedidos en la base de datos.

   Reemplaza (CREATE OR ALTER) los objetos creados en S6-S8 con la version 2:
     - cob.LogCambioPedido               (nueva: trazabilidad de pedidos, RNF-05)
     - cob.sp_LiberarPedidosRetenidos    (v2: valida estado, registra bitacora, devuelve conteo)
     - cob.tr_EstadoMorosidad_Liberar    (v2: multiples filas, solo cambios a Regularizado)
     - cob.sp_SincronizarClientesRegularizados (v2: contrato usado por el job de S10)

   Mejoras respecto de v1 (S6-S8):
     - Control de concurrencia: sp_getapplock impide dos sincronizaciones simultaneas.
     - Idempotencia: solo cambia clientes en estado Moroso o Suspendido; repetir la
       ejecucion con la misma lista no genera cambios.
     - Normalizacion de RUT (sin puntos, sin guion, mayusculas) en ambos lados.
     - Cada pedido liberado queda registrado con estado anterior/nuevo, origen y fecha.

   Requisitos: 00 sin hallazgos; 04_jobs_bitacoras.sql ejecutado (vista vw_EstadoActualCliente).
   Variables SQLCMD: UsuarioFunctionApp.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   1. Bitacora de cambios de pedido.
      Sin claves foraneas ni CHECK: es destino de OUTPUT INTO (restriccion de SQL Server).
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'cob.LogCambioPedido', N'U') IS NULL
BEGIN
    CREATE TABLE cob.LogCambioPedido (
        LogCambioPedidoId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_LogCambioPedido PRIMARY KEY,
        PedidoId          int          NOT NULL,
        ClienteId         int          NOT NULL,
        EstadoAnterior    varchar(15)  NOT NULL,
        EstadoNuevo       varchar(15)  NOT NULL,
        OrigenCambio      varchar(30)  NOT NULL,
        FechaCambio       datetime2(0) NOT NULL
    );
    CREATE INDEX IX_LogCambioPedido_Cliente ON cob.LogCambioPedido (ClienteId, FechaCambio);
END
GO

/* Funcion de normalizacion de RUT usada en comparaciones */
CREATE OR ALTER FUNCTION cob.fn_NormalizarRut (@Rut varchar(20))
RETURNS varchar(20)
WITH SCHEMABINDING
AS
BEGIN
    RETURN UPPER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Rut)), '.', ''), '-', ''), ' ', ''));
END
GO

/* ---------------------------------------------------------------------------
   2. Liberacion de pedidos retenidos de un cliente
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE cob.sp_LiberarPedidosRetenidos
    @ClienteId        int,
    @OrigenCambio     varchar(30) = 'Manual',
    @PedidosLiberados int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Regla de seguridad: no se liberan pedidos de un cliente que sigue en mora */
    IF NOT EXISTS (SELECT 1 FROM cob.vw_EstadoActualCliente
                   WHERE ClienteId = @ClienteId AND EstadoActual IN ('Regularizado', 'AlDia'))
        THROW 50020, N'El cliente no esta Regularizado ni AlDia; no se liberan pedidos.', 1;

    DECLARE @Ahora datetime2(0) = SYSUTCDATETIME();

    UPDATE p
       SET p.Estado = 'Liberado',
           p.FechaLiberacion = @Ahora
    OUTPUT inserted.PedidoId, inserted.ClienteId, deleted.Estado, inserted.Estado, @OrigenCambio, @Ahora
      INTO cob.LogCambioPedido (PedidoId, ClienteId, EstadoAnterior, EstadoNuevo, OrigenCambio, FechaCambio)
    FROM cob.Pedido AS p WITH (UPDLOCK, ROWLOCK)
    WHERE p.ClienteId = @ClienteId
      AND p.Estado = 'Retenido';

    SET @PedidosLiberados = @@ROWCOUNT;
END
GO

/* ---------------------------------------------------------------------------
   3. Trigger: al registrar un cambio a Regularizado, libera los pedidos retenidos.
      Procesa inserciones de multiples filas (un cliente a la vez).
   --------------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER cob.tr_EstadoMorosidad_Liberar
ON cob.EstadoMorosidad
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted
                   WHERE EstadoNuevo = 'Regularizado' AND ISNULL(EstadoAnterior, '') <> 'Regularizado')
        RETURN;

    DECLARE @ClienteId int, @Liberados int;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT ClienteId FROM inserted
        WHERE EstadoNuevo = 'Regularizado' AND ISNULL(EstadoAnterior, '') <> 'Regularizado';

    OPEN cur;
    FETCH NEXT FROM cur INTO @ClienteId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC cob.sp_LiberarPedidosRetenidos
             @ClienteId = @ClienteId,
             @OrigenCambio = 'TriggerRegularizacion',
             @PedidosLiberados = @Liberados OUTPUT;
        FETCH NEXT FROM cur INTO @ClienteId;
    END
    CLOSE cur;
    DEALLOCATE cur;
END
GO

/* ---------------------------------------------------------------------------
   4. Sincronizacion de clientes regularizados (contrato del job de S10)
      Entrada : @Ruts (cob.ListaRut, una columna con el RUT) y el Id de bitacora.
      Salida  : una fila con RutsRecibidos, RutsNoEncontrados, ClientesActualizados,
                PedidosLiberados.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE cob.sp_SincronizarClientesRegularizados
    @Ruts                cob.ListaRut READONLY,
    @LogSincronizacionId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Entrada TABLE (RutOriginal varchar(20) NULL);
    INSERT INTO @Entrada (RutOriginal) SELECT * FROM @Ruts;   -- cob.ListaRut tiene una sola columna (verificado en 00)

    DECLARE @Normalizados TABLE (RutNorm varchar(20) NOT NULL PRIMARY KEY);
    INSERT INTO @Normalizados (RutNorm)
    SELECT DISTINCT cob.fn_NormalizarRut(RutOriginal)
    FROM @Entrada
    WHERE NULLIF(LTRIM(RTRIM(RutOriginal)), '') IS NOT NULL;

    DECLARE @Cambios TABLE (ClienteId int NOT NULL PRIMARY KEY, EstadoAnterior varchar(15) NOT NULL);
    DECLARE @RetenidosAntes int, @RetenidosDespues int, @Bloqueo int;

    BEGIN TRAN;
        EXEC @Bloqueo = sp_getapplock @Resource = N'cob.SincronizacionRegularizados',
                                      @LockMode = N'Exclusive', @LockOwner = N'Transaction',
                                      @LockTimeout = 30000;
        IF @Bloqueo < 0
            THROW 50030, N'Otra sincronizacion esta en curso; se reintentara en la siguiente ejecucion.', 1;

        INSERT INTO @Cambios (ClienteId, EstadoAnterior)
        SELECT ea.ClienteId, ea.EstadoActual
        FROM cob.vw_EstadoActualCliente AS ea
        JOIN @Normalizados AS n ON n.RutNorm = cob.fn_NormalizarRut(ea.Rut)
        WHERE ea.EstadoActual IN ('Moroso', 'Suspendido');

        SELECT @RetenidosAntes = COUNT(*)
        FROM cob.Pedido AS p JOIN @Cambios AS c ON c.ClienteId = p.ClienteId
        WHERE p.Estado = 'Retenido';

        /* El trigger tr_EstadoMorosidad_Liberar libera los pedidos en la misma transaccion */
        INSERT INTO cob.EstadoMorosidad (ClienteId, FechaCambio, EstadoAnterior, EstadoNuevo, OrigenCambio)
        SELECT c.ClienteId, SYSUTCDATETIME(), c.EstadoAnterior, 'Regularizado', 'SincronizacionAutomatica'
        FROM @Cambios AS c;

        SELECT @RetenidosDespues = COUNT(*)
        FROM cob.Pedido AS p JOIN @Cambios AS c ON c.ClienteId = p.ClienteId
        WHERE p.Estado = 'Retenido';
    COMMIT;

    SELECT
        RutsRecibidos        = (SELECT COUNT(*) FROM @Normalizados),
        RutsNoEncontrados    = (SELECT COUNT(*) FROM @Normalizados AS n
                                WHERE NOT EXISTS (SELECT 1 FROM cob.Cliente AS cl
                                                  WHERE cob.fn_NormalizarRut(cl.Rut) = n.RutNorm)),
        ClientesActualizados = (SELECT COUNT(*) FROM @Cambios),
        PedidosLiberados     = ISNULL(@RetenidosAntes, 0) - ISNULL(@RetenidosDespues, 0);
END
GO

GRANT EXECUTE ON OBJECT::cob.sp_SincronizarClientesRegularizados TO [$(UsuarioFunctionApp)];
GRANT EXECUTE ON TYPE::cob.ListaRut TO [$(UsuarioFunctionApp)];   -- necesario para enviar el parametro de tabla
GO
