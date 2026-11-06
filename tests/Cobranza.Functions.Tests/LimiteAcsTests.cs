using System.ComponentModel.DataAnnotations;
using System.Net;
using Azure;
using Azure.Core;
using Azure.Core.Pipeline;
using Cobranza.Functions.Modelos;
using Cobranza.Functions.Servicios;

namespace Cobranza.Functions.Tests;

public class LimiteAcsTests
{
    private static readonly DateTimeOffset Ahora = new(2026, 11, 5, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Status429_EsLimite() => Assert.True(LimiteAcs.EsRechazoPorLimite(Datos.Error429()));

    [Theory]
    [InlineData(400)]
    [InlineData(500)]
    [InlineData(503)]
    public void OtrosStatus_NoSonLimite(int status) =>
        Assert.False(LimiteAcs.EsRechazoPorLimite(Datos.Error(status)));

    [Fact]
    public void RetryAfter_EnSegundos() =>
        Assert.Equal(TimeSpan.FromSeconds(60), LimiteAcs.ObtenerRetryAfter(Datos.Error429(("Retry-After", "60")), Ahora));

    [Fact]
    public void RetryAfter_EnMilisegundos_TienePrioridad() =>
        Assert.Equal(TimeSpan.FromMilliseconds(1500),
            LimiteAcs.ObtenerRetryAfter(Datos.Error429(("retry-after-ms", "1500"), ("Retry-After", "60")), Ahora));

    [Fact]
    public void RetryAfter_ComoFechaHttp() =>
        Assert.Equal(TimeSpan.FromMinutes(5),
            LimiteAcs.ObtenerRetryAfter(Datos.Error429(("Retry-After", "Thu, 05 Nov 2026 12:05:00 GMT")), Ahora));

    [Fact]
    public void RetryAfter_Ausente_EsNull()
    {
        Assert.Null(LimiteAcs.ObtenerRetryAfter(Datos.Error429(), Ahora));
        Assert.Null(LimiteAcs.ObtenerRetryAfter(new RequestFailedException(429, "sin respuesta"), Ahora));
    }

    // Politica de reintentos del EmailClient, probada sobre un pipeline real de Azure.Core
    // con un HttpMessageHandler local (sin red).

    private sealed class ManejadorFijo(HttpStatusCode codigo) : HttpMessageHandler
    {
        public int Llamadas;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Interlocked.Increment(ref Llamadas);
            return Task.FromResult(new HttpResponseMessage(codigo));
        }
    }

    private sealed class OpcionesPrueba : ClientOptions { }

    private static async Task<int> LlamadasConPolitica(HttpStatusCode codigo)
    {
        var manejador = new ManejadorFijo(codigo);
        var opciones = new OpcionesPrueba
        {
            Transport = new HttpClientTransport(new HttpClient(manejador)),
            RetryPolicy = new PoliticaReintentoSinLimite(3, DelayStrategy.CreateFixedDelayStrategy(TimeSpan.Zero))
        };
        var pipeline = HttpPipelineBuilder.Build(opciones);
        var msg = pipeline.CreateMessage();
        msg.Request.Method = RequestMethod.Post;
        msg.Request.Uri.Reset(new Uri("https://localhost.invalid/emails:send"));
        await pipeline.SendAsync(msg, CancellationToken.None);
        return manejador.Llamadas;
    }

    [Fact]
    public async Task Politica_NoReintenta429() =>
        Assert.Equal(1, await LlamadasConPolitica((HttpStatusCode)429));

    [Fact]
    public async Task Politica_ConservaReintentosDe503() =>
        Assert.Equal(4, await LlamadasConPolitica(HttpStatusCode.ServiceUnavailable));

    // Sin valores por defecto: si falta el ajuste Cobranza__*, la validacion falla.

    [Theory]
    [InlineData(0, 15000, nameof(OpcionesCobranza.MaxCorreosPorEjecucion))]
    [InlineData(10, 0, nameof(OpcionesCobranza.PausaEntreCorreosMs))]
    public void Opciones_SinLoteOPausa_NoValidan(int max, int pausa, string propiedad)
    {
        var o = Datos.Opciones(max, pausa);
        var errores = new List<ValidationResult>();
        Assert.False(Validator.TryValidateObject(o, new ValidationContext(o), errores, validateAllProperties: true));
        Assert.Contains(errores, e => e.MemberNames.Contains(propiedad));
    }

    [Fact]
    public void Opciones_ValoresDemoD12_Validan()
    {
        var o = Datos.Opciones(10, 15000);
        Assert.True(Validator.TryValidateObject(o, new ValidationContext(o), new List<ValidationResult>(), true));
    }
}
