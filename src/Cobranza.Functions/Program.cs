// Proyecto APT Cobranza Automatizada - Function App de jobs (Evidencia S10)
using Azure.Communication.Email;
using Cobranza.Functions.Modelos;
using Cobranza.Functions.Servicios;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

var builder = FunctionsApplication.CreateBuilder(args);

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

// Configuracion: ajustes de aplicacion con prefijo Cobranza__ (validados al iniciar).
builder.Services
    .AddOptions<OpcionesCobranza>()
    .Bind(builder.Configuration.GetSection(OpcionesCobranza.Seccion))
    .ValidateDataAnnotations()
    .Validate(o => o.DiasMora2 > o.DiasMora1, "DiasMora2 debe ser mayor que DiasMora1.")
    .ValidateOnStart();

builder.Services.AddSingleton<RepositorioCobranza>();
builder.Services.AddSingleton<IRepositorioNotificaciones>(sp => sp.GetRequiredService<RepositorioCobranza>());
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<IOrigenRegularizados, OrigenRegularizadosSql>();
builder.Services.AddSingleton<PlantillaCorreo>();
builder.Services.AddSingleton(sp =>
{
    var o = sp.GetRequiredService<IOptions<OpcionesCobranza>>().Value;
    // El 429 (limite de ACS) no se reintenta dentro de la ejecucion: lo trata el job (M-05).
    return new EmailClient(o.AcsConnectionString,
        new EmailClientOptions { RetryPolicy = new PoliticaReintentoSinLimite() });
});

builder.Build().Run();
