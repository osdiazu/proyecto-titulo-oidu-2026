namespace Cobranza.Api.Seguridad;

/// <summary>
/// Roles de cob.UsuarioInterno.Rol y cob.ClaveApi.Rol (ADR-001 seccion 5.6).
/// Mapeo desde Easy Auth: Ventas.Consulta -> Ventas, Finanzas.Consulta -> Finanzas,
/// TI.Operacion -> Admin (reemplaza a Roles.Operacion).
/// </summary>
public static class Roles
{
    public const string Ventas = "Ventas";
    public const string Finanzas = "Finanzas";
    public const string Admin = "Admin";

    public static readonly IReadOnlySet<string> Validos = new HashSet<string>(StringComparer.Ordinal) { Ventas, Finanzas, Admin };
}

/// <summary>Politicas de autorizacion. Conservan exactamente los permisos previos (ADR-001 5.6).</summary>
public static class Politicas
{
    public const string ConsultaCliente = "ConsultaCliente";   // Ventas o Finanzas
    public const string Cartera = "Cartera";                   // Finanzas
    public const string Operacion = "Operacion";               // Admin o Finanzas
    public const string SoloSesionPanel = "SoloSesionPanel";   // usuario autenticado por cookie
}

/// <summary>Nombres de los esquemas de autenticacion (ADR-001 5.6).</summary>
public static class Esquemas
{
    public const string Cookies = "Cookies";
    public const string ClaveApi = "ClaveApi";
    /// <summary>Esquema de politica por defecto: X-Api-Key -> ClaveApi; en otro caso -> Cookies.</summary>
    public const string Selector = "CobranzaSelector";
}

/// <summary>Tipos de claim propios (ADR-001 5.6).</summary>
public static class TiposClaim
{
    public const string Nombre = "nombre";
    public const string Sello = "sello";
    public const string EmitidaUtc = "emitida_utc";
    public const string DebeCambiarClave = "debe_cambiar_clave";
    public const string PrefijoClave = "prefijo_clave";
}

/// <summary>Encabezados y cookies de la autenticacion propia.</summary>
public static class NombresHttp
{
    public const string EncabezadoClaveApi = "X-Api-Key";
    public const string EncabezadoCsrf = "X-CSRF-TOKEN";
    public const string CookieSesion = "__Host-cobranza-sesion";
    public const string CookieAntifalsificacion = "__Host-cobranza-af";
}
