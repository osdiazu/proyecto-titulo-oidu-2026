// Proyecto APT Cobranza Automatizada - API interna de consulta (Evidencia S11)
// RF-06: consulta del estado financiero del cliente para la fuerza de ventas.
// RF-07: indicadores de cartera para Finanzas y Tesoreria (panel en wwwroot).
using Cobranza.Api.Datos;
using Cobranza.Api.Seguridad;
using Cobranza.Comun;
using Microsoft.AspNetCore.Authentication;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddProblemDetails();
builder.Services.AddSingleton<RepositorioConsultas>();

builder.Services
    .AddAuthentication(EasyAuthHandler.Esquema)
    .AddScheme<AuthenticationSchemeOptions, EasyAuthHandler>(EasyAuthHandler.Esquema, null);

builder.Services.AddAuthorizationBuilder()
    .AddPolicy(Politicas.ConsultaCliente, p => p.RequireRole(Roles.Ventas, Roles.Finanzas))
    .AddPolicy(Politicas.Cartera, p => p.RequireRole(Roles.Finanzas))
    .AddPolicy(Politicas.Operacion, p => p.RequireRole(Roles.Operacion, Roles.Finanzas))
    // Todo endpoint sin politica explicita exige usuario autenticado.
    .SetFallbackPolicy(new Microsoft.AspNetCore.Authorization.AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser().Build());

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseHsts();
app.UseAuthentication();
app.UseAuthorization();
app.UseDefaultFiles();
app.UseStaticFiles();

// Sondeo de salud (Application Gateway y App Service). Excluido de Easy Auth en la configuracion.
app.MapGet("/salud", async (RepositorioConsultas repo, CancellationToken ct) =>
        await repo.SaludAsync(ct)
            ? Results.Ok(new { estado = "ok" })
            : Results.Problem("Base de datos no disponible", statusCode: StatusCodes.Status503ServiceUnavailable))
   .AllowAnonymous();

var api = app.MapGroup("/api/v1");

api.MapGet("/yo", (HttpContext ctx) => Results.Ok(new
{
    nombre = ctx.User.Identity?.Name,
    roles = ctx.User.Claims.Where(c => c.Type == ((System.Security.Claims.ClaimsIdentity)ctx.User.Identity!).RoleClaimType)
                          .Select(c => c.Value)
}));

api.MapGet("/clientes/{rut}/estado", async (string rut, RepositorioConsultas repo, CancellationToken ct) =>
{
    var normalizado = RutUtil.Normalizar(rut);
    if (normalizado is null)
        return Results.Problem("RUT con formato o digito verificador invalido.", statusCode: StatusCodes.Status400BadRequest);
    var estado = await repo.EstadoClienteAsync(normalizado, ct);
    return estado is null ? Results.NotFound() : Results.Ok(estado);
}).RequireAuthorization(Politicas.ConsultaCliente);

api.MapGet("/clientes/{rut}/pedidos", async (string rut, string? estado, RepositorioConsultas repo, CancellationToken ct) =>
{
    var normalizado = RutUtil.Normalizar(rut);
    if (normalizado is null)
        return Results.Problem("RUT con formato o digito verificador invalido.", statusCode: StatusCodes.Status400BadRequest);
    if (estado is not null && estado is not ("Retenido" or "Liberado" or "Despachado"))
        return Results.Problem("Estado debe ser Retenido, Liberado o Despachado.", statusCode: StatusCodes.Status400BadRequest);
    return Results.Ok(await repo.PedidosClienteAsync(normalizado, estado, ct));
}).RequireAuthorization(Politicas.ConsultaCliente);

api.MapGet("/cartera/indicadores", async (RepositorioConsultas repo, CancellationToken ct) =>
    Results.Ok(await repo.IndicadoresAsync(ct)))
   .RequireAuthorization(Politicas.Cartera);

api.MapGet("/sincronizaciones", async (int? top, RepositorioConsultas repo, CancellationToken ct) =>
    Results.Ok(await repo.SincronizacionesAsync(top ?? 20, ct)))
   .RequireAuthorization(Politicas.Operacion);

app.Run();
