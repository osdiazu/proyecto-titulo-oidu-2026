using System.Globalization;
using System.Net;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Cobranza.Api.Datos;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Options;

namespace Cobranza.Api.Seguridad;

/// <summary>
/// Tipo de usuario para PasswordHasher (el hasher V3 no usa sus datos). La herramienta
/// src/Cobranza.Herramientas usa el mismo PasswordHasher con las opciones por defecto (V3).
/// </summary>
public sealed class UsuarioPanel;

public sealed record ResultadoLogin(bool Exito, UsuarioInterno? Usuario, string? Motivo)
{
    public static ResultadoLogin Fallo(string motivo) => new(false, null, motivo);
}

public enum EstadoCambioClave { Correcto, PoliticaInvalida, ClaveActualIncorrecta, SesionInvalida }

public sealed record ResultadoCambioClave(EstadoCambioClave Estado, ClaimsPrincipal? Principal = null, string? Detalle = null);

/// <summary>
/// Logica de autenticacion por usuario y contrasena (ADR-001 5.3, 5.4, 5.5, 5.7).
/// - Toda causa de fallo hace exactamente una verificacion PBKDF2 (contra el hash real o contra un
///   hash ficticio generado al iniciar) y la misma cantidad de llamadas a la base, para que el
///   tiempo de respuesta no delate si el usuario existe.
/// - Nunca envia la contrasena a SQL ni la escribe en logs.
/// </summary>
public sealed partial class ServicioAutenticacion
{
    public const string UsuarioNoValido = "(formato no valido)";
    public const string PropiedadRevalidada = "revalidada_utc";

    private readonly IRepositorioUsuarios _repo;
    private readonly IPasswordHasher<UsuarioPanel> _hasher;
    private readonly OpcionesSeguridad _o;
    private readonly TimeProvider _reloj;
    private readonly ILogger<ServicioAutenticacion> _log;
    private readonly string _hashFicticio;
    private static readonly UsuarioPanel Panel = new();

    public ServicioAutenticacion(IRepositorioUsuarios repo, IPasswordHasher<UsuarioPanel> hasher,
        IOptions<OpcionesSeguridad> opciones, TimeProvider reloj, ILogger<ServicioAutenticacion> log)
    {
        _repo = repo;
        _hasher = hasher;
        _o = opciones.Value;
        _reloj = reloj;
        _log = log;
        // Hash ficticio con una contrasena aleatoria que nadie conoce (ADR 5.3).
        _hashFicticio = _hasher.HashPassword(Panel, Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)));
    }

    [GeneratedRegex("^[a-z0-9._-]{3,50}$", RegexOptions.CultureInvariant)]
    private static partial Regex PatronUsuario();

    /// <summary>Minusculas y sin espacios en los extremos (la API normaliza antes de llamar, ADR 5.1).</summary>
    public static string Normalizar(string? usuario) => (usuario ?? "").Trim().ToLowerInvariant();

    /// <summary>
    /// Texto que se guarda en cob.LogAcceso.UsuarioIngresado: el usuario normalizado si cumple el
    /// patron; en otro caso "(formato no valido)" (SEG-H07, AUT-18).
    /// </summary>
    public static string SanitizarUsuario(string? usuario)
    {
        var n = Normalizar(usuario);
        return PatronUsuario().IsMatch(n) ? n : UsuarioNoValido;
    }

    public async Task<ResultadoLogin> LoginAsync(string usuarioIngresado, string clave, string? ip, string? agente,
        CancellationToken ct)
    {
        var normalizado = Normalizar(usuarioIngresado);
        var registrado = SanitizarUsuario(usuarioIngresado);
        var ahora = _reloj.GetUtcNow().UtcDateTime;

        // Formato invalido: no se consulta la base (no puede existir un usuario asi).
        var u = registrado == UsuarioNoValido ? null : await _repo.ObtenerUsuarioParaLoginAsync(normalizado, ct);

        string? motivo =
            u is null ? MotivosLogin.UsuarioInexistente
            : !u.Activo ? MotivosLogin.UsuarioInactivo
            // Cuenta bloqueada: se envia CuentaBloqueada y nunca ClaveIncorrecta, porque
            // sp_RegistrarLoginFallido extiende el bloqueo si recibe ClaveIncorrecta (D-12 de sql/12).
            : u.BloqueadoHastaUtc is { } b && b > ahora ? MotivosLogin.CuentaBloqueada
            : TemporalVencida(u, ahora) ? MotivosLogin.ClaveTemporalVencida
            : null;

        if (motivo is not null)
        {
            Verificar(_hashFicticio, clave);   // iguala el costo; el resultado se descarta
            await _repo.RegistrarLoginFallidoAsync(u?.UsuarioId, registrado, motivo, ip, agente,
                (short)_o.MaxIntentosFallidos, _o.MinutosBloqueo, ct);
            return ResultadoLogin.Fallo(motivo);
        }

        var verificacion = Verificar(u!.HashClave, clave);
        if (verificacion == PasswordVerificationResult.Failed)
        {
            await _repo.RegistrarLoginFallidoAsync(u.UsuarioId, registrado, MotivosLogin.ClaveIncorrecta, ip, agente,
                (short)_o.MaxIntentosFallidos, _o.MinutosBloqueo, ct);
            return ResultadoLogin.Fallo(MotivosLogin.ClaveIncorrecta);
        }

        var rehash = verificacion == PasswordVerificationResult.SuccessRehashNeeded ? _hasher.HashPassword(Panel, clave) : null;
        try
        {
            await _repo.RegistrarLoginExitosoAsync(u.UsuarioId, ip, agente, rehash, ct);
        }
        catch (UsuarioNoEncontradoException)
        {
            // D-5 de sql/12 (50061): el usuario dejo de existir entre la lectura y el registro.
            // Se responde el 401 generico y se registra como usuario inexistente.
            _log.LogWarning("Login rechazado: el usuario {UsuarioId} dejo de existir durante el inicio de sesion (50061).", u.UsuarioId);
            await _repo.RegistrarLoginFallidoAsync(null, registrado, MotivosLogin.UsuarioInexistente, ip, agente,
                (short)_o.MaxIntentosFallidos, _o.MinutosBloqueo, ct);
            return ResultadoLogin.Fallo(MotivosLogin.UsuarioInexistente);
        }
        return new ResultadoLogin(true, u, null);
    }

    /// <summary>
    /// Contrasena temporal vencida: DebeCambiarClave = 1 y FechaCambioClave anterior al limite.
    /// Si FechaCambioClave viene en NULL con DebeCambiarClave = 1 se trata como vencida (criterio conservador).
    /// </summary>
    private bool TemporalVencida(UsuarioInterno u, DateTime ahora) =>
        u.DebeCambiarClave
        && (u.FechaCambioClaveUtc is not { } f || f < ahora.AddHours(-_o.HorasVigenciaClaveTemporal));

    private PasswordVerificationResult Verificar(string? hash, string clave)
    {
        try
        {
            return _hasher.VerifyHashedPassword(Panel, hash ?? _hashFicticio, clave);
        }
        catch (FormatException)
        {
            // Hash almacenado con formato invalido: se trata como contrasena incorrecta.
            return PasswordVerificationResult.Failed;
        }
    }

    /// <summary>Principal de la cookie (claims de ADR 5.6).</summary>
    public static ClaimsPrincipal CrearPrincipal(UsuarioInterno u, DateTimeOffset emitida)
    {
        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, u.UsuarioId.ToString(CultureInfo.InvariantCulture)),
            new(ClaimTypes.Name, u.Usuario),
            new(TiposClaim.Nombre, u.Nombre),
            new(ClaimTypes.Role, u.Rol),
            new(TiposClaim.Sello, u.SelloSeguridad.ToString("D")),
            new(TiposClaim.EmitidaUtc, emitida.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture)),
        };
        if (u.DebeCambiarClave) claims.Add(new Claim(TiposClaim.DebeCambiarClave, "1"));
        return new ClaimsPrincipal(new ClaimsIdentity(claims, Esquemas.Cookies, ClaimTypes.Name, ClaimTypes.Role));
    }

    public AuthenticationProperties PropiedadesNuevas()
    {
        var p = new AuthenticationProperties { IsPersistent = false, AllowRefresh = true };
        p.Items[PropiedadRevalidada] = _reloj.GetUtcNow().ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        return p;
    }

    public DateTimeOffset Ahora() => _reloj.GetUtcNow();

    /// <summary>
    /// OnValidatePrincipal (ADR 5.5): duracion absoluta y revalidacion periodica contra
    /// sp_ObtenerUsuarioPorId. Rechaza si el usuario no existe, esta inactivo o bloqueado, o si
    /// cambiaron SelloSeguridad, Rol o DebeCambiarClave. Ante error de base se rechaza (falla cerrada).
    /// </summary>
    public async Task ValidarPrincipalAsync(CookieValidatePrincipalContext ctx)
    {
        var principal = ctx.Principal;
        var ahora = _reloj.GetUtcNow();

        if (principal is null || !TryUnix(principal.FindFirstValue(TiposClaim.EmitidaUtc), out var emitida)
            || ahora - emitida > TimeSpan.FromHours(_o.HorasMaximasSesion))
        {
            await RechazarAsync(ctx);
            return;
        }

        if (!ctx.Properties.Items.TryGetValue(PropiedadRevalidada, out var r) || !TryUnix(r, out var revalidada))
            revalidada = emitida;

        if (ahora - revalidada < TimeSpan.FromMinutes(_o.MinutosRevalidacionSesion))
            return;

        if (!int.TryParse(principal.FindFirstValue(ClaimTypes.NameIdentifier), NumberStyles.None, CultureInfo.InvariantCulture, out var id))
        {
            await RechazarAsync(ctx);
            return;
        }

        UsuarioInterno? u;
        try
        {
            u = await _repo.ObtenerUsuarioPorIdAsync(id, incluirHash: false, ctx.HttpContext.RequestAborted);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _log.LogWarning(ex, "No se pudo revalidar la sesion del usuario {UsuarioId}; se rechaza la cookie.", id);
            await RechazarAsync(ctx);
            return;
        }

        var vigente = u is not null
            && u.Activo
            && !(u.BloqueadoHastaUtc is { } b && b > ahora.UtcDateTime)
            && string.Equals(u.SelloSeguridad.ToString("D"), principal.FindFirstValue(TiposClaim.Sello), StringComparison.OrdinalIgnoreCase)
            && string.Equals(u.Rol, principal.FindFirstValue(ClaimTypes.Role), StringComparison.Ordinal)
            && u.DebeCambiarClave == principal.HasClaim(TiposClaim.DebeCambiarClave, "1");

        if (!vigente)
        {
            await RechazarAsync(ctx);
            return;
        }

        ctx.Properties.Items[PropiedadRevalidada] = ahora.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        ctx.ShouldRenew = true;
    }

    private static async Task RechazarAsync(CookieValidatePrincipalContext ctx)
    {
        ctx.RejectPrincipal();
        await ctx.HttpContext.SignOutAsync(Esquemas.Cookies);
    }

    private static bool TryUnix(string? s, out DateTimeOffset valor)
    {
        valor = default;
        if (!long.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out var seg)) return false;
        valor = DateTimeOffset.FromUnixTimeSeconds(seg);
        return true;
    }

    /// <summary>Reglas de contrasena (ADR 5.4): longitud, distinta del usuario y de la actual. Null si cumple.</summary>
    public string? ValidarPolitica(string usuario, string claveActual, string claveNueva)
    {
        if (claveNueva.Length < _o.LongitudMinimaClave || claveNueva.Length > _o.LongitudMaximaClave)
            return $"La contrasena nueva debe tener entre {_o.LongitudMinimaClave} y {_o.LongitudMaximaClave} caracteres.";
        if (string.Equals(claveNueva, usuario, StringComparison.OrdinalIgnoreCase))
            return "La contrasena nueva no puede ser igual al nombre de usuario.";
        if (string.Equals(claveNueva, claveActual, StringComparison.Ordinal))
            return "La contrasena nueva debe ser distinta de la actual.";
        return null;
    }

    /// <summary>
    /// Cambio de contrasena (ADR 5.8). La contrasena actual incorrecta cuenta como intento fallido.
    /// Devuelve el principal reemitido con el sello nuevo y sin debe_cambiar_clave.
    /// </summary>
    public async Task<ResultadoCambioClave> CambiarClaveAsync(ClaimsPrincipal sesion, string claveActual, string claveNueva,
        string? ip, string? agente, CancellationToken ct)
    {
        if (!int.TryParse(sesion.FindFirstValue(ClaimTypes.NameIdentifier), NumberStyles.None, CultureInfo.InvariantCulture, out var id)
            || !Guid.TryParse(sesion.FindFirstValue(TiposClaim.Sello), out var selloCookie)
            || !TryUnix(sesion.FindFirstValue(TiposClaim.EmitidaUtc), out var emitida))
            return new ResultadoCambioClave(EstadoCambioClave.SesionInvalida);

        var u = await _repo.ObtenerUsuarioPorIdAsync(id, incluirHash: true, ct);
        var ahora = _reloj.GetUtcNow().UtcDateTime;
        if (u is null || !u.Activo || u.SelloSeguridad != selloCookie || u.BloqueadoHastaUtc is { } b && b > ahora)
            return new ResultadoCambioClave(EstadoCambioClave.SesionInvalida);

        var politica = ValidarPolitica(u.Usuario, claveActual, claveNueva);
        if (politica is not null)
            return new ResultadoCambioClave(EstadoCambioClave.PoliticaInvalida, Detalle: politica);

        if (Verificar(u.HashClave, claveActual) == PasswordVerificationResult.Failed)
        {
            await _repo.RegistrarLoginFallidoAsync(u.UsuarioId, u.Usuario, MotivosLogin.ClaveIncorrecta, ip, agente,
                (short)_o.MaxIntentosFallidos, _o.MinutosBloqueo, ct);
            return new ResultadoCambioClave(EstadoCambioClave.ClaveActualIncorrecta);
        }

        try
        {
            await _repo.CambiarClaveAsync(u.UsuarioId, selloCookie, _hasher.HashPassword(Panel, claveNueva), ip, agente, ct);
        }
        catch (CambioClaveRechazadoException)
        {
            return new ResultadoCambioClave(EstadoCambioClave.SesionInvalida);
        }

        var actualizado = await _repo.ObtenerUsuarioPorIdAsync(id, incluirHash: false, ct);
        if (actualizado is null || !actualizado.Activo)
            return new ResultadoCambioClave(EstadoCambioClave.SesionInvalida);

        // Se conserva emitida_utc: el cambio de contrasena no extiende la duracion absoluta de la sesion.
        return new ResultadoCambioClave(EstadoCambioClave.Correcto, CrearPrincipal(actualizado, emitida));
    }
}

/// <summary>Datos de origen de la solicitud para cob.LogAcceso y para el limitador (ADR 5.4.1).</summary>
public static class OrigenSolicitud
{
    /// <summary>
    /// IP del cliente ya resuelta por UseForwardedHeaders (sin puerto: RemoteIpAddress es una
    /// IPAddress). Las IPv4 mapeadas a IPv6 se devuelven como IPv4. Maximo 45 caracteres.
    /// </summary>
    public static string? Ip(HttpContext ctx)
    {
        var ip = ctx.Connection.RemoteIpAddress;
        if (ip is null) return null;
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        var texto = ip.ToString();
        return texto.Length <= 45 ? texto : texto[..45];
    }

    public static string ParticionLimitador(HttpContext ctx) => Ip(ctx) ?? IPAddress.None.ToString();

    public static string? Agente(HttpContext ctx)
    {
        var a = ctx.Request.Headers.UserAgent.ToString();
        if (string.IsNullOrEmpty(a)) return null;
        return a.Length <= 200 ? a : a[..200];
    }
}
