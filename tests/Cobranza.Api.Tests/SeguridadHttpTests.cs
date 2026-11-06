using System.Net;
using Cobranza.Api.Seguridad;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.Extensions.DependencyInjection;

namespace Cobranza.Api.Tests;

/// <summary>
/// Atributos de cookie (RED-12), limitador (RED-15), encabezados reenviados (RED-16), archivos
/// estaticos antes de la autenticacion, arranque con configuracion incompleta y telemetria.
/// </summary>
public sealed class SeguridadHttpTests
{
    private static string AtributosDe(HttpResponseMessage r, string cookie) =>
        r.Headers.GetValues("Set-Cookie").Single(v => v.StartsWith(cookie + "=", StringComparison.Ordinal)).ToLowerInvariant();

    [Fact]
    public async Task RED12_CookieDeSesion_HostSecureHttpOnlySameSiteStrict_SinDomainNiExpires()
    {
        using var f = new FabricaApi();
        var r = await f.Nuevo().Login("finanzas.demo", f.Clave("finanzas.demo"));
        var a = AtributosDe(r, NombresHttp.CookieSesion);

        Assert.StartsWith("__host-", a);
        Assert.Contains("; path=/", a);
        Assert.Contains("; secure", a);
        Assert.Contains("; httponly", a);
        Assert.Contains("; samesite=strict", a);
        Assert.DoesNotContain("domain=", a);
        Assert.DoesNotContain("expires=", a);   // cookie de sesion (IsPersistent = false)
    }

    [Fact]
    public async Task CookieAntifalsificacion_HostSecureHttpOnlySameSiteStrict()
    {
        using var f = new FabricaApi();
        var r = await f.Nuevo().Get("/api/v1/auth/antiforgery");
        var a = AtributosDe(r, NombresHttp.CookieAntifalsificacion);

        Assert.Contains("; path=/", a);
        Assert.Contains("; secure", a);
        Assert.Contains("; httponly", a);
        Assert.Contains("; samesite=strict", a);
        Assert.DoesNotContain("domain=", a);
    }

    [Fact]
    public async Task RED15_MasDeDiezIntentosPorMinutoDesdeLaMismaIp_429()
    {
        using var f = new FabricaApi();
        var c = f.Nuevo("203.0.113.50");
        for (var i = 0; i < 10; i++)
            Assert.Equal(HttpStatusCode.Unauthorized, (await c.Login("no.existe", "x")).StatusCode);
        Assert.Equal(HttpStatusCode.TooManyRequests, (await c.Login("no.existe", "x")).StatusCode);
        // El 429 no escribe en SQL (ADR 5.7): solo los 10 intentos anteriores quedaron registrados.
        Assert.Equal(10, f.Usuarios.EventosCopia().Length);
        // Otra IP no queda afectada.
        Assert.Equal(HttpStatusCode.OK, (await f.Nuevo("203.0.113.51").Login("finanzas.demo", f.Clave("finanzas.demo"))).StatusCode);
    }

    [Fact]
    public async Task RED16_XForwardedForEscritoPorElCliente_NoCambiaIpNiEvadeElLimitador()
    {
        using var f = new FabricaApi();
        var c = f.Nuevo("203.0.113.60");   // IP real que agrega el front-end (valor de mas a la derecha)
        for (var i = 0; i < 10; i++)
        {
            // El cliente rota el valor que escribe; el front-end agrega la IP real a la derecha.
            var r = await c.Login("no.existe", "x", xffCliente: $"203.0.113.{100 + i}");
            Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
        }
        Assert.Equal(HttpStatusCode.TooManyRequests, (await c.Login("no.existe", "x", xffCliente: "203.0.113.10")).StatusCode);
        Assert.All(f.Usuarios.EventosCopia(), e => Assert.Equal("203.0.113.60", e.Ip));
    }

    [Fact]
    public async Task IpConPuerto_SeRegistraSinPuerto()
    {
        using var f = new FabricaApi();
        var c = f.Nuevo("203.0.113.70:51234");
        await c.Login("no.existe", "x");
        Assert.Equal("203.0.113.70", Assert.Single(f.Usuarios.EventosCopia()).Ip);
    }

    [Theory]
    [InlineData("/login.html")]
    [InlineData("/login.js")]
    [InlineData("/panel.css")]
    [InlineData("/panel.js")]
    [InlineData("/")]
    public async Task ArchivosEstaticos_AccesiblesSinSesion(string url)
    {
        using var f = new FabricaApi();
        Assert.Equal(HttpStatusCode.OK, (await f.Nuevo().Get(url)).StatusCode);
    }

    [Fact]
    public async Task Salud_Anonima()
    {
        using var f = new FabricaApi();
        Assert.Equal(HttpStatusCode.OK, (await f.Nuevo().Get("/salud")).StatusCode);
    }

    [Fact]
    public void Production_SinDataProtection_NoArranca()
    {
        // appsettings.json trae marcadores PENDIENTE: no son URI HTTPS.
        using var f = new FabricaApi("Production", new Dictionary<string, string?>());
        var ex = Assert.ThrowsAny<Exception>(() => f.CreateClient());
        Assert.Contains("DataProtection__BlobUri", ex.ToString());
    }

    [Fact]
    public void Production_DataProtectionConUriNoHttps_NoArranca()
    {
        using var f = new FabricaApi("Production", new Dictionary<string, string?>
        {
            ["DataProtection:BlobUri"] = "http://cuenta.blob.core.windows.net/dataprotection-keys/keys.xml",
            ["DataProtection:KeyIdentifier"] = "https://kv.vault.azure.net/keys/dataprotection-cobranza-api",
        });
        Assert.ThrowsAny<Exception>(() => f.CreateClient());
    }

    [Fact]
    public async Task Development_SinDataProtection_Arranca()
    {
        using var f = new FabricaApi();
        Assert.Equal(HttpStatusCode.OK, (await f.Nuevo().Get("/salud")).StatusCode);
    }

    [Fact]
    public void ForwardedHeadersDeLaPlataformaHabilitado_NoArranca()
    {
        using var f = new FabricaApi("Development", new Dictionary<string, string?> { ["FORWARDEDHEADERS_ENABLED"] = "true" });
        var ex = Assert.ThrowsAny<Exception>(() => f.CreateClient());
        Assert.Contains("ASPNETCORE_FORWARDEDHEADERS_ENABLED", ex.ToString());
    }

    [Theory]
    [InlineData("Seguridad:MaxIntentosFallidos", "0")]
    [InlineData("Seguridad:SaltosProxyConfiables", "3")]
    [InlineData("Seguridad:LongitudMinimaClave", "200")]
    public void OpcionesSeguridadInvalidas_NoArranca(string clave, string valor)
    {
        using var f = new FabricaApi("Development", new Dictionary<string, string?> { [clave] = valor });
        Assert.ThrowsAny<Exception>(() => f.CreateClient());
    }

    [Fact]
    public void Telemetria_EliminaEncabezadosSensibles_YConservaElPrefijo()
    {
        var t = new RequestTelemetry { Url = new Uri("https://localhost/api/v1/auth/login?x=1") };
        foreach (var k in new[] { "X-Api-Key", "Authorization", "Cookie", "Set-Cookie", "X-CSRF-TOKEN", "Request-Cookie",
                                  "RequestBody", "http_header_x_api_key" })
            t.Properties[k] = "valor";
        t.Properties[TiposClaim.PrefijoClave] = "abcdefgh";

        new TelemetriaSinDatosSensibles().Initialize(t);

        Assert.Equal([TiposClaim.PrefijoClave], t.Properties.Keys.ToArray());
        Assert.Equal("", t.Url.Query);
    }

    [Fact]
    public void Telemetria_EstaRegistradaEnLaApi()
    {
        using var f = new FabricaApi();
        var inicializadores = f.Services.GetServices<Microsoft.ApplicationInsights.Extensibility.ITelemetryInitializer>();
        Assert.Contains(inicializadores, i => i is TelemetriaSinDatosSensibles);
    }
}
