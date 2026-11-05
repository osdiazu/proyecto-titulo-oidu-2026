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
/// Control de cuota: maximo de envios por ejecucion y pausa entre envios (limites iniciales de
/// ACS con dominio administrado: 30 por minuto y 100 por hora). La programacion horaria permite
/// que los avisos no enviados en una ejecucion se envien en la siguiente.
/// </summary>
public sealed class NotificacionesFunction(
    RepositorioCobranza repo,
    EmailClient email,
    PlantillaCorreo plantilla,
    IOptions<OpcionesCobranza> opciones,
    ILogger<NotificacionesFunction> log)
{
    private readonly OpcionesCobranza _o = opciones.Value;

    [Function("EnviarNotificacionesCobranza")]
    public async Task RunAsync([TimerTrigger("%CRON_NOTIFICACIONES%")] TimerInfo timer, CancellationToken ct)
    {
        var avisos = await repo.ObtenerAvisosPendientesAsync(_o.MaxCorreosPorEjecucion, ct);
        int aceptados = 0, fallidos = 0;

        foreach (var a in avisos)
        {
            ct.ThrowIfCancellationRequested();
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
                await repo.RegistrarNotificacionAsync(a, "Aceptado", op.Id, null, ct);
                aceptados++;
            }
            catch (RequestFailedException ex)
            {
                fallidos++;
                log.LogWarning(ex, "Envio fallido factura {FacturaId} aviso {Tipo} (HTTP {Status}).", a.FacturaId, a.TipoAviso, ex.Status);
                await repo.RegistrarNotificacionAsync(a, "Fallido", null, $"HTTP {ex.Status} {ex.ErrorCode}: {ex.Message}", ct);
                if (ex.Status == 429)
                {
                    log.LogWarning("ACS informo limite de envio (429). Se detiene la ejecucion; continua en la siguiente.");
                    break;
                }
            }

            if (_o.PausaEntreCorreosMs > 0)
                await Task.Delay(_o.PausaEntreCorreosMs, ct);
        }

        log.LogInformation("Notificaciones: pendientes={Pendientes}, aceptados={Aceptados}, fallidos={Fallidos}",
            avisos.Count, aceptados, fallidos);
    }
}
