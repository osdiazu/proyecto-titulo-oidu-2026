/* =============================================================================
   08_datos_prueba.sql
   Proyecto APT Cobranza Automatizada - Evidencias S11 (demostracion) y S14 (pruebas E2E)

   Carga un conjunto de datos de prueba PERSISTENTE, identificado con el prefijo
   "DEMO" en la razon social, que cubre todos los tipos de aviso y el flujo de
   desbloqueo. Las fechas se calculan desde HOY (hora de Chile), por lo que el
   script puede volver a ejecutarse antes de cada demostracion: primero elimina
   los datos DEMO anteriores.

   Variables SQLCMD:
     CorreoPrueba1, CorreoPrueba2 : buzones del equipo que recibiran los avisos
     DiasPreaviso, DiasMora1, DiasMora2 : los mismos valores configurados en la Function App

   Clientes:
     DEMO-1 76555555-8 AlDia       factura vence en DiasPreaviso dias   -> Preaviso
     DEMO-2 76666666-3 AlDia       factura vence hoy                    -> Vencimiento
     DEMO-3 77777777-7 Moroso      factura vencida hace DiasMora1 dias  -> Mora1
     DEMO-4 78888888-0 Suspendido  factura vencida hace DiasMora2 dias  -> Mora2; 2 pedidos Retenido
     DEMO-5 76123456-0 Regularizado (historico), 1 pedido Despachado, factura Pagada
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Hoy date = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Pacific SA Standard Time' AS date);
DECLARE @Pre int = $(DiasPreaviso), @M1 int = $(DiasMora1), @M2 int = $(DiasMora2);
DECLARE @Ruts TABLE (Rut varchar(12) PRIMARY KEY);
INSERT @Ruts VALUES ('76555555-8'), ('76666666-3'), ('77777777-7'), ('78888888-0'), ('76123456-0');

BEGIN TRAN;

/* ---------- 1. Limpieza de datos DEMO anteriores ---------- */
DECLARE @Ids TABLE (ClienteId int PRIMARY KEY);
INSERT @Ids SELECT ClienteId FROM cob.Cliente WHERE RazonSocial LIKE 'DEMO %';

DELETE FROM cob.LogCambioPedido WHERE ClienteId IN (SELECT ClienteId FROM @Ids);
DELETE FROM cob.LogNotificacion WHERE ClienteId IN (SELECT ClienteId FROM @Ids);
DELETE FROM cob.Pedido          WHERE ClienteId IN (SELECT ClienteId FROM @Ids);
DELETE FROM cob.Factura         WHERE ClienteId IN (SELECT ClienteId FROM @Ids);
DELETE FROM cob.EstadoMorosidad WHERE ClienteId IN (SELECT ClienteId FROM @Ids);
DELETE FROM cob.Cliente         WHERE ClienteId IN (SELECT ClienteId FROM @Ids);
DELETE FROM origen_sim.ClienteRegularizacion WHERE Rut IN (SELECT Rut FROM @Ruts);

/* ---------- 2. Clientes ---------- */
DECLARE @C1 int, @C2 int, @C3 int, @C4 int, @C5 int;
INSERT cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76555555-8', 'DEMO Minimarket Los Aromos', 'Tradicional', '$(CorreoPrueba1)', '000000000', '30', SYSUTCDATETIME());
SET @C1 = SCOPE_IDENTITY();
INSERT cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76666666-3', 'DEMO Supermercado El Puerto', 'Digital', '$(CorreoPrueba2)', '000000000', '60', SYSUTCDATETIME());
SET @C2 = SCOPE_IDENTITY();
INSERT cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('77777777-7', 'DEMO Restaurante La Costa', 'Tradicional', '$(CorreoPrueba1)', '000000000', '30', SYSUTCDATETIME());
SET @C3 = SCOPE_IDENTITY();
INSERT cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('78888888-0', 'DEMO Almacen Don Pedro', 'Tradicional', '$(CorreoPrueba2)', '000000000', '30', SYSUTCDATETIME());
SET @C4 = SCOPE_IDENTITY();
INSERT cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76123456-0', 'DEMO Hotel Mirador', 'Digital', '$(CorreoPrueba1)', '000000000', '60', SYSUTCDATETIME());
SET @C5 = SCOPE_IDENTITY();

/* ---------- 3. Historial de estados ---------- */
INSERT cob.EstadoMorosidad (ClienteId, FechaCambio, EstadoAnterior, EstadoNuevo, OrigenCambio) VALUES
 (@C3, DATEADD(day, -@M1, SYSUTCDATETIME()), 'AlDia',  'Moroso',     'Manual'),
 (@C4, DATEADD(day, -@M2, SYSUTCDATETIME()), 'AlDia',  'Moroso',     'Manual'),
 (@C4, DATEADD(day, -1,   SYSUTCDATETIME()), 'Moroso', 'Suspendido', 'Manual'),
 (@C5, DATEADD(day, -40,  SYSUTCDATETIME()), 'AlDia',  'Suspendido', 'Manual'),
 (@C5, DATEADD(day, -35,  SYSUTCDATETIME()), 'Suspendido', 'Regularizado', 'Manual');

/* ---------- 4. Facturas (FechaVencimiento calculada = FechaEmision + PlazoDias) ---------- */
INSERT cob.Factura (ClienteId, NumeroFactura, MontoTotal, FechaEmision, PlazoDias, Estado) VALUES
 (@C1, 'DEMO-F-0001',  850000, DATEADD(day, @Pre - 30, @Hoy), 30, 'Pendiente'),
 (@C2, 'DEMO-F-0002', 1940000, DATEADD(day, -60, @Hoy),       60, 'Pendiente'),
 (@C3, 'DEMO-F-0003',  420000, DATEADD(day, -@M1 - 30, @Hoy), 30, 'Vencida'),
 (@C4, 'DEMO-F-0004',  615000, DATEADD(day, -@M2 - 30, @Hoy), 30, 'Vencida'),
 (@C5, 'DEMO-F-0005', 1200000, DATEADD(day, -100, @Hoy),      60, 'Pagada');

/* ---------- 5. Pedidos ---------- */
INSERT cob.Pedido (ClienteId, NumeroPedido, FechaCreacion, Estado, FechaLiberacion) VALUES
 (@C4, 'DEMO-P-0001', DATEADD(day, -1, SYSUTCDATETIME()), 'Retenido',   NULL),
 (@C4, 'DEMO-P-0002', SYSUTCDATETIME(),                   'Retenido',   NULL),
 (@C5, 'DEMO-P-0003', DATEADD(day, -30, SYSUTCDATETIME()), 'Despachado', NULL);

/* ---------- 6. Fuente simulada: los clientes existen sin regularizar ---------- */
INSERT origen_sim.ClienteRegularizacion (Rut, Regularizado, FechaRegularizacion)
SELECT Rut, 0, NULL FROM @Ruts;

COMMIT;

/* Verificacion: avisos que generaria hoy el job (deben aparecer 4 filas DEMO, una por tipo) */
EXEC cob.sp_GenerarAlertasVencimiento @DiasPreaviso = @Pre, @DiasMora1 = @M1, @DiasMora2 = @M2;

/* -----------------------------------------------------------------------------
   Paso de demostracion: la embotelladora registra el pago de DEMO-4.
   Ejecutar en el momento indicado por el guion (simula la escritura que hace
   la embotelladora en SU base; el proyecto nunca escribe en la fuente).
   -----------------------------------------------------------------------------
UPDATE origen_sim.ClienteRegularizacion
   SET Regularizado = 1, FechaRegularizacion = SYSUTCDATETIME(), FechaActualizacion = SYSUTCDATETIME()
 WHERE Rut = '78888888-0';
----------------------------------------------------------------------------- */
