using System.Globalization;
using System.Security.Claims;
using Cobranza.Api.Datos;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Mvc;

namespace Cobranza.Api.Seguridad;

public sealed record SolicitudLogin(string? Usuario, string? Clave);
public sealed record SolicitudCambioClave(string? ClaveActual, string? ClaveNueva);

/// <summary>Endpoints de /api/v1/auth (ADR-001 5.8). Nunca registran el cuerpo de la solicitud.</summary>
public static class EndpointsAutenticacion
{
    /// <summary>Respuesta unica para toda causa de login fallido (ADR 5.7).</summary>
    public const string MensajeLoginFallido = "Usuario o contraseña incorrectos";
    public const string MensajeClaveActualIncorrecta = "Contraseña actual incorrecta";

    /// <summary>Limite del cuerpo de las solicitudes de autenticacion.</summary>
    public const long MaxBytesCuerpo = 8 * 1024;

    public static RouteGroupBuilder MapearAutenticacion(this RouteGroupBuilder api)
    {
        // Los endpoints de autenticacion rechazan las solicitudes con clave de API (ADR 5.5).
        var auth = api.MapGroup("/auth").AddEndpointFilter(RechazarClaveApi);

        auth.MapGet("/antiforgery", (HttpContext ctx, IAntiforgery antiforgery) =>
        {
            var tokens = antiforgery.GetAndStoreTokens(ctx);
            ctx.Response.Headers.CacheControl = "no-store";
            return Results.Ok(new { token = tokens.RequestToken });
        }).AllowAnonymous();

        auth.MapPost("/login", async (SolicitudLogin? s, HttpContext ctx, ServicioAutenticacion svc, CancellationToken ct) =>
        {
            if (s is null || string.IsNullOrWhiteSpace(s.Usuario) || string.IsNullOrEmpty(s.Clave))
                return Results.Problem("Debe indicar usuario y contraseña.", statusCode: StatusCodes.Status400BadRequest);

            var r = await svc.LoginAsync(s.Usuario, s.Clave, OrigenSolicitud.Ip(ctx), OrigenSolicitud.Agente(ctx), ct);
            if (!r.Exito)
                return Results.Json(new { mensaje = MensajeLoginFallido }, statusCode: StatusCodes.Status401Unauthorized);

            var u = r.Usuario!;
            await ctx.SignInAsync(Esquemas.Cookies, ServicioAutenticacion.CrearPrincipal(u, svc.Ahora()), svc.PropiedadesNuevas());
            return Results.Ok(new { nombre = u.Nombre, roles = new[] { u.Rol }, debeCambiarClave = u.DebeCambiarClave });
        })
        .AllowAnonymous()
        .RequireRateLimiting(ConfiguracionSeguridad.PoliticaLimiteLogin)
        .AddEndpointFilter<FiltroAntifalsificacion>()
        .WithMetadata(new RequestSizeLimitAttribute(MaxBytesCuerpo));

        auth.MapPost("/logout", async (HttpContext ctx, IRepositorioUsuarios repo, CancellationToken ct) =>
        {
            if (int.TryParse(ctx.User.FindFirstValue(ClaimTypes.NameIdentifier), NumberStyles.None, CultureInfo.InvariantCulture, out var id))
                await repo.RegistrarLogoutAsync(id, OrigenSolicitud.Ip(ctx), OrigenSolicitud.Agente(ctx), ct);
            await ctx.SignOutAsync(Esquemas.Cookies);
            return Results.NoContent();
        })
        .RequireAuthorization(Politicas.SoloSesionPanel)
        .AddEndpointFilter<FiltroAntifalsificacion>()
        .WithMetadata(new RequestSizeLimitAttribute(MaxBytesCuerpo));

        auth.MapPost("/cambiar-clave", async (SolicitudCambioClave? s, HttpContext ctx, ServicioAutenticacion svc, CancellationToken ct) =>
        {
            if (s is null || string.IsNullOrEmpty(s.ClaveActual) || string.IsNullOrEmpty(s.ClaveNueva))
                return Results.Problem("Debe indicar la contraseña actual y la nueva.", statusCode: StatusCodes.Status400BadRequest);

            var r = await svc.CambiarClaveAsync(ctx.User, s.ClaveActual, s.ClaveNueva, OrigenSolicitud.Ip(ctx), OrigenSolicitud.Agente(ctx), ct);
            switch (r.Estado)
            {
                case EstadoCambioClave.Correcto:
                    await ctx.SignInAsync(Esquemas.Cookies, r.Principal!, svc.PropiedadesNuevas());
                    return Results.NoContent();
                case EstadoCambioClave.PoliticaInvalida:
                    return Results.Problem(r.Detalle, statusCode: StatusCodes.Status400BadRequest);
                case EstadoCambioClave.ClaveActualIncorrecta:
                    return Results.Json(new { mensaje = MensajeClaveActualIncorrecta }, statusCode: StatusCodes.Status401Unauthorized);
                default:
                    await ctx.SignOutAsync(Esquemas.Cookies);
                    return Results.Json(new { mensaje = "Sesión no válida. Inicie sesión nuevamente." }, statusCode: StatusCodes.Status401Unauthorized);
            }
        })
        .RequireAuthorization(Politicas.SoloSesionPanel)
        .AddEndpointFilter<FiltroAntifalsificacion>()
        .WithMetadata(new RequestSizeLimitAttribute(MaxBytesCuerpo));

        return auth;
    }

    private static async ValueTask<object?> RechazarClaveApi(EndpointFilterInvocationContext c, EndpointFilterDelegate next) =>
        c.HttpContext.Request.Headers.ContainsKey(NombresHttp.EncabezadoClaveApi)
            ? Results.Problem("Los endpoints de autenticación no admiten clave de API.", statusCode: StatusCodes.Status403Forbidden)
            : await next(c);
}

/// <summary>
/// Validacion antifalsificacion de los POST con cuerpo JSON (ADR 5.5): la validacion automatica
/// de Minimal APIs solo aplica a formularios. Token en el encabezado X-CSRF-TOKEN.
/// </summary>
public sealed class FiltroAntifalsificacion(IAntiforgery antiforgery) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        try
        {
            await antiforgery.ValidateRequestAsync(context.HttpContext);
        }
        catch (AntiforgeryValidationException)
        {
            return Results.Problem("Token antifalsificación ausente o inválido.", statusCode: StatusCodes.Status400BadRequest);
        }
        return await next(context);
    }
}
