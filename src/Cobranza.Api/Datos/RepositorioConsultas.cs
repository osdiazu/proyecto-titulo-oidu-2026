using System.Data;
using Microsoft.Data.SqlClient;

namespace Cobranza.Api.Datos;

public sealed record EstadoClienteDto(
    string Rut, string RazonSocial, string? Segmento, string? TipoConvenio,
    string EstadoActual, DateTime? FechaUltimoCambioUtc, bool PuedeTomarPedido,
    int FacturasPendientes, int FacturasVencidas, decimal MontoPendiente, decimal MontoVencido, int PedidosRetenidos);

public sealed record PedidoDto(int PedidoId, string NumeroPedido, DateTime FechaCreacion, string Estado, DateTime? FechaLiberacion);

public sealed record IndicadoresCarteraDto(
    int TotalClientes, int ClientesAlDia, int ClientesMorosos, int ClientesSuspendidos, int ClientesRegularizados,
    decimal MontoPorVencer, decimal MontoVencido1a30, decimal MontoVencido31a60, decimal MontoVencidoMas60,
    int PedidosRetenidos, int PedidosLiberados30d, int AvisosAceptados30d, int AvisosFallidos30d,
    DateTime? UltimaSincronizacionUtc, string? EstadoUltimaSincronizacion);

public sealed record SincronizacionDto(
    long LogSincronizacionId, DateTime FechaInicioUtc, DateTime? FechaFinUtc, string? Estado,
    int? ClientesLeidos, int? ClientesActualizados, int? PedidosLiberados, string? Detalle);

/// <summary>Consultas de negocio de la API. Interfaz para probar la API sin base de datos.</summary>
public interface IRepositorioConsultas
{
    Task<EstadoClienteDto?> EstadoClienteAsync(string rut, CancellationToken ct);
    Task<IReadOnlyList<PedidoDto>> PedidosClienteAsync(string rut, string? estado, CancellationToken ct);
    Task<IndicadoresCarteraDto> IndicadoresAsync(CancellationToken ct);
    Task<IReadOnlyList<SincronizacionDto>> SincronizacionesAsync(int top, CancellationToken ct);
    Task<bool> SaludAsync(CancellationToken ct);
}

/// <summary>Consultas de solo lectura; la identidad del App Service solo tiene EXECUTE (06_consultas_api.sql).</summary>
public sealed class RepositorioConsultas(IConfiguration config) : IRepositorioConsultas
{
    private readonly string _cs = config.GetConnectionString("Cobranza")
        ?? throw new InvalidOperationException("Falta ConnectionStrings:Cobranza.");

    private async Task<(SqlConnection, SqlCommand)> ProcAsync(string nombre, CancellationToken ct)
    {
        var cn = new SqlConnection(_cs);
        await cn.OpenAsync(ct);
        return (cn, new SqlCommand(nombre, cn) { CommandType = CommandType.StoredProcedure, CommandTimeout = 15 });
    }

    private static T? N<T>(SqlDataReader rd, string col) where T : struct
        => rd.IsDBNull(rd.GetOrdinal(col)) ? null : rd.GetFieldValue<T>(rd.GetOrdinal(col));
    private static string? S(SqlDataReader rd, string col)
        => rd.IsDBNull(rd.GetOrdinal(col)) ? null : Convert.ToString(rd.GetValue(rd.GetOrdinal(col)));

    public async Task<EstadoClienteDto?> EstadoClienteAsync(string rut, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_ConsultarEstadoCliente", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@Rut", SqlDbType.VarChar, 20).Value = rut;
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            if (!await rd.ReadAsync(ct)) return null;
            return new EstadoClienteDto(
                S(rd, "Rut")!, S(rd, "RazonSocial")!, S(rd, "Segmento"), S(rd, "TipoConvenio"),
                S(rd, "EstadoActual")!, N<DateTime>(rd, "FechaUltimoCambio"), rd.GetBoolean(rd.GetOrdinal("PuedeTomarPedido")),
                rd.GetInt32(rd.GetOrdinal("FacturasPendientes")), rd.GetInt32(rd.GetOrdinal("FacturasVencidas")),
                rd.GetDecimal(rd.GetOrdinal("MontoPendiente")), rd.GetDecimal(rd.GetOrdinal("MontoVencido")),
                rd.GetInt32(rd.GetOrdinal("PedidosRetenidos")));
        }
    }

    public async Task<IReadOnlyList<PedidoDto>> PedidosClienteAsync(string rut, string? estado, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_ListarPedidosCliente", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@Rut", SqlDbType.VarChar, 20).Value = rut;
            cmd.Parameters.Add("@Estado", SqlDbType.VarChar, 15).Value = (object?)estado ?? DBNull.Value;
            var lista = new List<PedidoDto>();
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            while (await rd.ReadAsync(ct))
                lista.Add(new PedidoDto(rd.GetInt32(0), S(rd, "NumeroPedido")!, rd.GetDateTime(2), S(rd, "Estado")!, N<DateTime>(rd, "FechaLiberacion")));
            return lista;
        }
    }

    public async Task<IndicadoresCarteraDto> IndicadoresAsync(CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_IndicadoresCartera", ct);
        await using (cn) await using (cmd)
        {
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            await rd.ReadAsync(ct);
            int I(string c) => rd.GetInt32(rd.GetOrdinal(c));
            decimal D(string c) => rd.GetDecimal(rd.GetOrdinal(c));
            return new IndicadoresCarteraDto(
                I("TotalClientes"), I("ClientesAlDia"), I("ClientesMorosos"), I("ClientesSuspendidos"), I("ClientesRegularizados"),
                D("MontoPorVencer"), D("MontoVencido1a30"), D("MontoVencido31a60"), D("MontoVencidoMas60"),
                I("PedidosRetenidos"), I("PedidosLiberados30d"), I("AvisosAceptados30d"), I("AvisosFallidos30d"),
                N<DateTime>(rd, "UltimaSincronizacion"), S(rd, "EstadoUltimaSincronizacion"));
        }
    }

    public async Task<IReadOnlyList<SincronizacionDto>> SincronizacionesAsync(int top, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_ListarSincronizaciones", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@Top", SqlDbType.Int).Value = top;
            var lista = new List<SincronizacionDto>();
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            while (await rd.ReadAsync(ct))
                lista.Add(new SincronizacionDto(
                    rd.GetInt64(rd.GetOrdinal("LogSincronizacionId")), rd.GetDateTime(rd.GetOrdinal("FechaInicio")),
                    N<DateTime>(rd, "FechaFin"), S(rd, "Estado"), N<int>(rd, "ClientesLeidos"),
                    N<int>(rd, "ClientesActualizados"), N<int>(rd, "PedidosLiberados"), S(rd, "Detalle")));
            return lista;
        }
    }

    public async Task<bool> SaludAsync(CancellationToken ct)
    {
        try
        {
            var (cn, cmd) = await ProcAsync("cob.sp_Salud", ct);
            await using (cn) await using (cmd) return (await cmd.ExecuteScalarAsync(ct)) is true;
        }
        catch (SqlException) { return false; }
    }
}
