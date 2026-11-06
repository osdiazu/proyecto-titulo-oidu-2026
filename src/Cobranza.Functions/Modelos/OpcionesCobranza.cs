using System.ComponentModel.DataAnnotations;

namespace Cobranza.Functions.Modelos;

/// <summary>
/// Parametros del job. Los valores de negocio (dias de aviso, textos de pago y contacto)
/// los define Finanzas; no tienen valor por defecto para que la Function App no inicie
/// con supuestos no aprobados.
/// </summary>
public sealed class OpcionesCobranza
{
    public const string Seccion = "Cobranza";

    [Required] public string SqlCobranza { get; set; } = "";
    [Required] public string SqlOrigen { get; set; } = "";

    /// <summary>Vista de la fuente en formato esquema.vista. Se valida contra inyeccion.</summary>
    [Required, RegularExpression(@"^[A-Za-z0-9_]{1,128}\.[A-Za-z0-9_]{1,128}$")]
    public string VistaOrigen { get; set; } = "";

    [Required] public string AcsConnectionString { get; set; } = "";
    [Required, EmailAddress] public string RemitenteCorreo { get; set; } = "";

    [Range(1, 60)] public int DiasPreaviso { get; set; }
    [Range(1, 180)] public int DiasMora1 { get; set; }
    [Range(2, 365)] public int DiasMora2 { get; set; }

    /// <summary>
    /// Limite de envios por ejecucion. Sin valor por defecto (0 no pasa la validacion).
    /// ACS con dominio administrado: 10 por hora (hallazgo H1). Valor DEMO D12: 10.
    /// </summary>
    [Range(1, 1000)] public int MaxCorreosPorEjecucion { get; set; }

    /// <summary>
    /// Pausa entre envios en ms. Sin valor por defecto: si falta el ajuste, el valor 0 no pasa la
    /// validacion y el job no inicia (evita superar 5 por minuto, hallazgo H1). Valor DEMO D12: 15000.
    /// </summary>
    [Range(1, 60000)] public int PausaEntreCorreosMs { get; set; }

    [Required] public string NombreEmpresa { get; set; } = "";
    [Required] public string CanalesPagoTexto { get; set; } = "";
    [Required] public string TelefonoContacto { get; set; } = "";
    [Required, EmailAddress] public string CorreoContacto { get; set; } = "";
}
