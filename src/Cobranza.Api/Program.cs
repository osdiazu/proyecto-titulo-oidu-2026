// Proyecto APT Cobranza Automatizada - API interna de consulta (Evidencia S11, ADR-001)
// RF-06: consulta del estado financiero del cliente para la fuerza de ventas.
// RF-07: indicadores de cartera para Finanzas y Tesoreria (panel en wwwroot).
// Autenticacion propia (ADR-001): cookie con usuario y contrasena para el panel y clave de API
// (X-Api-Key) para Ventas sistema a sistema. Easy Auth y X-MS-CLIENT-PRINCIPAL no se usan (A-01).
using System.Security.Claims;
using Cobranza.Api.Datos;
using Cobranza.Api.Seguridad;
using Cobranza.Comun;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddProblemDetails();
builder.Services.AddSingleton<IRepositorioConsultas, RepositorioConsultas>();
builder.AgregarSeguridadCobranza();

var app = builder.Build();

// Hash ficticio de ServicioAutenticacion generado al iniciar (ADR 5.3); valida tambien Seguridad__*.
_ = app.Services.GetRequiredService<ServicioAutenticacion>();

// Orden de middlewares (ADR 5.4.1 y 5.6):
// 1. Encabezados reenviados primero (IP correcta para el limitador y para cob.LogAcceso).
// 2. Archivos estaticos antes de la autenticacion (login.html debe ser accesible sin sesion).
// 3. Enrutamiento, limitador de tasa, autenticacion, autorizacion y antifalsificacion.
app.UseForwardedHeaders();
app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseHsts();
app.UseDefaultFiles();
app.UseStaticFiles();
app.UseRouting();
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
app.UseAntiforgery();

// Sondeo de salud (App Service y, si se aprueba D11, Application Gateway).
app.MapGet("/salud", async (IRepositorioConsultas repo, CancellationToken ct) =>
        await repo.SaludAsync(ct)
            ? Results.Ok(new { estado = "ok" })
            : Results.Problem("Base de datos no disponible", statusCode: StatusCodes.Status503ServiceUnavailable))
   .AllowAnonymous();

var api = app.MapGroup("/api/v1");

api.MapearAutenticacion();

// Permitido tambien con debe_cambiar_clave (AUT-06): solo exige usuario autenticado (politica de reserva).
api.MapGet("/yo", (HttpContext ctx) => Results.Ok(new
{
    nombre = ctx.User.Identity?.Name,
    roles = ctx.User.FindAll(ClaimTypes.Role).Select(c => c.Value),
    debeCambiarClave = ctx.User.HasClaim(TiposClaim.DebeCambiarClave, "1"),
    tipoAutenticacion = ctx.User.Identity?.AuthenticationType
}));

api.MapGet("/clientes/{rut}/estado", async (string rut, IRepositorioConsultas repo, CancellationToken ct) =>
{
    var normalizado = RutUtil.Normalizar(rut);
    if (normalizado is null)
        return Results.Problem("RUT con formato o digito verificador invalido.", statusCode: StatusCodes.Status400BadRequest);
    var estado = await repo.EstadoClienteAsync(normalizado, ct);
    return estado is null ? Results.NotFound() : Results.Ok(estado);
}).RequireAuthorization(Politicas.ConsultaCliente);

api.MapGet("/clientes/{rut}/pedidos", async (string rut, string? estado, IRepositorioConsultas repo, CancellationToken ct) =>
{
    var normalizado = RutUtil.Normalizar(rut);
    if (normalizado is null)
        return Results.Problem("RUT con formato o digito verificador invalido.", statusCode: StatusCodes.Status400BadRequest);
    if (estado is not null && estado is not ("Retenido" or "Liberado" or "Despachado"))
        return Results.Problem("Estado debe ser Retenido, Liberado o Despachado.", statusCode: StatusCodes.Status400BadRequest);
    return Results.Ok(await repo.PedidosClienteAsync(normalizado, estado, ct));
}).RequireAuthorization(Politicas.ConsultaCliente);

api.MapGet("/cartera/indicadores", async (IRepositorioConsultas repo, CancellationToken ct) =>
    Results.Ok(await repo.IndicadoresAsync(ct)))
   .RequireAuthorization(Politicas.Cartera);

api.MapGet("/sincronizaciones", async (int? top, IRepositorioConsultas repo, CancellationToken ct) =>
    Results.Ok(await repo.SincronizacionesAsync(top ?? 20, ct)))
   .RequireAuthorization(Politicas.Operacion);

app.Run();

/// <summary>Punto de entrada visible para WebApplicationFactory en tests/Cobranza.Api.Tests.</summary>
public partial class Program;
