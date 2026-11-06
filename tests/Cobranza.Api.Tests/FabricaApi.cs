using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Cobranza.Api.Datos;
using Cobranza.Api.Seguridad;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Mvc.Testing.Handlers;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;

namespace Cobranza.Api.Tests;

/// <summary>
/// API en memoria con repositorios simulados, reloj controlable y Data Protection efimero.
/// Entorno Development (no exige Data Protection en Blob; las pruebas de arranque en Production
/// usan <see cref="FabricaApi(string, IDictionary{string, string?})"/>).
/// </summary>
public sealed class FabricaApi : WebApplicationFactory<Program>
{
    private readonly string _entorno;
    private readonly IDictionary<string, string?> _ajustes;
    private static int _ipSiguiente;

    public RelojFalso Reloj { get; } = new();
    public RepositorioUsuariosFalso Usuarios { get; }
    public HasherContador Hasher { get; } = new();
    public ProveedorLogCapturado Logs { get; } = new();

    /// <summary>Contrasenas generadas en cada ejecucion (no hay contrasenas literales en el repositorio).</summary>
    public Dictionary<string, string> Claves { get; } = [];

    public FabricaApi() : this("Development", new Dictionary<string, string?>()) { }

    public FabricaApi(string entorno, IDictionary<string, string?> ajustes)
    {
        _entorno = entorno;
        _ajustes = ajustes;
        Usuarios = new RepositorioUsuariosFalso(Reloj);
        foreach (var (u, rol) in new[] { ("finanzas.demo", Roles.Finanzas), ("ventas.demo", Roles.Ventas), ("admin.demo", Roles.Admin) })
            Usuarios.Agregar(u, rol, Clave(u));
    }

    public string Clave(string usuario)
    {
        if (!Claves.TryGetValue(usuario, out var c))
            Claves[usuario] = c = "Prueba-" + Convert.ToBase64String(RandomNumberGenerator.GetBytes(12));
        return c;
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(_entorno);
        foreach (var (k, v) in _ajustes) builder.UseSetting(k, v);
        builder.ConfigureLogging(l => l.AddProvider(Logs));
        builder.ConfigureTestServices(s =>
        {
            s.RemoveAll<IRepositorioUsuarios>();
            s.AddSingleton<IRepositorioUsuarios>(Usuarios);
            s.RemoveAll<IRepositorioConsultas>();
            s.AddSingleton<IRepositorioConsultas, RepositorioConsultasFalso>();
            s.RemoveAll<TimeProvider>();
            s.AddSingleton<TimeProvider>(Reloj);
            s.RemoveAll<IPasswordHasher<UsuarioPanel>>();
            s.AddSingleton<IPasswordHasher<UsuarioPanel>>(Hasher);
            s.AddDataProtection().UseEphemeralDataProtectionProvider();
        });
    }

    /// <summary>
    /// Cliente HTTPS con contenedor de cookies propio. Simula el front-end de App Service agregando
    /// la IP del cliente como valor de mas a la derecha de X-Forwarded-For (una IP distinta por
    /// cliente, para que el limitador por IP no mezcle pruebas).
    /// </summary>
    public Cliente Nuevo(string? ip = null)
    {
        ip ??= $"198.51.100.{Interlocked.Increment(ref _ipSiguiente) % 250 + 1}";
        var cookies = new CookieContainer();
        var http = CreateDefaultClient(new Uri("https://localhost"), new CookieContainerHandler(cookies));
        return new Cliente(http, cookies, ip);
    }
}

public sealed class Cliente(HttpClient http, CookieContainer cookies, string ip)
{
    public HttpClient Http { get; } = http;
    public CookieContainer Cookies { get; } = cookies;
    public string Ip { get; } = ip;
    public static readonly Uri Base = new("https://localhost");

    public HttpRequestMessage Solicitud(HttpMethod m, string url, string? xffCliente = null)
    {
        var r = new HttpRequestMessage(m, url);
        // Lo que escribe el cliente queda a la izquierda; el front-end agrega la IP real a la derecha.
        r.Headers.TryAddWithoutValidation("X-Forwarded-For", xffCliente is null ? Ip : $"{xffCliente}, {Ip}");
        r.Headers.UserAgent.ParseAdd("PruebasCobranza/1.0");
        return r;
    }

    public async Task<HttpResponseMessage> Get(string url, string? claveApi = null)
    {
        var r = Solicitud(HttpMethod.Get, url);
        if (claveApi is not null) r.Headers.TryAddWithoutValidation(NombresHttp.EncabezadoClaveApi, claveApi);
        return await Http.SendAsync(r);
    }

    public async Task<string> TokenCsrf()
    {
        var resp = await Get("/api/v1/auth/antiforgery");
        resp.EnsureSuccessStatusCode();
        return (await resp.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!;
    }

    public async Task<HttpResponseMessage> Post(string url, object? cuerpo, bool conToken = true, string? xffCliente = null,
        string? claveApi = null)
    {
        var token = conToken ? await TokenCsrf() : null;
        var r = Solicitud(HttpMethod.Post, url, xffCliente);
        if (token is not null) r.Headers.TryAddWithoutValidation(NombresHttp.EncabezadoCsrf, token);
        if (claveApi is not null) r.Headers.TryAddWithoutValidation(NombresHttp.EncabezadoClaveApi, claveApi);
        if (cuerpo is not null) r.Content = JsonContent.Create(cuerpo);
        return await Http.SendAsync(r);
    }

    public Task<HttpResponseMessage> Login(string usuario, string clave, bool conToken = true, string? xffCliente = null) =>
        Post("/api/v1/auth/login", new { usuario, clave }, conToken, xffCliente);

    public string? CookieSesion() => Cookies.GetCookies(Base)[NombresHttp.CookieSesion]?.Value;
}
