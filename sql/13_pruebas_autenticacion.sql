/* =============================================================================
   13_pruebas_autenticacion.sql
   Proyecto APT Cobranza Automatizada - ADR-001 (autenticacion propia)
   Pruebas unitarias T-SQL de 12_autenticacion.sql y del estado Limitado de 04.
   Estado: PREPARADO, NO EJECUTADO (validado solo con analisis estatico).

   - Mismo estilo que 07: todo ocurre dentro de transacciones que se revierten;
     no deja datos. Los resultados se guardan en una variable de tabla (sobrevive
     al ROLLBACK) y se muestran al final. Criterio: Aprobadas = Total.
   - Cuatro bloques (A a D), cada uno con su propia transaccion. Cada caso que
     espera un error va al final de su bloque, porque el THROW de un
     procedimiento con XACT_ABORT ON deja la transaccion no confirmable (igual
     que PU-10 en 07). A diferencia de 07, se hace ROLLBACK antes de registrar
     el resultado del caso de error.
   - Ejecutar con un usuario administrador (grupo admin de Entra ID), NO con la
     identidad de la API: las pruebas preparan datos con escritura directa.
   - Los hashes son textos ficticios: no son salidas reales de PasswordHasher ni
     claves de API reales (ADR-001 7.2).
   - Requiere 01, 04 y 12 ejecutados. Orden: ... 00, 07, 13.

   Casos (ADR-001 5.10 y politica D.3, punto 6)
     PA-01 Alta: DebeCambiarClave = 1, FechaCambioClave fijada, evento AltaUsuario
     PA-02 sp_ObtenerUsuarioParaLogin: 1 fila si existe, 0 si no existe
     PA-03 sp_ObtenerUsuarioPorId: HashClave NULL con @IncluirHash = 0 y valor con 1
     PA-04 Bloqueo: 4 fallos sin bloqueo; el 5o bloquea 15 min, 5 LoginFallido y 1 CuentaBloqueada
     PA-05 Intento con cuenta bloqueada (motivo CuentaBloqueada) no incrementa ni extiende
     PA-06 Bloqueo vencido: el siguiente fallo reinicia el contador (1) y quita el bloqueo
     PA-07 Desbloqueo manual: contador 0, sin bloqueo, sello sin cambio, evento DesbloqueoManual
     PA-08 Login exitoso: contador 0, UltimoAcceso, re-hash, sello sin cambio, evento LoginExitoso
     PA-09 Saneamiento de UsuarioIngresado (SEG-H07, AUT-18)
     PA-10 Motivo ClaveTemporalVencida aceptado y sin incrementar el contador
     PA-11 Cambio de clave con sello vigente: sello nuevo devuelto, DebeCambiarClave = 0, evento
     PA-12 sp_VerificarCambioClave: 1 tras CambioClave, 0 sin CambioClave
     PA-13 Cambio de rol y baja cambian el sello y registran valores anterior y nuevo
     PA-14 Restablecimiento: temporal, desbloquea, sello nuevo; la verificacion vuelve a 0
     PA-15 Clave de API valida: 1 fila (Consumidor, Rol) y UltimoUso registrado
     PA-16 Clave de API con hash distinto: 0 filas
     PA-17 UltimoUso se actualiza como maximo una vez cada 60 min
     PA-18 Clave de API vencida: 0 filas
     PA-19 Clave de API revocada: 0 filas; revocar de nuevo no falla ni duplica el evento
     PA-20 Limitado no incrementa Intentos y el aviso se vuelve a ofrecer
     PA-21 Vista de evidencias: IPv4 /24, IPv6 /48, agente reducido, sin columnas de IP original
     PA-22 sp_ListarEventosAccesoDesde: solo eventos administrativos
     PA-23 Invalidacion: cambia todos los sellos y registra 1 evento con UsuarioId NULL
     PA-24 Purga: borra solo lo anterior a 90 dias, en lotes, y registra PurgaLogAcceso
     PA-25 sp_CambiarClave con sello anterior es rechazado (50060)
     PA-26 Purga con menos de 90 dias es rechazada (50071)
     PA-27 Alta con usuario en mayusculas es rechazada (50062)
     PA-28 Login fallido con motivo no valido es rechazado (50073)
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT OFF;

DECLARE @Resultados TABLE (Caso varchar(6), Descripcion nvarchar(200), Esperado nvarchar(100), Obtenido nvarchar(100), Resultado varchar(10));
DECLARE @Usu TABLE (UsuarioId int, Usuario varchar(50), Nombre nvarchar(120), Rol varchar(10), Activo bit, HashClave varchar(256),
                    DebeCambiarClave bit, IntentosFallidos smallint, BloqueadoHasta datetime2(0), SelloSeguridad uniqueidentifier, FechaCambioClave datetime2(0));
DECLARE @Bloq TABLE (BloqueadoHasta datetime2(0));
DECLARE @SelloNuevo TABLE (SelloSeguridad uniqueidentifier);
DECLARE @Clave TABLE (ClaveApiId int, Consumidor varchar(50), Rol varchar(10));
DECLARE @Purga TABLE (FilasBorradas bigint);
DECLARE @Verif TABLE (UsuarioId int, Usuario varchar(50), FechaEmision datetime2(0), FechaCambioClave datetime2(0), CambioRealizado bit, DebeCambiarClave bit);
DECLARE @Eventos TABLE (LogAccesoId bigint, FechaUtc datetime2(0), Evento varchar(25), UsuarioId int, Usuario varchar(50),
                        ClaveApiId int, Prefijo char(8), Detalle nvarchar(200), Actor nvarchar(128));
DECLARE @Alertas TABLE (FacturaId int, ClienteId int, Rut varchar(12), RazonSocial nvarchar(150), Email nvarchar(254), Segmento varchar(20),
                        NumeroFactura varchar(20), MontoTotal decimal(14,2), FechaVencimiento date, DiasDesdeVencimiento int, TipoAviso varchar(15));
DECLARE @Sellos TABLE (UsuarioId int PRIMARY KEY, SelloSeguridad uniqueidentifier);

DECLARE @Fin int, @Ven int, @Adm int, @Cli int, @Fac int, @i int, @n int, @Antiguas int,
        @Inicio bigint, @Desde datetime2(0), @Obt nvarchar(100), @A nvarchar(50), @B nvarchar(50), @C nvarchar(50),
        @Sello0 uniqueidentifier, @Sello1 uniqueidentifier, @Bloq4 datetime2(0), @Bloq5 datetime2(0),
        @Hash2 binary(32), @Hash3 binary(32), @Hash4 binary(32), @HashOtro binary(32), @Uso0 datetime2(0);

SET @Hash2    = HASHBYTES('SHA2_256', 'cobk_pzzzzzz2_prueba13-no-es-una-clave-real');
SET @Hash3    = HASHBYTES('SHA2_256', 'cobk_pzzzzzz3_prueba13-no-es-una-clave-real');
SET @Hash4    = HASHBYTES('SHA2_256', 'cobk_pzzzzzz4_prueba13-no-es-una-clave-real');
SET @HashOtro = HASHBYTES('SHA2_256', 'otra-clave-ficticia');

/* =========================== Bloque A =========================== */
BEGIN TRAN;

SET @Inicio = ISNULL((SELECT MAX(LogAccesoId) FROM cob.LogAcceso), 0);
SET @Desde  = DATEADD(SECOND, -1, SYSUTCDATETIME());

/* Datos: 3 usuarios de prueba */
EXEC cob.sp_CrearUsuarioInterno @Usuario = 'prueba13.fin', @Nombre = N'PRUEBA Finanzas', @Rol = 'Finanzas', @HashClave = 'hash-ficticio-prueba-1';
EXEC cob.sp_CrearUsuarioInterno @Usuario = 'prueba13.ven', @Nombre = N'PRUEBA Ventas',   @Rol = 'Ventas',   @HashClave = 'hash-ficticio-prueba-2';
EXEC cob.sp_CrearUsuarioInterno @Usuario = 'prueba13.adm', @Nombre = N'PRUEBA Admin',    @Rol = 'Admin',    @HashClave = 'hash-ficticio-prueba-3';
SELECT @Fin = UsuarioId FROM cob.UsuarioInterno WHERE Usuario = 'prueba13.fin';
SELECT @Ven = UsuarioId FROM cob.UsuarioInterno WHERE Usuario = 'prueba13.ven';
SELECT @Adm = UsuarioId FROM cob.UsuarioInterno WHERE Usuario = 'prueba13.adm';

/* PA-01 */
SELECT @Obt = CONCAT(DebeCambiarClave, '/', IIF(FechaCambioClave IS NULL, 'NULL', 'fecha'), '/', IntentosFallidos, '/', Activo, '/',
                     (SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Fin AND Evento = 'AltaUsuario'))
FROM cob.UsuarioInterno WHERE UsuarioId = @Fin;
INSERT @Resultados VALUES ('PA-01', N'Alta: DebeCambiar/FechaCambioClave/Intentos/Activo/eventos AltaUsuario', N'1/fecha/0/1/1', @Obt,
    CASE WHEN @Obt = N'1/fecha/0/1/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-02 */
INSERT @Usu EXEC cob.sp_ObtenerUsuarioParaLogin @Usuario = 'prueba13.fin';
SET @A = (SELECT COUNT(*) FROM @Usu WHERE UsuarioId = @Fin AND Rol = 'Finanzas' AND HashClave = 'hash-ficticio-prueba-1');
DELETE FROM @Usu;
INSERT @Usu EXEC cob.sp_ObtenerUsuarioParaLogin @Usuario = 'prueba13.noexiste';
SET @Obt = CONCAT(@A, '/', (SELECT COUNT(*) FROM @Usu));
DELETE FROM @Usu;
INSERT @Resultados VALUES ('PA-02', N'ObtenerUsuarioParaLogin: filas usuario existente / inexistente', N'1/0', @Obt,
    CASE WHEN @Obt = N'1/0' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-03 */
INSERT @Usu EXEC cob.sp_ObtenerUsuarioPorId @UsuarioId = @Fin;
SET @A = (SELECT ISNULL(HashClave, 'NULL') FROM @Usu);
DELETE FROM @Usu;
INSERT @Usu EXEC cob.sp_ObtenerUsuarioPorId @UsuarioId = @Fin, @IncluirHash = 1;
SET @Obt = CONCAT(@A, '/', (SELECT ISNULL(HashClave, 'NULL') FROM @Usu));
DELETE FROM @Usu;
INSERT @Resultados VALUES ('PA-03', N'ObtenerUsuarioPorId: HashClave con IncluirHash 0 / 1', N'NULL/hash-ficticio-prueba-1', @Obt,
    CASE WHEN @Obt = N'NULL/hash-ficticio-prueba-1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-04: 4 fallos, luego el 5o (MaxIntentos 5, MinutosBloqueo 15: valores DEMO de A.11) */
SET @i = 1;
WHILE @i <= 4
BEGIN
    INSERT @Bloq EXEC cob.sp_RegistrarLoginFallido @UsuarioId = @Fin, @UsuarioIngresado = N'prueba13.fin', @Motivo = 'ClaveIncorrecta',
         @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13', @MaxIntentos = 5, @MinutosBloqueo = 15;
    SET @i += 1;
END
SELECT @A = CONCAT(IntentosFallidos, '/', IIF(BloqueadoHasta IS NULL, 'NULL', 'bloq')) FROM cob.UsuarioInterno WHERE UsuarioId = @Fin;
DELETE FROM @Bloq;
INSERT @Bloq EXEC cob.sp_RegistrarLoginFallido @UsuarioId = @Fin, @UsuarioIngresado = N'prueba13.fin', @Motivo = 'ClaveIncorrecta',
     @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13', @MaxIntentos = 5, @MinutosBloqueo = 15;
SELECT @Bloq5 = BloqueadoHasta FROM cob.UsuarioInterno WHERE UsuarioId = @Fin;
SET @Obt = CONCAT(@A, '/',
                  (SELECT IntentosFallidos FROM cob.UsuarioInterno WHERE UsuarioId = @Fin), '/',
                  IIF(DATEDIFF(SECOND, SYSUTCDATETIME(), @Bloq5) BETWEEN 14 * 60 AND 15 * 60 + 5, '15min', 'otro'), '/',
                  IIF((SELECT BloqueadoHasta FROM @Bloq) = @Bloq5, 'devuelto', 'no'), '/',
                  (SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Fin AND Evento = 'LoginFallido' AND Motivo = 'ClaveIncorrecta'), '/',
                  (SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Fin AND Evento = 'CuentaBloqueada'));
DELETE FROM @Bloq;
INSERT @Resultados VALUES ('PA-04', N'Bloqueo: 4 fallos (intentos/bloq), 5o: intentos/duracion/valor devuelto/LoginFallido/CuentaBloqueada', N'4/NULL/5/15min/devuelto/5/1', @Obt,
    CASE WHEN @Obt = N'4/NULL/5/15min/devuelto/5/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-05 */
INSERT @Bloq EXEC cob.sp_RegistrarLoginFallido @UsuarioId = @Fin, @UsuarioIngresado = N'prueba13.fin', @Motivo = 'CuentaBloqueada',
     @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13', @MaxIntentos = 5, @MinutosBloqueo = 15;
SELECT @Obt = CONCAT(IntentosFallidos, '/', IIF(BloqueadoHasta = @Bloq5, 'igual', 'cambio'), '/',
                     (SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Fin AND Evento = 'LoginFallido' AND Motivo = 'CuentaBloqueada'))
FROM cob.UsuarioInterno WHERE UsuarioId = @Fin;
DELETE FROM @Bloq;
INSERT @Resultados VALUES ('PA-05', N'Intento con cuenta bloqueada: intentos/bloqueo/evento', N'5/igual/1', @Obt,
    CASE WHEN @Obt = N'5/igual/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-06: se simula el paso del tiempo dejando el bloqueo vencido */
UPDATE cob.UsuarioInterno SET BloqueadoHasta = DATEADD(MINUTE, -1, SYSUTCDATETIME()) WHERE UsuarioId = @Fin;
INSERT @Bloq EXEC cob.sp_RegistrarLoginFallido @UsuarioId = @Fin, @UsuarioIngresado = N'prueba13.fin', @Motivo = 'ClaveIncorrecta',
     @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13', @MaxIntentos = 5, @MinutosBloqueo = 15;
SELECT @Obt = CONCAT(IntentosFallidos, '/', IIF(BloqueadoHasta IS NULL, 'NULL', 'bloq'), '/', IIF((SELECT BloqueadoHasta FROM @Bloq) IS NULL, 'NULL', 'bloq'))
FROM cob.UsuarioInterno WHERE UsuarioId = @Fin;
DELETE FROM @Bloq;
INSERT @Resultados VALUES ('PA-06', N'Bloqueo vencido: intentos/bloqueo/valor devuelto tras un fallo', N'1/NULL/NULL', @Obt,
    CASE WHEN @Obt = N'1/NULL/NULL' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-07 */
UPDATE cob.UsuarioInterno SET IntentosFallidos = 5, BloqueadoHasta = DATEADD(MINUTE, 15, SYSUTCDATETIME()) WHERE UsuarioId = @Fin;
SELECT @Sello0 = SelloSeguridad FROM cob.UsuarioInterno WHERE UsuarioId = @Fin;
EXEC cob.sp_DesbloquearUsuario @Usuario = 'prueba13.fin';
SELECT @Obt = CONCAT(IntentosFallidos, '/', IIF(BloqueadoHasta IS NULL, 'NULL', 'bloq'), '/', IIF(SelloSeguridad = @Sello0, 'igual', 'distinto'), '/',
                     (SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Fin AND Evento = 'DesbloqueoManual'))
FROM cob.UsuarioInterno WHERE UsuarioId = @Fin;
INSERT @Resultados VALUES ('PA-07', N'Desbloqueo manual: intentos/bloqueo/sello/evento', N'0/NULL/igual/1', @Obt,
    CASE WHEN @Obt = N'0/NULL/igual/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-08 */
UPDATE cob.UsuarioInterno SET IntentosFallidos = 2 WHERE UsuarioId = @Fin;
EXEC cob.sp_RegistrarLoginExitoso @UsuarioId = @Fin, @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13', @HashClaveNuevo = 'hash-ficticio-rehash';
SELECT @Obt = CONCAT(IntentosFallidos, '/', IIF(UltimoAcceso IS NULL, 'NULL', 'fecha'), '/', HashClave, '/', IIF(SelloSeguridad = @Sello0, 'igual', 'distinto'), '/',
                     (SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Fin AND Evento = 'LoginExitoso'))
FROM cob.UsuarioInterno WHERE UsuarioId = @Fin;
INSERT @Resultados VALUES ('PA-08', N'Login exitoso: intentos/UltimoAcceso/hash/sello/evento', N'0/fecha/hash-ficticio-rehash/igual/1', @Obt,
    CASE WHEN @Obt = N'0/fecha/hash-ficticio-rehash/igual/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-09: textos ingresados (UsuarioId NULL, motivo UsuarioInexistente). F = '(formato no valido)' */
DECLARE @Textos TABLE (Orden int PRIMARY KEY, Texto nvarchar(50));
INSERT @Textos VALUES (1, N'Clave$Secreta.2026'), (2, N'juan.perez'), (3, N'ab'), (4, N'Juan.Perez'), (5, N'juan '), (6, CONCAT(N'jose.mu', NCHAR(241), N'oz'));   -- NCHAR(241) = enie (archivo solo ASCII)
SET @Obt = N'';
SET @i = 1;
WHILE @i <= 6
BEGIN
    SET @A = (SELECT Texto FROM @Textos WHERE Orden = @i);
    INSERT @Bloq EXEC cob.sp_RegistrarLoginFallido @UsuarioId = NULL, @UsuarioIngresado = @A, @Motivo = 'UsuarioInexistente',
         @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13', @MaxIntentos = 5, @MinutosBloqueo = 15;
    SET @B = (SELECT TOP (1) UsuarioIngresado FROM cob.LogAcceso
              WHERE LogAccesoId > @Inicio AND Evento = 'LoginFallido' AND UsuarioId IS NULL ORDER BY LogAccesoId DESC);
    SET @Obt = CONCAT(@Obt, IIF(@i = 1, N'', N'/'), IIF(@B = N'(formato no valido)', N'F', @B));
    SET @i += 1;
END
DELETE FROM @Bloq;
INSERT @Resultados VALUES ('PA-09', N'Saneamiento UsuarioIngresado: clave, valido, corto, mayusculas, espacio final, enie', N'F/juan.perez/F/F/F/F', @Obt,
    CASE WHEN @Obt = N'F/juan.perez/F/F/F/F' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-10 */
INSERT @Bloq EXEC cob.sp_RegistrarLoginFallido @UsuarioId = @Ven, @UsuarioIngresado = N'prueba13.ven', @Motivo = 'ClaveTemporalVencida',
     @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13', @MaxIntentos = 5, @MinutosBloqueo = 15;
SELECT @Obt = CONCAT((SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Ven AND Evento = 'LoginFallido' AND Motivo = 'ClaveTemporalVencida'), '/',
                     IntentosFallidos, '/', IIF(BloqueadoHasta IS NULL, 'NULL', 'bloq'))
FROM cob.UsuarioInterno WHERE UsuarioId = @Ven;
DELETE FROM @Bloq;
INSERT @Resultados VALUES ('PA-10', N'Motivo ClaveTemporalVencida: eventos/intentos/bloqueo', N'1/0/NULL', @Obt,
    CASE WHEN @Obt = N'1/0/NULL' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-11 (el sello anterior de prueba13.ven queda en @Sello1 para PA-25) */
SELECT @Sello1 = SelloSeguridad FROM cob.UsuarioInterno WHERE UsuarioId = @Ven;
INSERT @SelloNuevo EXEC cob.sp_CambiarClave @UsuarioId = @Ven, @SelloActual = @Sello1, @HashClaveNuevo = 'hash-ficticio-nuevo-2',
     @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13';
SELECT @Obt = CONCAT(IIF(SelloSeguridad <> @Sello1, 'distinto', 'igual'), '/',
                     IIF(SelloSeguridad = (SELECT SelloSeguridad FROM @SelloNuevo), 'coincide', 'no'), '/',
                     DebeCambiarClave, '/', HashClave, '/',
                     (SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Ven AND Evento = 'CambioClave'))
FROM cob.UsuarioInterno WHERE UsuarioId = @Ven;
INSERT @Resultados VALUES ('PA-11', N'Cambio de clave: sello/sello devuelto/DebeCambiar/hash/evento', N'distinto/coincide/0/hash-ficticio-nuevo-2/1', @Obt,
    CASE WHEN @Obt = N'distinto/coincide/0/hash-ficticio-nuevo-2/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-12 */
INSERT @Verif EXEC cob.sp_VerificarCambioClave @Usuario = 'prueba13.ven';
SET @A = (SELECT CAST(CambioRealizado AS nvarchar(1)) FROM @Verif);
DELETE FROM @Verif;
INSERT @Verif EXEC cob.sp_VerificarCambioClave @Usuario = 'prueba13.adm';
SET @Obt = CONCAT(@A, '/', (SELECT CAST(CambioRealizado AS nvarchar(1)) FROM @Verif));
DELETE FROM @Verif;
INSERT @Resultados VALUES ('PA-12', N'VerificarCambioClave: con CambioClave / sin CambioClave', N'1/0', @Obt,
    CASE WHEN @Obt = N'1/0' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-13 */
SELECT @Sello0 = SelloSeguridad FROM cob.UsuarioInterno WHERE UsuarioId = @Adm;
EXEC cob.sp_CambiarRolUsuario @Usuario = 'prueba13.adm', @Rol = 'Finanzas';
SELECT @A = CONCAT(Rol, '/', IIF(SelloSeguridad <> @Sello0, 'distinto', 'igual')) FROM cob.UsuarioInterno WHERE UsuarioId = @Adm;
SELECT @Sello0 = SelloSeguridad FROM cob.UsuarioInterno WHERE UsuarioId = @Adm;
EXEC cob.sp_CambiarEstadoUsuario @Usuario = 'prueba13.adm', @Activo = 0;
SELECT @Obt = CONCAT(@A, '/', Activo, '/', IIF(SelloSeguridad <> @Sello0, 'distinto', 'igual'), '/',
                     (SELECT TOP (1) Detalle FROM cob.LogAcceso WHERE UsuarioId = @Adm AND Evento = 'CambioRolUsuario' ORDER BY LogAccesoId DESC), '/',
                     (SELECT TOP (1) Detalle FROM cob.LogAcceso WHERE UsuarioId = @Adm AND Evento = 'CambioEstadoUsuario' ORDER BY LogAccesoId DESC))
FROM cob.UsuarioInterno WHERE UsuarioId = @Adm;
INSERT @Resultados VALUES ('PA-13', N'Rol/sello tras cambio de rol; Activo/sello tras baja; detalle de ambos eventos', N'Finanzas/distinto/0/distinto/Rol Admin -> Finanzas/Activo 1 -> 0', @Obt,
    CASE WHEN @Obt = N'Finanzas/distinto/0/distinto/Rol Admin -> Finanzas/Activo 1 -> 0' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-14 */
UPDATE cob.UsuarioInterno SET IntentosFallidos = 3, BloqueadoHasta = DATEADD(MINUTE, 10, SYSUTCDATETIME()) WHERE UsuarioId = @Ven;
SELECT @Sello0 = SelloSeguridad FROM cob.UsuarioInterno WHERE UsuarioId = @Ven;
EXEC cob.sp_RestablecerClaveUsuario @Usuario = 'prueba13.ven', @HashClave = 'hash-ficticio-temporal-2';
INSERT @Verif EXEC cob.sp_VerificarCambioClave @Usuario = 'prueba13.ven';
SELECT @Obt = CONCAT(DebeCambiarClave, '/', IntentosFallidos, '/', IIF(BloqueadoHasta IS NULL, 'NULL', 'bloq'), '/',
                     IIF(SelloSeguridad <> @Sello0, 'distinto', 'igual'), '/', HashClave, '/',
                     (SELECT COUNT(*) FROM cob.LogAcceso WHERE UsuarioId = @Ven AND Evento = 'RestablecimientoClave'), '/',
                     (SELECT CAST(CambioRealizado AS nvarchar(1)) FROM @Verif))
FROM cob.UsuarioInterno WHERE UsuarioId = @Ven;
DELETE FROM @Verif;
INSERT @Resultados VALUES ('PA-14', N'Restablecimiento: DebeCambiar/intentos/bloqueo/sello/hash/evento/verificacion', N'1/0/NULL/distinto/hash-ficticio-temporal-2/1/0', @Obt,
    CASE WHEN @Obt = N'1/0/NULL/distinto/hash-ficticio-temporal-2/1/0' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* Datos de claves de API (prefijos Base32 ficticios) */
DECLARE @Vence datetime2(0) = DATEADD(DAY, 30, SYSUTCDATETIME());
EXEC cob.sp_RegistrarClaveApi @Prefijo = 'pzzzzzz2', @HashClave = @Hash2, @Consumidor = 'prueba-13', @Rol = 'Ventas',
     @FechaVencimiento = @Vence, @NombreSecretoKv = 'apikey-prueba-13-pzzzzzz2';
EXEC cob.sp_RegistrarClaveApi @Prefijo = 'pzzzzzz3', @HashClave = @Hash3, @Consumidor = 'prueba-13', @Rol = 'Ventas',
     @FechaVencimiento = @Vence, @NombreSecretoKv = 'apikey-prueba-13-pzzzzzz3';
EXEC cob.sp_RegistrarClaveApi @Prefijo = 'pzzzzzz4', @HashClave = @Hash4, @Consumidor = 'prueba-13', @Rol = 'Ventas',
     @FechaVencimiento = @Vence, @NombreSecretoKv = 'apikey-prueba-13-pzzzzzz4';

/* PA-15 */
INSERT @Clave EXEC cob.sp_ValidarClaveApi @Prefijo = 'pzzzzzz2', @HashClave = @Hash2;
SELECT @Obt = CONCAT((SELECT COUNT(*) FROM @Clave), '/', (SELECT Consumidor FROM @Clave), '/', (SELECT Rol FROM @Clave), '/',
                     IIF(UltimoUso IS NULL, 'NULL', 'fecha'))
FROM cob.ClaveApi WHERE Prefijo = 'pzzzzzz2';
DELETE FROM @Clave;
INSERT @Resultados VALUES ('PA-15', N'Clave de API valida: filas/consumidor/rol/UltimoUso', N'1/prueba-13/Ventas/fecha', @Obt,
    CASE WHEN @Obt = N'1/prueba-13/Ventas/fecha' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-16 */
INSERT @Clave EXEC cob.sp_ValidarClaveApi @Prefijo = 'pzzzzzz2', @HashClave = @HashOtro;
SET @Obt = CAST((SELECT COUNT(*) FROM @Clave) AS nvarchar(10));
DELETE FROM @Clave;
INSERT @Resultados VALUES ('PA-16', N'Clave de API con hash distinto: filas', N'0', @Obt,
    CASE WHEN @Obt = N'0' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-17 */
SET @Uso0 = DATEADD(MINUTE, -30, SYSUTCDATETIME());
UPDATE cob.ClaveApi SET UltimoUso = @Uso0 WHERE Prefijo = 'pzzzzzz2';
INSERT @Clave EXEC cob.sp_ValidarClaveApi @Prefijo = 'pzzzzzz2', @HashClave = @Hash2;
SET @A = (SELECT IIF(UltimoUso = @Uso0, N'igual', N'cambio') FROM cob.ClaveApi WHERE Prefijo = 'pzzzzzz2');
SET @Uso0 = DATEADD(MINUTE, -61, SYSUTCDATETIME());
UPDATE cob.ClaveApi SET UltimoUso = @Uso0 WHERE Prefijo = 'pzzzzzz2';
INSERT @Clave EXEC cob.sp_ValidarClaveApi @Prefijo = 'pzzzzzz2', @HashClave = @Hash2;
SET @Obt = CONCAT(@A, '/', (SELECT IIF(UltimoUso > @Uso0, N'actualizado', N'igual') FROM cob.ClaveApi WHERE Prefijo = 'pzzzzzz2'), '/',
                  (SELECT COUNT(*) FROM @Clave));
DELETE FROM @Clave;
INSERT @Resultados VALUES ('PA-17', N'UltimoUso hace 30 min / hace 61 min / filas validas', N'igual/actualizado/2', @Obt,
    CASE WHEN @Obt = N'igual/actualizado/2' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-18: se simula el vencimiento */
UPDATE cob.ClaveApi SET FechaVencimiento = DATEADD(MINUTE, -1, SYSUTCDATETIME()) WHERE Prefijo = 'pzzzzzz3';
INSERT @Clave EXEC cob.sp_ValidarClaveApi @Prefijo = 'pzzzzzz3', @HashClave = @Hash3;
SET @Obt = CAST((SELECT COUNT(*) FROM @Clave) AS nvarchar(10));
DELETE FROM @Clave;
INSERT @Resultados VALUES ('PA-18', N'Clave de API vencida: filas', N'0', @Obt,
    CASE WHEN @Obt = N'0' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-19 */
INSERT @Clave EXEC cob.sp_ValidarClaveApi @Prefijo = 'pzzzzzz4', @HashClave = @Hash4;
SET @A = CAST((SELECT COUNT(*) FROM @Clave) AS nvarchar(10));
DELETE FROM @Clave;
EXEC cob.sp_RevocarClaveApi @Prefijo = 'pzzzzzz4';
INSERT @Clave EXEC cob.sp_ValidarClaveApi @Prefijo = 'pzzzzzz4', @HashClave = @Hash4;
EXEC cob.sp_RevocarClaveApi @Prefijo = 'pzzzzzz4';   -- segunda revocacion: sin error ni evento nuevo
SELECT @Obt = CONCAT(@A, '/', (SELECT COUNT(*) FROM @Clave), '/', Activa, '/', IIF(FechaRevocacion IS NULL, 'NULL', 'fecha'), '/',
                     (SELECT COUNT(*) FROM cob.LogAcceso WHERE ClaveApiId = ca.ClaveApiId AND Evento = 'RevocacionClaveApi'))
FROM cob.ClaveApi AS ca WHERE ca.Prefijo = 'pzzzzzz4';
DELETE FROM @Clave;
INSERT @Resultados VALUES ('PA-19', N'Revocacion: filas antes/despues, Activa, FechaRevocacion, eventos tras 2 revocaciones', N'1/0/0/fecha/1', @Obt,
    CASE WHEN @Obt = N'1/0/0/fecha/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-20: Limitado (04). Factura vencida en 1990: siempre corresponde Mora2 y
   queda primera en el orden de sp_GenerarAlertasVencimiento. */
INSERT INTO cob.Cliente (Rut, RazonSocial, Segmento, Email, Telefono, TipoConvenio, FechaRegistro)
VALUES ('76131313-0', 'PRUEBA 13 Limitado', 'Tradicional', 'prueba.13@example.invalid', '000000000', 30, SYSUTCDATETIME());
SET @Cli = SCOPE_IDENTITY();
INSERT INTO cob.Factura (ClienteId, NumeroFactura, MontoTotal, FechaEmision, PlazoDias, Estado)
VALUES (@Cli, 'PRU13-F-001', 1000, '1990-01-01', 30, 'Vencida');
SET @Fac = SCOPE_IDENTITY();

EXEC cob.sp_RegistrarNotificacion @FacturaId = @Fac, @TipoAviso = 'Mora2', @Destinatario = 'prueba.13@example.invalid', @EstadoEnvio = 'Limitado',
     @Detalle = N'PRUEBA 13: HTTP 429';
SET @A = (SELECT CONCAT(Intentos, '-', EstadoEnvio) FROM cob.LogNotificacion WHERE FacturaId = @Fac AND TipoAviso = 'Mora2');
INSERT @Alertas EXEC cob.sp_GenerarAlertasVencimiento @DiasPreaviso = 5, @DiasMora1 = 10, @DiasMora2 = 30;
SET @B = CAST((SELECT COUNT(*) FROM @Alertas WHERE FacturaId = @Fac AND TipoAviso = 'Mora2') AS nvarchar(10));
DELETE FROM @Alertas;
EXEC cob.sp_RegistrarNotificacion @FacturaId = @Fac, @TipoAviso = 'Mora2', @Destinatario = 'prueba.13@example.invalid', @EstadoEnvio = 'Fallido',
     @Detalle = N'PRUEBA 13: error no de limite';
SET @C = (SELECT CAST(Intentos AS nvarchar(10)) FROM cob.LogNotificacion WHERE FacturaId = @Fac AND TipoAviso = 'Mora2');
EXEC cob.sp_RegistrarNotificacion @FacturaId = @Fac, @TipoAviso = 'Mora2', @Destinatario = 'prueba.13@example.invalid', @EstadoEnvio = 'Limitado',
     @Detalle = N'PRUEBA 13: HTTP 429';
INSERT @Alertas EXEC cob.sp_GenerarAlertasVencimiento @DiasPreaviso = 5, @DiasMora1 = 10, @DiasMora2 = 30;
SET @Obt = CONCAT(@A, '/', @B, '/', @C, '/',
                  (SELECT CONCAT(Intentos, '-', EstadoEnvio) FROM cob.LogNotificacion WHERE FacturaId = @Fac AND TipoAviso = 'Mora2'), '/',
                  (SELECT COUNT(*) FROM @Alertas WHERE FacturaId = @Fac AND TipoAviso = 'Mora2'));
DELETE FROM @Alertas;
INSERT @Resultados VALUES ('PA-20', N'Limitado: insert/se ofrece/tras Fallido/tras 2o Limitado/se ofrece', N'0-Limitado/1/1/1-Limitado/1', @Obt,
    CASE WHEN @Obt = N'0-Limitado/1/1/1-Limitado/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-21 */
EXEC cob.sp_RegistrarLogout @UsuarioId = @Fin, @IpOrigen = '203.0.113.77',
     @AgenteUsuario = N'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
SET @A = (SELECT TOP (1) CONCAT(IpEnmascarada, '|', AgenteUsuarioReducido) FROM cob.vw_LogAccesoEvidencia
          WHERE UsuarioId = @Fin AND Evento = 'Logout' ORDER BY LogAccesoId DESC);
EXEC cob.sp_RegistrarLogout @UsuarioId = @Fin, @IpOrigen = '2001:db8:abcd:12::1', @AgenteUsuario = NULL;
SET @B = (SELECT TOP (1) IpEnmascarada FROM cob.vw_LogAccesoEvidencia WHERE UsuarioId = @Fin AND Evento = 'Logout' ORDER BY LogAccesoId DESC);
EXEC cob.sp_RegistrarLogout @UsuarioId = @Fin, @IpOrigen = '::ffff:198.51.100.9', @AgenteUsuario = NULL;
SET @C = (SELECT TOP (1) IpEnmascarada FROM cob.vw_LogAccesoEvidencia WHERE UsuarioId = @Fin AND Evento = 'Logout' ORDER BY LogAccesoId DESC);
SET @Obt = CONCAT(@A, '/', @B, '/', @C, '/',
                  (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'cob.vw_LogAccesoEvidencia') AND name IN (N'IpOrigen', N'AgenteUsuario')));
INSERT @Resultados VALUES ('PA-21', N'Vista: IPv4|agente / IPv6 / IPv4 mapeada / columnas originales', N'203.0.113.0|Chrome / Windows/2001:db8:abcd::/::ffff:198.51.100.0/0', @Obt,
    CASE WHEN @Obt = N'203.0.113.0|Chrome / Windows/2001:db8:abcd::/::ffff:198.51.100.0/0' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-22: eventos administrativos de los usuarios y claves de prueba:
   3 AltaUsuario + 1 CambioClave + 1 RestablecimientoClave + 1 CambioRolUsuario
   + 1 CambioEstadoUsuario + 3 AltaClaveApi + 1 RevocacionClaveApi = 11 */
INSERT @Eventos EXEC cob.sp_ListarEventosAccesoDesde @Desde = @Desde;
SET @Obt = CONCAT(
    (SELECT COUNT(*) FROM @Eventos WHERE UsuarioId IN (@Fin, @Ven, @Adm) OR Prefijo IN ('pzzzzzz2', 'pzzzzzz3', 'pzzzzzz4')), '/',
    (SELECT COUNT(*) FROM @Eventos WHERE Evento NOT IN ('RevocacionClaveApi', 'CambioEstadoUsuario', 'CambioRolUsuario', 'CambioClave',
                                                        'RestablecimientoClave', 'AltaUsuario', 'AltaClaveApi')), '/',
    (SELECT COUNT(*) FROM @Eventos WHERE Evento = 'RevocacionClaveApi' AND Prefijo = 'pzzzzzz4'));
DELETE FROM @Eventos;
INSERT @Resultados VALUES ('PA-22', N'ListarEventosAccesoDesde: eventos de prueba / otros tipos / revocacion con prefijo', N'11/0/1', @Obt,
    CASE WHEN @Obt = N'11/0/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-23 */
INSERT @Sellos (UsuarioId, SelloSeguridad) SELECT UsuarioId, SelloSeguridad FROM cob.UsuarioInterno;
EXEC cob.sp_InvalidarTodasLasSesiones;
SET @Obt = CONCAT(
    IIF((SELECT COUNT(*) FROM @Sellos) >= 3, 'hay', 'faltan'), '/',
    (SELECT COUNT(*) FROM cob.UsuarioInterno AS u JOIN @Sellos AS s ON s.UsuarioId = u.UsuarioId AND s.SelloSeguridad = u.SelloSeguridad), '/',
    (SELECT COUNT(*) FROM cob.LogAcceso WHERE LogAccesoId > @Inicio AND Evento = 'InvalidacionSesiones' AND UsuarioId IS NULL));
INSERT @Resultados VALUES ('PA-23', N'Invalidacion: usuarios / sellos sin cambio / eventos con UsuarioId NULL', N'hay/0/1', @Obt,
    CASE WHEN @Obt = N'hay/0/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-24: 2 filas de hace 100 dias y 1 de hace 89 dias; lote de 1 fila para probar el ciclo */
INSERT INTO cob.LogAcceso (FechaUtc, Evento, UsuarioId, Detalle) VALUES
 (DATEADD(DAY, -100, SYSUTCDATETIME()), 'Logout', @Fin, N'PRUEBA13-ANTIGUA'),
 (DATEADD(DAY, -100, SYSUTCDATETIME()), 'Logout', @Fin, N'PRUEBA13-ANTIGUA'),
 (DATEADD(DAY, -89,  SYSUTCDATETIME()), 'Logout', @Fin, N'PRUEBA13-RECIENTE');
SET @Antiguas = (SELECT COUNT(*) FROM cob.LogAcceso WHERE FechaUtc < DATEADD(DAY, -90, SYSUTCDATETIME()));
INSERT @Purga EXEC cob.sp_PurgarLogAcceso @DiasRetencion = 90, @TamanoLote = 1;
SET @Obt = CONCAT(
    IIF((SELECT FilasBorradas FROM @Purga) = @Antiguas AND @Antiguas >= 2, 'total', 'distinto'), '/',
    (SELECT COUNT(*) FROM cob.LogAcceso WHERE Detalle = N'PRUEBA13-ANTIGUA'), '/',
    (SELECT COUNT(*) FROM cob.LogAcceso WHERE Detalle = N'PRUEBA13-RECIENTE'), '/',
    (SELECT COUNT(*) FROM cob.LogAcceso WHERE LogAccesoId > @Inicio AND Evento = 'PurgaLogAcceso'));
DELETE FROM @Purga;
INSERT @Resultados VALUES ('PA-24', N'Purga 90 dias: total devuelto / antiguas restantes / reciente / evento', N'total/0/1/1', @Obt,
    CASE WHEN @Obt = N'total/0/1/1' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* PA-25: debe fallar con 50060 (al final del bloque: deja la transaccion no confirmable) */
BEGIN TRY
    EXEC cob.sp_CambiarClave @UsuarioId = @Ven, @SelloActual = @Sello1, @HashClaveNuevo = 'hash-ficticio-otro',
         @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13';
    SET @Obt = N'sin error';
END TRY
BEGIN CATCH
    SET @Obt = CAST(ERROR_NUMBER() AS nvarchar(10));
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;   -- antes de escribir: la transaccion quedo no confirmable
INSERT @Resultados VALUES ('PA-25', N'CambiarClave con sello anterior es rechazado', N'50060', @Obt,
    CASE WHEN @Obt = N'50060' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* =========================== Bloque B =========================== */
BEGIN TRAN;
BEGIN TRY
    EXEC cob.sp_PurgarLogAcceso @DiasRetencion = 89;
    SET @Obt = N'sin error';
END TRY
BEGIN CATCH
    SET @Obt = CAST(ERROR_NUMBER() AS nvarchar(10));
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;   -- antes de escribir: la transaccion quedo no confirmable
INSERT @Resultados VALUES ('PA-26', N'Purga con DiasRetencion = 89 es rechazada', N'50071', @Obt,
    CASE WHEN @Obt = N'50071' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* =========================== Bloque C =========================== */
BEGIN TRAN;
BEGIN TRY
    EXEC cob.sp_CrearUsuarioInterno @Usuario = 'Prueba13.Mayus', @Nombre = N'PRUEBA', @Rol = 'Ventas', @HashClave = 'hash-ficticio-prueba-4';
    SET @Obt = N'sin error';
END TRY
BEGIN CATCH
    SET @Obt = CAST(ERROR_NUMBER() AS nvarchar(10));
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;   -- antes de escribir: la transaccion quedo no confirmable
INSERT @Resultados VALUES ('PA-27', N'Alta con usuario en mayusculas es rechazada', N'50062', @Obt,
    CASE WHEN @Obt = N'50062' THEN 'APROBADA' ELSE 'FALLIDA' END);

/* =========================== Bloque D =========================== */
BEGIN TRAN;
BEGIN TRY
    EXEC cob.sp_RegistrarLoginFallido @UsuarioId = NULL, @UsuarioIngresado = N'prueba13.x', @Motivo = 'Otro',
         @IpOrigen = '203.0.113.10', @AgenteUsuario = N'PRUEBA 13', @MaxIntentos = 5, @MinutosBloqueo = 15;
    SET @Obt = N'sin error';
END TRY
BEGIN CATCH
    SET @Obt = CAST(ERROR_NUMBER() AS nvarchar(10));
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;   -- antes de escribir: la transaccion quedo no confirmable
INSERT @Resultados VALUES ('PA-28', N'Login fallido con motivo no valido es rechazado', N'50073', @Obt,
    CASE WHEN @Obt = N'50073' THEN 'APROBADA' ELSE 'FALLIDA' END);

SELECT Caso, Descripcion, Esperado, Obtenido, Resultado FROM @Resultados ORDER BY Caso;
SELECT Aprobadas = SUM(CASE WHEN Resultado = 'APROBADA' THEN 1 ELSE 0 END), Total = COUNT(*) FROM @Resultados;
