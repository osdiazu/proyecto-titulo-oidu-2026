using System.Security.Claims;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace Cobranza.Api.Seguridad;

/// <summary>
/// Autenticacion integrada de App Service (Easy Auth) con Microsoft Entra ID.
/// La plataforma valida el inicio de sesion o el token Bearer ANTES de que la solicitud llegue
/// a la aplicacion y entrega la identidad en el encabezado X-MS-CLIENT-PRINCIPAL (Base64/JSON).
/// App Service elimina ese encabezado si viene desde el cliente, por lo que no puede falsificarse
/// mientras la aplicacion solo sea alcanzable a traves de la plataforma.
/// Este manejador convierte el encabezado en un ClaimsPrincipal con los roles de la aplicacion.
/// </summary>
public sealed class EasyAuthHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string Esquema = "EasyAuth";
    private const string Encabezado = "X-MS-CLIENT-PRINCIPAL";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue(Encabezado, out var valor) || string.IsNullOrWhiteSpace(valor))
            return Task.FromResult(AuthenticateResult.NoResult());

        try
        {
            var json = Encoding.UTF8.GetString(Convert.FromBase64String(valor.ToString()));
            var principal = JsonSerializer.Deserialize<PrincipalEasyAuth>(json,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (principal?.Claims is null)
                return Task.FromResult(AuthenticateResult.Fail("Encabezado de identidad sin claims."));

            var tipoNombre = principal.Name_Typ ?? ClaimTypes.Name;
            var tipoRol = principal.Role_Typ ?? ClaimTypes.Role;
            var claims = principal.Claims
                .Where(c => !string.IsNullOrEmpty(c.Typ) && c.Val is not null)
                .Select(c => new Claim(c.Typ == "roles" ? tipoRol : c.Typ!, c.Val!));

            var identidad = new ClaimsIdentity(claims, principal.Auth_Typ ?? Esquema, tipoNombre, tipoRol);
            var ticket = new AuthenticationTicket(new ClaimsPrincipal(identidad), Esquema);
            return Task.FromResult(AuthenticateResult.Success(ticket));
        }
        catch (Exception ex) when (ex is FormatException or JsonException)
        {
            return Task.FromResult(AuthenticateResult.Fail("Encabezado de identidad invalido."));
        }
    }

    private sealed class PrincipalEasyAuth
    {
        public string? Auth_Typ { get; set; }
        public string? Name_Typ { get; set; }
        public string? Role_Typ { get; set; }
        public List<ClaimEasyAuth>? Claims { get; set; }
    }

    private sealed class ClaimEasyAuth
    {
        public string? Typ { get; set; }
        public string? Val { get; set; }
    }
}

/// <summary>Roles de aplicacion definidos en el registro de Entra ID (script s12_registro_entra_id.sh).</summary>
public static class Roles
{
    public const string Ventas = "Ventas.Consulta";
    public const string Finanzas = "Finanzas.Consulta";
    public const string Operacion = "TI.Operacion";
}

public static class Politicas
{
    public const string ConsultaCliente = "ConsultaCliente";   // Ventas o Finanzas
    public const string Cartera = "Cartera";                   // Finanzas
    public const string Operacion = "Operacion";               // TI o Finanzas
}
