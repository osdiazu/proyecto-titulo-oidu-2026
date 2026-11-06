using Cobranza.Functions.Modelos;

namespace Cobranza.Functions.Servicios;

/// <summary>
/// Operaciones del job de notificaciones sobre la base (procedimientos
/// cob.sp_GenerarAlertasVencimiento y cob.sp_RegistrarNotificacion). Se separa en una
/// interfaz para probar el job sin base de datos.
/// </summary>
public interface IRepositorioNotificaciones
{
    Task<IReadOnlyList<AvisoPendiente>> ObtenerAvisosPendientesAsync(int maxFilas, CancellationToken ct);

    /// <summary>estado: Aceptado o Fallido (valores admitidos por cob.sp_RegistrarNotificacion).</summary>
    Task RegistrarNotificacionAsync(AvisoPendiente a, string estado, string? idOperacion, string? detalle,
        CancellationToken ct);
}
