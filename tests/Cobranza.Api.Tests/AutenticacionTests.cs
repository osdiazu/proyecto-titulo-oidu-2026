using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Cobranza.Api.Datos;
using Cobranza.Api.Seguridad;

namespace Cobranza.Api.Tests;

/// <summary>Casos AUT de ADR-001 6.1 automatizables sin Azure (login con cookie).</summary>
public sealed class AutenticacionTests : IDisposable
{
    private readonly FabricaApi _f = new();
    public void Dispose() => _f.Dispose();

    private static async Task<string> Cuerpo(HttpResponseMessage r) => await r.Content.ReadAsStringAsync();

    [Fact]
    public async Task AUT01_LoginCorrectoFinanzas_200_Cookie_LoginExitoso()
    {
        var c = _f.Nuevo();
        var r = await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));

        Assert.Equal(HttpStatusCode.OK, r.StatusCode);
        var j = await r.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("Nombre finanzas.demo", j.GetProperty("nombre").GetString());
        Assert.Equal(Roles.Finanzas, j.GetProperty("roles")[0].GetString());
        Assert.False(j.GetProperty("debeCambiarClave").GetBoolean());
        Assert.NotNull(c.CookieSesion());
        var e = Assert.Single(_f.Usuarios.EventosCopia());
        Assert.Equal(("LoginExitoso", 1, c.Ip, "PruebasCobranza/1.0"), (e.Evento, e.UsuarioId, e.Ip, e.Agente));

        Assert.Equal(HttpStatusCode.OK, (await c.Get("/api/v1/cartera/indicadores")).StatusCode);
    }

    [Fact]
    public async Task AUT02_ClaveIncorrecta_401Generico_ClaveIncorrecta()
    {
        var c = _f.Nuevo();
        var r = await c.Login("finanzas.demo", "otra-clave-cualquiera");

        Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
        Assert.Contains(EndpointsAutenticacion.MensajeLoginFallido, await Cuerpo(r));
        Assert.Null(c.CookieSesion());
        var e = Assert.Single(_f.Usuarios.EventosCopia());
        Assert.Equal(("LoginFallido", MotivosLogin.ClaveIncorrecta, 1, "finanzas.demo"), (e.Evento, e.Motivo, e.UsuarioId, e.UsuarioIngresado));
        Assert.Equal(1, _f.Usuarios.Fila("finanzas.demo").IntentosFallidos);
    }

    [Fact]
    public async Task AUT03_UsuarioInexistente_MismaRespuesta_UnaVerificacion_UsuarioInexistente()
    {
        var c = _f.Nuevo();
        var antes = _f.Hasher.Verificaciones;
        var inexistente = await c.Login("no.existe", "clave-cualquiera");
        var trasInexistente = _f.Hasher.Verificaciones;
        var incorrecta = await c.Login("finanzas.demo", "clave-cualquiera");

        Assert.Equal(HttpStatusCode.Unauthorized, inexistente.StatusCode);
        Assert.Equal(await Cuerpo(incorrecta), await Cuerpo(inexistente));
        // Una verificacion PBKDF2 (contra el hash ficticio) tambien para el usuario inexistente.
        Assert.Equal(1, trasInexistente - antes);
        Assert.Equal(2, _f.Hasher.Verificaciones - antes);
        var e = _f.Usuarios.EventosCopia()[0];
        Assert.Equal(("LoginFallido", MotivosLogin.UsuarioInexistente, (int?)null, "no.existe"), (e.Evento, e.Motivo, e.UsuarioId, e.UsuarioIngresado));
    }

    [Fact]
    public async Task AUT03_TiempoSimilar_InexistenteFrenteAClaveIncorrecta()
    {
        // Ambos caminos hacen una verificacion PBKDF2 (100.000 iteraciones); la base es simulada.
        // Cota amplia (factor 3) para no depender de la carga de la maquina.
        async Task<double> Mediana(string usuario)
        {
            var t = new List<double>();
            for (var i = 0; i < 5; i++)
            {
                var c = _f.Nuevo();
                var sw = Stopwatch.StartNew();
                Assert.Equal(HttpStatusCode.Unauthorized, (await c.Login(usuario, "clave-cualquiera-" + i)).StatusCode);
                t.Add(sw.Elapsed.TotalMilliseconds);
            }
            t.Sort();
            return t[2];
        }
        await _f.Nuevo().Login("ventas.demo", "calentamiento");
        var inexistente = await Mediana("nadie.aqui");
        var incorrecta = await Mediana("admin.demo");
        var razon = inexistente / incorrecta;
        Assert.InRange(razon, 1.0 / 3, 3.0);
    }

    [Fact]
    public async Task MensajeDeFallo_IdenticoParaTodasLasCausas()
    {
        _f.Usuarios.Agregar("inactivo.demo", Roles.Ventas, _f.Clave("inactivo.demo")).Activo = false;
        _f.Usuarios.Agregar("bloqueado.demo", Roles.Ventas, _f.Clave("bloqueado.demo")).BloqueadoHasta = _f.Reloj.GetUtcNow().UtcDateTime.AddMinutes(10);
        _f.Usuarios.Agregar("vencido.demo", Roles.Ventas, _f.Clave("vencido.demo"), debeCambiar: true,
            fechaCambio: _f.Reloj.GetUtcNow().UtcDateTime.AddHours(-25));

        var cuerpos = new List<string>();
        foreach (var (u, p) in new[]
                 {
                     ("finanzas.demo", "incorrecta"), ("no.existe", "x"), ("inactivo.demo", _f.Clave("inactivo.demo")),
                     ("bloqueado.demo", _f.Clave("bloqueado.demo")), ("vencido.demo", _f.Clave("vencido.demo")),
                     ("Clave Con Espacios!", "x"),
                 })
        {
            var r = await _f.Nuevo().Login(u, p);
            Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
            cuerpos.Add(await Cuerpo(r));
        }
        Assert.Single(cuerpos.Distinct());
        string[] esperados =
            [MotivosLogin.ClaveIncorrecta, MotivosLogin.UsuarioInexistente, MotivosLogin.UsuarioInactivo,
             MotivosLogin.CuentaBloqueada, MotivosLogin.ClaveTemporalVencida, MotivosLogin.UsuarioInexistente];
        Assert.Equal(esperados, _f.Usuarios.EventosCopia().Select(e => e.Motivo ?? "").ToArray());
    }

    [Fact]
    public async Task AUT04_CincoFallos_Bloquea_YElSextoConClaveCorrectaDa401()
    {
        var c = _f.Nuevo();
        for (var i = 0; i < 5; i++)
            Assert.Equal(HttpStatusCode.Unauthorized, (await c.Login("ventas.demo", "mala-" + i)).StatusCode);

        Assert.Contains(_f.Usuarios.EventosCopia(), e => e.Evento == "CuentaBloqueada" && e.UsuarioId == 2);
        var verif = _f.Hasher.Verificaciones;

        var sexto = await c.Login("ventas.demo", _f.Clave("ventas.demo"));
        Assert.Equal(HttpStatusCode.Unauthorized, sexto.StatusCode);
        Assert.Null(c.CookieSesion());
        var ultimo = _f.Usuarios.EventosCopia()[^1];
        Assert.Equal(MotivosLogin.CuentaBloqueada, ultimo.Motivo);
        Assert.Equal(5, _f.Usuarios.Fila("ventas.demo").IntentosFallidos);   // no incrementa el contador
        Assert.Equal(1, _f.Hasher.Verificaciones - verif);                   // solo el hash ficticio
    }

    [Fact]
    public async Task AUT05_LoginTrasVencerElBloqueo_200_YContadorEnCero()
    {
        var c = _f.Nuevo();
        for (var i = 0; i < 5; i++) await c.Login("ventas.demo", "mala-" + i);
        Assert.NotNull(_f.Usuarios.Fila("ventas.demo").BloqueadoHasta);

        _f.Reloj.Avanzar(TimeSpan.FromMinutes(16));
        var r = await c.Login("ventas.demo", _f.Clave("ventas.demo"));

        Assert.Equal(HttpStatusCode.OK, r.StatusCode);
        Assert.Equal(0, _f.Usuarios.Fila("ventas.demo").IntentosFallidos);
        Assert.Null(_f.Usuarios.Fila("ventas.demo").BloqueadoHasta);
    }

    [Fact]
    public async Task AUT06_DebeCambiarClave_SoloYoCambiarClaveYLogout()
    {
        _f.Usuarios.Agregar("temporal.demo", Roles.Finanzas, _f.Clave("temporal.demo"), debeCambiar: true);
        var c = _f.Nuevo();
        var r = await c.Login("temporal.demo", _f.Clave("temporal.demo"));
        Assert.Equal(HttpStatusCode.OK, r.StatusCode);
        Assert.True((await r.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("debeCambiarClave").GetBoolean());

        var yo = await c.Get("/api/v1/yo");
        Assert.Equal(HttpStatusCode.OK, yo.StatusCode);
        var jyo = await yo.Content.ReadFromJsonAsync<JsonElement>();
        Assert.True(jyo.GetProperty("debeCambiarClave").GetBoolean());
        Assert.Equal(Esquemas.Cookies, jyo.GetProperty("tipoAutenticacion").GetString());

        foreach (var url in new[] { "/api/v1/clientes/76555555-8/estado", "/api/v1/clientes/76555555-8/pedidos",
                                    "/api/v1/cartera/indicadores", "/api/v1/sincronizaciones" })
            Assert.Equal(HttpStatusCode.Forbidden, (await c.Get(url)).StatusCode);

        var nueva = "Nueva-" + Guid.NewGuid().ToString("N");
        Assert.Equal(HttpStatusCode.NoContent,
            (await c.Post("/api/v1/auth/cambiar-clave", new { claveActual = _f.Clave("temporal.demo"), claveNueva = nueva })).StatusCode);

        // Cookie reemitida sin debe_cambiar_clave: ya puede consultar la cartera.
        Assert.Equal(HttpStatusCode.OK, (await c.Get("/api/v1/cartera/indicadores")).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await c.Post("/api/v1/auth/logout", null)).StatusCode);
    }

    [Fact]
    public async Task AUT06_LogoutPermitidoConDebeCambiarClave()
    {
        _f.Usuarios.Agregar("temporal2.demo", Roles.Ventas, _f.Clave("temporal2.demo"), debeCambiar: true);
        var c = _f.Nuevo();
        await c.Login("temporal2.demo", _f.Clave("temporal2.demo"));
        Assert.Equal(HttpStatusCode.NoContent, (await c.Post("/api/v1/auth/logout", null)).StatusCode);
    }

    [Fact]
    public async Task AUT07_CambioDeClave_204_YLaCookieAnteriorDejaDeServirAlRevalidar()
    {
        var c = _f.Nuevo();
        await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));
        var copiada = c.CookieSesion()!;
        var selloAntes = _f.Usuarios.Fila("finanzas.demo").Sello;

        var nueva = "Nueva-" + Guid.NewGuid().ToString("N");
        var r = await c.Post("/api/v1/auth/cambiar-clave", new { claveActual = _f.Clave("finanzas.demo"), claveNueva = nueva });
        Assert.Equal(HttpStatusCode.NoContent, r.StatusCode);
        Assert.NotEqual(selloAntes, _f.Usuarios.Fila("finanzas.demo").Sello);
        Assert.Contains(_f.Usuarios.EventosCopia(), e => e.Evento == "CambioClave");

        var otro = _f.Nuevo();
        otro.Cookies.Add(Cliente.Base, new Cookie(NombresHttp.CookieSesion, copiada) { Secure = true });
        Assert.Equal(HttpStatusCode.OK, (await otro.Get("/api/v1/yo")).StatusCode);    // antes de revalidar (DEMO 5 min)

        _f.Reloj.Avanzar(TimeSpan.FromMinutes(6));
        Assert.Equal(HttpStatusCode.Unauthorized, (await otro.Get("/api/v1/yo")).StatusCode);
        // La sesion del usuario (cookie reemitida con el sello nuevo) sigue valida.
        Assert.Equal(HttpStatusCode.OK, (await c.Get("/api/v1/yo")).StatusCode);
        // Y la contrasena nueva funciona.
        Assert.Equal(HttpStatusCode.OK, (await _f.Nuevo().Login("finanzas.demo", nueva)).StatusCode);
    }

    [Fact]
    public async Task AUT08_DesactivacionConSesionAbierta_RechazadaAlRevalidar()
    {
        var c = _f.Nuevo();
        await c.Login("ventas.demo", _f.Clave("ventas.demo"));
        _f.Usuarios.Fila("ventas.demo").Activo = false;

        _f.Reloj.Avanzar(TimeSpan.FromMinutes(4));
        Assert.Equal(HttpStatusCode.OK, (await c.Get("/api/v1/yo")).StatusCode);
        _f.Reloj.Avanzar(TimeSpan.FromMinutes(2));
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.Get("/api/v1/yo")).StatusCode);
    }

    [Fact]
    public async Task Revalidacion_CambioDeRol_RechazaLaCookie()
    {
        var c = _f.Nuevo();
        await c.Login("ventas.demo", _f.Clave("ventas.demo"));
        _f.Usuarios.Fila("ventas.demo").Rol = Roles.Finanzas;
        _f.Reloj.Avanzar(TimeSpan.FromMinutes(6));
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.Get("/api/v1/yo")).StatusCode);
    }

    [Fact]
    public async Task Revalidacion_ErrorDeBase_FallaCerrada()
    {
        var c = _f.Nuevo();
        await c.Login("ventas.demo", _f.Clave("ventas.demo"));
        _f.Usuarios.FallarObtenerPorId = true;
        _f.Reloj.Avanzar(TimeSpan.FromMinutes(6));
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.Get("/api/v1/yo")).StatusCode);
    }

    [Fact]
    public async Task Sesion_DuracionAbsolutaDeOchoHoras()
    {
        var c = _f.Nuevo();
        await c.Login("ventas.demo", _f.Clave("ventas.demo"));
        // Actividad cada 20 min (dentro de la inactividad de 30): la sesion se desliza hasta las 8 h.
        for (var i = 0; i < 23; i++)
        {
            _f.Reloj.Avanzar(TimeSpan.FromMinutes(20));
            Assert.Equal(HttpStatusCode.OK, (await c.Get("/api/v1/yo")).StatusCode);
        }
        _f.Reloj.Avanzar(TimeSpan.FromMinutes(21));   // 8 h 1 min desde la emision
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.Get("/api/v1/yo")).StatusCode);
    }

    [Fact]
    public async Task Sesion_ExpiraPorInactividad()
    {
        var c = _f.Nuevo();
        await c.Login("ventas.demo", _f.Clave("ventas.demo"));
        _f.Reloj.Avanzar(TimeSpan.FromMinutes(31));
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.Get("/api/v1/yo")).StatusCode);
    }

    [Fact]
    public async Task AUT09_RolVentas_EnCartera_403()
    {
        var c = _f.Nuevo();
        await c.Login("ventas.demo", _f.Clave("ventas.demo"));
        Assert.Equal(HttpStatusCode.Forbidden, (await c.Get("/api/v1/cartera/indicadores")).StatusCode);
    }

    [Fact]
    public async Task AUT13_PostSinTokenCsrf_400()
    {
        var c = _f.Nuevo();
        Assert.Equal(HttpStatusCode.BadRequest,
            (await c.Login("finanzas.demo", _f.Clave("finanzas.demo"), conToken: false)).StatusCode);
        Assert.Empty(_f.Usuarios.EventosCopia());   // no llega a verificar la contrasena

        await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));
        Assert.Equal(HttpStatusCode.BadRequest, (await c.Post("/api/v1/auth/logout", null, conToken: false)).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await c.Post("/api/v1/auth/cambiar-clave",
            new { claveActual = _f.Clave("finanzas.demo"), claveNueva = "Nueva-" + Guid.NewGuid() }, conToken: false)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await c.Get("/api/v1/yo")).StatusCode);   // sigue con sesion
    }

    [Fact]
    public async Task AUT13_TokenDeOtroUsuario_400()
    {
        var anonimo = _f.Nuevo();
        var tokenAnonimo = await anonimo.TokenCsrf();

        var c = _f.Nuevo();
        await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));
        var req = c.Solicitud(HttpMethod.Post, "/api/v1/auth/logout");
        req.Headers.TryAddWithoutValidation(NombresHttp.EncabezadoCsrf, tokenAnonimo);
        Assert.Equal(HttpStatusCode.BadRequest, (await c.Http.SendAsync(req)).StatusCode);
    }

    [Fact]
    public async Task AUT14_Logout_204_CookieEliminada_Logout()
    {
        var c = _f.Nuevo();
        await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));
        var r = await c.Post("/api/v1/auth/logout", null);

        Assert.Equal(HttpStatusCode.NoContent, r.StatusCode);
        var setCookie = string.Join("\n", r.Headers.GetValues("Set-Cookie"));
        Assert.Contains(NombresHttp.CookieSesion + "=;", setCookie);
        Assert.Contains("expires=Thu, 01 Jan 1970", setCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Null(c.CookieSesion());
        Assert.Equal("Logout", _f.Usuarios.EventosCopia()[^1].Evento);
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.Get("/api/v1/yo")).StatusCode);
    }

    [Fact]
    public async Task AUT16_ClaveTemporalVencida_401_ClaveTemporalVencida_ContadorSinCambio()
    {
        var fila = _f.Usuarios.Agregar("vencida.demo", Roles.Finanzas, _f.Clave("vencida.demo"), debeCambiar: true,
            fechaCambio: _f.Reloj.GetUtcNow().UtcDateTime.AddHours(-24).AddMinutes(-1));
        var verif = _f.Hasher.Verificaciones;

        var r = await _f.Nuevo().Login("vencida.demo", _f.Clave("vencida.demo"));

        Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
        Assert.Contains(EndpointsAutenticacion.MensajeLoginFallido, await Cuerpo(r));
        Assert.Equal(MotivosLogin.ClaveTemporalVencida, _f.Usuarios.EventosCopia()[^1].Motivo);
        Assert.Equal(0, fila.IntentosFallidos);
        Assert.Equal(1, _f.Hasher.Verificaciones - verif);   // solo el hash ficticio, no la contrasena real
    }

    [Fact]
    public async Task AUT16_ClaveTemporalDentroDeVigencia_Permite()
    {
        _f.Usuarios.Agregar("vigente.demo", Roles.Finanzas, _f.Clave("vigente.demo"), debeCambiar: true,
            fechaCambio: _f.Reloj.GetUtcNow().UtcDateTime.AddHours(-23));
        Assert.Equal(HttpStatusCode.OK, (await _f.Nuevo().Login("vigente.demo", _f.Clave("vigente.demo"))).StatusCode);
    }

    [Fact]
    public async Task AUT18_ContrasenaEscritaEnElCampoUsuario_SeGuardaFormatoNoValido()
    {
        var escritaPorError = "Mi Clave Secreta#2026";
        await _f.Nuevo().Login(escritaPorError, "x");

        var e = Assert.Single(_f.Usuarios.EventosCopia());
        Assert.Equal(ServicioAutenticacion.UsuarioNoValido, e.UsuarioIngresado);
        Assert.Equal(MotivosLogin.UsuarioInexistente, e.Motivo);
        Assert.DoesNotContain(_f.Usuarios.ArgumentosTexto, t => t.Contains(escritaPorError, StringComparison.Ordinal));
    }

    [Fact]
    public async Task Login_UsuarioSeNormalizaAMinusculas()
    {
        var r = await _f.Nuevo().Login("  FINANZAS.Demo ", _f.Clave("finanzas.demo"));
        Assert.Equal(HttpStatusCode.OK, r.StatusCode);
    }

    [Theory]
    [InlineData("{\"usuario\":\"finanzas.demo\"}")]
    [InlineData("{\"clave\":\"x\"}")]
    [InlineData("{\"usuario\":\"\",\"clave\":\"x\"}")]
    [InlineData("null")]
    public async Task Login_FaltaUnCampo_400(string json)
    {
        var c = _f.Nuevo();
        var token = await c.TokenCsrf();
        var req = c.Solicitud(HttpMethod.Post, "/api/v1/auth/login");
        req.Headers.TryAddWithoutValidation(NombresHttp.EncabezadoCsrf, token);
        req.Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");
        Assert.Equal(HttpStatusCode.BadRequest, (await c.Http.SendAsync(req)).StatusCode);
    }

    [Fact]
    public async Task CambiarClave_Politica_400()
    {
        var c = _f.Nuevo();
        var actual = _f.Clave("finanzas.demo");
        await c.Login("finanzas.demo", actual);

        foreach (var nueva in new[] { "corta", "FINANZAS.DEMO", actual, new string('x', 129) })
        {
            var r = await c.Post("/api/v1/auth/cambiar-clave", new { claveActual = actual, claveNueva = nueva });
            Assert.Equal(HttpStatusCode.BadRequest, r.StatusCode);
        }
        Assert.DoesNotContain(_f.Usuarios.EventosCopia(), e => e.Evento == "CambioClave");
    }

    [Fact]
    public async Task CambiarClave_ActualIncorrecta_401_CuentaComoIntentoFallido()
    {
        var c = _f.Nuevo();
        await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));
        var r = await c.Post("/api/v1/auth/cambiar-clave", new { claveActual = "no-es-la-actual", claveNueva = "Nueva-" + Guid.NewGuid() });

        Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
        Assert.Equal(1, _f.Usuarios.Fila("finanzas.demo").IntentosFallidos);
        Assert.Equal(MotivosLogin.ClaveIncorrecta, _f.Usuarios.EventosCopia()[^1].Motivo);
    }

    [Fact]
    public async Task CambiarClave_SinSesion_401()
    {
        var r = await _f.Nuevo().Post("/api/v1/auth/cambiar-clave", new { claveActual = "a", claveNueva = "b" });
        Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
    }

    [Fact]
    public async Task NuncaSeEnvianContrasenasEnTextoPlanoNiSeRegistranEnLogs()
    {
        var c = _f.Nuevo();
        var actual = _f.Clave("finanzas.demo");
        var nueva = "Nueva-" + Guid.NewGuid().ToString("N");
        await c.Login("finanzas.demo", "incorrecta-" + actual);
        await c.Login("finanzas.demo", actual);
        await c.Post("/api/v1/auth/cambiar-clave", new { claveActual = actual, claveNueva = nueva });
        await c.Post("/api/v1/auth/logout", null);

        foreach (var secreto in new[] { actual, nueva })
        {
            Assert.DoesNotContain(_f.Usuarios.ArgumentosTexto, t => t.Contains(secreto, StringComparison.Ordinal));
            Assert.DoesNotContain(_f.Logs.Mensajes, m => m.Contains(secreto, StringComparison.Ordinal));
        }
        // El hash nuevo es un hash V3 de PasswordHasher, no la contrasena.
        Assert.StartsWith("AQAAAA", _f.Usuarios.Fila("finanzas.demo").HashClave);
    }
}
