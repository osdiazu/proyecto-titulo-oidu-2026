/* =============================================================================
   00_verificar_esquema.sql
   Proyecto APT Cobranza Automatizada - Embotelladora del Pacifico S.A.
   Evidencia S10 - Responsable de ejecucion: Especialista en Bases de Datos

   Proposito
   ---------
   Los scripts 03 en adelante se escribieron contra el esquema documentado en
   las evidencias S1-S6 (diccionario de datos) y S6-S8 (esquema cob). Antes de
   ejecutar cualquier script nuevo, este script compara ese esquema esperado con
   la base de datos desplegada y lista las diferencias.

   Uso: ejecutar en la base de datos del proyecto con un usuario de Entra ID
   miembro del grupo administrador. Es de solo lectura: no modifica nada.

   Resultado esperado: las consultas 1 a 5 devuelven 0 filas.
   Si devuelven filas, corregir los scripts nuevos o el esquema antes de seguir.

   Version 06-11-2026 (ADR-001): columnas de cob.UsuarioInterno, cob.ClaveApi y
   cob.LogAcceso; objetos de 12_autenticacion.sql; CHECK de EstadoEnvio con
   Limitado (consulta 4) y permisos no esperados sobre los objetos de
   autenticacion (consulta 5). Se ejecuta despues de 12 y 11.
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @Esperado TABLE (
    Esquema  sysname NOT NULL,
    Tabla    sysname NOT NULL,
    Columna  sysname NOT NULL
);

INSERT INTO @Esperado (Esquema, Tabla, Columna) VALUES
 (N'cob', N'Cliente', N'ClienteId'), (N'cob', N'Cliente', N'Rut'), (N'cob', N'Cliente', N'RazonSocial'),
 (N'cob', N'Cliente', N'Segmento'), (N'cob', N'Cliente', N'Email'), (N'cob', N'Cliente', N'Telefono'),
 (N'cob', N'Cliente', N'TipoConvenio'), (N'cob', N'Cliente', N'FechaRegistro'),

 (N'cob', N'Factura', N'FacturaId'), (N'cob', N'Factura', N'ClienteId'), (N'cob', N'Factura', N'NumeroFactura'),
 (N'cob', N'Factura', N'MontoTotal'), (N'cob', N'Factura', N'FechaEmision'), (N'cob', N'Factura', N'FechaVencimiento'),
 (N'cob', N'Factura', N'PlazoDias'), (N'cob', N'Factura', N'Estado'),

 (N'cob', N'EstadoMorosidad', N'EstadoId'), (N'cob', N'EstadoMorosidad', N'ClienteId'),
 (N'cob', N'EstadoMorosidad', N'FechaCambio'), (N'cob', N'EstadoMorosidad', N'EstadoAnterior'),
 (N'cob', N'EstadoMorosidad', N'EstadoNuevo'), (N'cob', N'EstadoMorosidad', N'OrigenCambio'),

 (N'cob', N'Pedido', N'PedidoId'), (N'cob', N'Pedido', N'ClienteId'), (N'cob', N'Pedido', N'NumeroPedido'),
 (N'cob', N'Pedido', N'FechaCreacion'), (N'cob', N'Pedido', N'Estado'), (N'cob', N'Pedido', N'FechaLiberacion'),

 (N'cob', N'LogNotificacion', N'LogNotificacionId'), (N'cob', N'LogNotificacion', N'FacturaId'),
 (N'cob', N'LogNotificacion', N'ClienteId'), (N'cob', N'LogNotificacion', N'TipoAviso'),
 (N'cob', N'LogNotificacion', N'EstadoEnvio'), (N'cob', N'LogNotificacion', N'Intentos'),

 (N'cob', N'LogSincronizacion', N'LogSincronizacionId'),

 /* ADR-001 5.1 */
 (N'cob', N'UsuarioInterno', N'UsuarioId'), (N'cob', N'UsuarioInterno', N'Usuario'), (N'cob', N'UsuarioInterno', N'Nombre'),
 (N'cob', N'UsuarioInterno', N'Rol'), (N'cob', N'UsuarioInterno', N'Activo'), (N'cob', N'UsuarioInterno', N'HashClave'),
 (N'cob', N'UsuarioInterno', N'DebeCambiarClave'), (N'cob', N'UsuarioInterno', N'IntentosFallidos'),
 (N'cob', N'UsuarioInterno', N'BloqueadoHasta'), (N'cob', N'UsuarioInterno', N'UltimoAcceso'),
 (N'cob', N'UsuarioInterno', N'FechaCambioClave'), (N'cob', N'UsuarioInterno', N'SelloSeguridad'),
 (N'cob', N'UsuarioInterno', N'FechaCreacion'),

 (N'cob', N'ClaveApi', N'ClaveApiId'), (N'cob', N'ClaveApi', N'Prefijo'), (N'cob', N'ClaveApi', N'HashClave'),
 (N'cob', N'ClaveApi', N'Consumidor'), (N'cob', N'ClaveApi', N'Rol'), (N'cob', N'ClaveApi', N'Activa'),
 (N'cob', N'ClaveApi', N'FechaCreacion'), (N'cob', N'ClaveApi', N'FechaVencimiento'), (N'cob', N'ClaveApi', N'FechaRevocacion'),
 (N'cob', N'ClaveApi', N'UltimoUso'), (N'cob', N'ClaveApi', N'NombreSecretoKv'),

 (N'cob', N'LogAcceso', N'LogAccesoId'), (N'cob', N'LogAcceso', N'FechaUtc'), (N'cob', N'LogAcceso', N'Evento'),
 (N'cob', N'LogAcceso', N'Motivo'), (N'cob', N'LogAcceso', N'UsuarioId'), (N'cob', N'LogAcceso', N'UsuarioIngresado'),
 (N'cob', N'LogAcceso', N'ClaveApiId'), (N'cob', N'LogAcceso', N'IpOrigen'), (N'cob', N'LogAcceso', N'AgenteUsuario'),
 (N'cob', N'LogAcceso', N'Actor'), (N'cob', N'LogAcceso', N'Detalle');

/* 1. Columnas esperadas que no existen en la base desplegada */
SELECT e.Esquema, e.Tabla, e.Columna, N'FALTA en la base desplegada' AS Hallazgo
FROM @Esperado AS e
WHERE NOT EXISTS (
    SELECT 1
    FROM sys.columns AS c
    JOIN sys.tables  AS t ON t.object_id = c.object_id
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE s.name = e.Esquema AND t.name = e.Tabla AND c.name = e.Columna)
ORDER BY e.Tabla, e.Columna;

/* 2. Objetos programables esperados (S6-S8 y ADR-001) que no existen */
SELECT v.Objeto, N'FALTA objeto programable' AS Hallazgo
FROM (VALUES (N'cob.sp_SincronizarClientesRegularizados'),
             (N'cob.sp_LiberarPedidosRetenidos'),
             (N'cob.sp_GenerarAlertasVencimiento'),
             (N'cob.tr_EstadoMorosidad_Liberar'),
             (N'cob.sp_RegistrarNotificacion'),
             /* 12_autenticacion.sql: con GRANT a UsuarioApi */
             (N'cob.sp_ObtenerUsuarioParaLogin'), (N'cob.sp_ObtenerUsuarioPorId'),
             (N'cob.sp_RegistrarLoginFallido'),   (N'cob.sp_RegistrarLoginExitoso'),
             (N'cob.sp_RegistrarLogout'),         (N'cob.sp_CambiarClave'),
             (N'cob.sp_ValidarClaveApi'),
             /* 12_autenticacion.sql: administrativos, sin GRANT */
             (N'cob.sp_CrearUsuarioInterno'),     (N'cob.sp_RestablecerClaveUsuario'),
             (N'cob.sp_DesbloquearUsuario'),      (N'cob.sp_CambiarEstadoUsuario'),
             (N'cob.sp_CambiarRolUsuario'),       (N'cob.sp_RegistrarClaveApi'),
             (N'cob.sp_RevocarClaveApi'),         (N'cob.sp_PurgarLogAcceso'),
             (N'cob.sp_InvalidarTodasLasSesiones'), (N'cob.sp_ListarEventosAccesoDesde'),
             (N'cob.sp_VerificarCambioClave'),
             (N'cob.vw_LogAccesoEvidencia'),
             (N'cob.fn_SanearUsuarioIngresado'),  (N'cob.fn_EnmascararIp')) AS v(Objeto)
WHERE OBJECT_ID(v.Objeto) IS NULL;

/* 3. Tipo de tabla cob.ListaRut: debe existir y tener exactamente 1 columna */
SELECT N'cob.ListaRut' AS Objeto,
       CASE WHEN tt.user_type_id IS NULL THEN N'FALTA el tipo de tabla'
            ELSE N'El tipo tiene ' + CAST(COUNT(c.column_id) AS nvarchar(5)) + N' columnas; se esperaba 1' END AS Hallazgo
FROM (SELECT 1 AS x) AS d
LEFT JOIN sys.table_types AS tt
       ON tt.name = N'ListaRut' AND SCHEMA_NAME(tt.schema_id) = N'cob'
LEFT JOIN sys.columns AS c ON c.object_id = tt.type_table_object_id
GROUP BY tt.user_type_id
HAVING tt.user_type_id IS NULL OR COUNT(c.column_id) <> 1;

/* 4. CHECK de EstadoEnvio: debe admitir Limitado (ADR-001 5.12). SQL Server
      guarda IN (...) como OR de igualdades. */
SELECT N'cob.LogNotificacion.CK_LogNotificacion_EstadoEnvio' AS Objeto,
       N'FALTA el CHECK o no admite Limitado' AS Hallazgo
WHERE NOT EXISTS (SELECT 1 FROM sys.check_constraints AS cc
                  WHERE cc.parent_object_id = OBJECT_ID(N'cob.LogNotificacion')
                    AND cc.name = N'CK_LogNotificacion_EstadoEnvio'
                    AND cc.definition LIKE N'%''Aceptado''%'
                    AND cc.definition LIKE N'%''Fallido''%'
                    AND cc.definition LIKE N'%''Limitado''%');

/* 5. Permisos no esperados (ADR-001 5.1, 5.2 y 7.2; politica B.4):
      - ningun permiso concedido sobre cob.LogAcceso, cob.ClaveApi,
        cob.UsuarioInterno, cob.vw_LogAccesoEvidencia ni las funciones de 12;
      - ningun EXECUTE sobre los procedimientos administrativos de 12;
      - ningun permiso a nivel del esquema cob;
      - ningun usuario de Entra ID en db_datareader, db_datawriter ni db_owner. */
DECLARE @Restringidos TABLE (Objeto sysname NOT NULL);
INSERT INTO @Restringidos (Objeto) VALUES
 (N'cob.LogAcceso'), (N'cob.ClaveApi'), (N'cob.UsuarioInterno'), (N'cob.vw_LogAccesoEvidencia'),
 (N'cob.fn_SanearUsuarioIngresado'), (N'cob.fn_EnmascararIp'),
 (N'cob.sp_CrearUsuarioInterno'), (N'cob.sp_RestablecerClaveUsuario'), (N'cob.sp_DesbloquearUsuario'),
 (N'cob.sp_CambiarEstadoUsuario'), (N'cob.sp_CambiarRolUsuario'), (N'cob.sp_RegistrarClaveApi'),
 (N'cob.sp_RevocarClaveApi'), (N'cob.sp_PurgarLogAcceso'), (N'cob.sp_InvalidarTodasLasSesiones'),
 (N'cob.sp_ListarEventosAccesoDesde'), (N'cob.sp_VerificarCambioClave');

SELECT pr.name AS Principal, dp.permission_name AS Permiso, r.Objeto, N'Permiso no esperado sobre objeto restringido' AS Hallazgo
FROM sys.database_permissions AS dp
JOIN sys.database_principals AS pr ON pr.principal_id = dp.grantee_principal_id
JOIN @Restringidos AS r ON OBJECT_ID(r.Objeto) = dp.major_id
WHERE dp.class = 1 AND dp.state IN ('G', 'W')
UNION ALL
SELECT pr.name, dp.permission_name, N'SCHEMA::cob', N'Permiso a nivel de esquema (debe ser por objeto)'
FROM sys.database_permissions AS dp
JOIN sys.database_principals AS pr ON pr.principal_id = dp.grantee_principal_id
WHERE dp.class = 3 AND dp.major_id = SCHEMA_ID(N'cob') AND dp.state IN ('G', 'W')
UNION ALL
SELECT m.name, N'MIEMBRO', ro.name, N'Usuario de Entra ID en rol fijo de lectura/escritura'
FROM sys.database_role_members AS rm
JOIN sys.database_principals AS ro ON ro.principal_id = rm.role_principal_id
JOIN sys.database_principals AS m  ON m.principal_id = rm.member_principal_id
WHERE ro.name IN (N'db_datareader', N'db_datawriter', N'db_owner') AND m.type IN ('E', 'X');

/* Informativo: columnas reales de las bitacoras (los scripts 04 y 05 las amplian si faltan) */
SELECT t.name AS Tabla, c.name AS Columna, TYPE_NAME(c.user_type_id) AS Tipo, c.max_length, c.is_nullable
FROM sys.columns AS c
JOIN sys.tables  AS t ON t.object_id = c.object_id
WHERE SCHEMA_NAME(t.schema_id) = N'cob' AND t.name IN (N'LogNotificacion', N'LogSincronizacion')
ORDER BY t.name, c.column_id;

/* Informativo: restricciones CHECK vigentes (valores permitidos de estados y tipos de aviso).
   Los scripts nuevos usan: Factura.Estado {Pendiente, Vencida, Pagada};
   EstadoMorosidad {AlDia, Moroso, Suspendido, Regularizado}; OrigenCambio {SincronizacionAutomatica, Manual};
   Pedido.Estado {Retenido, Liberado, Despachado}; TipoAviso {Preaviso, Vencimiento, Mora1, Mora2};
   EstadoEnvio {Aceptado, Fallido, Limitado} (Limitado: ADR-001 5.12);
   UsuarioInterno.Rol {Finanzas, Ventas, Admin}; ClaveApi.Rol {Ventas};
   LogAcceso.Evento (14 valores) y LogAcceso.Motivo (5 valores) segun ADR-001 5.1.
   Si las restricciones no admiten estos valores, ajustar antes de seguir. */
SELECT OBJECT_NAME(cc.parent_object_id) AS Tabla, cc.name AS Restriccion, cc.definition
FROM sys.check_constraints AS cc
WHERE SCHEMA_NAME(cc.schema_id) = N'cob'
ORDER BY Tabla, Restriccion;

/* Informativo: usuarios de base de datos creados desde Entra ID (identidades administradas y grupos) */
SELECT name AS UsuarioBD, type_desc, authentication_type_desc
FROM sys.database_principals
WHERE type IN ('E', 'X')
ORDER BY name;
