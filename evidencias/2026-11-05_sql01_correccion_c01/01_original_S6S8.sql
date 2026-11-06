/* =====================================================================
   Proyecto APT: Cobranza Automatizada - Embotelladora del Pacifico S.A.
   Script 01: estructura de la base de datos sqldb-cobranza (Azure SQL)
   Responsables: Arnaldo Munoz G. (modelo), Oscar Diaz U. (despliegue)
   Estado: PREPARADO, NO EJECUTADO (sin suscripcion Azure a la fecha).
   Ejecutar conectado como miembro del grupo administrador Entra ID.
   ===================================================================== */

SET XACT_ABORT ON;
GO

/* ---------- Esquema ---------- */
IF SCHEMA_ID('cob') IS NULL EXEC('CREATE SCHEMA cob');
GO

/* ---------- CLIENTE ---------- */
CREATE TABLE cob.Cliente (
    ClienteId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Cliente PRIMARY KEY,
    Rut             VARCHAR(12)   NOT NULL CONSTRAINT UQ_Cliente_Rut UNIQUE,
    RazonSocial     NVARCHAR(150) NOT NULL,
    Segmento        VARCHAR(20)   NOT NULL
        CONSTRAINT CK_Cliente_Segmento CHECK (Segmento IN ('Supermercado','Minimarket','Hotel','Restaurante','Almacen','Distribuidor')),
    Email           NVARCHAR(254) NOT NULL,
    Telefono        VARCHAR(20)   NULL,
    TipoConvenio    TINYINT       NOT NULL
        CONSTRAINT CK_Cliente_Convenio CHECK (TipoConvenio IN (30, 60)),
    EstadoActual    VARCHAR(15)   NOT NULL CONSTRAINT DF_Cliente_Estado DEFAULT ('AlDia')
        CONSTRAINT CK_Cliente_Estado CHECK (EstadoActual IN ('AlDia','Moroso','Suspendido','Regularizado')),
    FechaRegistro   DATETIME2(0)  NOT NULL CONSTRAINT DF_Cliente_Fecha DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------- FACTURA ---------- */
CREATE TABLE cob.Factura (
    FacturaId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Factura PRIMARY KEY,
    ClienteId        INT           NOT NULL CONSTRAINT FK_Factura_Cliente REFERENCES cob.Cliente(ClienteId),
    NumeroFactura    VARCHAR(20)   NOT NULL CONSTRAINT UQ_Factura_Numero UNIQUE,
    MontoTotal       DECIMAL(14,2) NOT NULL CONSTRAINT CK_Factura_Monto CHECK (MontoTotal > 0),
    FechaEmision     DATE          NOT NULL,
    PlazoDias        TINYINT       NOT NULL CONSTRAINT CK_Factura_Plazo CHECK (PlazoDias IN (30, 60)),
    FechaVencimiento AS DATEADD(DAY, PlazoDias, FechaEmision) PERSISTED,
    Estado           VARCHAR(12)   NOT NULL CONSTRAINT DF_Factura_Estado DEFAULT ('Pendiente')
        CONSTRAINT CK_Factura_Estado CHECK (Estado IN ('Pendiente','Vencida','Pagada','Anulada'))
);
CREATE INDEX IX_Factura_Vencimiento ON cob.Factura (Estado, FechaVencimiento) INCLUDE (ClienteId, MontoTotal);
GO

/* ---------- ESTADO_MOROSIDAD (historial de cambios) ---------- */
CREATE TABLE cob.EstadoMorosidad (
    EstadoId        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EstadoMorosidad PRIMARY KEY,
    ClienteId       INT          NOT NULL CONSTRAINT FK_EstadoMorosidad_Cliente REFERENCES cob.Cliente(ClienteId),
    FechaCambio     DATETIME2(0) NOT NULL CONSTRAINT DF_EstadoMorosidad_Fecha DEFAULT (SYSUTCDATETIME()),
    EstadoAnterior  VARCHAR(15)  NOT NULL,
    EstadoNuevo     VARCHAR(15)  NOT NULL
        CONSTRAINT CK_EstadoMorosidad_Nuevo CHECK (EstadoNuevo IN ('AlDia','Moroso','Suspendido','Regularizado')),
    OrigenCambio    VARCHAR(30)  NOT NULL
        CONSTRAINT CK_EstadoMorosidad_Origen CHECK (OrigenCambio IN ('JobSincronizacion','JobVencimiento','UsuarioFinanzas'))
);
CREATE INDEX IX_EstadoMorosidad_Cliente ON cob.EstadoMorosidad (ClienteId, FechaCambio DESC);
GO

/* ---------- PEDIDO ---------- */
CREATE TABLE cob.Pedido (
    PedidoId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Pedido PRIMARY KEY,
    ClienteId       INT          NOT NULL CONSTRAINT FK_Pedido_Cliente REFERENCES cob.Cliente(ClienteId),
    NumeroPedido    VARCHAR(20)  NOT NULL CONSTRAINT UQ_Pedido_Numero UNIQUE,
    FechaCreacion   DATETIME2(0) NOT NULL CONSTRAINT DF_Pedido_Fecha DEFAULT (SYSUTCDATETIME()),
    Estado          VARCHAR(12)  NOT NULL CONSTRAINT DF_Pedido_Estado DEFAULT ('Retenido')
        CONSTRAINT CK_Pedido_Estado CHECK (Estado IN ('Retenido','Liberado','Despachado')),
    FechaLiberacion DATETIME2(0) NULL
);
CREATE INDEX IX_Pedido_Cliente_Estado ON cob.Pedido (ClienteId, Estado);
GO

/* ---------- LOG_NOTIFICACION ---------- */
CREATE TABLE cob.LogNotificacion (
    LogNotificacionId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LogNotificacion PRIMARY KEY,
    FacturaId         INT           NOT NULL CONSTRAINT FK_LogNotificacion_Factura REFERENCES cob.Factura(FacturaId),
    TipoAviso         VARCHAR(15)   NOT NULL
        CONSTRAINT CK_LogNotificacion_Tipo CHECK (TipoAviso IN ('PreVencimiento','Vencimiento','PostVencimiento')),
    Destinatario      NVARCHAR(254) NOT NULL,
    FechaEnvio        DATETIME2(0)  NOT NULL CONSTRAINT DF_LogNotificacion_Fecha DEFAULT (SYSUTCDATETIME()),
    IdOperacionAcs    VARCHAR(100)  NULL,
    ResultadoEnvio    VARCHAR(20)   NOT NULL
        CONSTRAINT CK_LogNotificacion_Resultado CHECK (ResultadoEnvio IN ('Aceptado','Entregado','Fallido','Limitado')),
    Detalle           NVARCHAR(400) NULL,
    /* Evita reenviar el mismo tipo de aviso para la misma factura */
    CONSTRAINT UQ_LogNotificacion_Aviso UNIQUE (FacturaId, TipoAviso)
);
GO

/* ---------- LOG_SINCRONIZACION ---------- */
CREATE TABLE cob.LogSincronizacion (
    LogSincronizacionId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LogSincronizacion PRIMARY KEY,
    FechaInicio         DATETIME2(0)  NOT NULL,
    FechaFin            DATETIME2(0)  NULL,
    RegistrosLeidos     INT           NOT NULL CONSTRAINT DF_LogSinc_Leidos DEFAULT (0),
    ClientesRegularizados INT         NOT NULL CONSTRAINT DF_LogSinc_Reg DEFAULT (0),
    PedidosLiberados    INT           NOT NULL CONSTRAINT DF_LogSinc_Lib DEFAULT (0),
    Resultado           VARCHAR(10)   NOT NULL CONSTRAINT CK_LogSinc_Resultado CHECK (Resultado IN ('Exito','Error')),
    Detalle             NVARCHAR(400) NULL
);
GO

/* ---------- USUARIO_INTERNO ---------- */
CREATE TABLE cob.UsuarioInterno (
    UsuarioId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_UsuarioInterno PRIMARY KEY,
    EntraObjectId   UNIQUEIDENTIFIER NOT NULL CONSTRAINT UQ_UsuarioInterno_Oid UNIQUE,
    Nombre          NVARCHAR(120) NOT NULL,
    Rol             VARCHAR(10)   NOT NULL CONSTRAINT CK_UsuarioInterno_Rol CHECK (Rol IN ('Finanzas','Ventas','Admin')),
    Activo          BIT           NOT NULL CONSTRAINT DF_UsuarioInterno_Activo DEFAULT (1)
);
GO

/* ---------- Tipo tabla para recibir RUT regularizados desde el job ---------- */
CREATE TYPE cob.ListaRut AS TABLE (Rut VARCHAR(12) NOT NULL PRIMARY KEY);
GO

/* =====================================================================
   Procedimiento: libera pedidos retenidos de un cliente
   ===================================================================== */
CREATE PROCEDURE cob.sp_LiberarPedidosRetenidos
    @ClienteId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE cob.Pedido
       SET Estado = 'Liberado',
           FechaLiberacion = SYSUTCDATETIME()
     WHERE ClienteId = @ClienteId
       AND Estado = 'Retenido';
    RETURN @@ROWCOUNT;
END;
GO

/* =====================================================================
   Trigger: al registrarse un paso a "Regularizado" se liberan pedidos
   ===================================================================== */
CREATE TRIGGER cob.tr_EstadoMorosidad_Liberar
ON cob.EstadoMorosidad
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE p
       SET p.Estado = 'Liberado',
           p.FechaLiberacion = SYSUTCDATETIME()
      FROM cob.Pedido p
      JOIN inserted i ON i.ClienteId = p.ClienteId
     WHERE i.EstadoNuevo = 'Regularizado'
       AND i.EstadoAnterior = 'Suspendido'
       AND p.Estado = 'Retenido';
END;
GO

/* =====================================================================
   Procedimiento: sincroniza clientes regularizados.
   El job lee (solo lectura) la BD de la embotelladora y entrega la
   lista de RUT regularizados; el motor de esa BD externa aun no esta
   confirmado, por eso la lectura queda en el job y no en T-SQL.
   ===================================================================== */
CREATE PROCEDURE cob.sp_SincronizarClientesRegularizados
    @Ruts cob.ListaRut READONLY,
    @RegistrosLeidos INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inicio DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @cambios TABLE (ClienteId INT, EstadoAnterior VARCHAR(15));
    DECLARE @pedidosAntes INT, @pedidosDespues INT;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @pedidosAntes = COUNT(*) FROM cob.Pedido WHERE Estado = 'Retenido';

        UPDATE c
           SET c.EstadoActual = 'Regularizado'
        OUTPUT deleted.ClienteId, deleted.EstadoActual INTO @cambios
          FROM cob.Cliente c
          JOIN @Ruts r ON r.Rut = c.Rut
         WHERE c.EstadoActual IN ('Moroso','Suspendido');

        INSERT INTO cob.EstadoMorosidad (ClienteId, EstadoAnterior, EstadoNuevo, OrigenCambio)
        SELECT ClienteId, EstadoAnterior, 'Regularizado', 'JobSincronizacion' FROM @cambios;

        SELECT @pedidosDespues = COUNT(*) FROM cob.Pedido WHERE Estado = 'Retenido';

        INSERT INTO cob.LogSincronizacion (FechaInicio, FechaFin, RegistrosLeidos, ClientesRegularizados, PedidosLiberados, Resultado)
        VALUES (@inicio, SYSUTCDATETIME(), @RegistrosLeidos, (SELECT COUNT(*) FROM @cambios), @pedidosAntes - @pedidosDespues, 'Exito');

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO cob.LogSincronizacion (FechaInicio, FechaFin, RegistrosLeidos, Resultado, Detalle)
        VALUES (@inicio, SYSUTCDATETIME(), @RegistrosLeidos, 'Error', LEFT(ERROR_MESSAGE(), 400));
        THROW;
    END CATCH
END;
GO

/* =====================================================================
   Procedimiento: facturas que requieren aviso hoy (insumo del job de
   notificaciones). Excluye avisos ya enviados.
   Ventana de pre-aviso: parametro, a confirmar con Finanzas.
   ===================================================================== */
CREATE PROCEDURE cob.sp_GenerarAlertasVencimiento
    @DiasPreAviso INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hoy DATE = CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific SA Standard Time' AS DATE);

    WITH candidatas AS (
        SELECT f.FacturaId, f.NumeroFactura, f.MontoTotal, f.FechaVencimiento,
               c.ClienteId, c.RazonSocial, c.Email,
               CASE
                   WHEN f.FechaVencimiento = DATEADD(DAY, @DiasPreAviso, @hoy) THEN 'PreVencimiento'
                   WHEN f.FechaVencimiento = @hoy THEN 'Vencimiento'
                   WHEN f.FechaVencimiento < @hoy THEN 'PostVencimiento'
               END AS TipoAviso
          FROM cob.Factura f
          JOIN cob.Cliente c ON c.ClienteId = f.ClienteId
         WHERE f.Estado IN ('Pendiente','Vencida')
    )
    SELECT x.*
      FROM candidatas x
     WHERE x.TipoAviso IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cob.LogNotificacion l
                        WHERE l.FacturaId = x.FacturaId AND l.TipoAviso = x.TipoAviso);
END;
GO
