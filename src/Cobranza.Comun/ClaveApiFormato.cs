using System.Security.Cryptography;
using System.Text;

namespace Cobranza.Comun;

/// <summary>
/// Formato de las claves de API (ADR-001 seccion 5.3): cobk_&lt;prefijo&gt;_&lt;secreto&gt;.
/// - prefijo: 8 caracteres Base32 en minusculas ([a-z2-7]), 5 bytes aleatorios. Es la parte publica
///   que identifica la clave (cob.ClaveApi.Prefijo, CHAR(8)).
/// - secreto: 32 bytes aleatorios en Base64url sin relleno (43 caracteres).
/// - Longitud total: 57. Hash almacenado: SHA-256 de la clave completa en UTF-8 (BINARY(32)).
/// Lo comparten la API (validacion) y Cobranza.Herramientas (emision), para que ambas usen
/// exactamente el mismo formato.
/// </summary>
public static class ClaveApiFormato
{
    public const string Inicio = "cobk_";
    public const int LargoPrefijo = 8;
    public const int LargoSecreto = 43;
    public const int LargoTotal = 5 + LargoPrefijo + 1 + LargoSecreto; // 57

    private const string AlfabetoBase32 = "abcdefghijklmnopqrstuvwxyz234567";

    /// <summary>Genera una clave nueva. Devuelve la clave completa y su prefijo.</summary>
    public static (string Clave, string Prefijo) Generar()
    {
        var prefijo = Base32Minusculas(RandomNumberGenerator.GetBytes(5));
        var secreto = Base64Url(RandomNumberGenerator.GetBytes(32));
        return ($"{Inicio}{prefijo}_{secreto}", prefijo);
    }

    /// <summary>
    /// Valida el formato sin consultar la base. Si es valido devuelve el prefijo.
    /// No hace comparaciones dependientes del secreto (solo longitud y alfabeto).
    /// </summary>
    public static bool TryObtenerPrefijo(string? clave, out string prefijo)
    {
        prefijo = "";
        if (clave is null || clave.Length != LargoTotal) return false;
        if (!clave.StartsWith(Inicio, StringComparison.Ordinal)) return false;
        if (clave[Inicio.Length + LargoPrefijo] != '_') return false;

        var p = clave.AsSpan(Inicio.Length, LargoPrefijo);
        foreach (var c in p)
            if (!((c >= 'a' && c <= 'z') || (c >= '2' && c <= '7'))) return false;

        var s = clave.AsSpan(Inicio.Length + LargoPrefijo + 1);
        foreach (var c in s)
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'))
                return false;

        prefijo = p.ToString();
        return true;
    }

    /// <summary>SHA-256 de la clave completa en UTF-8 (32 bytes).</summary>
    public static byte[] Hash(string clave) => SHA256.HashData(Encoding.UTF8.GetBytes(clave));

    private static string Base32Minusculas(byte[] datos)
    {
        // 5 bytes = 40 bits = 8 simbolos de 5 bits, sin relleno.
        var sb = new StringBuilder(datos.Length * 8 / 5);
        int buffer = 0, bits = 0;
        foreach (var b in datos)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5)
            {
                sb.Append(AlfabetoBase32[(buffer >> (bits - 5)) & 31]);
                bits -= 5;
            }
        }
        if (bits > 0) sb.Append(AlfabetoBase32[(buffer << (5 - bits)) & 31]);
        return sb.ToString();
    }

    private static string Base64Url(byte[] datos) =>
        Convert.ToBase64String(datos).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
