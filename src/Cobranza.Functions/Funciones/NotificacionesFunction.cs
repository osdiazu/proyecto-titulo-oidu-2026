using Azure;
using Azure.Communication.Email;
using Cobranza.Functions.Modelos;
using Cobranza.Functions.Servicios;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobranza.Functions.Funciones;

/// <summary>
/// Job de notificaciones (RF-01, RF-05). Obtiene los avisos que corresponden hoy, envia cada
/// correo con Azure Communication Services y registra el resultado en cob.LogNotificacion.
/// Control de cuota (hallazgo H1, dominio administrado: 5 por minuto y 10 por hora): maximo de
/// envios por ejecucion y pausa entre envios, ambos desde configuracion (Cobranza__*).
/// Un rechazo por limite (HTTP 429) no cuenta como intento fallido (ADR-001 5.12, decision U5):
/// se registra con EstadoEnvio = 'Limitado' (sp_RegistrarNotificacion no incrementa Intentos con ese
/// estado, sql/04), se corta la ejecucion y los avisos no enviados quedan pendientes para la
/// siguiente ejecucion programada.
/// </summary>
public sealed class NotificacionesFunction(
    IRepositorioNotificaciones repo,
    EmailClient email,
    PlantillaCorreo plantilla,
    IOptions<OpcionesCobranza> opciones,
    ILogger<NotificacionesFunction> log,
    TimeProvider reloj)
{
    /// <summary>Evento de log para consultar los cortes por limite en Application Insights.</summary>
    public static readonly EventId EventoLimiteAcs = new(4290, "LimiteAcs429");

    /// <summary>Evento de log si no se pudo registrar el estado Limitado en la base.</summary>
    public static readonly EventId EventoRegistroLimitadoFallido = new(4291, "RegistroLimitadoFallido");

    /// <summary>Valores de EstadoEnvio admitidos por cob.sp_RegistrarNotificacion (sql/04).</summary>
    public const string EstadoAceptado = "Aceptado";
    public const string EstadoFallido = "Fallido";
    public const string EstadoLimitado = "Limitado";

    private readonly OpcionesCobranza _o = opciones.Value;

    [Function("EnviarNotificacionesCobranza")]
    public async Task RunAsync([TimerTrigger("%CRON_NOTIFICACIONES%")] TimerInfo timer, CancellationToken ct)
        => await ProcesarAsync(ct);

    public async Task<ResultadoNotificaciones> ProcesarAsync(CancellationToken ct)
    {
        var avisos = await repo.ObtenerAvisosPendientesAsync(_o.MaxCorreosPorEjecucion, ct);
        int aceptados = 0, fallidos = 0, procesados = 0;
        bool cortadoPorLimite = false;
        TimeSpan? retryAfter = null;

        foreach (var a in avisos)
        {
            ct.ThrowIfCancellationRequested();

            if (procesados > 0 && _o.PausaEntreCorreosMs > 0)
                await Task.Delay(TimeSpan.FromMilliseconds(_o.PausaEntreCorreosMs), reloj, ct);

            var correo = plantilla.Construir(a);
            var mensaje = new EmailMessage(
                senderAddress: _o.RemitenteCorreo,
                recipientAddress: a.Email,
                content: new EmailContent(correo.Asunto) { PlainText = correo.TextoPlano, Html = correo.Html });

            try
            {
                // WaitUntil.Started: ACS acepta el mensaje y devuelve el Id de operacion.
                // El estado final de entrega se mide con los registros de ACS en Log Analytics.
                var op = await email.SendAsync(WaitUntil.Started, mensaje, ct);
                procesados++;
                await repo.RegistrarNotificacionAsync(a, EstadoAceptado, op.Id, null, ct);
                aceptados++;
            }
            catch (RequestFailedException ex) when (LimiteAcs.EsRechazoPorLimite(ex))
            {
                // Limite de ACS: no es un fallo del aviso. Se registra como Limitado (RF-05: el evento
                // queda en la bitacora; sp_RegistrarNotificacion no suma Intentos con ese estado, por lo
                // que no lo acerca a la exclusion de 3 intentos) y se corta el lote.
                cortadoPorLimite = true;
                retryAfter = LimiteAcs.ObtenerRetryAfter(ex, reloj.GetUtcNow());
                log.LogWarning(EventoLimiteAcs, ex,
                    "ACS rechazo el envio por limite (HTTP {Status}, codigo {ErrorCode}) en factura {FacturaId} aviso {Tipo}. " +
                    "Se registra como Limitado y se corta la ejecucion; quedan {Diferidos} avisos para la siguiente ejecucion. " +
                    "Retry-After: {RetryAfterSegundos} s.",
                    ex.Status, ex.ErrorCode, a.FacturaId, a.TipoAviso, avisos.Count - procesados,
                    retryAfter?.TotalSeconds);
                try
                {
                    await repo.RegistrarNotificacionAsync(a, EstadoLimitado, null, DetalleLimite(ex, retryAfter), ct);
                }
                catch (Exception exReg) when (exReg is not OperationCanceledException)
                {
                    // El corte del lote se mantiene aunque falle el registro (por ejemplo, si sql/04 aun
                    // no admite Limitado): el aviso sigue elegible en la siguiente ejecucion.
                    log.LogError(EventoRegistroLimitadoFallido, exReg,
                        "No se pudo registrar el estado Limitado de la factura {FacturaId} aviso {Tipo}.", a.FacturaId, a.TipoAviso);
                }
                break;
            }
            catch (RequestFailedException ex)
            {
                procesados++;
                fallidos++;
                log.LogWarning(ex, "Envio fallido factura {FacturaId} aviso {Tipo} (HTTP {Status}).", a.FacturaId, a.TipoAviso, ex.Status);
                await repo.RegistrarNotificacionAsync(a, EstadoFallido, null, $"HTTP {ex.Status} {ex.ErrorCode}: {ex.Message}", ct);
            }
        }

        var resultado = new ResultadoNotificaciones(
            avisos.Count, aceptados, fallidos, avisos.Count - procesados, cortadoPorLimite, retryAfter);

        log.LogInformation(
            "Notificaciones: pendientes={Pendientes}, aceptados={Aceptados}, fallidos={Fallidos}, diferidos={Diferidos}, cortePorLimite={Corte}",
            resultado.Pendientes, resultado.Aceptados, resultado.Fallidos, resultado.Diferidos, resultado.CortadoPorLimite);

        return resultado;
    }

    private static string DetalleLimite(Azure.RequestFailedException ex, TimeSpan? retryAfter) =>
        $"HTTP {ex.Status} {ex.ErrorCode}: rechazo por limite de envio de ACS" +
        (retryAfter is { } r ? $"; Retry-After {r.TotalSeconds:0} s" : "");
}

/// <summary>Resumen de una ejecucion del job de notificaciones.</summary>
/// <param name="Diferidos">Avisos obtenidos que no se enviaron por corte de limite (incluye el rechazado con 429, registrado como Limitado).</param>
public sealed record ResultadoNotificaciones(
    int Pendientes,
    int Aceptados,
    int Fallidos,
    int Diferidos,
    bool CortadoPorLimite,
    TimeSpan? RetryAfter);
