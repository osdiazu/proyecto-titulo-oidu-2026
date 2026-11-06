using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Cobranza.Api.Datos;
using Cobranza.Comun;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace Cobranza.Api.Seguridad;

/// <summary>
/// Autenticacion sistema a sistema por clave de API en el encabezado X-Api-Key (ADR-001 5.3 y 5.6).
/// - Formato invalido: 401 sin consultar la base.
/// - Calcula SHA-256 de la clave completa y llama a cob.sp_ValidarClaveApi. No lee Key Vault.
/// - Guarda en memoria las validaciones correctas durante Seguridad__SegundosCacheClaveApi.
/// - Nunca registra la clave ni su hash; solo el prefijo.
/// </summary>
public sealed class ClaveApiHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    IRepositorioUsuarios repo,
    CacheClavesApi cache)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue(NombresHttp.EncabezadoClaveApi, out var valores))
            return AuthenticateResult.NoResult();

        if (valores.Count != 1 || !ClaveApiFormato.TryObtenerPrefijo(valores[0], out var prefijo))
        {
            Logger.LogWarning("Clave de API rechazada: formato invalido.");
            return AuthenticateResult.Fail("Clave de API invalida.");
        }

        var hash = ClaveApiFormato.Hash(valores[0]!);
        var resultado = cache.Obtener(hash);
        if (resultado is null)
        {
            resultado = await repo.ValidarClaveApiAsync(prefijo, hash, Context.RequestAborted);
            if (resultado is null)
            {
                Logger.LogWarning("Clave de API rechazada (prefijo {PrefijoClave}).", prefijo);
                return AuthenticateResult.Fail("Clave de API invalida.");
            }
            cache.Guardar(hash, resultado);
        }

        // Dimension personalizada en Application Insights (solo el prefijo, ADR 5.1).
        var telemetria = Context.Features.Get<RequestTelemetry>();
        if (telemetria is not null) telemetria.Properties[TiposClaim.PrefijoClave] = prefijo;

        var identidad = new ClaimsIdentity(
        [
            new Claim(ClaimTypes.NameIdentifier, "clave:" + resultado.ClaveApiId.ToString(CultureInfo.InvariantCulture)),
            new Claim(ClaimTypes.Name, "api:" + resultado.Consumidor),
            new Claim(ClaimTypes.Role, resultado.Rol),
            new Claim(TiposClaim.PrefijoClave, prefijo),
        ], Esquemas.ClaveApi, ClaimTypes.Name, ClaimTypes.Role);

        return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identidad), Esquemas.ClaveApi));
    }
}

/// <summary>
/// Cache en memoria de validaciones correctas (clave: SHA-256 de la clave). Una revocacion tarda
/// como maximo Seguridad__SegundosCacheClaveApi en aplicarse (ADR 5.3). Acotada en tamano.
/// </summary>
public sealed class CacheClavesApi(IOptions<OpcionesSeguridad> opciones, TimeProvider reloj)
{
    private const int MaxEntradas = 1000;
    private readonly ConcurrentDictionary<string, (ClaveApiValida Valor, DateTimeOffset Expira)> _entradas = new(StringComparer.Ordinal);
    private readonly TimeSpan _duracion = TimeSpan.FromSeconds(opciones.Value.SegundosCacheClaveApi);

    public ClaveApiValida? Obtener(byte[] hash)
    {
        var k = Convert.ToHexString(hash);
        if (!_entradas.TryGetValue(k, out var e)) return null;
        if (e.Expira > reloj.GetUtcNow()) return e.Valor;
        _entradas.TryRemove(k, out _);
        return null;
    }

    public void Guardar(byte[] hash, ClaveApiValida valor)
    {
        if (_entradas.Count >= MaxEntradas) _entradas.Clear();
        _entradas[Convert.ToHexString(hash)] = (valor, reloj.GetUtcNow() + _duracion);
    }
}
