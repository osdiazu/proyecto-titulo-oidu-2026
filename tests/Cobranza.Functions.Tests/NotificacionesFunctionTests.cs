using Azure;
using Cobranza.Functions.Funciones;
using Cobranza.Functions.Servicios;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobranza.Functions.Tests;

/// <summary>
/// M-05 y ADR-001 5.12: un rechazo por limite de ACS (429) se registra como Limitado (no suma Intentos
/// en sp_RegistrarNotificacion) y corta el lote; los demas errores siguen registrandose como Fallido.
/// </summary>
public class NotificacionesFunctionTests
{
    private static (NotificacionesFunction Fn, RepositorioFalso Repo, EmailClientFalso Email,
        LoggerCapturador<NotificacionesFunction> Log, RelojInmediato Reloj)
        Crear(int avisos, Func<int, Exception?> respuesta, int max = 10, int pausaMs = 15000)
    {
        var opciones = Options.Create(Datos.Opciones(max, pausaMs));
        var repo = new RepositorioFalso(Datos.Avisos(avisos));
        var email = new EmailClientFalso((n, _) => respuesta(n));
        var log = new LoggerCapturador<NotificacionesFunction>();
        var reloj = new RelojInmediato();
        var fn = new NotificacionesFunction(repo, email, new PlantillaCorreo(opciones), opciones, log, reloj);
        return (fn, repo, email, log, reloj);
    }

    [Fact]
    public async Task Rechazo429_RegistraLimitado_YCortaElLote()
    {
        var (fn, repo, email, _, _) = Crear(5, n => n == 3 ? Datos.Error429() : null);

        var r = await fn.ProcesarAsync(CancellationToken.None);

        Assert.Equal(3, email.Enviados.Count);                        // no intenta los avisos 4 y 5
        Assert.Equal(3, repo.Registros.Count);                        // 2 aceptados y 1 limitado
        Assert.Equal(2, repo.Registros.Count(x => x.Estado == "Aceptado"));
        var limitado = Assert.Single(repo.Registros, x => x.Estado == "Limitado");
        Assert.Equal(3, limitado.FacturaId);
        Assert.Null(limitado.IdOperacion);
        Assert.StartsWith("HTTP 429 TooManyRequests", limitado.Detalle);
        Assert.DoesNotContain(repo.Registros, x => x.Estado == "Fallido");
        Assert.DoesNotContain(repo.Registros, x => x.FacturaId > 3);
        Assert.True(r.CortadoPorLimite);
        Assert.Equal(2, r.Aceptados);
        Assert.Equal(0, r.Fallidos);
        Assert.Equal(3, r.Diferidos);                                 // 3, 4 y 5 quedan para la siguiente ejecucion
    }

    [Fact]
    public async Task Rechazo429_EnPrimerEnvio_SoloRegistraLimitado()
    {
        var (fn, repo, email, _, reloj) = Crear(4, _ => Datos.Error429());

        var r = await fn.ProcesarAsync(CancellationToken.None);

        Assert.Single(email.Enviados);
        var reg = Assert.Single(repo.Registros);
        Assert.Equal((1, "Limitado"), (reg.FacturaId, reg.Estado));
        Assert.Empty(reloj.Esperas);
        Assert.Equal(4, r.Diferidos);
    }

    [Fact]
    public async Task CodigoTooManyRequests_SinStatus429_SeTrataComoLimite()
    {
        var (fn, repo, email, _, _) = Crear(3,
            n => n == 1 ? new RequestFailedException(0, "limite", "TooManyRequests", null) : null);

        var r = await fn.ProcesarAsync(CancellationToken.None);

        Assert.Single(email.Enviados);
        Assert.Equal("Limitado", Assert.Single(repo.Registros).Estado);
        Assert.True(r.CortadoPorLimite);
    }

    [Fact]
    public async Task Rechazo429_SeRegistraEnLogConEventoYRetryAfter()
    {
        var (fn, _, _, log, _) = Crear(2, n => n == 1 ? Datos.Error429(("Retry-After", "120")) : null);

        var r = await fn.ProcesarAsync(CancellationToken.None);

        Assert.Equal(TimeSpan.FromSeconds(120), r.RetryAfter);
        var e = Assert.Single(log.Entradas, x => x.Evento.Id == NotificacionesFunction.EventoLimiteAcs.Id);
        Assert.Equal(LogLevel.Warning, e.Nivel);
        Assert.Contains("120", e.Mensaje);
    }

    [Fact]
    public async Task Rechazo429_RegistroLimitadoFalla_IgualCortaElLote()
    {
        var (fn, repo, email, log, _) = Crear(3, n => n == 1 ? Datos.Error429() : null);
        repo.FallarAlRegistrar = "Limitado";

        var r = await fn.ProcesarAsync(CancellationToken.None);

        Assert.Single(email.Enviados);
        Assert.Empty(repo.Registros);
        Assert.True(r.CortadoPorLimite);
        Assert.Equal(3, r.Diferidos);
        Assert.Contains(log.Entradas, x => x.Evento.Id == NotificacionesFunction.EventoRegistroLimitadoFallido.Id && x.Nivel == LogLevel.Error);
    }

    [Fact]
    public async Task Rechazo429_ConRetryAfter_LoIncluyeEnElDetalle()
    {
        var (fn, repo, _, _, _) = Crear(1, _ => Datos.Error429(("Retry-After", "120")));

        await fn.ProcesarAsync(CancellationToken.None);

        Assert.EndsWith("Retry-After 120 s", Assert.Single(repo.Registros).Detalle);
    }

    [Theory]
    [InlineData(500, "InternalServerError")]
    [InlineData(400, "BadRequest")]
    [InlineData(503, "ServiceUnavailable")]
    public async Task OtrosErrores_RegistranFallido_YContinuan(int status, string codigo)
    {
        var (fn, repo, email, _, _) = Crear(3, n => n == 2 ? Datos.Error(status, codigo) : null);

        var r = await fn.ProcesarAsync(CancellationToken.None);

        Assert.Equal(3, email.Enviados.Count);                        // no corta el lote
        Assert.Equal(3, repo.Registros.Count);
        var fallido = Assert.Single(repo.Registros, x => x.Estado == "Fallido");
        Assert.Equal(2, fallido.FacturaId);
        Assert.Null(fallido.IdOperacion);
        Assert.StartsWith($"HTTP {status} {codigo}", fallido.Detalle);
        Assert.False(r.CortadoPorLimite);
        Assert.Equal(1, r.Fallidos);
        Assert.Equal(2, r.Aceptados);
        Assert.Equal(0, r.Diferidos);
    }

    [Fact]
    public async Task TodosLosEnviosFallidos_CadaUnoSeRegistraComoFallido()
    {
        var (fn, repo, _, _, _) = Crear(3, _ => Datos.Error(500, "InternalServerError"));

        var r = await fn.ProcesarAsync(CancellationToken.None);

        Assert.Equal(3, repo.Registros.Count(x => x.Estado == "Fallido"));
        Assert.Equal(3, r.Fallidos);
    }

    [Fact]
    public async Task Aceptado_RegistraIdOperacion()
    {
        var (fn, repo, _, _, _) = Crear(1, _ => null);

        await fn.ProcesarAsync(CancellationToken.None);

        var reg = Assert.Single(repo.Registros);
        Assert.Equal(("Aceptado", "op-1"), (reg.Estado, reg.IdOperacion));
    }

    [Fact]
    public async Task UsaMaximoYPausaDeConfiguracion()
    {
        var (fn, repo, email, _, reloj) = Crear(25, _ => null, max: 10, pausaMs: 15000);

        await fn.ProcesarAsync(CancellationToken.None);

        Assert.Equal(10, repo.MaxFilasSolicitado);
        Assert.Equal(10, email.Enviados.Count);
        Assert.Equal(9, reloj.Esperas.Count);                         // pausa solo entre envios
        Assert.All(reloj.Esperas, t => Assert.Equal(TimeSpan.FromMilliseconds(15000), t));
    }
}
