/* =============================================================================
   07_pruebas_desbloqueo.sql
   Proyecto APT Cobranza Automatizada - Evidencia S11
   Pruebas unitarias T-SQL de la automatizacion de desbloqueo (scripts 04 y 05).

   - Todo se ejecuta dentro de una transaccion que se revierte al final:
     no deja datos en la base.
   - Los resultados se guardan en una variable de tabla (sobrevive al ROLLBACK)
     y se muestran al final. Criterio de aprobacion: todas las filas con Resultado = APROBADA.
   - Ejecutar con un usuario administrador (grupo admin de Entra ID), NO con la
     identidad de la Function App.

   Casos:
     PU-01 Cliente Suspendido con 2 pedidos retenidos y 1 despachado -> Regularizado, 2 liberados
     PU-02 Los pedidos Despachado no se modifican
     PU-03 Cada pedido liberado queda en cob.LogCambioPedido (RNF-05)
     PU-04 Idempotencia: repetir la misma lista no genera cambios
     PU-05 Cliente AlDia incluido en la lista -> sin cambios
     PU-06 RUT inexistente -> se informa en RutsNoEncontrados
     PU-07 RUT con puntos y k minuscula se reconoce (normalizacion)
     PU-08 Cliente Moroso sin pedidos -> Regularizado, 0 pedidos liberados
     PU-09 Origen del cambio = SincronizacionAutomatica
     PU-10 sp_LiberarPedidosRetenidos rechaza un cliente Suspendido (error 50020)
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT OFF;

DECLARE @Resultados TABLE (Caso varchar(6), Descripcion nvarchar(200), Esperado nvarchar(100), Obtenido nvarchar(100), Resultado varchar(10));
DECLARE @Salida TABLE (RutsRecibidos int, RutsNoEncontrados int, ClientesActualizados int, PedidosLiberados int);
DECLARE @Lista cob.ListaRut;
DECLARE @A int, @B int, @C int, @D int, @E int, @Obt nvarchar(100);

BEGIN TRAN;

/* ---------- Datos de prueba (RUT validos, razon social con prefijo PRUEBA) ---------- */
INSERT INTO cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76111111-6', 'PRUEBA Minimarket A', 'Tradicional', 'prueba.a@example.invalid', '000000000', '30', SYSUTCDATETIME());
SET @A = SCOPE_IDENTITY();
INSERT INTO cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76222222-1', 'PRUEBA Supermercado B', 'Digital', 'prueba.b@example.invalid', '000000000', '60', SYSUTCDATETIME());
SET @B = SCOPE_IDENTITY();
INSERT INTO cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76500005-K', 'PRUEBA Restaurante C', 'Tradicional', 'prueba.c@example.invalid', '000000000', '30', SYSUTCDATETIME());
SET @C = SCOPE_IDENTITY();
INSERT INTO cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76333333-7', 'PRUEBA Hotel D', 'Digital', 'prueba.d@example.invalid', '000000000', '60', SYSUTCDATETIME());
SET @D = SCOPE_IDENTITY();
INSERT INTO cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76444444-2', 'PRUEBA Almacen E', 'Tradicional', 'prueba.e@example.invalid', '000000000', '30', SYSUTCDATETIME());
SET @E = SCOPE_IDENTITY();

INSERT INTO cob.EstadoMorosidad (ClienteId, FechaCambio, EstadoAnterior, EstadoNuevo, OrigenCambio) VALUES
 (@A, DATEADD(day, -10, SYSUTCDATETIME()), 'AlDia',  'Moroso',     'Manual'),
 (@A, DATEADD(day, -5,  SYSUTCDATETIME()), 'Moroso', 'Suspendido', 'Manual'),
 (@C, DATEADD(day, -5,  SYSUTCDATETIME()), 'AlDia',  'Suspendido', 'Manual'),
 (@D, DATEADD(day, -3,  SYSUTCDATETIME()), 'AlDia',  'Moroso',     'Manual'),
 (@E, DATEADD(day, -5,  SYSUTCDATETIME()), 'AlDia',  'Suspendido', 'Manual');

INSERT INTO cob.Pedido (ClienteId, NumeroPedido, FechaCreacion, Estado, FechaLiberacion) VALUES
 (@A, 'PRU-A-001', SYSUTCDATETIME(), 'Retenido',   NULL),
 (@A, 'PRU-A-002', SYSUTCDATETIME(), 'Retenido',   NULL),
 (@A, 'PRU-A-003', SYSUTCDATETIME(), 'Despachado', NULL),
 (@C, 'PRU-C-001', SYSUTCDATETIME(), 'Retenido',   NULL),
 (@E, 'PRU-E-001', SYSUTCDATETIME(), 'Retenido',   NULL);

/* ---------- Primera sincronizacion: A, B, C (con formato distinto), D y un RUT inexistente ---------- */
INSERT INTO @Lista VALUES ('76111111-6'), ('76222222-1'), ('76.500.005-k'), ('76333333-7'), ('79999999-4');
INSERT INTO @Salida EXEC cob.sp_SincronizarClientesRegularizados @Ruts = @Lista;

/* PU-01 */
SELECT @Obt = CONCAT((SELECT EstadoActual FROM cob.vw_EstadoActualCliente WHERE ClienteId = @A), ' / ',
                     (SELECT COUNT(*) FROM cob.Pedido WHERE ClienteId = @A AND Estado = 'Liberado'));
INSERT @Resultados VALUES ('PU-01', N'Suspendido con 2 retenidos pasa a Regularizado y libera 2', N'Regularizado / 2', @Obt,
    CASE WHEN @Obt = N'Regularizado / 2' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-02 */
SELECT @Obt = (SELECT Estado FROM cob.Pedido WHERE ClienteId = @A AND NumeroPedido = 'PRU-A-003');
INSERT @Resultados VALUES ('PU-02', N'Pedido Despachado no se modifica', N'Despachado', @Obt,
    CASE WHEN @Obt = N'Despachado' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-03 */
SELECT @Obt = CAST((SELECT COUNT(*) FROM cob.LogCambioPedido
                    WHERE ClienteId IN (@A, @C) AND EstadoAnterior = 'Retenido' AND EstadoNuevo = 'Liberado'
                      AND OrigenCambio = 'TriggerRegularizacion') AS nvarchar(10));
INSERT @Resultados VALUES ('PU-03', N'Pedidos liberados registrados en LogCambioPedido', N'3', @Obt,
    CASE WHEN @Obt = N'3' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-06 y conteos de la primera ejecucion */
SELECT @Obt = CONCAT(RutsRecibidos, '/', RutsNoEncontrados, '/', ClientesActualizados, '/', PedidosLiberados) FROM @Salida;
INSERT @Resultados VALUES ('PU-06', N'Conteos 1a ejecucion: recibidos/no encontrados/actualizados/liberados', N'5/1/3/3', @Obt,
    CASE WHEN @Obt = N'5/1/3/3' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-05 */
SELECT @Obt = (SELECT EstadoActual FROM cob.vw_EstadoActualCliente WHERE ClienteId = @B);
INSERT @Resultados VALUES ('PU-05', N'Cliente AlDia en la lista no cambia', N'AlDia', @Obt,
    CASE WHEN @Obt = N'AlDia' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-07 */
SELECT @Obt = CONCAT((SELECT EstadoActual FROM cob.vw_EstadoActualCliente WHERE ClienteId = @C), ' / ',
                     (SELECT Estado FROM cob.Pedido WHERE NumeroPedido = 'PRU-C-001'));
INSERT @Resultados VALUES ('PU-07', N'RUT 76.500.005-k reconocido y pedido liberado', N'Regularizado / Liberado', @Obt,
    CASE WHEN @Obt = N'Regularizado / Liberado' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-08 */
SELECT @Obt = (SELECT EstadoActual FROM cob.vw_EstadoActualCliente WHERE ClienteId = @D);
INSERT @Resultados VALUES ('PU-08', N'Moroso sin pedidos pasa a Regularizado', N'Regularizado', @Obt,
    CASE WHEN @Obt = N'Regularizado' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-09 */
SELECT @Obt = (SELECT TOP (1) OrigenCambio FROM cob.EstadoMorosidad WHERE ClienteId = @A ORDER BY FechaCambio DESC, EstadoId DESC);
INSERT @Resultados VALUES ('PU-09', N'Origen del cambio registrado', N'SincronizacionAutomatica', @Obt,
    CASE WHEN @Obt = N'SincronizacionAutomatica' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-04: segunda ejecucion con la misma lista */
DELETE FROM @Salida;
INSERT INTO @Salida EXEC cob.sp_SincronizarClientesRegularizados @Ruts = @Lista;
SELECT @Obt = CONCAT(ClientesActualizados, '/', PedidosLiberados, '/',
                     (SELECT COUNT(*) FROM cob.EstadoMorosidad WHERE ClienteId = @A)) FROM @Salida;
INSERT @Resultados VALUES ('PU-04', N'Idempotencia: 2a ejecucion actualizados/liberados/filas historial A', N'0/0/3', @Obt,
    CASE WHEN @Obt = N'0/0/3' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PU-10: debe fallar con 50020 (se ejecuta al final porque deja la transaccion no confirmable) */
BEGIN TRY
    EXEC cob.sp_LiberarPedidosRetenidos @ClienteId = @E, @OrigenCambio = 'Prueba';
    SET @Obt = N'sin error';
END TRY
BEGIN CATCH
    SET @Obt = CAST(ERROR_NUMBER() AS nvarchar(10));
END CATCH;
INSERT @Resultados VALUES ('PU-10', N'Liberacion manual de cliente Suspendido es rechazada', N'50020', @Obt,
    CASE WHEN @Obt = N'50020' THEN 'APROBADA' ELSE 'FALLIDA' END);

IF @@TRANCOUNT > 0 ROLLBACK;

SELECT Caso, Descripcion, Esperado, Obtenido, Resultado FROM @Resultados ORDER BY Caso;
SELECT Aprobadas = SUM(CASE WHEN Resultado = 'APROBADA' THEN 1 ELSE 0 END), Total = COUNT(*) FROM @Resultados;
