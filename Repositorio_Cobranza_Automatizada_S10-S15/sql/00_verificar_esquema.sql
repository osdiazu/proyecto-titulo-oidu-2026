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

   Resultado esperado: las tres consultas finales devuelven 0 filas.
   Si devuelven filas, corregir los scripts nuevos o el esquema antes de seguir.
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

 (N'cob', N'LogSincronizacion', N'LogSincronizacionId');

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

/* 2. Objetos programables esperados de S6-S8 que no existen */
SELECT v.Objeto, N'FALTA objeto programable' AS Hallazgo
FROM (VALUES (N'cob.sp_SincronizarClientesRegularizados'),
             (N'cob.sp_LiberarPedidosRetenidos'),
             (N'cob.sp_GenerarAlertasVencimiento'),
             (N'cob.tr_EstadoMorosidad_Liberar')) AS v(Objeto)
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
   EstadoEnvio {Aceptado, Fallido}. Si las restricciones no admiten estos valores, ajustar antes de seguir. */
SELECT OBJECT_NAME(cc.parent_object_id) AS Tabla, cc.name AS Restriccion, cc.definition
FROM sys.check_constraints AS cc
WHERE SCHEMA_NAME(cc.schema_id) = N'cob'
ORDER BY Tabla, Restriccion;

/* Informativo: usuarios de base de datos creados desde Entra ID (identidades administradas y grupos) */
SELECT name AS UsuarioBD, type_desc, authentication_type_desc
FROM sys.database_principals
WHERE type IN ('E', 'X')
ORDER BY name;
