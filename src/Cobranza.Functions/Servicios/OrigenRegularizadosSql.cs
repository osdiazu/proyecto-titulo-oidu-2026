using Cobranza.Functions.Modelos;
using Cobranza.Comun;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Cobranza.Functions.Servicios;

/// <summary>Fuente de clientes regularizados (base de datos de la embotelladora).</summary>
public interface IOrigenRegularizados
{
    Task<IReadOnlyList<string>> ObtenerRutsRegularizadosAsync(CancellationToken ct);
}

/// <summary>
/// Implementacion para SQL Server / Azure SQL. Solo ejecuta SELECT sobre la vista configurada;
/// la conexion usa ApplicationIntent=ReadOnly y el usuario de BD solo tiene permiso SELECT
/// sobre esa vista (RNF-08). Si la base real usa otro motor, se agrega otra implementacion
/// de IOrigenRegularizados sin modificar el job.
/// </summary>
public sealed class OrigenRegularizadosSql(IOptions<OpcionesCobranza> opciones, ILogger<OrigenRegularizadosSql> log)
    : IOrigenRegularizados
{
    private readonly OpcionesCobranza _o = opciones.Value;

    public async Task<IReadOnlyList<string>> ObtenerRutsRegularizadosAsync(CancellationToken ct)
    {
        var partes = _o.VistaOrigen.Split('.');
        // Nombre validado por expresion regular en OpcionesCobranza; se delimita con corchetes.
        var sql = $"SELECT Rut FROM [{partes[0]}].[{partes[1]}];";

        var ruts = new HashSet<string>(StringComparer.Ordinal);
        int invalidos = 0;

        await using var cn = new SqlConnection(_o.SqlOrigen);
        await cn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, cn) { CommandTimeout = 120 };
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct))
        {
            var rut = RutUtil.Normalizar(rd.IsDBNull(0) ? null : rd.GetString(0));
            if (rut is null) { invalidos++; continue; }
            ruts.Add(rut);
        }

        if (invalidos > 0)
            log.LogWarning("Fuente de regularizacion: {Invalidos} RUT con formato o digito verificador invalido fueron descartados.", invalidos);

        return ruts.ToList();
    }
}
