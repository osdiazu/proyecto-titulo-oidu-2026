/* =============================================================================
   10_marcador_rpo.sql
   Proyecto APT Cobranza Automatizada - Evidencia S14 (simulacro de continuidad)

   Crea el esquema ops con una tabla de marcadores de tiempo. Durante el simulacro
   de restauracion se inserta un marcador cada 30 segundos (seccion 2). Despues de
   restaurar a un punto en el tiempo, el ultimo marcador presente en la base
   restaurada indica hasta que instante se recupero la informacion:
       RPO medido = instante solicitado de restauracion - ultimo marcador restaurado
   (o, si se restaura al ultimo punto disponible, instante del incidente - ultimo marcador).
   ============================================================================= */
SET NOCOUNT ON;
GO
IF SCHEMA_ID(N'ops') IS NULL EXEC (N'CREATE SCHEMA ops AUTHORIZATION dbo;');
GO
IF OBJECT_ID(N'ops.MarcadorRpo', N'U') IS NULL
    CREATE TABLE ops.MarcadorRpo (
        MarcadorId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_MarcadorRpo PRIMARY KEY,
        FechaUtc   datetime2(3) NOT NULL CONSTRAINT DF_MarcadorRpo_Fecha DEFAULT (SYSUTCDATETIME()),
        Simulacro  varchar(30)  NOT NULL
    );
GO

/* ---------------------------------------------------------------------------
   Seccion 2 - Generador de marcadores (ejecutar en una sesion aparte durante el
   simulacro; se detiene solo al cumplir @Minutos o cancelando la consulta).
   Variables SQLCMD: Simulacro (ej. DR-01-20261110), Minutos (ej. 40)
   ---------------------------------------------------------------------------
DECLARE @Fin datetime2 = DATEADD(minute, $(Minutos), SYSUTCDATETIME());
WHILE SYSUTCDATETIME() < @Fin
BEGIN
    INSERT ops.MarcadorRpo (Simulacro) VALUES ('$(Simulacro)');
    WAITFOR DELAY '00:00:30';
END
--------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   Seccion 3 - Medicion en la base RESTAURADA
   ---------------------------------------------------------------------------
SELECT MAX(FechaUtc) AS UltimoMarcadorRestaurado, COUNT(*) AS Marcadores
FROM ops.MarcadorRpo WHERE Simulacro = '$(Simulacro)';
--------------------------------------------------------------------------- */
