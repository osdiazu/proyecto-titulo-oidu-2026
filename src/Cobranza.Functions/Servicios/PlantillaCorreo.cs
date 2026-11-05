using System.Globalization;
using System.Net;
using Cobranza.Functions.Modelos;
using Microsoft.Extensions.Options;

namespace Cobranza.Functions.Servicios;

/// <summary>
/// Construye el correo de cobranza. Criterios de diseno (perfil de clientes, seccion 3.2 del informe):
///  - lenguaje simple y datos completos de la factura;
///  - sin enlaces de pago ni solicitud de datos bancarios (mitigacion de phishing);
///  - canales oficiales de contacto para verificar la autenticidad del aviso.
/// </summary>
public sealed class PlantillaCorreo(IOptions<OpcionesCobranza> opciones)
{
    private static readonly CultureInfo Chile = CultureInfo.GetCultureInfo("es-CL");
    private readonly OpcionesCobranza _o = opciones.Value;

    public CorreoCobranza Construir(AvisoPendiente a)
    {
        var fecha = a.FechaVencimiento.ToString("dd-MM-yyyy", Chile);
        var monto = a.MontoTotal.ToString("C0", Chile);

        var (asunto, frase) = a.TipoAviso switch
        {
            "Preaviso" => ($"Aviso: su factura N° {a.NumeroFactura} vence el {fecha}",
                           $"le recordamos que la factura N° {a.NumeroFactura} vence el {fecha}."),
            "Vencimiento" => ($"Aviso: su factura N° {a.NumeroFactura} tiene vencimiento el {fecha}",
                           $"le informamos que la factura N° {a.NumeroFactura} tiene fecha de vencimiento el {fecha} y a la fecha figura pendiente de pago."),
            "Mora1" or "Mora2" => ($"Recordatorio: factura N° {a.NumeroFactura} vencida el {fecha}",
                           $"le informamos que la factura N° {a.NumeroFactura}, vencida el {fecha}, figura pendiente de pago hace {a.DiasDesdeVencimiento} días."),
            _ => throw new ArgumentOutOfRangeException(nameof(a), a.TipoAviso, "Tipo de aviso no soportado.")
        };
        asunto = $"{_o.NombreEmpresa} - {asunto}";

        var lineas = new[]
        {
            $"Estimado(a) cliente {a.RazonSocial} (RUT {a.Rut}):",
            "",
            $"De parte de {_o.NombreEmpresa}, {frase}",
            "",
            $"Número de factura: {a.NumeroFactura}",
            $"Monto total: {monto}",
            $"Fecha de vencimiento: {fecha}",
            "",
            $"Formas de pago: {_o.CanalesPagoTexto}",
            "",
            "Si ya realizó el pago, por favor no considere este mensaje.",
            "",
            "Importante: este correo no contiene enlaces de pago y nunca le solicitaremos claves ni datos bancarios por correo.",
            $"Ante cualquier duda, comuníquese directamente al {_o.TelefonoContacto} o a {_o.CorreoContacto}.",
            "",
            "Este es un mensaje automático; por favor no responda a esta dirección."
        };

        var texto = string.Join(Environment.NewLine, lineas);
        var html = ConstruirHtml(lineas);
        return new CorreoCobranza(asunto, texto, html);
    }

    private static string ConstruirHtml(IEnumerable<string> lineas)
    {
        var parrafos = string.Join("", lineas.Select(l =>
            l.Length == 0 ? "<br/>" : $"<p style=\"margin:0 0 6px 0\">{WebUtility.HtmlEncode(l)}</p>"));
        return "<!DOCTYPE html><html lang=\"es\"><body style=\"font-family:Arial,Helvetica,sans-serif;font-size:15px;color:#1a1a1a;line-height:1.5\">"
             + parrafos + "</body></html>";
    }
}
