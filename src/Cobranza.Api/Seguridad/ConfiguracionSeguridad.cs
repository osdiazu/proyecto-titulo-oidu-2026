using System.Threading.RateLimiting;
using Azure.Core;
using Azure.Identity;
using Cobranza.Api.Datos;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;

namespace Cobranza.Api.Seguridad;

/// <summary>Registro de servicios de la autenticacion propia (ADR-001 secciones 5.3 a 5.7).</summary>
public static class ConfiguracionSeguridad
{
    public const string PoliticaLimiteLogin = "login-por-ip";

    /// <summary>Clave de configuracion que habilita el middleware de encabezados reenviados de la plataforma.</summary>
    public const string ClaveForwardedHeadersPlataforma = "ForwardedHeaders_Enabled";

    public static WebApplicationBuilder AgregarSeguridadCobranza(this WebApplicationBuilder builder)
    {
        var services = builder.Services;
        var config = builder.Configuration;
        var entorno = builder.Environment;

        // --- Opciones Seguridad__* (sin valores por defecto en codigo; ValidateOnStart) ---
        services.AddOptions<OpcionesSeguridad>()
            .Bind(config.GetSection(OpcionesSeguridad.Seccion))
            .ValidateDataAnnotations()
            .Validate(OpcionesSeguridad.Coherentes,
                "Seguridad: LongitudMinimaClave <= LongitudMaximaClave, MinutosRevalidacionSesion <= MinutosInactividadSesion " +
                "y MinutosInactividadSesion <= HorasMaximasSesion * 60.")
            .ValidateOnStart();

        services.TryAddSingleton(TimeProvider.System);
        services.AddSingleton<IPasswordHasher<UsuarioPanel>, PasswordHasher<UsuarioPanel>>();   // V3 por defecto
        services.AddSingleton<IRepositorioUsuarios, RepositorioUsuarios>();
        services.AddSingleton<ServicioAutenticacion>();
        services.AddSingleton<CacheClavesApi>();
        services.AddSingleton<ITelemetryInitializer, TelemetriaSinDatosSensibles>();

        // --- Encabezados reenviados (ADR 5.4.1): una sola configuracion, en codigo ---
        if (string.Equals(config[ClaveForwardedHeadersPlataforma], "true", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                "ASPNETCORE_FORWARDEDHEADERS_ENABLED=true agrega una segunda instancia del middleware de encabezados " +
                "reenviados y modifica ForwardedHeadersOptions (ADR-001 5.4.1, regla 1). Debe valer false; la API no arranca.");

        services.AddOptions<ForwardedHeadersOptions>().Configure<IOptions<OpcionesSeguridad>>((o, s) =>
        {
            o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;   // sin X-Forwarded-Host
            o.ForwardLimit = s.Value.SaltosProxyConfiables;
            // Las direcciones del front-end de App Service no estan documentadas como fijas: la confianza
            // se acota con ForwardLimit (regla 4).
            o.KnownProxies.Clear();
            o.KnownIPNetworks.Clear();
        });

        // --- Data Protection (ADR 5.5): Blob + Key Vault; fuera de Development es obligatorio ---
        AgregarDataProtection(services, config, entorno);

        // --- Esquemas de autenticacion (ADR 5.6) ---
        services.AddAuthentication(Esquemas.Selector)
            .AddPolicyScheme(Esquemas.Selector, Esquemas.Selector, o =>
                o.ForwardDefaultSelector = ctx =>
                    ctx.Request.Headers.ContainsKey(NombresHttp.EncabezadoClaveApi) ? Esquemas.ClaveApi : Esquemas.Cookies)
            .AddCookie(Esquemas.Cookies)
            .AddScheme<AuthenticationSchemeOptions, ClaveApiHandler>(Esquemas.ClaveApi, null);

        services.AddOptions<CookieAuthenticationOptions>(Esquemas.Cookies).Configure<IOptions<OpcionesSeguridad>>((o, s) =>
        {
            o.Cookie.Name = NombresHttp.CookieSesion;        // __Host-: Secure, Path=/ y sin Domain
            o.Cookie.Path = "/";
            o.Cookie.Domain = null;
            o.Cookie.HttpOnly = true;
            o.Cookie.SecurePolicy = CookieSecurePolicy.Always;
            o.Cookie.SameSite = SameSiteMode.Strict;
            o.Cookie.IsEssential = true;
            o.ExpireTimeSpan = TimeSpan.FromMinutes(s.Value.MinutosInactividadSesion);
            o.SlidingExpiration = true;
            o.Events.OnValidatePrincipal = ctx =>
                ctx.HttpContext.RequestServices.GetRequiredService<ServicioAutenticacion>().ValidarPrincipalAsync(ctx);
            o.Events.OnRedirectToLogin = ctx => { ctx.Response.StatusCode = StatusCodes.Status401Unauthorized; return Task.CompletedTask; };
            o.Events.OnRedirectToAccessDenied = ctx => { ctx.Response.StatusCode = StatusCodes.Status403Forbidden; return Task.CompletedTask; };
            o.Events.OnRedirectToLogout = ctx => { ctx.Response.StatusCode = StatusCodes.Status204NoContent; return Task.CompletedTask; };
            o.Events.OnRedirectToReturnUrl = ctx => Task.CompletedTask;
        });

        // --- Antifalsificacion (ADR 5.5) ---
        services.AddAntiforgery(o =>
        {
            o.HeaderName = NombresHttp.EncabezadoCsrf;
            o.Cookie.Name = NombresHttp.CookieAntifalsificacion;
            o.Cookie.Path = "/";
            o.Cookie.HttpOnly = true;
            o.Cookie.SecurePolicy = CookieSecurePolicy.Always;
            o.Cookie.SameSite = SameSiteMode.Strict;
        });

        // --- Autorizacion: mismos permisos que antes (ADR 5.6) ---
        static bool SinCambioPendiente(AuthorizationHandlerContext c) => !c.User.HasClaim(TiposClaim.DebeCambiarClave, "1");

        services.AddAuthorizationBuilder()
            .AddPolicy(Politicas.ConsultaCliente, p => p.RequireRole(Roles.Ventas, Roles.Finanzas).RequireAssertion(SinCambioPendiente))
            .AddPolicy(Politicas.Cartera, p => p.RequireRole(Roles.Finanzas).RequireAssertion(SinCambioPendiente))
            .AddPolicy(Politicas.Operacion, p => p.RequireRole(Roles.Admin, Roles.Finanzas).RequireAssertion(SinCambioPendiente))
            .AddPolicy(Politicas.SoloSesionPanel, p => p.RequireAuthenticatedUser()
                .RequireAssertion(c => c.User.Identity is { IsAuthenticated: true, AuthenticationType: Esquemas.Cookies }))
            // Todo endpoint sin politica explicita exige usuario autenticado.
            .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build());

        // --- Limitador de intentos de login por IP (ADR 5.4), ventana fija de 1 minuto, en memoria ---
        services.AddRateLimiter(o =>
        {
            o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
            o.AddPolicy(PoliticaLimiteLogin, ctx =>
            {
                var s = ctx.RequestServices.GetRequiredService<IOptions<OpcionesSeguridad>>().Value;
                return RateLimitPartition.GetFixedWindowLimiter(OrigenSolicitud.ParticionLimitador(ctx), _ =>
                    new FixedWindowRateLimiterOptions
                    {
                        PermitLimit = s.LoginPorIpPorMinuto,
                        Window = TimeSpan.FromMinutes(1),
                        QueueLimit = 0,
                        AutoReplenishment = true,
                    });
            });
            // Solo Application Insights (429), sin escritura en SQL (ADR 5.7).
            o.OnRejected = (ctx, _) =>
            {
                ctx.HttpContext.RequestServices.GetRequiredService<ILoggerFactory>()
                    .CreateLogger("Cobranza.Api.LimiteLogin")
                    .LogWarning("Login rechazado por el limitador de tasa (429).");
                return ValueTask.CompletedTask;
            };
        });

        return builder;
    }

    private static void AgregarDataProtection(IServiceCollection services, IConfiguration config, IWebHostEnvironment entorno)
    {
        var dp = services.AddDataProtection().SetApplicationName(OpcionesDataProtection.NombreAplicacion);
        var opciones = config.GetSection(OpcionesDataProtection.Seccion).Get<OpcionesDataProtection>() ?? new OpcionesDataProtection();

        if (opciones.Validas() is { } uris)
        {
            // Identidad administrada asignada por el sistema en Azure; en Development, la sesion local (az login).
            TokenCredential credencial = entorno.IsDevelopment()
                ? new DefaultAzureCredential()
                : new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);
            dp.PersistKeysToAzureBlobStorage(uris.Blob, credencial)
              .ProtectKeysWithAzureKeyVault(uris.Clave, credencial);
            return;
        }

        if (!entorno.IsDevelopment())
            throw new InvalidOperationException(
                "Faltan o no son URI HTTPS validas los ajustes DataProtection__BlobUri y DataProtection__KeyIdentifier " +
                "(ADR-001 5.5). La API no arranca fuera de Development sin Data Protection en Blob y Key Vault.");
        // Development: almacenamiento local por defecto de ASP.NET Core (solo para pruebas locales).
    }
}
