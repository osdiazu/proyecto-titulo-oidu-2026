using System.Globalization;
using Azure;
using Azure.Core;
using Azure.Core.Pipeline;

namespace Cobranza.Functions.Servicios;

/// <summary>
/// Tratamiento del rechazo por limite de envio de Azure Communication Services Email
/// (HTTP 429 Too Many Requests). Con dominio administrado el limite es 5 por minuto y
/// 10 por hora (hallazgo H1), por lo que un 429 no es un error del aviso sino una senal de
/// cuota: el aviso se difiere a la siguiente ejecucion y no se registra como intento fallido.
/// </summary>
public static class LimiteAcs
{
    public const int EstadoHttpLimite = 429;
    public const string CodigoErrorLimite = "TooManyRequests";

    /// <summary>Indica si la excepcion del SDK corresponde a un rechazo por limite de envio.</summary>
    public static bool EsRechazoPorLimite(RequestFailedException ex) =>
        ex.Status == EstadoHttpLimite
        || string.Equals(ex.ErrorCode, CodigoErrorLimite, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Lee la espera indicada por el servicio. Revisa, en este orden, retry-after-ms,
    /// x-ms-retry-after-ms y Retry-After (segundos o fecha HTTP). Devuelve null si el SDK no
    /// expone la respuesta o si no viene ninguno de esos encabezados.
    /// </summary>
    public static TimeSpan? ObtenerRetryAfter(RequestFailedException ex, DateTimeOffset ahora)
    {
        var respuesta = ex.GetRawResponse();
        if (respuesta is null) return null;

        foreach (var nombre in new[] { "retry-after-ms", "x-ms-retry-after-ms" })
        {
            if (respuesta.Headers.TryGetValue(nombre, out var ms)
                && double.TryParse(ms, NumberStyles.Float, CultureInfo.InvariantCulture, out var valorMs)
                && valorMs >= 0)
                return TimeSpan.FromMilliseconds(valorMs);
        }

        if (respuesta.Headers.TryGetValue("Retry-After", out var ra) && !string.IsNullOrWhiteSpace(ra))
        {
            if (int.TryParse(ra, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seg) && seg >= 0)
                return TimeSpan.FromSeconds(seg);
            if (DateTimeOffset.TryParse(ra, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var fecha))
                return fecha > ahora ? fecha - ahora : TimeSpan.Zero;
        }
        return null;
    }
}

/// <summary>
/// Politica de reintentos del EmailClient: conserva los reintentos estandar de Azure.Core
/// (408, 5xx, errores de red), pero no reintenta un 429. Sin esto, el SDK esperaria el
/// Retry-After dentro de la misma ejecucion (hasta 3 veces) y podria agotar el
/// functionTimeout; con esta politica el 429 llega de inmediato al job, que corta el lote y
/// deja los avisos para la siguiente ejecucion programada.
/// </summary>
public sealed class PoliticaReintentoSinLimite(int maxReintentos = 3, DelayStrategy? estrategia = null)
    : RetryPolicy(maxReintentos, estrategia)
{
    protected override bool ShouldRetry(HttpMessage message, Exception? exception)
    {
        if (exception is null && message.HasResponse && message.Response.Status == LimiteAcs.EstadoHttpLimite)
            return false;
        return base.ShouldRetry(message, exception);
    }

    protected override ValueTask<bool> ShouldRetryAsync(HttpMessage message, Exception? exception)
    {
        if (exception is null && message.HasResponse && message.Response.Status == LimiteAcs.EstadoHttpLimite)
            return new ValueTask<bool>(false);
        return base.ShouldRetryAsync(message, exception);
    }
}
