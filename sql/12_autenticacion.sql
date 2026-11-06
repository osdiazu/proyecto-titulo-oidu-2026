/* =============================================================================
   12_autenticacion.sql
   Proyecto APT Cobranza Automatizada - Embotelladora del Pacifico S.A.
   ADR-001: autenticacion propia de la API (sin Easy Auth ni roles de Entra ID).
   Estado: PREPARADO, NO EJECUTADO. Validado solo con analisis estatico
   (evidencias/2026-11-06_adr001_sql/).

   Contenido
   ---------
   1. Tablas cob.ClaveApi y cob.LogAcceso (ADR-001 5.1).
   2. Funciones auxiliares (solo uso interno de los procedimientos y la vista):
        cob.fn_SanearUsuarioIngresado, cob.fn_EnmascararIp.
   3. Procedimientos con GRANT EXECUTE a $(UsuarioApi) (ADR-001 5.2, tabla 1):
        sp_ObtenerUsuarioParaLogin, sp_ObtenerUsuarioPorId,
        sp_RegistrarLoginFallido, sp_RegistrarLoginExitoso, sp_RegistrarLogout,
        sp_CambiarClave, sp_ValidarClaveApi.
   4. Procedimientos administrativos SIN GRANT (solo grp-cobranza-sql-admin,
      igual que 11) (ADR-001 5.2, tabla 2):
        sp_CrearUsuarioInterno, sp_RestablecerClaveUsuario, sp_DesbloquearUsuario,
        sp_CambiarEstadoUsuario, sp_CambiarRolUsuario, sp_RegistrarClaveApi,
        sp_RevocarClaveApi, sp_PurgarLogAcceso, sp_InvalidarTodasLasSesiones,
        sp_ListarEventosAccesoDesde, sp_VerificarCambioClave.
   5. Vista cob.vw_LogAccesoEvidencia SIN GRANT (IP enmascarada /24 y /48).
   6. GRANT EXECUTE a $(UsuarioApi) sobre los 7 procedimientos del punto 3.

   Reglas
   ------
   - Idempotente: tablas con guarda IF OBJECT_ID ... IS NULL; programables con
     CREATE OR ALTER; GRANT es repetible.
   - Nadie recibe SELECT sobre cob.LogAcceso, cob.ClaveApi, cob.UsuarioInterno
     ni sobre la vista. Ningun procedimiento con GRANT lee cob.LogAcceso (solo
     insertan eventos). 00 lo verifica.
   - A SQL nunca llegan contrasenas ni claves de API en texto plano: solo el
     hash PBKDF2 (PasswordHasher V3) o el SHA-256 de la clave.
   - Errores propios en el rango 50060-50079:
       50060 sp_CambiarClave no actualizo filas (usuario inactivo o sello distinto)
       50061 Usuario no encontrado
       50062 Usuario con formato no valido
       50063 Rol no valido
       50064 El usuario ya existe
       50065 Hash vacio
       50066 Nombre vacio
       50067 Datos de clave de API no validos (prefijo, consumidor o nombre de secreto)
       50068 Prefijo de clave de API ya registrado
       50069 Clave de API no encontrada
       50070 Fecha de vencimiento de clave de API no valida
       50071 Dias de retencion fuera de rango (minimo 90)
       50072 Tamano de lote no valido
       50073 Motivo de login fallido no valido
       50074 Parametros de bloqueo no validos
       50075 Estado Activo nulo
       50076 Fecha @Desde nula
   - Las validaciones lanzan THROW ANTES de abrir la transaccion o despues de
     confirmarla: ningun procedimiento ejecuta ROLLBACK propio (con XACT_ABORT ON
     el motor revierte), para no romper transacciones externas (13 y 07).
   - Actor = ORIGINAL_LOGIN() por DEFAULT en cob.LogAcceso.

   Requisitos: 01 (cob.UsuarioInterno de ADR-001) y 02 (usuario $(UsuarioApi)).
   Orden de despliegue: 01, 02, 03, 04, 05, 06, 12, 11, 00, 07, 13.
   Variables SQLCMD: UsuarioApi.
   Ejecutar con sqlcmd -b, conectado como miembro de grp-cobranza-sql-admin.
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Proteccion: cob.UsuarioInterno debe tener la definicion de ADR-001 (script 01) */
IF COL_LENGTH(N'cob.UsuarioInterno', N'HashClave') IS NULL
   OR COL_LENGTH(N'cob.UsuarioInterno', N'SelloSeguridad') IS NULL
BEGIN
    RAISERROR(N'12: cob.UsuarioInterno no tiene la definicion de ADR-001 (ejecutar antes 01 version 06-11-2026). Se detiene sin cambios.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------------------
   1. Tablas
   --------------------------------------------------------------------------- */

/* cob.ClaveApi (ADR-001 5.1). Solo el SHA-256 de la clave; el valor real vive
   en Key Vault, en el secreto NombreSecretoKv = apikey-<consumidor>-<prefijo>.
   La vigencia maxima (Seguridad__DiasVigenciaClaveApi) la aplica el script de alta. */
IF OBJECT_ID(N'cob.ClaveApi', N'U') IS NULL
BEGIN
    CREATE TABLE cob.ClaveApi (
        ClaveApiId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ClaveApi PRIMARY KEY,
        Prefijo          CHAR(8)       NOT NULL CONSTRAINT UQ_ClaveApi_Prefijo UNIQUE,
        HashClave        BINARY(32)    NOT NULL,
        Consumidor       VARCHAR(50)   NOT NULL,
        Rol              VARCHAR(10)   NOT NULL CONSTRAINT CK_ClaveApi_Rol CHECK (Rol IN ('Ventas')),
        Activa           BIT           NOT NULL CONSTRAINT DF_ClaveApi_Activa DEFAULT (1),
        FechaCreacion    DATETIME2(0)  NOT NULL CONSTRAINT DF_ClaveApi_FechaCreacion DEFAULT (SYSUTCDATETIME()),
        FechaVencimiento DATETIME2(0)  NOT NULL,
        FechaRevocacion  DATETIME2(0)  NULL,
        UltimoUso        DATETIME2(0)  NULL,
        NombreSecretoKv  VARCHAR(127)  NOT NULL,
        /* Base32 en minusculas, exactamente 8 caracteres (LEN no cuenta el relleno de CHAR) */
        CONSTRAINT CK_ClaveApi_Prefijo CHECK (
                LEN(Prefijo) = 8
            AND Prefijo NOT LIKE '%[^a-z2-7]%' COLLATE Latin1_General_BIN2),
        CONSTRAINT CK_ClaveApi_Consumidor CHECK (
                LEN(Consumidor) BETWEEN 3 AND 50
            AND DATALENGTH(Consumidor) = LEN(Consumidor)
            AND Consumidor NOT LIKE '%[^a-z0-9-]%' COLLATE Latin1_General_BIN2),
        CONSTRAINT CK_ClaveApi_NombreSecretoKv CHECK (NombreSecretoKv = 'apikey-' + Consumidor + '-' + Prefijo)
    );
END
GO

/* cob.LogAcceso (ADR-001 5.1). Sin FK (mismo criterio que cob.LogCambioPedido).
   Retencion 90 dias (D15): cob.sp_PurgarLogAcceso.
   IP y agente de usuario son datos personales: solo los lee grp-cobranza-sql-admin;
   para evidencias se usa cob.vw_LogAccesoEvidencia.
   Detalle: columna agregada por el dba (desviacion del contrato documentada en
   evidencias/2026-11-06_adr001_sql/CAMBIOS.md): total purgado, valores anterior y
   nuevo de rol o estado (RNF-05), usuarios afectados. Nunca contiene contrasenas,
   hashes ni claves. Solo la escriben los procedimientos de este script. */
IF OBJECT_ID(N'cob.LogAcceso', N'U') IS NULL
BEGIN
    CREATE TABLE cob.LogAcceso (
        LogAccesoId      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LogAcceso PRIMARY KEY,
        FechaUtc         DATETIME2(0)  NOT NULL CONSTRAINT DF_LogAcceso_FechaUtc DEFAULT (SYSUTCDATETIME()),
        Evento           VARCHAR(25)   NOT NULL
            CONSTRAINT CK_LogAcceso_Evento CHECK (Evento IN ('LoginExitoso','LoginFallido','CuentaBloqueada','Logout','CambioClave','AltaUsuario','RestablecimientoClave','DesbloqueoManual','CambioEstadoUsuario','CambioRolUsuario','AltaClaveApi','RevocacionClaveApi','PurgaLogAcceso','InvalidacionSesiones')),
        Motivo           VARCHAR(25)   NULL
            CONSTRAINT CK_LogAcceso_Motivo CHECK (Motivo IN ('ClaveIncorrecta','UsuarioInexistente','UsuarioInactivo','CuentaBloqueada','ClaveTemporalVencida')),
        UsuarioId        INT           NULL,
        UsuarioIngresado NVARCHAR(50)  NULL,
        ClaveApiId       INT           NULL,
        IpOrigen         VARCHAR(45)   NULL,
        AgenteUsuario    NVARCHAR(200) NULL,
        Actor            NVARCHAR(128) NOT NULL CONSTRAINT DF_LogAcceso_Actor DEFAULT (ORIGINAL_LOGIN()),
        Detalle          NVARCHAR(200) NULL,
        /* Defensa en profundidad (SEG-H07): solo texto con el patron de usuario
           o el marcador '(formato no valido)'. Misma regla que fn_SanearUsuarioIngresado. */
        CONSTRAINT CK_LogAcceso_UsuarioIngresado CHECK (
               UsuarioIngresado IS NULL
            OR UsuarioIngresado = N'(formato no valido)'
            OR (    LEN(UsuarioIngresado) BETWEEN 3 AND 50
                AND DATALENGTH(UsuarioIngresado) = 2 * LEN(UsuarioIngresado)
                AND UsuarioIngresado NOT LIKE N'%[^a-z0-9._-]%' COLLATE Latin1_General_BIN2))
    );
    CREATE INDEX IX_LogAcceso_Fecha   ON cob.LogAcceso (FechaUtc);
    CREATE INDEX IX_LogAcceso_Usuario ON cob.LogAcceso (UsuarioId, FechaUtc DESC);
END
GO

/* ---------------------------------------------------------------------------
   2. Funciones auxiliares (sin GRANT; las usan los procedimientos y la vista
      por encadenamiento de propiedad)
   --------------------------------------------------------------------------- */

/* Saneamiento de UsuarioIngresado (ADR-001 5.1, SEG-H07): el texto se conserva
   solo si cumple el patron de usuario ([a-z0-9._-], 3 a 50 caracteres, sin
   espacios finales); si no, '(formato no valido)'. No convierte a minusculas:
   la API normaliza antes de llamar; un texto con mayusculas se descarta. */
CREATE OR ALTER FUNCTION cob.fn_SanearUsuarioIngresado (@Texto nvarchar(4000))
RETURNS nvarchar(50)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN @Texto IS NULL THEN NULL
        WHEN LEN(@Texto) BETWEEN 3 AND 50
             AND DATALENGTH(@Texto) = 2 * LEN(@Texto)
             AND @Texto NOT LIKE N'%[^a-z0-9._-]%' COLLATE Latin1_General_BIN2
            THEN CAST(@Texto AS nvarchar(50))
        ELSE N'(formato no valido)'
    END;
END
GO

/* Enmascaramiento de IP para evidencias (politica B.4): IPv4 al /24 (a.b.c.0),
   IPv6 al /48 (g1:g2:g3::), IPv4 mapeada (::ffff:a.b.c.d) como IPv4.
   Expande la forma comprimida '::' antes de tomar los 3 primeros grupos.
   Texto no reconocible (por ejemplo con puerto) -> '(no valida)': nunca devuelve
   la direccion original. */
CREATE OR ALTER FUNCTION cob.fn_EnmascararIp (@Ip varchar(45))
RETURNS varchar(45)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s varchar(64) = LOWER(LTRIM(RTRIM(@Ip)));
    IF @s IS NULL OR @s = '' RETURN NULL;
    IF CHARINDEX('%', @s) > 0 SET @s = LEFT(@s, CHARINDEX('%', @s) - 1);   -- identificador de zona IPv6

    DECLARE @Pref varchar(10) = '';
    IF @s LIKE '::ffff:%.%.%.%'
    BEGIN
        SET @Pref = '::ffff:';
        SET @s = SUBSTRING(@s, 8, 64);
    END

    /* IPv4 */
    IF CHARINDEX(':', @s) = 0
        RETURN CASE WHEN @s NOT LIKE '%[^0-9.]%'
                     AND LEN(@s) - LEN(REPLACE(@s, '.', '')) = 3
                     AND @s LIKE '_%._%._%._%'
                    THEN @Pref + LEFT(@s, LEN(@s) - CHARINDEX('.', REVERSE(@s))) + '.0'
                    ELSE '(no valida)' END;

    /* IPv6 */
    IF @s LIKE '%[^0-9a-f:.]%' RETURN '(no valida)';
    IF CHARINDEX('.', @s) > 0   -- IPv4 embebida al final: ocupa 2 grupos
        SET @s = LEFT(@s, LEN(@s) - CHARINDEX(':', REVERSE(@s)) + 1) + '0:0';

    DECLARE @p int = CHARINDEX('::', @s), @Izq varchar(64), @Der varchar(64),
            @nIzq int, @nDer int, @Completa varchar(100);
    IF @p > 0
    BEGIN
        SET @Izq = LEFT(@s, @p - 1);
        SET @Der = SUBSTRING(@s, @p + 2, 64);
    END
    ELSE
    BEGIN
        SET @Izq = @s;
        SET @Der = '';
    END
    SET @nIzq = CASE WHEN @Izq = '' THEN 0 ELSE LEN(@Izq) - LEN(REPLACE(@Izq, ':', '')) + 1 END;
    SET @nDer = CASE WHEN @Der = '' THEN 0 ELSE LEN(@Der) - LEN(REPLACE(@Der, ':', '')) + 1 END;
    IF (@p = 0 AND @nIzq <> 8) OR (@p > 0 AND @nIzq + @nDer > 7) RETURN '(no valida)';

    /* Cada grupo seguido de ':' */
    SET @Completa = CASE WHEN @Izq = '' THEN '' ELSE @Izq + ':' END
                  + CASE WHEN @p > 0 THEN REPLICATE('0:', 8 - @nIzq - @nDer) ELSE '' END
                  + CASE WHEN @Der = '' THEN '' ELSE @Der + ':' END;
    IF LEFT(@Completa, 1) = ':' OR CHARINDEX('::', @Completa) > 0 RETURN '(no valida)';

    DECLARE @i1 int = CHARINDEX(':', @Completa);
    DECLARE @i2 int = CHARINDEX(':', @Completa, @i1 + 1);
    DECLARE @i3 int = CHARINDEX(':', @Completa, @i2 + 1);
    IF @i1 < 2 OR @i2 - @i1 < 2 OR @i3 - @i2 < 2
       OR @i1 > 5 OR @i2 - @i1 > 5 OR @i3 - @i2 > 5 RETURN '(no valida)';

    RETURN LEFT(@Completa, @i3 - 1) + '::';
END
GO

/* ---------------------------------------------------------------------------
   3. Procedimientos con GRANT EXECUTE a $(UsuarioApi)
   --------------------------------------------------------------------------- */

/* Login: devuelve 0 o 1 fila. Solo lectura. La API normaliza @Usuario a minusculas. */
CREATE OR ALTER PROCEDURE cob.sp_ObtenerUsuarioParaLogin
    @Usuario varchar(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UsuarioId, Usuario, Nombre, Rol, Activo, HashClave, DebeCambiarClave,
           IntentosFallidos, BloqueadoHasta, SelloSeguridad, FechaCambioClave
    FROM cob.UsuarioInterno
    WHERE Usuario = @Usuario;
END
GO

/* Revalidacion de la cookie y cambio de contrasena. Mismas 11 columnas que
   sp_ObtenerUsuarioParaLogin; con @IncluirHash = 0 la columna HashClave
   se devuelve en NULL (forma estable del conjunto de resultados). */
CREATE OR ALTER PROCEDURE cob.sp_ObtenerUsuarioPorId
    @UsuarioId   int,
    @IncluirHash bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UsuarioId, Usuario, Nombre, Rol, Activo,
           CASE WHEN @IncluirHash = 1 THEN HashClave END AS HashClave,
           DebeCambiarClave, IntentosFallidos, BloqueadoHasta, SelloSeguridad, FechaCambioClave
    FROM cob.UsuarioInterno
    WHERE UsuarioId = @UsuarioId;
END
GO

/* Login fallido. Con @UsuarioId no nulo y @Motivo = 'ClaveIncorrecta': un UPDATE
   atomico que reinicia el contador si el bloqueo anterior ya vencio, suma 1 y,
   si alcanza @MaxIntentos, fija BloqueadoHasta = ahora + @MinutosBloqueo.
   Con otros motivos (CuentaBloqueada, ClaveTemporalVencida, UsuarioInactivo,
   UsuarioInexistente) solo registra. Siempre devuelve 1 fila: BloqueadoHasta
   del usuario (NULL si no esta bloqueado o si @UsuarioId es NULL). */
CREATE OR ALTER PROCEDURE cob.sp_RegistrarLoginFallido
    @UsuarioId        int,
    @UsuarioIngresado nvarchar(50),
    @Motivo           varchar(25),
    @IpOrigen         varchar(45),
    @AgenteUsuario    nvarchar(200),
    @MaxIntentos      smallint,
    @MinutosBloqueo   int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Motivo IS NULL
       OR @Motivo NOT IN ('ClaveIncorrecta', 'UsuarioInexistente', 'UsuarioInactivo', 'CuentaBloqueada', 'ClaveTemporalVencida')
        THROW 50073, N'Motivo de login fallido no valido.', 1;

    DECLARE @Cuenta bit = CASE WHEN @UsuarioId IS NOT NULL AND @Motivo = 'ClaveIncorrecta' THEN 1 ELSE 0 END;
    IF @Cuenta = 1 AND (@MaxIntentos IS NULL OR @MaxIntentos < 1 OR @MinutosBloqueo IS NULL OR @MinutosBloqueo < 1)
        THROW 50074, N'MaxIntentos y MinutosBloqueo deben ser mayores o iguales a 1.', 1;

    DECLARE @Ahora datetime2(0) = SYSUTCDATETIME();
    DECLARE @Ingresado nvarchar(50) = cob.fn_SanearUsuarioIngresado(@UsuarioIngresado);
    DECLARE @Resultado TABLE (IntentosFallidos smallint NOT NULL, BloqueadoHasta datetime2(0) NULL);
    DECLARE @Bloqueo bit = 0;

    BEGIN TRAN;
        IF @Cuenta = 1
        BEGIN
            UPDATE u
               SET u.IntentosFallidos = v.Nuevo,
                   u.BloqueadoHasta = CASE WHEN v.Nuevo >= @MaxIntentos THEN DATEADD(MINUTE, @MinutosBloqueo, @Ahora)
                                           WHEN u.BloqueadoHasta <= @Ahora THEN NULL
                                           ELSE u.BloqueadoHasta END
            OUTPUT inserted.IntentosFallidos, inserted.BloqueadoHasta INTO @Resultado (IntentosFallidos, BloqueadoHasta)
            FROM cob.UsuarioInterno AS u
            CROSS APPLY (SELECT CAST(CASE WHEN u.BloqueadoHasta <= @Ahora THEN 1                      -- bloqueo vencido: reinicia
                                          WHEN u.IntentosFallidos >= 32000 THEN u.IntentosFallidos    -- tope (evita desborde)
                                          ELSE u.IntentosFallidos + 1 END AS smallint)) AS v(Nuevo)
            WHERE u.UsuarioId = @UsuarioId;

            IF EXISTS (SELECT 1 FROM @Resultado WHERE IntentosFallidos >= @MaxIntentos) SET @Bloqueo = 1;
        END

        INSERT INTO cob.LogAcceso (Evento, Motivo, UsuarioId, UsuarioIngresado, IpOrigen, AgenteUsuario)
        VALUES ('LoginFallido', @Motivo, @UsuarioId, @Ingresado, @IpOrigen, LEFT(@AgenteUsuario, 200));

        IF @Bloqueo = 1
            INSERT INTO cob.LogAcceso (Evento, UsuarioId, UsuarioIngresado, IpOrigen, AgenteUsuario, Detalle)
            SELECT 'CuentaBloqueada', @UsuarioId, @Ingresado, @IpOrigen, LEFT(@AgenteUsuario, 200),
                   CONCAT(N'IntentosFallidos=', r.IntentosFallidos, N'; BloqueadoHasta=', CONVERT(nvarchar(19), r.BloqueadoHasta, 120), N' UTC')
            FROM @Resultado AS r;
    COMMIT;

    SELECT (SELECT BloqueadoHasta FROM cob.UsuarioInterno WHERE UsuarioId = @UsuarioId) AS BloqueadoHasta;
END
GO

/* Login exitoso: reinicia contador y bloqueo, registra UltimoAcceso y, si
   @HashClaveNuevo no es NULL ni vacio, reemplaza el hash (re-hash por
   SuccessRehashNeeded; no cambia el sello porque la contrasena es la misma).
   Sin conjunto de resultados. */
CREATE OR ALTER PROCEDURE cob.sp_RegistrarLoginExitoso
    @UsuarioId      int,
    @IpOrigen       varchar(45),
    @AgenteUsuario  nvarchar(200),
    @HashClaveNuevo varchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Ahora datetime2(0) = SYSUTCDATETIME(), @Filas int;

    BEGIN TRAN;
        UPDATE cob.UsuarioInterno
           SET IntentosFallidos = 0,
               BloqueadoHasta = NULL,
               UltimoAcceso = @Ahora,
               HashClave = ISNULL(NULLIF(@HashClaveNuevo, ''), HashClave)
         WHERE UsuarioId = @UsuarioId;
        SET @Filas = @@ROWCOUNT;

        IF @Filas = 1
            INSERT INTO cob.LogAcceso (Evento, UsuarioId, IpOrigen, AgenteUsuario)
            VALUES ('LoginExitoso', @UsuarioId, @IpOrigen, LEFT(@AgenteUsuario, 200));
    COMMIT;

    IF @Filas = 0
        THROW 50061, N'Usuario no encontrado.', 1;
END
GO

/* Logout: solo registra el evento. Sin conjunto de resultados. */
CREATE OR ALTER PROCEDURE cob.sp_RegistrarLogout
    @UsuarioId     int,
    @IpOrigen      varchar(45),
    @AgenteUsuario nvarchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO cob.LogAcceso (Evento, UsuarioId, IpOrigen, AgenteUsuario)
    VALUES ('Logout', @UsuarioId, @IpOrigen, LEFT(@AgenteUsuario, 200));
END
GO

/* Cambio de contrasena por el propio usuario. Actualiza solo si el usuario
   esta activo y el sello coincide (evita carreras). Devuelve 1 fila con el
   sello nuevo (columna SelloSeguridad). Si no actualiza: THROW 50060. */
CREATE OR ALTER PROCEDURE cob.sp_CambiarClave
    @UsuarioId      int,
    @SelloActual    uniqueidentifier,
    @HashClaveNuevo varchar(256),
    @IpOrigen       varchar(45),
    @AgenteUsuario  nvarchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(@HashClaveNuevo, '') IS NULL
        THROW 50065, N'El hash de la contrasena no puede ser vacio.', 1;

    DECLARE @Nuevo TABLE (SelloSeguridad uniqueidentifier NOT NULL);

    BEGIN TRAN;
        UPDATE cob.UsuarioInterno
           SET HashClave = @HashClaveNuevo,
               DebeCambiarClave = 0,
               FechaCambioClave = SYSUTCDATETIME(),
               SelloSeguridad = NEWID()
        OUTPUT inserted.SelloSeguridad INTO @Nuevo (SelloSeguridad)
         WHERE UsuarioId = @UsuarioId
           AND Activo = 1
           AND SelloSeguridad = @SelloActual;

        IF EXISTS (SELECT 1 FROM @Nuevo)
            INSERT INTO cob.LogAcceso (Evento, UsuarioId, IpOrigen, AgenteUsuario)
            VALUES ('CambioClave', @UsuarioId, @IpOrigen, LEFT(@AgenteUsuario, 200));
    COMMIT;

    IF NOT EXISTS (SELECT 1 FROM @Nuevo)
        THROW 50060, N'No se cambio la contrasena: usuario inexistente o inactivo, o la sesion cambio (sello distinto).', 1;

    SELECT SelloSeguridad FROM @Nuevo;
END
GO

/* Validacion de clave de API (RF-06). Devuelve 0 o 1 fila (ClaveApiId,
   Consumidor, Rol). Actualiza UltimoUso como maximo una vez cada 60 minutos
   (DEMO, ADR-001 5.2; frecuencia PENDIENTE de aprobacion, 5.4). */
CREATE OR ALTER PROCEDURE cob.sp_ValidarClaveApi
    @Prefijo   char(8),
    @HashClave binary(32)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Ahora datetime2(0) = SYSUTCDATETIME();
    DECLARE @Clave TABLE (ClaveApiId int NOT NULL, Consumidor varchar(50) NOT NULL, Rol varchar(10) NOT NULL);

    INSERT INTO @Clave (ClaveApiId, Consumidor, Rol)
    SELECT ClaveApiId, Consumidor, Rol
    FROM cob.ClaveApi
    WHERE Prefijo = @Prefijo
      AND HashClave = @HashClave
      AND Activa = 1
      AND FechaRevocacion IS NULL
      AND FechaVencimiento > @Ahora;

    UPDATE ca
       SET ca.UltimoUso = @Ahora
    FROM cob.ClaveApi AS ca
    JOIN @Clave AS c ON c.ClaveApiId = ca.ClaveApiId
    WHERE ca.UltimoUso IS NULL OR ca.UltimoUso < DATEADD(MINUTE, -60, @Ahora);

    SELECT ClaveApiId, Consumidor, Rol FROM @Clave;
END
GO

/* ---------------------------------------------------------------------------
   4. Procedimientos administrativos (SIN GRANT). Cada uno registra su evento
      en cob.LogAcceso con Actor = ORIGINAL_LOGIN(). Los que solo modifican no
      devuelven conjunto de resultados.
   --------------------------------------------------------------------------- */

/* Alta de usuario del panel. DebeCambiarClave = 1 y FechaCambioClave = ahora
   (inicio de la vigencia de la contrasena temporal). Evento AltaUsuario. */
CREATE OR ALTER PROCEDURE cob.sp_CrearUsuarioInterno
    @Usuario   varchar(50),
    @Nombre    nvarchar(120),
    @Rol       varchar(10),
    @HashClave varchar(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Usuario IS NULL
       OR LEN(@Usuario) NOT BETWEEN 3 AND 50
       OR DATALENGTH(@Usuario) <> LEN(@Usuario)
       OR @Usuario LIKE '%[^a-z0-9._-]%' COLLATE Latin1_General_BIN2   -- binaria: rechaza mayusculas
        THROW 50062, N'Usuario no valido: minusculas, 3 a 50 caracteres, solo a-z, 0-9, punto, guion bajo y guion.', 1;
    IF NULLIF(LTRIM(RTRIM(@Nombre)), N'') IS NULL
        THROW 50066, N'El nombre no puede ser vacio.', 1;
    IF @Rol IS NULL OR @Rol COLLATE Latin1_General_BIN2 NOT IN ('Finanzas', 'Ventas', 'Admin')   -- exacto: la API compara roles con mayusculas
        THROW 50063, N'Rol no valido. Use Finanzas, Ventas o Admin.', 1;
    IF NULLIF(@HashClave, '') IS NULL
        THROW 50065, N'El hash de la contrasena no puede ser vacio.', 1;
    IF EXISTS (SELECT 1 FROM cob.UsuarioInterno WHERE Usuario = @Usuario)
        THROW 50064, N'El usuario ya existe.', 1;

    DECLARE @Nuevo TABLE (UsuarioId int NOT NULL);

    BEGIN TRAN;
        INSERT INTO cob.UsuarioInterno (Usuario, Nombre, Rol, HashClave, DebeCambiarClave, FechaCambioClave)
        OUTPUT inserted.UsuarioId INTO @Nuevo (UsuarioId)
        VALUES (@Usuario, @Nombre, @Rol, @HashClave, 1, SYSUTCDATETIME());

        INSERT INTO cob.LogAcceso (Evento, UsuarioId, Detalle)
        SELECT 'AltaUsuario', n.UsuarioId, CONCAT(N'Rol=', @Rol) FROM @Nuevo AS n;
    COMMIT;
END
GO

/* Restablecimiento: hash temporal nuevo, DebeCambiarClave = 1,
   FechaCambioClave = ahora, desbloquea y cambia el sello. Evento RestablecimientoClave. */
CREATE OR ALTER PROCEDURE cob.sp_RestablecerClaveUsuario
    @Usuario   varchar(50),
    @HashClave varchar(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(@HashClave, '') IS NULL
        THROW 50065, N'El hash de la contrasena no puede ser vacio.', 1;
    DECLARE @UsuarioId int = (SELECT UsuarioId FROM cob.UsuarioInterno WHERE Usuario = @Usuario);
    IF @UsuarioId IS NULL
        THROW 50061, N'Usuario no encontrado.', 1;

    BEGIN TRAN;
        UPDATE cob.UsuarioInterno
           SET HashClave = @HashClave,
               DebeCambiarClave = 1,
               FechaCambioClave = SYSUTCDATETIME(),
               IntentosFallidos = 0,
               BloqueadoHasta = NULL,
               SelloSeguridad = NEWID()
         WHERE UsuarioId = @UsuarioId;

        INSERT INTO cob.LogAcceso (Evento, UsuarioId) VALUES ('RestablecimientoClave', @UsuarioId);
    COMMIT;
END
GO

/* Desbloqueo manual sin cambio de contrasena (verificacion presencial). Evento DesbloqueoManual. */
CREATE OR ALTER PROCEDURE cob.sp_DesbloquearUsuario
    @Usuario varchar(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @UsuarioId int = (SELECT UsuarioId FROM cob.UsuarioInterno WHERE Usuario = @Usuario);
    IF @UsuarioId IS NULL
        THROW 50061, N'Usuario no encontrado.', 1;

    BEGIN TRAN;
        UPDATE cob.UsuarioInterno
           SET IntentosFallidos = 0,
               BloqueadoHasta = NULL
         WHERE UsuarioId = @UsuarioId;

        INSERT INTO cob.LogAcceso (Evento, UsuarioId) VALUES ('DesbloqueoManual', @UsuarioId);
    COMMIT;
END
GO

/* Activacion o baja (la baja no borra la fila). Cambia el sello. Evento
   CambioEstadoUsuario con el valor anterior y el nuevo en Detalle (RNF-05). */
CREATE OR ALTER PROCEDURE cob.sp_CambiarEstadoUsuario
    @Usuario varchar(50),
    @Activo  bit
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Activo IS NULL
        THROW 50075, N'Activo debe ser 0 o 1.', 1;
    DECLARE @UsuarioId int = (SELECT UsuarioId FROM cob.UsuarioInterno WHERE Usuario = @Usuario);
    IF @UsuarioId IS NULL
        THROW 50061, N'Usuario no encontrado.', 1;

    DECLARE @Cambio TABLE (Anterior bit NOT NULL, Nuevo bit NOT NULL);

    BEGIN TRAN;
        UPDATE cob.UsuarioInterno
           SET Activo = @Activo,
               SelloSeguridad = NEWID()
        OUTPUT deleted.Activo, inserted.Activo INTO @Cambio (Anterior, Nuevo)
         WHERE UsuarioId = @UsuarioId;

        INSERT INTO cob.LogAcceso (Evento, UsuarioId, Detalle)
        SELECT 'CambioEstadoUsuario', @UsuarioId, CONCAT(N'Activo ', c.Anterior, N' -> ', c.Nuevo) FROM @Cambio AS c;
    COMMIT;
END
GO

/* Cambio de rol. Cambia el sello. Evento CambioRolUsuario con el valor
   anterior y el nuevo en Detalle (RNF-05). */
CREATE OR ALTER PROCEDURE cob.sp_CambiarRolUsuario
    @Usuario varchar(50),
    @Rol     varchar(10)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Rol IS NULL OR @Rol COLLATE Latin1_General_BIN2 NOT IN ('Finanzas', 'Ventas', 'Admin')   -- exacto: la API compara roles con mayusculas
        THROW 50063, N'Rol no valido. Use Finanzas, Ventas o Admin.', 1;
    DECLARE @UsuarioId int = (SELECT UsuarioId FROM cob.UsuarioInterno WHERE Usuario = @Usuario);
    IF @UsuarioId IS NULL
        THROW 50061, N'Usuario no encontrado.', 1;

    DECLARE @Cambio TABLE (Anterior varchar(10) NOT NULL, Nuevo varchar(10) NOT NULL);

    BEGIN TRAN;
        UPDATE cob.UsuarioInterno
           SET Rol = @Rol,
               SelloSeguridad = NEWID()
        OUTPUT deleted.Rol, inserted.Rol INTO @Cambio (Anterior, Nuevo)
         WHERE UsuarioId = @UsuarioId;

        INSERT INTO cob.LogAcceso (Evento, UsuarioId, Detalle)
        SELECT 'CambioRolUsuario', @UsuarioId, CONCAT(N'Rol ', c.Anterior, N' -> ', c.Nuevo) FROM @Cambio AS c;
    COMMIT;
END
GO

/* Alta de clave de API (prefijo y SHA-256; el valor real lo guarda el script
   de alta en Key Vault). Evento AltaClaveApi. */
CREATE OR ALTER PROCEDURE cob.sp_RegistrarClaveApi
    @Prefijo          char(8),
    @HashClave        binary(32),
    @Consumidor       varchar(50),
    @Rol              varchar(10),
    @FechaVencimiento datetime2(0),
    @NombreSecretoKv  varchar(127)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Prefijo IS NULL OR LEN(@Prefijo) <> 8 OR @Prefijo LIKE '%[^a-z2-7]%' COLLATE Latin1_General_BIN2
        THROW 50067, N'Prefijo no valido: 8 caracteres Base32 en minusculas (a-z, 2-7).', 1;
    IF @Consumidor IS NULL
       OR LEN(@Consumidor) NOT BETWEEN 3 AND 50
       OR DATALENGTH(@Consumidor) <> LEN(@Consumidor)
       OR @Consumidor LIKE '%[^a-z0-9-]%' COLLATE Latin1_General_BIN2
        THROW 50067, N'Consumidor no valido: 3 a 50 caracteres, solo a-z, 0-9 y guion.', 1;
    IF @NombreSecretoKv IS NULL OR @NombreSecretoKv <> 'apikey-' + @Consumidor + '-' + @Prefijo
        THROW 50067, N'NombreSecretoKv debe ser apikey-<consumidor>-<prefijo>.', 1;
    IF @HashClave IS NULL
        THROW 50065, N'El hash de la clave no puede ser vacio.', 1;
    IF @Rol IS NULL OR @Rol COLLATE Latin1_General_BIN2 <> 'Ventas'
        THROW 50063, N'Rol de clave de API no valido. Solo Ventas (ADR-001 5.1).', 1;
    IF @FechaVencimiento IS NULL OR @FechaVencimiento <= SYSUTCDATETIME()
        THROW 50070, N'FechaVencimiento debe ser posterior a la fecha actual (UTC).', 1;
    IF EXISTS (SELECT 1 FROM cob.ClaveApi WHERE Prefijo = @Prefijo)
        THROW 50068, N'El prefijo ya esta registrado.', 1;

    DECLARE @Nueva TABLE (ClaveApiId int NOT NULL);

    BEGIN TRAN;
        INSERT INTO cob.ClaveApi (Prefijo, HashClave, Consumidor, Rol, FechaVencimiento, NombreSecretoKv)
        OUTPUT inserted.ClaveApiId INTO @Nueva (ClaveApiId)
        VALUES (@Prefijo, @HashClave, @Consumidor, @Rol, @FechaVencimiento, @NombreSecretoKv);

        INSERT INTO cob.LogAcceso (Evento, ClaveApiId, Detalle)
        SELECT 'AltaClaveApi', n.ClaveApiId,
               CONCAT(N'Consumidor=', @Consumidor, N'; Prefijo=', @Prefijo, N'; Vence=', CONVERT(nvarchar(19), @FechaVencimiento, 120), N' UTC')
        FROM @Nueva AS n;
    COMMIT;
END
GO

/* Revocacion: Activa = 0 y FechaRevocacion. Idempotente: si ya estaba
   revocada no cambia nada ni registra otro evento (permite repetir
   revocaciones en la revision posterior a una restauracion, politica C.3).
   Prefijo inexistente: THROW 50069. Evento RevocacionClaveApi. */
CREATE OR ALTER PROCEDURE cob.sp_RevocarClaveApi
    @Prefijo char(8)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM cob.ClaveApi WHERE Prefijo = @Prefijo)
        THROW 50069, N'Clave de API no encontrada.', 1;

    DECLARE @Revocada TABLE (ClaveApiId int NOT NULL);

    BEGIN TRAN;
        UPDATE cob.ClaveApi
           SET Activa = 0,
               FechaRevocacion = SYSUTCDATETIME()
        OUTPUT inserted.ClaveApiId INTO @Revocada (ClaveApiId)
         WHERE Prefijo = @Prefijo
           AND (FechaRevocacion IS NULL OR Activa = 1);

        INSERT INTO cob.LogAcceso (Evento, ClaveApiId, Detalle)
        SELECT 'RevocacionClaveApi', r.ClaveApiId, CONCAT(N'Prefijo=', @Prefijo) FROM @Revocada AS r;
    COMMIT;
END
GO

/* Purga de la bitacora (D15, politica B.3). Minimo 90 dias (THROW 50071).
   Borra en lotes de @TamanoLote (5000 DEMO) por FechaUtc (IX_LogAcceso_Fecha);
   cada lote se confirma por separado si no hay transaccion externa.
   Registra PurgaLogAcceso con el total y devuelve 1 fila (FilasBorradas).
   No se otorga a ninguna identidad administrada (una identidad comprometida
   podria borrar su rastro). */
CREATE OR ALTER PROCEDURE cob.sp_PurgarLogAcceso
    @DiasRetencion int = 90,
    @TamanoLote    int = 5000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DiasRetencion IS NULL OR @DiasRetencion < 90 OR @DiasRetencion > 36500
        THROW 50071, N'DiasRetencion debe estar entre 90 y 36500 (retencion minima de cob.LogAcceso: 90 dias, D15).', 1;
    IF @TamanoLote IS NULL OR @TamanoLote < 1
        THROW 50072, N'TamanoLote debe ser mayor o igual a 1.', 1;

    DECLARE @Corte datetime2(0) = DATEADD(DAY, -@DiasRetencion, SYSUTCDATETIME());
    DECLARE @Total bigint = 0, @Filas int = 1;

    WHILE @Filas > 0
    BEGIN
        DELETE TOP (@TamanoLote) FROM cob.LogAcceso WHERE FechaUtc < @Corte;
        SET @Filas = @@ROWCOUNT;
        SET @Total += @Filas;
    END

    INSERT INTO cob.LogAcceso (Evento, Detalle)
    VALUES ('PurgaLogAcceso', CONCAT(N'FilasBorradas=', @Total, N'; DiasRetencion=', @DiasRetencion,
                                     N'; Corte=', CONVERT(nvarchar(19), @Corte, 120), N' UTC'));

    SELECT @Total AS FilasBorradas;
END
GO

/* Invalidacion masiva de sesiones (revision posterior a una restauracion,
   ADR-001 4.2 y politica C.3): SelloSeguridad nuevo para todos los usuarios.
   Evento InvalidacionSesiones con UsuarioId NULL. Sin conjunto de resultados
   (el total queda en Detalle). */
CREATE OR ALTER PROCEDURE cob.sp_InvalidarTodasLasSesiones
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Filas int;

    BEGIN TRAN;
        UPDATE cob.UsuarioInterno SET SelloSeguridad = NEWID();
        SET @Filas = @@ROWCOUNT;

        INSERT INTO cob.LogAcceso (Evento, UsuarioId, Detalle)
        VALUES ('InvalidacionSesiones', NULL, CONCAT(N'UsuariosAfectados=', @Filas));
    COMMIT;
END
GO

/* Eventos administrativos desde un punto (insumo de la revision posterior a
   restauracion, politica C.3). Solo lectura. Sin IP ni agente de usuario.
   Usuario y Prefijo se resuelven contra las tablas de ESTA base. */
CREATE OR ALTER PROCEDURE cob.sp_ListarEventosAccesoDesde
    @Desde datetime2(0)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Desde IS NULL
        THROW 50076, N'Desde no puede ser nulo (fecha UTC).', 1;

    SELECT la.LogAccesoId, la.FechaUtc, la.Evento, la.UsuarioId, u.Usuario,
           la.ClaveApiId, ca.Prefijo, la.Detalle, la.Actor
    FROM cob.LogAcceso AS la
    LEFT JOIN cob.UsuarioInterno AS u ON u.UsuarioId = la.UsuarioId
    LEFT JOIN cob.ClaveApi AS ca ON ca.ClaveApiId = la.ClaveApiId
    WHERE la.FechaUtc >= @Desde
      AND la.Evento IN ('RevocacionClaveApi', 'CambioEstadoUsuario', 'CambioRolUsuario', 'CambioClave',
                        'RestablecimientoClave', 'AltaUsuario', 'AltaClaveApi')
    ORDER BY la.FechaUtc, la.LogAccesoId;
END
GO

/* Cierre del alta (ADR-001 5.9, paso 8): indica si existe CambioClave del
   usuario posterior (por orden de registro) a su ultimo AltaUsuario o
   RestablecimientoClave. Devuelve 1 fila. Usuario inexistente: THROW 50061. */
CREATE OR ALTER PROCEDURE cob.sp_VerificarCambioClave
    @Usuario varchar(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UsuarioId int, @UsuarioReal varchar(50), @DebeCambiar bit;
    SELECT @UsuarioId = UsuarioId, @UsuarioReal = Usuario, @DebeCambiar = DebeCambiarClave
    FROM cob.UsuarioInterno WHERE Usuario = @Usuario;
    IF @UsuarioId IS NULL
        THROW 50061, N'Usuario no encontrado.', 1;

    DECLARE @IdEmision bigint, @FechaEmision datetime2(0), @IdCambio bigint, @FechaCambio datetime2(0);

    SELECT TOP (1) @IdEmision = LogAccesoId, @FechaEmision = FechaUtc
    FROM cob.LogAcceso
    WHERE UsuarioId = @UsuarioId AND Evento IN ('AltaUsuario', 'RestablecimientoClave')
    ORDER BY LogAccesoId DESC;

    SELECT TOP (1) @IdCambio = LogAccesoId, @FechaCambio = FechaUtc
    FROM cob.LogAcceso
    WHERE UsuarioId = @UsuarioId AND Evento = 'CambioClave' AND LogAccesoId > ISNULL(@IdEmision, 0)
    ORDER BY LogAccesoId;

    SELECT @UsuarioId AS UsuarioId,
           @UsuarioReal AS Usuario,
           @FechaEmision AS FechaEmision,
           @FechaCambio AS FechaCambioClave,
           CAST(CASE WHEN @IdCambio IS NULL THEN 0 ELSE 1 END AS bit) AS CambioRealizado,
           @DebeCambiar AS DebeCambiarClave;
END
GO

/* ---------------------------------------------------------------------------
   5. Vista de evidencias (SIN GRANT): IP enmascarada (IPv4 /24, IPv6 /48),
      agente de usuario reducido a familia de navegador y sistema operativo,
      Actor sin dominio. No expone IpOrigen ni AgenteUsuario originales.
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW cob.vw_LogAccesoEvidencia
AS
SELECT la.LogAccesoId,
       la.FechaUtc,
       la.Evento,
       la.Motivo,
       la.UsuarioId,
       la.UsuarioIngresado,
       la.ClaveApiId,
       cob.fn_EnmascararIp(la.IpOrigen) AS IpEnmascarada,
       CASE WHEN la.AgenteUsuario IS NULL THEN NULL
            ELSE CONCAT(
                   CASE WHEN la.AgenteUsuario LIKE N'%Edg/%'     THEN N'Edge'
                        WHEN la.AgenteUsuario LIKE N'%OPR/%'     THEN N'Opera'
                        WHEN la.AgenteUsuario LIKE N'%Firefox/%' THEN N'Firefox'
                        WHEN la.AgenteUsuario LIKE N'%Chrome/%'  THEN N'Chrome'
                        WHEN la.AgenteUsuario LIKE N'%Safari/%'  THEN N'Safari'
                        WHEN la.AgenteUsuario LIKE N'%curl/%'    THEN N'curl'
                        WHEN la.AgenteUsuario LIKE N'%k6/%'      THEN N'k6'
                        ELSE N'Otro' END,
                   N' / ',
                   CASE WHEN la.AgenteUsuario LIKE N'%Windows%'  THEN N'Windows'
                        WHEN la.AgenteUsuario LIKE N'%Android%'  THEN N'Android'
                        WHEN la.AgenteUsuario LIKE N'%iPhone%' OR la.AgenteUsuario LIKE N'%iPad%' THEN N'iOS'
                        WHEN la.AgenteUsuario LIKE N'%Mac OS X%' THEN N'macOS'
                        WHEN la.AgenteUsuario LIKE N'%Linux%'    THEN N'Linux'
                        ELSE N'Otro' END)
       END AS AgenteUsuarioReducido,
       CASE WHEN CHARINDEX(N'@', la.Actor) > 0 THEN LEFT(la.Actor, CHARINDEX(N'@', la.Actor) - 1) + N'@***'
            ELSE la.Actor END AS ActorReducido,
       la.Detalle
FROM cob.LogAcceso AS la;
GO

/* ---------------------------------------------------------------------------
   6. Permisos minimos para la API: solo EXECUTE sobre los 7 procedimientos
      del punto 3. Sin permisos sobre tablas, funciones, la vista ni los
      procedimientos administrativos.
   --------------------------------------------------------------------------- */
GRANT EXECUTE ON OBJECT::cob.sp_ObtenerUsuarioParaLogin TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_ObtenerUsuarioPorId     TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_RegistrarLoginFallido   TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_RegistrarLoginExitoso   TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_RegistrarLogout         TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_CambiarClave            TO [$(UsuarioApi)];
GRANT EXECUTE ON OBJECT::cob.sp_ValidarClaveApi         TO [$(UsuarioApi)];
GO

SET NOEXEC OFF;
GO
