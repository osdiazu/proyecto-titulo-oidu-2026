/* =============================================================================
   03_origen_simulado.sql
   Proyecto APT Cobranza Automatizada - Evidencia S10

   Proposito
   ---------
   El motor, la ubicacion y la vista de la base de datos de Embotelladora del
   Pacifico S.A. aun no estan definidos (pendiente registrado en S6-S8). Para
   construir y probar el job de sincronizacion se crea una FUENTE SIMULADA de
   solo lectura en el esquema origen_sim, dentro de la misma base del proyecto,
   sin costo adicional.

   Cuando se defina la base real:
     1. La embotelladora expone una vista con las columnas Rut y FechaRegularizacion.
     2. Se entrega un usuario de solo lectura (SELECT unicamente sobre esa vista).
     3. Se cambian los ajustes Cobranza__SqlOrigen y Cobranza__VistaOrigen de la
        Function App. El codigo no cambia.
     4. Este esquema se elimina (seccion final, comentada).

   Variables SQLCMD (ejecutar con sqlcmd -v o en modo SQLCMD de SSMS / Azure Data Studio):
     UsuarioFunctionApp : nombre del usuario de BD de la identidad administrada de
                          la Function App (ver consulta informativa de 00_verificar_esquema.sql).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'origen_sim') IS NULL
    EXEC (N'CREATE SCHEMA origen_sim AUTHORIZATION dbo;');
GO

/* Tabla que representa el registro de regularizacion que mantiene la embotelladora */
IF OBJECT_ID(N'origen_sim.ClienteRegularizacion', N'U') IS NULL
BEGIN
    CREATE TABLE origen_sim.ClienteRegularizacion (
        Rut                  varchar(12)  NOT NULL,
        Regularizado         bit          NOT NULL CONSTRAINT DF_ClienteRegularizacion_Regularizado DEFAULT (0),
        FechaRegularizacion  datetime2(0) NULL,
        FechaActualizacion   datetime2(0) NOT NULL CONSTRAINT DF_ClienteRegularizacion_FechaAct DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ClienteRegularizacion PRIMARY KEY (Rut),
        CONSTRAINT CK_ClienteRegularizacion_Fecha CHECK (Regularizado = 0 OR FechaRegularizacion IS NOT NULL)
    );
END
GO

/* Contrato de la fuente: solo Rut y FechaRegularizacion de clientes regularizados */
CREATE OR ALTER VIEW origen_sim.vw_ClientesRegularizados
AS
SELECT cr.Rut, cr.FechaRegularizacion
FROM origen_sim.ClienteRegularizacion AS cr
WHERE cr.Regularizado = 1;
GO

/* Permisos: la identidad de la Function App solo puede LEER la vista */
GRANT SELECT ON OBJECT::origen_sim.vw_ClientesRegularizados TO [$(UsuarioFunctionApp)];
DENY  INSERT, UPDATE, DELETE, ALTER ON SCHEMA::origen_sim TO [$(UsuarioFunctionApp)];
DENY  SELECT ON OBJECT::origen_sim.ClienteRegularizacion TO [$(UsuarioFunctionApp)];
GO

/* Verificacion de solo lectura (debe devolver SELECT=1 y el resto 0) */
EXECUTE AS USER = N'$(UsuarioFunctionApp)';
SELECT
    HAS_PERMS_BY_NAME(N'origen_sim.vw_ClientesRegularizados', N'OBJECT', N'SELECT') AS PuedeLeerVista,
    HAS_PERMS_BY_NAME(N'origen_sim.ClienteRegularizacion',   N'OBJECT', N'SELECT') AS PuedeLeerTablaBase,
    HAS_PERMS_BY_NAME(N'origen_sim.ClienteRegularizacion',   N'OBJECT', N'INSERT') AS PuedeInsertar,
    HAS_PERMS_BY_NAME(N'origen_sim.ClienteRegularizacion',   N'OBJECT', N'UPDATE') AS PuedeActualizar,
    HAS_PERMS_BY_NAME(N'origen_sim.ClienteRegularizacion',   N'OBJECT', N'DELETE') AS PuedeEliminar;
REVERT;
GO

/* -----------------------------------------------------------------------------
   Retiro de la fuente simulada (ejecutar solo cuando la fuente real este operativa)
   -----------------------------------------------------------------------------
DROP VIEW  IF EXISTS origen_sim.vw_ClientesRegularizados;
DROP TABLE IF EXISTS origen_sim.ClienteRegularizacion;
DROP SCHEMA IF EXISTS origen_sim;
----------------------------------------------------------------------------- */
