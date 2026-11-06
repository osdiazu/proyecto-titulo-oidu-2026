using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Cobranza.Api.Seguridad;
using Cobranza.Comun;

namespace Cobranza.Api.Tests;

/// <summary>
/// Matriz de permisos (ADR-001 5.6: se conservan exactamente los permisos previos), claves de API
/// (AUT-10 a AUT-12) y regresion de A-01 (X-MS-CLIENT-PRINCIPAL ya no autentica).
/// </summary>
public sealed class AutorizacionYClaveApiTests : IDisposable
{
    private readonly FabricaApi _f = new();
    public void Dispose() => _f.Dispose();

    private const string Estado = "/api/v1/clientes/76555555-8/estado";
    private const string Pedidos = "/api/v1/clientes/76555555-8/pedidos";
    private const string Cartera = "/api/v1/cartera/indicadores";
    private const string Sincronizaciones = "/api/v1/sincronizaciones";

    [Theory]
    // usuario,        estado, pedidos, cartera, sincronizaciones
    [InlineData("ventas.demo", 200, 200, 403, 403)]   // antes Ventas.Consulta
    [InlineData("finanzas.demo", 200, 200, 200, 200)] // antes Finanzas.Consulta
    [InlineData("admin.demo", 403, 403, 403, 200)]    // antes TI.Operacion
    public async Task MatrizDePermisos_PorRolDeUsuario(string usuario, int estado, int pedidos, int cartera, int sinc)
    {
        var c = _f.Nuevo();
        Assert.Equal(HttpStatusCode.OK, (await c.Login(usuario, _f.Clave(usuario))).StatusCode);
        Assert.Equal(estado, (int)(await c.Get(Estado)).StatusCode);
        Assert.Equal(pedidos, (int)(await c.Get(Pedidos)).StatusCode);
        Assert.Equal(cartera, (int)(await c.Get(Cartera)).StatusCode);
        Assert.Equal(sinc, (int)(await c.Get(Sincronizaciones)).StatusCode);
    }

    [Fact]
    public async Task SinCredenciales_EndpointsProtegidos_401()
    {
        var c = _f.Nuevo();
        foreach (var url in new[] { Estado, Pedidos, Cartera, Sincronizaciones, "/api/v1/yo" })
            Assert.Equal(HttpStatusCode.Unauthorized, (await c.Get(url)).StatusCode);   // RED-02: solo 401, sin 302
    }

    [Fact]
    public async Task A01_EncabezadoEasyAuthFalsificado_NoAutentica()
    {
        var principal = Convert.ToBase64String(Encoding.UTF8.GetBytes(
            """{"auth_typ":"aad","claims":[{"typ":"roles","val":"Finanzas.Consulta"},{"typ":"roles","val":"Finanzas"}]}"""));
        var c = _f.Nuevo();
        var req = c.Solicitud(HttpMethod.Get, Cartera);
        req.Headers.TryAddWithoutValidation("X-MS-CLIENT-PRINCIPAL", principal);
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.Http.SendAsync(req)).StatusCode);
    }

    [Fact]
    public void A01_EasyAuthHandler_NoExisteEnElEnsamblado()
    {
        var tipos = typeof(Program).Assembly.GetTypes().Select(t => t.Name);
        Assert.DoesNotContain("EasyAuthHandler", tipos);
    }

    [Fact]
    public async Task AUT10_ClaveApiValida_EstadoCliente_200()
    {
        var (clave, fila) = _f.Usuarios.AgregarClave();
        var c = _f.Nuevo();
        var r = await c.Get(Estado, clave);
        Assert.Equal(HttpStatusCode.OK, r.StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await c.Get(Pedidos, clave)).StatusCode);

        var yo = await (await c.Get("/api/v1/yo", clave)).Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("api:ventas-demo", yo.GetProperty("nombre").GetString());
        Assert.Equal(Esquemas.ClaveApi, yo.GetProperty("tipoAutenticacion").GetString());
        Assert.Equal(Roles.Ventas, yo.GetProperty("roles")[0].GetString());
        Assert.NotNull(fila);
    }

    [Fact]
    public async Task AUT11_ClaveApi_EnCartera_403_YEnSincronizaciones_403()
    {
        var (clave, _) = _f.Usuarios.AgregarClave();
        var c = _f.Nuevo();
        Assert.Equal(HttpStatusCode.Forbidden, (await c.Get(Cartera, clave)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await c.Get(Sincronizaciones, clave)).StatusCode);
    }

    [Fact]
    public async Task AUT12_ClaveRevocada_401_TrasVencerLaCache()
    {
        var (clave, fila) = _f.Usuarios.AgregarClave();
        var c = _f.Nuevo();
        Assert.Equal(HttpStatusCode.OK, (await c.Get(Estado, clave)).StatusCode);

        fila.FechaRevocacion = _f.Reloj.GetUtcNow().UtcDateTime;
        fila.Activa = false;
        _f.Reloj.Avanzar(TimeSpan.FromSeconds(30));
        Assert.Equal(HttpStatusCode.OK, (await c.Get(Estado, clave)).StatusCode);   // dentro de los 60 s de cache (DEMO)
        _f.Reloj.Avanzar(TimeSpan.FromSeconds(31));
        Assert.Equal(HttpStatusCode.Unauthorized, (await c.Get(Estado, clave)).StatusCode);
    }

    [Fact]
    public async Task AUT12_ClaveVencida_401()
    {
        var (clave, _) = _f.Usuarios.AgregarClave(vigencia: TimeSpan.FromMinutes(-1));
        Assert.Equal(HttpStatusCode.Unauthorized, (await _f.Nuevo().Get(Estado, clave)).StatusCode);
    }

    [Fact]
    public async Task ClaveApi_CacheEvitaConsultarLaBaseEnCadaSolicitud()
    {
        var (clave, _) = _f.Usuarios.AgregarClave();
        var c = _f.Nuevo();
        for (var i = 0; i < 5; i++) await c.Get(Estado, clave);
        Assert.Equal(1, _f.Usuarios.LlamadasValidarClave);
    }

    [Theory]
    [InlineData("no-es-una-clave")]
    [InlineData("cobk_ABCDEFGH_0123456789012345678901234567890123456789012")]   // prefijo en mayusculas
    [InlineData("cobk_abcdefg1_0123456789012345678901234567890123456789012")]   // 1 no es Base32
    [InlineData("cobk_abcdefgh_012345678901234567890123456789012345678901")]    // secreto corto
    [InlineData("cobk_abcdefgh_01234567890123456789012345678901234567890+=")]   // Base64 no url
    public async Task ClaveApi_FormatoInvalido_401_SinConsultarLaBase(string clave)
    {
        Assert.Equal(HttpStatusCode.Unauthorized, (await _f.Nuevo().Get(Estado, clave)).StatusCode);
        Assert.Equal(0, _f.Usuarios.LlamadasValidarClave);
    }

    [Fact]
    public async Task ClaveApi_FormatoValidoPeroDesconocida_401_YSeRegistraSoloElPrefijo()
    {
        var (clave, prefijo) = ClaveApiFormato.Generar();
        Assert.Equal(HttpStatusCode.Unauthorized, (await _f.Nuevo().Get(Estado, clave)).StatusCode);
        Assert.Equal(1, _f.Usuarios.LlamadasValidarClave);
        Assert.Contains(_f.Logs.Mensajes, m => m.Contains(prefijo, StringComparison.Ordinal));
        Assert.DoesNotContain(_f.Logs.Mensajes, m => m.Contains(clave, StringComparison.Ordinal));
        Assert.DoesNotContain(_f.Usuarios.ArgumentosTexto, t => t.Contains(clave, StringComparison.Ordinal));
    }

    [Fact]
    public async Task ClaveApi_NoSeRegistraEnLogsNiSeEnviaASql()
    {
        var (clave, _) = _f.Usuarios.AgregarClave();
        await _f.Nuevo().Get(Estado, clave);
        Assert.DoesNotContain(_f.Logs.Mensajes, m => m.Contains(clave, StringComparison.Ordinal));
        Assert.DoesNotContain(_f.Usuarios.ArgumentosTexto, t => t.Contains(clave, StringComparison.Ordinal));
    }

    [Fact]
    public async Task EndpointsDeAutenticacion_RechazanClaveApi()
    {
        var (clave, _) = _f.Usuarios.AgregarClave();
        var c = _f.Nuevo();
        Assert.Equal(HttpStatusCode.Forbidden, (await c.Get("/api/v1/auth/antiforgery", clave)).StatusCode);
        // Login: el filtro rechaza antes de mirar el cuerpo.
        var req = c.Solicitud(HttpMethod.Post, "/api/v1/auth/login");
        req.Headers.TryAddWithoutValidation(NombresHttp.EncabezadoClaveApi, clave);
        req.Content = JsonContent.Create(new { usuario = "finanzas.demo", clave = _f.Clave("finanzas.demo") });
        Assert.Equal(HttpStatusCode.Forbidden, (await c.Http.SendAsync(req)).StatusCode);
        // Logout y cambio de contrasena exigen sesion por cookie (SoloSesionPanel).
        foreach (var url in new[] { "/api/v1/auth/logout", "/api/v1/auth/cambiar-clave" })
        {
            var r = c.Solicitud(HttpMethod.Post, url);
            r.Headers.TryAddWithoutValidation(NombresHttp.EncabezadoClaveApi, clave);
            Assert.Equal(HttpStatusCode.Forbidden, (await c.Http.SendAsync(r)).StatusCode);
        }
        Assert.Empty(_f.Usuarios.EventosCopia());
    }

    [Fact]
    public async Task ClaveApi_TienePrioridadSobreLaCookie()
    {
        var (clave, _) = _f.Usuarios.AgregarClave();
        var c = _f.Nuevo();
        await c.Login("finanzas.demo", _f.Clave("finanzas.demo"));
        // Con X-Api-Key el selector usa ClaveApi (rol Ventas), aunque la cookie sea de Finanzas.
        Assert.Equal(HttpStatusCode.Forbidden, (await c.Get(Cartera, clave)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await c.Get(Cartera)).StatusCode);
    }
}
