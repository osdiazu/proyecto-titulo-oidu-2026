using System.Net;
using Cobranza.Api.Datos;
using Cobranza.Api.Seguridad;

namespace Cobranza.Api.Tests;

/// <summary>
/// Desviaciones de sql/12 informadas por el dba (evidencias/2026-11-06_adr001_sql/CAMBIOS.md):
/// - D-12: sp_RegistrarLoginFallido extiende el bloqueo si recibe ClaveIncorrecta para una cuenta ya
///   bloqueada; la API debe enviar CuentaBloqueada cuando BloqueadoHasta es mayor que ahora.
/// - D-5: sp_RegistrarLoginExitoso lanza 50061 si el usuario no existe; la API no debe responder 500.
/// </summary>
public sealed class DesviacionesSqlTests : IDisposable
{
    private readonly FabricaApi _f = new();
    public void Dispose() => _f.Dispose();

    private async Task Bloquear(string usuario)
    {
        var c = _f.Nuevo();
        for (var i = 0; i < 5; i++) await c.Login(usuario, "mala-" + i);
        Assert.NotNull(_f.Usuarios.Fila(usuario).BloqueadoHasta);
    }

    [Fact]
    public async Task D12_CuentaBloqueada_ConClaveIncorrecta_EnviaCuentaBloqueada_YNoExtiendeElBloqueo()
    {
        await Bloquear("ventas.demo");
        var fila = _f.Usuarios.Fila("ventas.demo");
        var bloqueoOriginal = fila.BloqueadoHasta;
        var eventosAntes = _f.Usuarios.EventosCopia().Length;

        _f.Reloj.Avanzar(TimeSpan.FromMinutes(5));
        for (var i = 0; i < 3; i++)
            Assert.Equal(HttpStatusCode.Unauthorized, (await _f.Nuevo().Login("ventas.demo", "otra-mala-" + i)).StatusCode);

        var nuevos = _f.Usuarios.EventosCopia()[eventosAntes..];
        Assert.Equal(3, nuevos.Length);
        Assert.All(nuevos, e => Assert.Equal(("LoginFallido", MotivosLogin.CuentaBloqueada), (e.Evento, e.Motivo)));
        Assert.DoesNotContain(nuevos, e => e.Motivo == MotivosLogin.ClaveIncorrecta || e.Evento == "CuentaBloqueada");
        Assert.Equal(bloqueoOriginal, fila.BloqueadoHasta);   // el bloqueo no se extendio
        Assert.Equal(5, fila.IntentosFallidos);               // el contador no cambio
    }

    [Fact]
    public async Task D12_CuentaBloqueada_ElBloqueoVenceALaHoraOriginal()
    {
        await Bloquear("ventas.demo");
        _f.Reloj.Avanzar(TimeSpan.FromMinutes(10));
        await _f.Nuevo().Login("ventas.demo", "mala-durante-bloqueo");   // no debe extender
        _f.Reloj.Avanzar(TimeSpan.FromMinutes(5) + TimeSpan.FromSeconds(1));   // 15 min desde el bloqueo
        Assert.Equal(HttpStatusCode.OK, (await _f.Nuevo().Login("ventas.demo", _f.Clave("ventas.demo"))).StatusCode);
    }

    [Fact]
    public async Task D12_BloqueoVencidoExactamente_SeTrataComoNoBloqueado()
    {
        // Mismo criterio que sql/12 (PA-06): BloqueadoHasta <= ahora equivale a no bloqueado.
        var fila = _f.Usuarios.Fila("ventas.demo");
        fila.IntentosFallidos = 5;
        fila.BloqueadoHasta = _f.Reloj.GetUtcNow().UtcDateTime;

        await _f.Nuevo().Login("ventas.demo", "mala");

        Assert.Equal(MotivosLogin.ClaveIncorrecta, _f.Usuarios.EventosCopia()[^1].Motivo);
        Assert.Equal(1, fila.IntentosFallidos);   // el procedimiento reinicio el contador
        Assert.Null(fila.BloqueadoHasta);
    }

    [Fact]
    public async Task D12_CambiarClave_ConCuentaBloqueada_NoEnviaClaveIncorrecta()
    {
        var c = _f.Nuevo();
        await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));
        var fila = _f.Usuarios.Fila("finanzas.demo");
        fila.BloqueadoHasta = _f.Reloj.GetUtcNow().UtcDateTime.AddMinutes(10);
        var bloqueo = fila.BloqueadoHasta;
        var eventosAntes = _f.Usuarios.EventosCopia().Length;

        var r = await c.Post("/api/v1/auth/cambiar-clave", new { claveActual = "no-es-la-actual", claveNueva = "Nueva-" + Guid.NewGuid() });

        Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
        Assert.Empty(_f.Usuarios.EventosCopia()[eventosAntes..]);   // no llama a sp_RegistrarLoginFallido
        Assert.Equal(bloqueo, fila.BloqueadoHasta);
        Assert.Equal(0, fila.IntentosFallidos);
    }

    [Fact]
    public async Task D5_UsuarioEliminadoDuranteElLogin_401Generico_SinCookie_NoEs500()
    {
        _f.Usuarios.UsuarioNoExisteEnLoginExitoso = true;
        var c = _f.Nuevo();

        var r = await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));

        Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
        Assert.Contains(EndpointsAutenticacion.MensajeLoginFallido, await r.Content.ReadAsStringAsync());
        Assert.Null(c.CookieSesion());
        var e = _f.Usuarios.EventosCopia()[^1];
        Assert.Equal(("LoginFallido", MotivosLogin.UsuarioInexistente, (int?)null, "finanzas.demo"),
            (e.Evento, e.Motivo, e.UsuarioId, e.UsuarioIngresado));
    }
}
