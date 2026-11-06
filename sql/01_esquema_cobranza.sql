/* =====================================================================
   Proyecto APT: Cobranza Automatizada - Embotelladora del Pacifico S.A.
   Script 01: estructura de la base de datos sqldb-cobranza (Azure SQL)
   Responsables: Arnaldo Munoz G. (modelo), Oscar Diaz U. (despliegue)
   Estado: PREPARADO, NO EJECUTADO (sin suscripcion Azure a la fecha).
   Ejecutar conectado como miembro del grupo administrador Entra ID.

   Version 05-11-2026 (correccion C-01, revision qa 2026-11-05):
   la copia S6-S8 se alineo con el esquema que esperan 00 (lineas 27-46
   y 85-89), 03-11 y el codigo de src/. Detalle en
   evidencias/2026-11-05_sql01_correccion_c01/CAMBIOS.md.
     - El estado actual del cliente NO se guarda en cob.Cliente: es el
       ultimo registro de cob.EstadoMorosidad (vista cob.vw_EstadoActualCliente,
       script 04). Se retiro la columna Cliente.EstadoActual.
     - Dominios de CHECK segun 00:86-89 y los scripts 04, 05, 07, 08 y 11.
     - cob.LogNotificacion y cob.LogSincronizacion con las columnas que
       usan 04, 06, 09 y 11 (04 solo las agrega si faltan).
     - Los procedimientos y el trigger v1 de S6-S8 se retiraron de este
       script: la version vigente (v2) la crean 04 (sp_GenerarAlertasVencimiento)
       y 05 (sp_LiberarPedidosRetenidos, tr_EstadoMorosidad_Liberar,
       sp_SincronizarClientesRegularizados). 00 verifica que existan.
     - Idempotente: cada objeto se crea solo si no existe. Si detecta una
       estructura S6-S8 ya desplegada, se detiene (no la altera sola).
     - cob.UsuarioInterno se mantiene SIN CAMBIOS (rediseno en ADR-001);
       es la unica sentencia no idempotente del script.

   Intercalacion: la base se crea con Modern_Spanish_CI_AS (infra/main.bicep);
   las columnas heredan la intercalacion de la base.
   Ejecutar con sqlcmd -b para detener el despliegue ante un error.
   ===================================================================== */

SET XACT_ABORT ON;
GO

/* ---------- Esquema ---------- */
IF SCHEMA_ID('cob') IS NULL EXEC('CREATE SCHEMA cob');
GO

/* ---------- Proteccion: estructura S6-S8 ya desplegada ----------
   Si la base contiene la version anterior (columnas o CHECK incompatibles),
   el script no la modifica: se requiere una migracion revisada. */
IF COL_LENGTH(N'cob.Cliente', N'EstadoActual') IS NOT NULL
   OR COL_LENGTH(N'cob.LogNotificacion', N'ResultadoEnvio') IS NOT NULL
   OR COL_LENGTH(N'cob.LogSincronizacion', N'Resultado') IS NOT NULL
   OR EXISTS (SELECT 1 FROM sys.check_constraints AS cc
              WHERE SCHEMA_NAME(cc.schema_id) = N'cob'
                AND (cc.definition LIKE N'%JobSincronizacion%'
                  OR cc.definition LIKE N'%PreVencimiento%'
                  OR cc.definition LIKE N'%Supermercado%'))
BEGIN
    RAISERROR(N'01: la base contiene la estructura S6-S8 (incompatible con 03-11). Se detiene sin cambios; ver evidencias/2026-11-05_sql01_correccion_c01/CAMBIOS.md.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------- CLIENTE ----------
   Segmento: valores usados por 07 y 08 (dominio definitivo PENDIENTE de
   confirmar con el equipo). Sin columna de estado: ver cabecera. */
IF OBJECT_ID(N'cob.Cliente', N'U') IS NULL
BEGIN
    CREATE TABLE cob.Cliente (
        ClienteId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Cliente PRIMARY KEY,
        Rut             VARCHAR(12)   NOT NULL CONSTRAINT UQ_Cliente_Rut UNIQUE,
        RazonSocial     NVARCHAR(150) NOT NULL,
        Segmento        VARCHAR(20)   NOT NULL
            CONSTRAINT CK_Cliente_Segmento CHECK (Segmento IN ('Tradicional','Digital')),
        Email           NVARCHAR(254) NOT NULL,
        Telefono        VARCHAR(20)   NULL,
        TipoConvenio    TINYINT       NOT NULL
            CONSTRAINT CK_Cliente_Convenio CHECK (TipoConvenio IN (30, 60)),
        FechaRegistro   DATETIME2(0)  NOT NULL CONSTRAINT DF_Cliente_Fecha DEFAULT (SYSUTCDATETIME())
    );
END
GO

/* ---------- FACTURA ----------
   Estado segun 00:86 {Pendiente, Vencida, Pagada}. 04 y 06 tratan toda
   factura distinta de Pagada como adeudada, por eso no se admite otro valor. */
IF OBJECT_ID(N'cob.Factura', N'U') IS NULL
BEGIN
    CREATE TABLE cob.Factura (
        FacturaId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Factura PRIMARY KEY,
        ClienteId        INT           NOT NULL CONSTRAINT FK_Factura_Cliente REFERENCES cob.Cliente(ClienteId),
        NumeroFactura    VARCHAR(20)   NOT NULL CONSTRAINT UQ_Factura_Numero UNIQUE,
        MontoTotal       DECIMAL(14,2) NOT NULL CONSTRAINT CK_Factura_Monto CHECK (MontoTotal > 0),
        FechaEmision     DATE          NOT NULL,
        PlazoDias        TINYINT       NOT NULL CONSTRAINT CK_Factura_Plazo CHECK (PlazoDias IN (30, 60)),
        FechaVencimiento AS DATEADD(DAY, PlazoDias, FechaEmision) PERSISTED,
        Estado           VARCHAR(12)   NOT NULL CONSTRAINT DF_Factura_Estado DEFAULT ('Pendiente')
            CONSTRAINT CK_Factura_Estado CHECK (Estado IN ('Pendiente','Vencida','Pagada'))
    );
    CREATE INDEX IX_Factura_Vencimiento ON cob.Factura (Estado, FechaVencimiento) INCLUDE (ClienteId, MontoTotal);
END
GO

/* ---------- ESTADO_MOROSIDAD (historial de cambios; fuente del estado actual) ----------
   OrigenCambio segun 00:87 {SincronizacionAutomatica, Manual}:
   SincronizacionAutomatica = 05 (job), Manual = 11 (TI/Finanzas), 07 y 08. */
IF OBJECT_ID(N'cob.EstadoMorosidad', N'U') IS NULL
BEGIN
    CREATE TABLE cob.EstadoMorosidad (
        EstadoId        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EstadoMorosidad PRIMARY KEY,
        ClienteId       INT          NOT NULL CONSTRAINT FK_EstadoMorosidad_Cliente REFERENCES cob.Cliente(ClienteId),
        FechaCambio     DATETIME2(0) NOT NULL CONSTRAINT DF_EstadoMorosidad_Fecha DEFAULT (SYSUTCDATETIME()),
        EstadoAnterior  VARCHAR(15)  NOT NULL
            CONSTRAINT CK_EstadoMorosidad_Anterior CHECK (EstadoAnterior IN ('AlDia','Moroso','Suspendido','Regularizado')),
        EstadoNuevo     VARCHAR(15)  NOT NULL
            CONSTRAINT CK_EstadoMorosidad_Nuevo CHECK (EstadoNuevo IN ('AlDia','Moroso','Suspendido','Regularizado')),
        OrigenCambio    VARCHAR(30)  NOT NULL
            CONSTRAINT CK_EstadoMorosidad_Origen CHECK (OrigenCambio IN ('SincronizacionAutomatica','Manual'))
    );
    CREATE INDEX IX_EstadoMorosidad_Cliente ON cob.EstadoMorosidad (ClienteId, FechaCambio DESC);
END
GO

/* ---------- PEDIDO ---------- */
IF OBJECT_ID(N'cob.Pedido', N'U') IS NULL
BEGIN
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
END
GO

/* ---------- LOG_NOTIFICACION ----------
   Una fila por factura y tipo de aviso (UNIQUE); los reintentos actualizan
   la misma fila (cob.sp_RegistrarNotificacion, script 04).
   TipoAviso segun D3 y 00:88; EstadoEnvio segun 00:89.
   Nombres de restricciones iguales a los de 04 (04 no las vuelve a crear). */
IF OBJECT_ID(N'cob.LogNotificacion', N'U') IS NULL
BEGIN
    CREATE TABLE cob.LogNotificacion (
        LogNotificacionId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LogNotificacion PRIMARY KEY,
        FacturaId          INT           NOT NULL CONSTRAINT FK_LogNotificacion_Factura REFERENCES cob.Factura(FacturaId),
        ClienteId          INT           NOT NULL CONSTRAINT FK_LogNotificacion_Cliente REFERENCES cob.Cliente(ClienteId),
        TipoAviso          VARCHAR(15)   NOT NULL
            CONSTRAINT CK_LogNotificacion_Tipo CHECK (TipoAviso IN ('Preaviso','Vencimiento','Mora1','Mora2')),
        Destinatario       NVARCHAR(254) NULL,
        EstadoEnvio        VARCHAR(15)   NOT NULL
            CONSTRAINT CK_LogNotificacion_EstadoEnvio CHECK (EstadoEnvio IN ('Aceptado','Fallido')),
        IdOperacionAcs     VARCHAR(100)  NULL,
        Intentos           INT           NOT NULL CONSTRAINT DF_LogNotificacion_Intentos DEFAULT (0),
        Detalle            NVARCHAR(400) NULL,
        FechaRegistro      DATETIME2(0)  NOT NULL CONSTRAINT DF_LogNotificacion_FechaRegistro DEFAULT (SYSUTCDATETIME()),
        FechaActualizacion DATETIME2(0)  NULL,
        /* Evita duplicar el mismo tipo de aviso para la misma factura */
        CONSTRAINT UQ_LogNotificacion_Factura_Tipo UNIQUE (FacturaId, TipoAviso)
    );
    CREATE INDEX IX_LogNotificacion_Cliente ON cob.LogNotificacion (ClienteId);
END
GO

/* ---------- LOG_SINCRONIZACION ----------
   Una fila por ejecucion del job: sp_IniciarSincronizacion inserta EnCurso y
   sp_FinalizarSincronizacion la cierra como Exitosa o Fallida (script 04).
   Los conteos admiten NULL porque una ejecucion fallida puede no tenerlos. */
IF OBJECT_ID(N'cob.LogSincronizacion', N'U') IS NULL
BEGIN
    CREATE TABLE cob.LogSincronizacion (
        LogSincronizacionId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LogSincronizacion PRIMARY KEY,
        FechaInicio          DATETIME2(0)  NOT NULL CONSTRAINT DF_LogSincronizacion_FechaInicio DEFAULT (SYSUTCDATETIME()),
        FechaFin             DATETIME2(0)  NULL,
        ClientesLeidos       INT           NULL,
        ClientesActualizados INT           NULL,
        PedidosLiberados     INT           NULL,
        Estado               VARCHAR(15)   NOT NULL CONSTRAINT DF_LogSincronizacion_Estado DEFAULT ('EnCurso')
            CONSTRAINT CK_LogSincronizacion_Estado CHECK (Estado IN ('EnCurso','Exitosa','Fallida')),
        Detalle              NVARCHAR(400) NULL
    );
END
GO

/* ---------- USUARIO_INTERNO ----------
   SIN CAMBIOS respecto de S6-S8: su rediseno lo define el ADR-001 (en
   actualizacion por el arquitecto). No se le agrego guarda de idempotencia
   para no modificar el bloque; volver a ejecutar 01 da error 2714 solo aqui. */
CREATE TABLE cob.UsuarioInterno (
    UsuarioId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_UsuarioInterno PRIMARY KEY,
    EntraObjectId   UNIQUEIDENTIFIER NOT NULL CONSTRAINT UQ_UsuarioInterno_Oid UNIQUE,
    Nombre          NVARCHAR(120) NOT NULL,
    Rol             VARCHAR(10)   NOT NULL CONSTRAINT CK_UsuarioInterno_Rol CHECK (Rol IN ('Finanzas','Ventas','Admin')),
    Activo          BIT           NOT NULL CONSTRAINT DF_UsuarioInterno_Activo DEFAULT (1)
);
GO

/* ---------- Tipo tabla para recibir RUT regularizados desde el job ----------
   Exactamente una columna (00 lo verifica; 05 hace SELECT * sobre el parametro). */
IF TYPE_ID(N'cob.ListaRut') IS NULL
    EXEC (N'CREATE TYPE cob.ListaRut AS TABLE (Rut VARCHAR(12) NOT NULL PRIMARY KEY);');
GO

/* =====================================================================
   Logica (procedimientos y trigger): NO se crea en este script.
     04 -> cob.vw_EstadoActualCliente, cob.sp_GenerarAlertasVencimiento,
           cob.sp_RegistrarNotificacion, cob.sp_IniciarSincronizacion,
           cob.sp_FinalizarSincronizacion
     05 -> cob.LogCambioPedido, cob.fn_NormalizarRut,
           cob.sp_LiberarPedidosRetenidos, cob.tr_EstadoMorosidad_Liberar,
           cob.sp_SincronizarClientesRegularizados
   ===================================================================== */

SET NOEXEC OFF;
GO
