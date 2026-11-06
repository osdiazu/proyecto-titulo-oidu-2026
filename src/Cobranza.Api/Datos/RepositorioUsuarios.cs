using System.Data;
using Microsoft.Data.SqlClient;

namespace Cobranza.Api.Datos;

/// <summary>Fila de cob.UsuarioInterno devuelta por sp_ObtenerUsuarioParaLogin y sp_ObtenerUsuarioPorId.</summary>
/// <param name="HashClave">Null cuando sp_ObtenerUsuarioPorId se llama con @IncluirHash = 0.</param>
public sealed record UsuarioInterno(
    int UsuarioId,
    string Usuario,
    string Nombre,
    string Rol,
    bool Activo,
    string? HashClave,
    bool DebeCambiarClave,
    short IntentosFallidos,
    DateTime? BloqueadoHastaUtc,
    Guid SelloSeguridad,
    DateTime? FechaCambioClaveUtc);

/// <summary>Fila devuelta por sp_ValidarClaveApi.</summary>
public sealed record ClaveApiValida(int ClaveApiId, string Consumidor, string Rol);

/// <summary>
/// Procedimientos de autenticacion con GRANT EXECUTE a UsuarioApi (ADR-001 5.2, sql/12).
/// Nunca recibe contrasenas ni claves en texto plano: solo hashes (ADR 4.3).
/// </summary>
public interface IRepositorioUsuarios
{
    Task<UsuarioInterno?> ObtenerUsuarioParaLoginAsync(string usuario, CancellationToken ct);
    Task<UsuarioInterno?> ObtenerUsuarioPorIdAsync(int usuarioId, bool incluirHash, CancellationToken ct);

    Task RegistrarLoginFallidoAsync(int? usuarioId, string usuarioIngresado, string motivo, string? ipOrigen,
        string? agenteUsuario, short maxIntentos, int minutosBloqueo, CancellationToken ct);

    /// <summary>Lanza <see cref="UsuarioNoEncontradoException"/> si el procedimiento responde THROW 50061 (D-5 de sql/12).</summary>
    Task RegistrarLoginExitosoAsync(int usuarioId, string? ipOrigen, string? agenteUsuario, string? hashClaveNuevo,
        CancellationToken ct);

    Task RegistrarLogoutAsync(int usuarioId, string? ipOrigen, string? agenteUsuario, CancellationToken ct);

    /// <summary>Lanza <see cref="CambioClaveRechazadoException"/> si el procedimiento responde THROW 50060.</summary>
    Task CambiarClaveAsync(int usuarioId, Guid selloActual, string hashClaveNuevo, string? ipOrigen,
        string? agenteUsuario, CancellationToken ct);

    Task<ClaveApiValida?> ValidarClaveApiAsync(string prefijo, byte[] hashClave, CancellationToken ct);
}

/// <summary>sp_CambiarClave no actualizo filas (usuario inactivo o sello distinto): THROW 50060.</summary>
public sealed class CambioClaveRechazadoException(Exception? interna = null)
    : Exception("sp_CambiarClave rechazo el cambio (50060).", interna);

/// <summary>
/// El usuario dejo de existir entre la lectura y el registro del login exitoso: THROW 50061
/// (desviacion D-5 de sql/12). La API responde el 401 generico en vez de un 500.
/// </summary>
public sealed class UsuarioNoEncontradoException(Exception? interna = null)
    : Exception("El usuario indicado no existe (50061).", interna);

/// <summary>Motivos admitidos por cob.LogAcceso.Motivo (ADR-001 5.1).</summary>
public static class MotivosLogin
{
    public const string ClaveIncorrecta = "ClaveIncorrecta";
    public const string UsuarioInexistente = "UsuarioInexistente";
    public const string UsuarioInactivo = "UsuarioInactivo";
    public const string CuentaBloqueada = "CuentaBloqueada";
    public const string ClaveTemporalVencida = "ClaveTemporalVencida";
}

public sealed class RepositorioUsuarios(IConfiguration config) : IRepositorioUsuarios
{
    /// <summary>Codigo de error de sp_CambiarClave cuando no actualiza filas (ADR 5.2).</summary>
    public const int ErrorCambioClaveRechazado = 50060;

    /// <summary>Codigo de error de sql/12 cuando el usuario no existe (desviacion D-5).</summary>
    public const int ErrorUsuarioNoExiste = 50061;

    private readonly string _cs = config.GetConnectionString("Cobranza")
        ?? throw new InvalidOperationException("Falta ConnectionStrings:Cobranza.");

    private async Task<(SqlConnection, SqlCommand)> ProcAsync(string nombre, CancellationToken ct)
    {
        var cn = new SqlConnection(_cs);
        await cn.OpenAsync(ct);
        return (cn, new SqlCommand(nombre, cn) { CommandType = CommandType.StoredProcedure, CommandTimeout = 15 });
    }

    private static object Nulo(object? v) => v ?? DBNull.Value;

    private static void IpYAgente(SqlCommand cmd, string? ip, string? agente)
    {
        cmd.Parameters.Add("@IpOrigen", SqlDbType.VarChar, 45).Value = Nulo(ip);
        cmd.Parameters.Add("@AgenteUsuario", SqlDbType.NVarChar, 200).Value = Nulo(agente);
    }

    public async Task<UsuarioInterno?> ObtenerUsuarioParaLoginAsync(string usuario, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_ObtenerUsuarioParaLogin", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@Usuario", SqlDbType.VarChar, 50).Value = usuario;
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            return await rd.ReadAsync(ct) ? LeerUsuario(rd) : null;
        }
    }

    public async Task<UsuarioInterno?> ObtenerUsuarioPorIdAsync(int usuarioId, bool incluirHash, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_ObtenerUsuarioPorId", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@UsuarioId", SqlDbType.Int).Value = usuarioId;
            cmd.Parameters.Add("@IncluirHash", SqlDbType.Bit).Value = incluirHash;
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            return await rd.ReadAsync(ct) ? LeerUsuario(rd) : null;
        }
    }

    public async Task RegistrarLoginFallidoAsync(int? usuarioId, string usuarioIngresado, string motivo, string? ipOrigen,
        string? agenteUsuario, short maxIntentos, int minutosBloqueo, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_RegistrarLoginFallido", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@UsuarioId", SqlDbType.Int).Value = Nulo(usuarioId);
            cmd.Parameters.Add("@UsuarioIngresado", SqlDbType.NVarChar, 50).Value = usuarioIngresado;
            cmd.Parameters.Add("@Motivo", SqlDbType.VarChar, 25).Value = motivo;
            IpYAgente(cmd, ipOrigen, agenteUsuario);
            cmd.Parameters.Add("@MaxIntentos", SqlDbType.SmallInt).Value = maxIntentos;
            cmd.Parameters.Add("@MinutosBloqueo", SqlDbType.Int).Value = minutosBloqueo;
            // El procedimiento devuelve BloqueadoHasta; la API no lo usa (la respuesta es siempre la misma).
            await cmd.ExecuteNonQueryAsync(ct);
        }
    }

    public async Task RegistrarLoginExitosoAsync(int usuarioId, string? ipOrigen, string? agenteUsuario, string? hashClaveNuevo,
        CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_RegistrarLoginExitoso", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@UsuarioId", SqlDbType.Int).Value = usuarioId;
            IpYAgente(cmd, ipOrigen, agenteUsuario);
            cmd.Parameters.Add("@HashClaveNuevo", SqlDbType.VarChar, 256).Value = Nulo(hashClaveNuevo);
            try
            {
                await cmd.ExecuteNonQueryAsync(ct);
            }
            catch (SqlException ex) when (ex.Number == ErrorUsuarioNoExiste)
            {
                throw new UsuarioNoEncontradoException(ex);
            }
        }
    }

    public async Task RegistrarLogoutAsync(int usuarioId, string? ipOrigen, string? agenteUsuario, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_RegistrarLogout", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@UsuarioId", SqlDbType.Int).Value = usuarioId;
            IpYAgente(cmd, ipOrigen, agenteUsuario);
            await cmd.ExecuteNonQueryAsync(ct);
        }
    }

    public async Task CambiarClaveAsync(int usuarioId, Guid selloActual, string hashClaveNuevo, string? ipOrigen,
        string? agenteUsuario, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_CambiarClave", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@UsuarioId", SqlDbType.Int).Value = usuarioId;
            cmd.Parameters.Add("@SelloActual", SqlDbType.UniqueIdentifier).Value = selloActual;
            cmd.Parameters.Add("@HashClaveNuevo", SqlDbType.VarChar, 256).Value = hashClaveNuevo;
            IpYAgente(cmd, ipOrigen, agenteUsuario);
            try
            {
                // El procedimiento devuelve el sello nuevo; la API lo vuelve a leer con
                // sp_ObtenerUsuarioPorId para reemitir la cookie con el estado completo.
                await cmd.ExecuteNonQueryAsync(ct);
            }
            catch (SqlException ex) when (ex.Number == ErrorCambioClaveRechazado)
            {
                throw new CambioClaveRechazadoException(ex);
            }
        }
    }

    public async Task<ClaveApiValida?> ValidarClaveApiAsync(string prefijo, byte[] hashClave, CancellationToken ct)
    {
        var (cn, cmd) = await ProcAsync("cob.sp_ValidarClaveApi", ct);
        await using (cn) await using (cmd)
        {
            cmd.Parameters.Add("@Prefijo", SqlDbType.Char, 8).Value = prefijo;
            cmd.Parameters.Add("@HashClave", SqlDbType.Binary, 32).Value = hashClave;
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            if (!await rd.ReadAsync(ct)) return null;
            return new ClaveApiValida(
                rd.GetInt32(rd.GetOrdinal("ClaveApiId")),
                rd.GetString(rd.GetOrdinal("Consumidor")),
                rd.GetString(rd.GetOrdinal("Rol")).Trim());
        }
    }

    private static UsuarioInterno LeerUsuario(SqlDataReader rd)
    {
        // HashClave puede no venir (sp_ObtenerUsuarioPorId con @IncluirHash = 0): se acepta que la
        // columna no exista o que venga en NULL.
        string? hash = null;
        var iHash = Ordinal(rd, "HashClave");
        if (iHash >= 0 && !rd.IsDBNull(iHash)) hash = rd.GetString(iHash);

        DateTime? Fecha(string c) { var i = rd.GetOrdinal(c); return rd.IsDBNull(i) ? null : DateTime.SpecifyKind(rd.GetDateTime(i), DateTimeKind.Utc); }

        return new UsuarioInterno(
            rd.GetInt32(rd.GetOrdinal("UsuarioId")),
            rd.GetString(rd.GetOrdinal("Usuario")),
            rd.GetString(rd.GetOrdinal("Nombre")),
            rd.GetString(rd.GetOrdinal("Rol")).Trim(),
            rd.GetBoolean(rd.GetOrdinal("Activo")),
            hash,
            rd.GetBoolean(rd.GetOrdinal("DebeCambiarClave")),
            rd.GetInt16(rd.GetOrdinal("IntentosFallidos")),
            Fecha("BloqueadoHasta"),
            rd.GetGuid(rd.GetOrdinal("SelloSeguridad")),
            Fecha("FechaCambioClave"));
    }

    private static int Ordinal(SqlDataReader rd, string columna)
    {
        for (var i = 0; i < rd.FieldCount; i++)
            if (string.Equals(rd.GetName(i), columna, StringComparison.OrdinalIgnoreCase)) return i;
        return -1;
    }
}
