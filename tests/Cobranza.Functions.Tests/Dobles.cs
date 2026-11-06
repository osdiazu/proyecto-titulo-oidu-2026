using System.Diagnostics.CodeAnalysis;
using Azure;
using Azure.Communication.Email;
using Azure.Core;
using Cobranza.Functions.Modelos;
using Cobranza.Functions.Servicios;

namespace Cobranza.Functions.Tests;

/// <summary>Repositorio en memoria: registra cada llamada a sp_RegistrarNotificacion.</summary>
internal sealed class RepositorioFalso(IReadOnlyList<AvisoPendiente> avisos) : IRepositorioNotificaciones
{
    public List<(int FacturaId, string TipoAviso, string Estado, string? IdOperacion, string? Detalle)> Registros { get; } = [];
    public int? MaxFilasSolicitado { get; private set; }

    public Task<IReadOnlyList<AvisoPendiente>> ObtenerAvisosPendientesAsync(int maxFilas, CancellationToken ct)
    {
        MaxFilasSolicitado = maxFilas;
        return Task.FromResult<IReadOnlyList<AvisoPendiente>>(avisos.Take(maxFilas).ToList());
    }

    public Task RegistrarNotificacionAsync(AvisoPendiente a, string estado, string? idOperacion, string? detalle, CancellationToken ct)
    {
        Registros.Add((a.FacturaId, a.TipoAviso, estado, idOperacion, detalle));
        return Task.CompletedTask;
    }
}

/// <summary>EmailClient falso: por cada envio aplica la respuesta programada para ese numero de envio.</summary>
internal sealed class EmailClientFalso(Func<int, EmailMessage, Exception?> respuesta) : EmailClient
{
    public List<EmailMessage> Enviados { get; } = [];

    public override Task<EmailSendOperation> SendAsync(WaitUntil wait, EmailMessage message, CancellationToken cancellationToken = default)
    {
        Enviados.Add(message);
        var ex = respuesta(Enviados.Count, message);
        if (ex is not null) throw ex;
        return Task.FromResult<EmailSendOperation>(new OperacionFalsa($"op-{Enviados.Count}"));
    }
}

internal sealed class OperacionFalsa(string id) : EmailSendOperation
{
    public override string Id => id;
}

/// <summary>Respuesta HTTP minima para construir RequestFailedException con encabezados.</summary>
internal sealed class RespuestaFalsa(int status, params (string Nombre, string Valor)[] encabezados) : Response
{
    public override int Status => status;
    public override string ReasonPhrase => "";
    public override Stream? ContentStream { get; set; }
    public override string ClientRequestId { get; set; } = "";
    public override void Dispose() { }

    protected override bool ContainsHeader(string name) => TryGetHeader(name, out _);

    protected override IEnumerable<HttpHeader> EnumerateHeaders() =>
        encabezados.Select(e => new HttpHeader(e.Nombre, e.Valor));

    protected override bool TryGetHeader(string name, [NotNullWhen(true)] out string? value)
    {
        foreach (var e in encabezados)
            if (string.Equals(e.Nombre, name, StringComparison.OrdinalIgnoreCase)) { value = e.Valor; return true; }
        value = null;
        return false;
    }

    protected override bool TryGetHeaderValues(string name, [NotNullWhen(true)] out IEnumerable<string>? values)
    {
        if (TryGetHeader(name, out var v)) { values = [v]; return true; }
        values = null;
        return false;
    }
}

/// <summary>
/// Reloj que no espera: dispara cada temporizador de inmediato y guarda la espera solicitada,
/// para verificar la pausa configurada sin demorar las pruebas.
/// </summary>
internal sealed class RelojInmediato : TimeProvider
{
    public List<TimeSpan> Esperas { get; } = [];

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        lock (Esperas) Esperas.Add(dueTime);
        ThreadPool.QueueUserWorkItem(_ => callback(state));
        return new TemporizadorNulo();
    }

    private sealed class TemporizadorNulo : ITimer
    {
        public bool Change(TimeSpan dueTime, TimeSpan period) => true;
        public void Dispose() { }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}

internal static class Datos
{
    /// <summary>Avisos ficticios de prueba (dominio reservado example.com, RFC 2606).</summary>
    public static List<AvisoPendiente> Avisos(int n, string tipo = "Preaviso") =>
        Enumerable.Range(1, n).Select(i => new AvisoPendiente(
            FacturaId: i, ClienteId: 100 + i, Rut: $"1111111{i}-1", RazonSocial: $"Cliente Prueba {i}",
            Email: $"cliente{i}@example.com", Segmento: null, NumeroFactura: $"F-{i:000}",
            MontoTotal: 1000m * i, FechaVencimiento: new DateTime(2026, 11, 10), DiasDesdeVencimiento: -5,
            TipoAviso: tipo)).ToList();

    public static OpcionesCobranza Opciones(int max = 10, int pausaMs = 15000) => new()
    {
        SqlCobranza = "no-usado", SqlOrigen = "no-usado", VistaOrigen = "origen_sim.vw_ClientesRegularizados",
        AcsConnectionString = "no-usado", RemitenteCorreo = "DoNotReply@example.com",
        DiasPreaviso = 7, DiasMora1 = 3, DiasMora2 = 7,
        MaxCorreosPorEjecucion = max, PausaEntreCorreosMs = pausaMs,
        NombreEmpresa = "Empresa Prueba", CanalesPagoTexto = "Texto de prueba",
        TelefonoContacto = "000", CorreoContacto = "contacto@example.com"
    };

    public static RequestFailedException Error429(params (string, string)[] encabezados) =>
        Construir(429, "TooManyRequests", encabezados);

    public static RequestFailedException Error(int status, string codigo = "Error") =>
        Construir(status, codigo, []);

    /// <summary>Respuesta con cuerpo de error en formato Azure ({"error":{"code","message"}}).</summary>
    private static RequestFailedException Construir(int status, string codigo, (string, string)[] encabezados)
    {
        var cuerpo = $$$"""{"error":{"code":"{{{codigo}}}","message":"Mensaje de prueba"}}""";
        var r = new RespuestaFalsa(status, [("Content-Type", "application/json"), .. encabezados])
        {
            ContentStream = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(cuerpo))
        };
        return new RequestFailedException(r);
    }
}
