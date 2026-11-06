using System.Data;
using Cobranza.Functions.Modelos;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace Cobranza.Functions.Servicios;

/// <summary>
/// Acceso a la base del proyecto. Toda escritura se hace mediante procedimientos almacenados
/// (decision de S6-S8: escritura solo via procedimientos).
/// </summary>
public sealed class RepositorioCobranza(IOptions<OpcionesCobranza> opciones) : IRepositorioNotificaciones
{
    private readonly OpcionesCobranza _o = opciones.Value;

    private async Task<SqlConnection> AbrirAsync(CancellationToken ct)
    {
        var cn = new SqlConnection(_o.SqlCobranza);
        await cn.OpenAsync(ct);
        return cn;
    }

    private static SqlCommand Proc(SqlConnection cn, string nombre) =>
        new(nombre, cn) { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };

    public async Task<long> IniciarSincronizacionAsync(CancellationToken ct)
    {
        await using var cn = await AbrirAsync(ct);
        await using var cmd = Proc(cn, "cob.sp_IniciarSincronizacion");
        var id = cmd.Parameters.Add("@LogSincronizacionId", SqlDbType.BigInt);
        id.Direction = ParameterDirection.Output;
        await cmd.ExecuteNonQueryAsync(ct);
        return (long)id.Value;
    }

    public async Task FinalizarSincronizacionAsync(long id, string estado, int? leidos, ResultadoSincronizacion? r,
        string? detalle, CancellationToken ct)
    {
        await using var cn = await AbrirAsync(ct);
        await using var cmd = Proc(cn, "cob.sp_FinalizarSincronizacion");
        cmd.Parameters.Add("@LogSincronizacionId", SqlDbType.BigInt).Value = id;
        cmd.Parameters.Add("@Estado", SqlDbType.VarChar, 15).Value = estado;
        cmd.Parameters.Add("@ClientesLeidos", SqlDbType.Int).Value = (object?)leidos ?? DBNull.Value;
        cmd.Parameters.Add("@ClientesActualizados", SqlDbType.Int).Value = (object?)r?.ClientesActualizados ?? DBNull.Value;
        cmd.Parameters.Add("@PedidosLiberados", SqlDbType.Int).Value = (object?)r?.PedidosLiberados ?? DBNull.Value;
        cmd.Parameters.Add("@Detalle", SqlDbType.NVarChar, 400).Value = (object?)Recortar(detalle, 400) ?? DBNull.Value;
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>Envia la lista de RUT regularizados como parametro de tabla cob.ListaRut.</summary>
    public async Task<ResultadoSincronizacion> SincronizarAsync(IReadOnlyList<string> ruts, long logId, CancellationToken ct)
    {
        var tabla = new DataTable();
        tabla.Columns.Add("Rut", typeof(string));
        foreach (var rut in ruts) tabla.Rows.Add(rut);

        await using var cn = await AbrirAsync(ct);
        await using var cmd = Proc(cn, "cob.sp_SincronizarClientesRegularizados");
        var p = cmd.Parameters.AddWithValue("@Ruts", tabla);
        p.SqlDbType = SqlDbType.Structured;
        p.TypeName = "cob.ListaRut";
        cmd.Parameters.Add("@LogSincronizacionId", SqlDbType.BigInt).Value = logId;

        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (!await rd.ReadAsync(ct))
            throw new InvalidOperationException("sp_SincronizarClientesRegularizados no devolvio resultado.");

        return new ResultadoSincronizacion(
            rd.GetInt32(rd.GetOrdinal("RutsRecibidos")),
            rd.GetInt32(rd.GetOrdinal("RutsNoEncontrados")),
            rd.GetInt32(rd.GetOrdinal("ClientesActualizados")),
            rd.GetInt32(rd.GetOrdinal("PedidosLiberados")));
    }

    public async Task<IReadOnlyList<AvisoPendiente>> ObtenerAvisosPendientesAsync(int maxFilas, CancellationToken ct)
    {
        await using var cn = await AbrirAsync(ct);
        await using var cmd = Proc(cn, "cob.sp_GenerarAlertasVencimiento");
        cmd.Parameters.Add("@DiasPreaviso", SqlDbType.Int).Value = _o.DiasPreaviso;
        cmd.Parameters.Add("@DiasMora1", SqlDbType.Int).Value = _o.DiasMora1;
        cmd.Parameters.Add("@DiasMora2", SqlDbType.Int).Value = _o.DiasMora2;
        cmd.Parameters.Add("@MaxFilas", SqlDbType.Int).Value = maxFilas;

        var lista = new List<AvisoPendiente>();
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct))
        {
            lista.Add(new AvisoPendiente(
                rd.GetInt32(rd.GetOrdinal("FacturaId")),
                rd.GetInt32(rd.GetOrdinal("ClienteId")),
                rd.GetString(rd.GetOrdinal("Rut")),
                rd.GetString(rd.GetOrdinal("RazonSocial")),
                rd.GetString(rd.GetOrdinal("Email")).Trim(),
                rd.IsDBNull(rd.GetOrdinal("Segmento")) ? null : rd.GetString(rd.GetOrdinal("Segmento")),
                rd.GetString(rd.GetOrdinal("NumeroFactura")),
                rd.GetDecimal(rd.GetOrdinal("MontoTotal")),
                rd.GetDateTime(rd.GetOrdinal("FechaVencimiento")),
                rd.GetInt32(rd.GetOrdinal("DiasDesdeVencimiento")),
                rd.GetString(rd.GetOrdinal("TipoAviso"))));
        }
        return lista;
    }

    public async Task RegistrarNotificacionAsync(AvisoPendiente a, string estado, string? idOperacion, string? detalle,
        CancellationToken ct)
    {
        await using var cn = await AbrirAsync(ct);
        await using var cmd = Proc(cn, "cob.sp_RegistrarNotificacion");
        cmd.Parameters.Add("@FacturaId", SqlDbType.Int).Value = a.FacturaId;
        cmd.Parameters.Add("@TipoAviso", SqlDbType.VarChar, 15).Value = a.TipoAviso;
        cmd.Parameters.Add("@Destinatario", SqlDbType.VarChar, 120).Value = a.Email;
        cmd.Parameters.Add("@EstadoEnvio", SqlDbType.VarChar, 15).Value = estado;
        cmd.Parameters.Add("@IdOperacionAcs", SqlDbType.VarChar, 100).Value = (object?)idOperacion ?? DBNull.Value;
        cmd.Parameters.Add("@Detalle", SqlDbType.NVarChar, 400).Value = (object?)Recortar(detalle, 400) ?? DBNull.Value;
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static string? Recortar(string? s, int max) => s is null ? null : (s.Length <= max ? s : s[..max]);
}
