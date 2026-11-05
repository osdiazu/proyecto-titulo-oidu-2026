namespace Cobranza.Functions.Modelos;

/// <summary>Fila devuelta por cob.sp_GenerarAlertasVencimiento.</summary>
public sealed record AvisoPendiente(
    int FacturaId,
    int ClienteId,
    string Rut,
    string RazonSocial,
    string Email,
    string? Segmento,
    string NumeroFactura,
    decimal MontoTotal,
    DateTime FechaVencimiento,
    int DiasDesdeVencimiento,
    string TipoAviso);

/// <summary>Resultado de cob.sp_SincronizarClientesRegularizados (contrato definido en S11, script 05).</summary>
public sealed record ResultadoSincronizacion(
    int RutsRecibidos,
    int RutsNoEncontrados,
    int ClientesActualizados,
    int PedidosLiberados);

public sealed record CorreoCobranza(string Asunto, string TextoPlano, string Html);
