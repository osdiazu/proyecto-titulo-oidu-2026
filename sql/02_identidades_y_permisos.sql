/* =====================================================================
   Script 02: usuarios de base de datos para las identidades administradas
   Estado: PREPARADO, NO EJECUTADO.

   Adaptacion 05-11-2026 (desde la version S6-S8): los nombres entre <> se
   reemplazaron por variables SQLCMD, igual que en los scripts 03 a 06.

   Variables SQLCMD (sqlcmd -v o modo SQLCMD de SSMS / Azure Data Studio):
     UsuarioFunctionApp : nombre de la Function App (salida usuarioFunctionApp
                          de infra/main.bicep; la identidad administrada del
                          sistema tiene el mismo nombre que el sitio).
     UsuarioApi         : nombre de la Web App de la API (salida usuarioApi).

   Debe ejecutarse conectado con una cuenta de Entra ID miembro del grupo
   administrador (grp-cobranza-sql-admin); CREATE USER ... FROM EXTERNAL
   PROVIDER no funciona con autenticacion SQL.

   Permisos: este script solo crea los usuarios. Los permisos minimos se
   otorgan objeto por objeto en los scripts siguientes:
     03 -> UsuarioFunctionApp: SELECT sobre origen_sim.vw_ClientesRegularizados
     04 -> UsuarioFunctionApp: EXECUTE sobre procedimientos de jobs y bitacoras
     05 -> UsuarioFunctionApp: EXECUTE sobre sp_SincronizarClientesRegularizados
           y sobre el tipo cob.ListaRut
     06 -> UsuarioApi: EXECUTE sobre los procedimientos de consulta
   Respecto de S6-S8 se retiraron db_datareader (ambas identidades),
   EXECUTE ON SCHEMA::cob e INSERT sobre cob.LogNotificacion, porque 06 indica
   que la API no tiene SELECT directo sobre tablas y la escritura ocurre solo
   mediante procedimientos almacenados (sp_RegistrarNotificacion).
   Ninguna identidad recibe db_datawriter.
   ===================================================================== */
SET NOCOUNT ON;
GO

/* Identidad de los jobs (Function App) */
IF DATABASE_PRINCIPAL_ID(N'$(UsuarioFunctionApp)') IS NULL
    CREATE USER [$(UsuarioFunctionApp)] FROM EXTERNAL PROVIDER;
GO

/* Identidad de la API interna (App Service) */
IF DATABASE_PRINCIPAL_ID(N'$(UsuarioApi)') IS NULL
    CREATE USER [$(UsuarioApi)] FROM EXTERNAL PROVIDER;
GO

/* -----------------------------------------------------------------------------
   ALTERNATIVA M-08a (PREPARADA, COMENTADA, NO VERIFICADA EN EL TENANT)
   -----------------------------------------------------------------------------
   Usar solo si los CREATE USER ... FROM EXTERNAL PROVIDER anteriores fallan
   porque el tenant (Duoc) restringe la lectura del directorio (Microsoft Graph)
   al operador o al servidor SQL. Con WITH SID el motor no consulta Graph: el
   usuario se crea a partir del identificador de la aplicacion.

   Como obtener el SID (sin escribir IDs reales en el repositorio):
     1. El SID de una identidad administrada (o de cualquier entidad de servicio)
        se forma con su CLIENT ID (= application ID / appId), NO con el object ID
        (principalId). Si se usa el object ID, el usuario se crea pero el inicio
        de sesion de la identidad falla.
     2. Obtener el clientId de la identidad administrada del sistema:
        - con lectura de directorio:
            az webapp identity show -g <rg> -n <sitio> --query principalId -o tsv   (object ID)
            az ad sp show --id <principalId> --query appId -o tsv                    (client ID)
        - sin lectura de directorio (solo ARM, rol Lector sobre el sitio; NO VERIFICADO):
            az rest --method get --url "https://management.azure.com/<idRecursoSitio>/providers/Microsoft.ManagedIdentity/identities/default?api-version=2023-01-31" --query properties.clientId -o tsv
        - o desde la propia aplicacion: claim "appid"/"azp" de un token emitido a la identidad.
     3. Convertir el clientId a SID con CONVERT (respeta el orden de bytes de
        uniqueidentifier; NO copiar el texto hexadecimal del GUID a mano):
            SELECT CONVERT(varchar(34), CONVERT(varbinary(16), CAST(N'<clientId>' AS uniqueidentifier)), 1);
        El bloque siguiente hace la conversion y arma el CREATE USER, porque
        WITH SID solo acepta un literal binario.
     4. Verificar despues: SELECT name, type_desc, CAST(sid AS uniqueidentifier) AS ClientId
                           FROM sys.database_principals WHERE type = 'E';
        La columna ClientId debe coincidir con el clientId de cada identidad.
   TYPE = E corresponde a usuario o aplicacion de Entra ID (TYPE = X seria grupo).

   Para activar: reemplazar <clientId Function App> y <clientId API> (o
   convertirlos en variables SQLCMD), quitar los delimitadores de comentario y
   comentar los dos CREATE USER ... FROM EXTERNAL PROVIDER anteriores.
   Nota: no se escriben aqui variables SQLCMD con la sintaxis de dolar y
   parentesis porque sqlcmd tambien las sustituye dentro de comentarios y
   exigiria definirlas aunque el bloque no se use. El bloque no contiene GO
   (sqlcmd podria cortar el lote dentro del comentario): ejecutarlo como un solo lote.

IF DATABASE_PRINCIPAL_ID(N'<nombre Function App>') IS NULL
BEGIN
    DECLARE @sidFn varbinary(16) = CONVERT(varbinary(16), CAST(N'<clientId Function App>' AS uniqueidentifier));
    DECLARE @sqlFn nvarchar(400) = N'CREATE USER ' + QUOTENAME(N'<nombre Function App>')
                                 + N' WITH SID = ' + CONVERT(nvarchar(34), @sidFn, 1) + N', TYPE = E;';
    EXEC (@sqlFn);
END

IF DATABASE_PRINCIPAL_ID(N'<nombre API>') IS NULL
BEGIN
    DECLARE @sidApi varbinary(16) = CONVERT(varbinary(16), CAST(N'<clientId API>' AS uniqueidentifier));
    DECLARE @sqlApi nvarchar(400) = N'CREATE USER ' + QUOTENAME(N'<nombre API>')
                                  + N' WITH SID = ' + CONVERT(nvarchar(34), @sidApi, 1) + N', TYPE = E;';
    EXEC (@sqlApi);
END
   ----------------------------------------------------------------------------- */

/* Verificacion informativa */
SELECT name AS UsuarioBD, type_desc, authentication_type_desc
FROM sys.database_principals
WHERE name IN (N'$(UsuarioFunctionApp)', N'$(UsuarioApi)')
ORDER BY name;
GO
