namespace Cobranza.Comun;

/// <summary>
/// Normaliza RUT al formato 12345678-9 (sin puntos, guion antes del DV, DV en mayuscula).
/// Se aplica a los RUT leidos desde la fuente para compararlos con cob.Cliente.
/// </summary>
public static class RutUtil
{
    public static string? Normalizar(string? rut)
    {
        if (string.IsNullOrWhiteSpace(rut)) return null;
        var limpio = rut.Trim().Replace(".", "").Replace("-", "").Replace(" ", "").ToUpperInvariant();
        if (limpio.Length < 2 || limpio.Length > 10) return null;
        var cuerpo = limpio[..^1];
        var dv = limpio[^1];
        if (!cuerpo.All(char.IsDigit)) return null;
        if (!(char.IsDigit(dv) || dv == 'K')) return null;
        return DigitoVerificador(cuerpo) == dv ? $"{cuerpo.TrimStart('0')}-{dv}" : null;
    }

    private static char DigitoVerificador(string cuerpo)
    {
        int suma = 0, factor = 2;
        for (int i = cuerpo.Length - 1; i >= 0; i--)
        {
            suma += (cuerpo[i] - '0') * factor;
            factor = factor == 7 ? 2 : factor + 1;
        }
        var resto = 11 - (suma % 11);
        return resto switch { 11 => '0', 10 => 'K', _ => (char)('0' + resto) };
    }
}
