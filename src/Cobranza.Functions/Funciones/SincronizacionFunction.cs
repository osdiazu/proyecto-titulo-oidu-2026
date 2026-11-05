using Cobranza.Functions.Modelos;
using Cobranza.Functions.Servicios;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Cobranza.Functions.Funciones;

/// <summary>
/// Job de sincronizacion (RF-02, RF-03, RF-08). Cada ejecucion:
///  1. registra el inicio en cob.LogSincronizacion;
///  2. lee en solo lectura los RUT regularizados desde la fuente de la embotelladora;
///  3. entrega la lista a cob.sp_SincronizarClientesRegularizados, que cambia el estado a
///     Regularizado; el trigger de cob.EstadoMorosidad libera los pedidos retenidos (S11);
///  4. registra el resultado (Exitosa o Fallida) en la bitacora.
/// Si falla, la siguiente ejecucion programada reintenta: el procedimiento es idempotente.
/// </summary>
public sealed class SincronizacionFunction(
    IOrigenRegularizados origen,
    RepositorioCobranza repo,
    ILogger<SincronizacionFunction> log)
{
    [Function("SincronizarClientesRegularizados")]
    public async Task RunAsync([TimerTrigger("%CRON_SINCRONIZACION%")] TimerInfo timer, CancellationToken ct)
    {
        var logId = await repo.IniciarSincronizacionAsync(ct);
        int? leidos = null;
        try
        {
            var ruts = await origen.ObtenerRutsRegularizadosAsync(ct);
            leidos = ruts.Count;

            var r = await repo.SincronizarAsync(ruts, logId, ct);

            await repo.FinalizarSincronizacionAsync(logId, "Exitosa", leidos, r,
                $"RUT no encontrados en cob.Cliente: {r.RutsNoEncontrados}", ct);

            log.LogInformation(
                "Sincronizacion {LogId} exitosa: leidos={Leidos}, actualizados={Actualizados}, pedidosLiberados={Pedidos}, noEncontrados={NoEnc}",
                logId, leidos, r.ClientesActualizados, r.PedidosLiberados, r.RutsNoEncontrados);
        }
        catch (Exception ex)
        {
            log.LogError(ex, "Sincronizacion {LogId} fallida.", logId);
            await repo.FinalizarSincronizacionAsync(logId, "Fallida", leidos, null,
                $"{ex.GetType().Name}: {ex.Message}", CancellationToken.None);
            throw; // la ejecucion queda como fallida en Application Insights (alerta S12)
        }
    }
}
