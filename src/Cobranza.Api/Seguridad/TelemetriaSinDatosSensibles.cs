using Microsoft.ApplicationInsights.Channel;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.ApplicationInsights.Extensibility;

namespace Cobranza.Api.Seguridad;

/// <summary>
/// Exclusion de datos sensibles de Application Insights (ADR-001 5.5 y 5.7).
///
/// Configuracion verificada en el codigo de este proyecto (no se supone el comportamiento por defecto):
/// - No se registra HttpLogging ni ningun middleware que lea cuerpos de solicitud.
/// - No se agrega ningun inicializador que copie encabezados o cuerpos a la telemetria.
/// - Los endpoints de /api/v1/auth/* no escriben la solicitud en logs.
///
/// Como defensa adicional, este inicializador elimina de toda telemetria cualquier propiedad cuyo
/// nombre corresponda a los encabezados X-Api-Key, Authorization, Cookie o Set-Cookie, al token CSRF
/// o a cuerpos de solicitud, y en las solicitudes a /api/v1/auth/* elimina la cadena de consulta.
/// Que Application Insights en Azure no capture estos datos por otra via: PENDIENTE verificar en Azure.
/// </summary>
public sealed class TelemetriaSinDatosSensibles : ITelemetryInitializer
{
    private static readonly string[] Fragmentos =
        ["x-api-key", "authorization", "cookie", "x-csrf-token", "requestbody", "request-body", "body"];

    public const string RutaAutenticacion = "/api/v1/auth/";

    public void Initialize(ITelemetry telemetry)
    {
        if (telemetry is ISupportProperties conPropiedades)
        {
            foreach (var clave in conPropiedades.Properties.Keys.ToList())
                if (EsSensible(clave)) conPropiedades.Properties.Remove(clave);
        }

        if (telemetry is RequestTelemetry solicitud && solicitud.Url is { } url
            && url.AbsolutePath.StartsWith(RutaAutenticacion, StringComparison.OrdinalIgnoreCase)
            && !string.IsNullOrEmpty(url.Query))
        {
            solicitud.Url = new UriBuilder(url) { Query = "" }.Uri;
        }
    }

    public static bool EsSensible(string nombrePropiedad)
    {
        var n = nombrePropiedad.Replace("_", "-", StringComparison.Ordinal).ToLowerInvariant();
        foreach (var f in Fragmentos)
            if (n.Contains(f, StringComparison.Ordinal)) return true;
        return false;
    }
}
