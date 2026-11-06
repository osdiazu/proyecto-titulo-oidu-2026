using System.ComponentModel.DataAnnotations;

namespace Cobranza.Api.Seguridad;

/// <summary>
/// Parametros de bloqueo, sesion y contrasena (ADR-001 seccion 5.4), ajustes Seguridad__*.
/// Sin valores por defecto en codigo: un ajuste ausente vale 0, no pasa la validacion y la API
/// no arranca (ValidateOnStart). Los valores DEMO estan en appsettings.json.
/// </summary>
public sealed class OpcionesSeguridad
{
    public const string Seccion = "Seguridad";

    /// <summary>DEMO 5 (aprobado 05-11-2026).</summary>
    [Range(1, 100)] public int MaxIntentosFallidos { get; set; }

    /// <summary>DEMO 15 (aprobado 05-11-2026).</summary>
    [Range(1, 1440)] public int MinutosBloqueo { get; set; }

    /// <summary>Limitador de tasa del login por IP, ventana fija de 1 minuto. DEMO 10 (PENDIENTE).</summary>
    [Range(1, 1000)] public int LoginPorIpPorMinuto { get; set; }

    /// <summary>DEMO 12 (PENDIENTE).</summary>
    [Range(8, 128)] public int LongitudMinimaClave { get; set; }

    /// <summary>DEMO 128 (PENDIENTE).</summary>
    [Range(12, 1024)] public int LongitudMaximaClave { get; set; }

    /// <summary>Expiracion deslizante de la cookie. DEMO 30 (aprobado).</summary>
    [Range(1, 1440)] public int MinutosInactividadSesion { get; set; }

    /// <summary>Duracion absoluta de la sesion (claim emitida_utc). DEMO 8 (aprobado).</summary>
    [Range(1, 24)] public int HorasMaximasSesion { get; set; }

    /// <summary>Cada cuanto se revalida la cookie contra sp_ObtenerUsuarioPorId. DEMO 5 (aprobado).</summary>
    [Range(1, 60)] public int MinutosRevalidacionSesion { get; set; }

    /// <summary>Cache en memoria de validaciones correctas de clave de API. DEMO 60 (aprobado).</summary>
    [Range(1, 3600)] public int SegundosCacheClaveApi { get; set; }

    /// <summary>Vigencia maxima de una clave de API; la aplica el script de alta. DEMO 180 (PENDIENTE).</summary>
    [Range(1, 3650)] public int DiasVigenciaClaveApi { get; set; }

    /// <summary>Vigencia de la contrasena temporal. DEMO 24 (aprobado).</summary>
    [Range(1, 168)] public int HorasVigenciaClaveTemporal { get; set; }

    /// <summary>ForwardLimit del middleware de encabezados reenviados: 1 sin WAF, 2 con WAF (ADR 5.4.1).</summary>
    [Range(1, 2)] public int SaltosProxyConfiables { get; set; }

    /// <summary>Reglas cruzadas que DataAnnotations no expresa.</summary>
    public static bool Coherentes(OpcionesSeguridad o) =>
        o.LongitudMinimaClave <= o.LongitudMaximaClave
        && o.MinutosRevalidacionSesion <= o.MinutosInactividadSesion
        && o.MinutosInactividadSesion <= o.HorasMaximasSesion * 60;
}

/// <summary>
/// Ubicacion de las claves de Data Protection (ADR-001 5.5), ajustes DataProtection__*.
/// Los valores los produce infra/main.bicep; no se escriben a mano.
/// </summary>
public sealed class OpcionesDataProtection
{
    public const string Seccion = "DataProtection";

    /// <summary>URI del blob del anillo de claves (contenedor dataprotection-keys, blob keys.xml).</summary>
    public string? BlobUri { get; set; }

    /// <summary>Identificador sin version de la clave RSA de Key Vault dataprotection-cobranza-api.</summary>
    public string? KeyIdentifier { get; set; }

    /// <summary>Nombre de aplicacion del anillo (ADR 5.5). Fijo: no es configurable.</summary>
    public const string NombreAplicacion = "cobranza-api";

    /// <summary>Devuelve las URI si ambas son absolutas y HTTPS; en otro caso null.</summary>
    public (Uri Blob, Uri Clave)? Validas()
    {
        if (Uri.TryCreate(BlobUri, UriKind.Absolute, out var blob) && blob.Scheme == Uri.UriSchemeHttps
            && Uri.TryCreate(KeyIdentifier, UriKind.Absolute, out var clave) && clave.Scheme == Uri.UriSchemeHttps)
            return (blob, clave);
        return null;
    }
}
