/* =============================================================================
   04_jobs_bitacoras.sql
   Proyecto APT Cobranza Automatizada - Evidencia S10

   Contenido
   ---------
   1. Columnas de bitacora requeridas por los jobs (se agregan solo si faltan).
   2. Vista cob.vw_EstadoActualCliente (ultimo estado de morosidad por cliente).
   3. cob.sp_GenerarAlertasVencimiento  (version 2, reemplaza la de S6-S8).
   4. cob.sp_RegistrarNotificacion       (registro idempotente del envio).
   5. cob.sp_IniciarSincronizacion / cob.sp_FinalizarSincronizacion.
   6. Permisos EXECUTE para la identidad de la Function App.

   Requisito previo: 00_verificar_esquema.sql sin hallazgos en Cliente, Factura,
   EstadoMorosidad y en las restricciones CHECK.

   Variables SQLCMD:
     UsuarioFunctionApp : usuario de BD de la identidad administrada de la Function App.
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------------
   1. Bitacoras
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'cob.LogNotificacion', N'U') IS NULL
BEGIN
    CREATE TABLE cob.LogNotificacion (
        LogNotificacionId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_LogNotificacion PRIMARY KEY,
        FacturaId          int          NOT NULL CONSTRAINT FK_LogNotificacion_Factura REFERENCES cob.Factura (FacturaId),
        ClienteId          int          NOT NULL CONSTRAINT FK_LogNotificacion_Cliente REFERENCES cob.Cliente (ClienteId),
        TipoAviso          varchar(15)  NOT NULL,
        CONSTRAINT UQ_LogNotificacion_Factura_Tipo UNIQUE (FacturaId, TipoAviso)
    );
END
GO
IF COL_LENGTH(N'cob.LogNotificacion', N'Destinatario')       IS NULL ALTER TABLE cob.LogNotificacion ADD Destinatario       varchar(120)  NULL;
IF COL_LENGTH(N'cob.LogNotificacion', N'EstadoEnvio')        IS NULL ALTER TABLE cob.LogNotificacion ADD EstadoEnvio        varchar(15)   NULL;
IF COL_LENGTH(N'cob.LogNotificacion', N'IdOperacionAcs')     IS NULL ALTER TABLE cob.LogNotificacion ADD IdOperacionAcs     varchar(100)  NULL;
IF COL_LENGTH(N'cob.LogNotificacion', N'Intentos')           IS NULL ALTER TABLE cob.LogNotificacion ADD Intentos           int           NOT NULL CONSTRAINT DF_LogNotificacion_Intentos DEFAULT (0);
IF COL_LENGTH(N'cob.LogNotificacion', N'Detalle')            IS NULL ALTER TABLE cob.LogNotificacion ADD Detalle            nvarchar(400) NULL;
IF COL_LENGTH(N'cob.LogNotificacion', N'FechaRegistro')      IS NULL ALTER TABLE cob.LogNotificacion ADD FechaRegistro      datetime2(0)  NOT NULL CONSTRAINT DF_LogNotificacion_FechaRegistro DEFAULT (SYSUTCDATETIME());
IF COL_LENGTH(N'cob.LogNotificacion', N'FechaActualizacion') IS NULL ALTER TABLE cob.LogNotificacion ADD FechaActualizacion datetime2(0)  NULL;
GO

IF OBJECT_ID(N'cob.LogSincronizacion', N'U') IS NULL
BEGIN
    CREATE TABLE cob.LogSincronizacion (
        LogSincronizacionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_LogSincronizacion PRIMARY KEY
    );
END
GO
IF COL_LENGTH(N'cob.LogSincronizacion', N'FechaInicio')          IS NULL ALTER TABLE cob.LogSincronizacion ADD FechaInicio          datetime2(0)  NOT NULL CONSTRAINT DF_LogSincronizacion_FechaInicio DEFAULT (SYSUTCDATETIME());
IF COL_LENGTH(N'cob.LogSincronizacion', N'FechaFin')             IS NULL ALTER TABLE cob.LogSincronizacion ADD FechaFin             datetime2(0)  NULL;
IF COL_LENGTH(N'cob.LogSincronizacion', N'ClientesLeidos')       IS NULL ALTER TABLE cob.LogSincronizacion ADD ClientesLeidos       int           NULL;
IF COL_LENGTH(N'cob.LogSincronizacion', N'ClientesActualizados') IS NULL ALTER TABLE cob.LogSincronizacion ADD ClientesActualizados int           NULL;
IF COL_LENGTH(N'cob.LogSincronizacion', N'PedidosLiberados')     IS NULL ALTER TABLE cob.LogSincronizacion ADD PedidosLiberados     int           NULL;
IF COL_LENGTH(N'cob.LogSincronizacion', N'Estado')               IS NULL ALTER TABLE cob.LogSincronizacion ADD Estado               varchar(15)   NULL;
IF COL_LENGTH(N'cob.LogSincronizacion', N'Detalle')              IS NULL ALTER TABLE cob.LogSincronizacion ADD Detalle              nvarchar(400) NULL;
GO

/* ---------------------------------------------------------------------------
   2. Estado actual de cada cliente = ultimo registro de cob.EstadoMorosidad.
      Un cliente sin registros se considera AlDia.
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW cob.vw_EstadoActualCliente
AS
SELECT c.ClienteId,
       c.Rut,
       ISNULL(u.EstadoNuevo, 'AlDia') AS EstadoActual,
       u.FechaCambio                  AS FechaUltimoCambio
FROM cob.Cliente AS c
OUTER APPLY (
    SELECT TOP (1) em.EstadoNuevo, em.FechaCambio
    FROM cob.EstadoMorosidad AS em
    WHERE em.ClienteId = c.ClienteId
    ORDER BY em.FechaCambio DESC, em.EstadoId DESC
) AS u;
GO

/* ---------------------------------------------------------------------------
   3. Alertas de vencimiento (version 2)
      Para cada factura no pagada calcula el aviso que corresponde HOY (hora de Chile):
        Preaviso    : faltan entre 1 y @DiasPreaviso dias para el vencimiento
        Vencimiento : vence hoy o vencio hace menos de @DiasMora1 dias
        Mora1       : vencida hace @DiasMora1 o mas dias (y menos de @DiasMora2)
        Mora2       : vencida hace @DiasMora2 o mas dias
      Se devuelve solo el aviso mas avanzado aplicable, para no enviar avisos atrasados.
      Se excluyen avisos ya aceptados por ACS y avisos con 3 intentos fallidos.
      Regla a validar con Finanzas: los avisos de mora no se envian si el cliente
      quedo Regularizado despues del vencimiento de la factura.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE cob.sp_GenerarAlertasVencimiento
    @DiasPreaviso   int,
    @DiasMora1      int,
    @DiasMora2      int,
    @MaxFilas       int  = 500,
    @FechaReferencia date = NULL      -- solo para pruebas; NULL = hoy en Chile
AS
BEGIN
    SET NOCOUNT ON;

    IF @DiasPreaviso < 1 OR @DiasMora1 < 1 OR @DiasMora2 <= @DiasMora1
        THROW 50001, N'Parametros de avisos invalidos: se requiere DiasPreaviso >= 1, DiasMora1 >= 1 y DiasMora2 > DiasMora1.', 1;

    DECLARE @Hoy date = ISNULL(@FechaReferencia,
                               CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Pacific SA Standard Time' AS date));

    ;WITH Calculo AS (
        SELECT f.FacturaId, f.ClienteId, f.NumeroFactura, f.MontoTotal, f.FechaVencimiento,
               DATEDIFF(day, f.FechaVencimiento, @Hoy) AS DiasDesdeVencimiento
        FROM cob.Factura AS f
        WHERE f.Estado <> 'Pagada'
    ),
    Aviso AS (
        SELECT c.*,
               CASE
                   WHEN c.DiasDesdeVencimiento >= @DiasMora2 THEN 'Mora2'
                   WHEN c.DiasDesdeVencimiento >= @DiasMora1 THEN 'Mora1'
                   WHEN c.DiasDesdeVencimiento >= 0          THEN 'Vencimiento'
                   WHEN c.DiasDesdeVencimiento >= -@DiasPreaviso THEN 'Preaviso'
               END AS TipoAviso
        FROM Calculo AS c
    )
    SELECT TOP (@MaxFilas)
           a.FacturaId, a.ClienteId, cl.Rut, cl.RazonSocial, cl.Email, cl.Segmento,
           a.NumeroFactura, a.MontoTotal, a.FechaVencimiento, a.DiasDesdeVencimiento, a.TipoAviso
    FROM Aviso AS a
    JOIN cob.Cliente AS cl ON cl.ClienteId = a.ClienteId
    JOIN cob.vw_EstadoActualCliente AS ea ON ea.ClienteId = a.ClienteId
    WHERE a.TipoAviso IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(cl.Email)), '') IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM cob.LogNotificacion AS ln
            WHERE ln.FacturaId = a.FacturaId AND ln.TipoAviso = a.TipoAviso
              AND (ln.EstadoEnvio = 'Aceptado' OR ln.Intentos >= 3))
      AND NOT (a.TipoAviso IN ('Mora1', 'Mora2')
               AND ea.EstadoActual = 'Regularizado'
               AND ea.FechaUltimoCambio >= CAST(a.FechaVencimiento AS datetime2(0)))
    ORDER BY a.FechaVencimiento, a.FacturaId;
END
GO

/* ---------------------------------------------------------------------------
   4. Registro idempotente de notificaciones (una fila por factura y tipo de aviso)
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE cob.sp_RegistrarNotificacion
    @FacturaId      int,
    @TipoAviso      varchar(15),
    @Destinatario   varchar(120),
    @EstadoEnvio    varchar(15),          -- Aceptado | Fallido
    @IdOperacionAcs varchar(100) = NULL,
    @Detalle        nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @EstadoEnvio NOT IN ('Aceptado', 'Fallido')
        THROW 50002, N'EstadoEnvio debe ser Aceptado o Fallido.', 1;

    DECLARE @ClienteId int = (SELECT ClienteId FROM cob.Factura WHERE FacturaId = @FacturaId);
    IF @ClienteId IS NULL
        THROW 50003, N'La factura indicada no existe.', 1;

    BEGIN TRAN;
        UPDATE cob.LogNotificacion WITH (UPDLOCK, HOLDLOCK)
           SET EstadoEnvio = @EstadoEnvio,
               IdOperacionAcs = @IdOperacionAcs,
               Destinatario = @Destinatario,
               Detalle = @Detalle,
               Intentos = Intentos + 1,
               FechaActualizacion = SYSUTCDATETIME()
         WHERE FacturaId = @FacturaId AND TipoAviso = @TipoAviso;

        IF @@ROWCOUNT = 0
            INSERT INTO cob.LogNotificacion
                (FacturaId, ClienteId, TipoAviso, Destinatario, EstadoEnvio, IdOperacionAcs, Intentos, Detalle)
            VALUES
                (@FacturaId, @ClienteId, @TipoAviso, @Destinatario, @EstadoEnvio, @IdOperacionAcs, 1, @Detalle);
    COMMIT;
END
GO

/* ---------------------------------------------------------------------------
   5. Bitacora de ejecuciones del job de sincronizacion
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE cob.sp_IniciarSincronizacion
    @LogSincronizacionId bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO cob.LogSincronizacion (FechaInicio, Estado) VALUES (SYSUTCDATETIME(), 'EnCurso');
    SET @LogSincronizacionId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE cob.sp_FinalizarSincronizacion
    @LogSincronizacionId  bigint,
    @Estado               varchar(15),    -- Exitosa | Fallida
    @ClientesLeidos       int = NULL,
    @ClientesActualizados int = NULL,
    @PedidosLiberados     int = NULL,
    @Detalle              nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Estado NOT IN ('Exitosa', 'Fallida')
        THROW 50004, N'Estado debe ser Exitosa o Fallida.', 1;

    UPDATE cob.LogSincronizacion
       SET FechaFin = SYSUTCDATETIME(),
           Estado = @Estado,
           ClientesLeidos = @ClientesLeidos,
           ClientesActualizados = @ClientesActualizados,
           PedidosLiberados = @PedidosLiberados,
           Detalle = @Detalle
     WHERE LogSincronizacionId = @LogSincronizacionId;
END
GO

/* ---------------------------------------------------------------------------
   6. Permisos minimos para la Function App (solo EXECUTE sobre procedimientos)
   --------------------------------------------------------------------------- */
GRANT EXECUTE ON OBJECT::cob.sp_GenerarAlertasVencimiento TO [$(UsuarioFunctionApp)];
GRANT EXECUTE ON OBJECT::cob.sp_RegistrarNotificacion     TO [$(UsuarioFunctionApp)];
GRANT EXECUTE ON OBJECT::cob.sp_IniciarSincronizacion     TO [$(UsuarioFunctionApp)];
GRANT EXECUTE ON OBJECT::cob.sp_FinalizarSincronizacion   TO [$(UsuarioFunctionApp)];
GO
