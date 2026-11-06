using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Cobranza.Comun;
using Microsoft.AspNetCore.Identity;

namespace Cobranza.Herramientas;

/// <summary>Canal hacia la terminal del operador que no pasa por la salida estandar.</summary>
public interface ITerminal
{
    /// <summary>Escribe en la terminal. Devuelve false y un motivo si no hay una terminal utilizable.</summary>
    bool TryEscribir(string texto, out string? error);
}

/// <summary>Tipo de usuario para PasswordHasher (el formato V3 no usa sus datos), igual que en la API.</summary>
public sealed class UsuarioPanel;

/// <summary>Comandos de la herramienta (interfaz documentada en README.md).</summary>
public static partial class Comandos
{
    public const int CodigoOk = 0;
    public const int CodigoErrorUso = 1;
    public const int CodigoSinTerminal = 2;
    public const int CodigoErrorArchivo = 3;

    public const string Uso =
        "Uso:\n" +
        "  Cobranza.Herramientas hash-clave\n" +
        "      Genera una contrasena temporal (20 caracteres), la escribe SOLO en la terminal y deja en la\n" +
        "      salida estandar unicamente el hash PasswordHasher V3. Sin terminal utilizable, falla (codigo 2).\n" +
        "  Cobranza.Herramientas nueva-clave-api --consumidor <nombre> --salida-archivo <ruta>\n" +
        "      Genera una clave de API, la escribe SOLO en <ruta> (sin salto de linea final) y deja en la\n" +
        "      salida estandar unicamente: <prefijo> <hash SHA-256 en hexadecimal mayusculas>.\n";

    [GeneratedRegex("^[a-z0-9-]{3,50}$", RegexOptions.CultureInvariant)]
    private static partial Regex PatronConsumidor();

    public static int Ejecutar(string[] args, TextWriter stdout, TextWriter stderr, ITerminal terminal)
    {
        if (args.Length == 0) { stderr.Write(Uso); return CodigoErrorUso; }
        return args[0] switch
        {
            "hash-clave" when args.Length == 1 => HashClave(stdout, stderr, terminal),
            "nueva-clave-api" => NuevaClaveApi(args[1..], stdout, stderr),
            _ => Error(stderr, "Comando o argumentos no reconocidos.\n" + Uso, CodigoErrorUso),
        };
    }

    /// <summary>
    /// hash-clave: la contrasena va a la terminal; stdout solo lleva el hash. Si la terminal no esta
    /// disponible no se escribe nada en stdout (ADR 5.9: falla en lugar de escribir en stdout).
    /// </summary>
    public static int HashClave(TextWriter stdout, TextWriter stderr, ITerminal terminal)
    {
        var clave = GeneradorClaveTemporal.Generar();
        var hash = new PasswordHasher<UsuarioPanel>().HashPassword(new UsuarioPanel(), clave);

        var texto = "\nContrasena temporal (se muestra una sola vez; uso inmediato y cambio obligatorio):\n\n    "
                    + clave + "\n\n";
        if (!terminal.TryEscribir(texto, out var error))
            return Error(stderr, "No hay una terminal utilizable para mostrar la contrasena: " + error +
                                 "\nNo se genero ninguna salida. Ejecute el comando en una terminal interactiva.", CodigoSinTerminal);

        stdout.WriteLine(hash);
        stdout.Flush();
        return CodigoOk;
    }

    /// <summary>nueva-clave-api: la clave va solo al archivo; stdout solo lleva prefijo y hash.</summary>
    public static int NuevaClaveApi(string[] args, TextWriter stdout, TextWriter stderr)
    {
        string? consumidor = null, ruta = null;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--consumidor" when i + 1 < args.Length && consumidor is null: consumidor = args[++i]; break;
                case "--salida-archivo" when i + 1 < args.Length && ruta is null: ruta = args[++i]; break;
                default: return Error(stderr, $"Argumento no reconocido o repetido: {args[i]}\n" + Uso, CodigoErrorUso);
            }
        }
        if (consumidor is null || ruta is null)
            return Error(stderr, "Faltan --consumidor o --salida-archivo.\n" + Uso, CodigoErrorUso);
        if (!PatronConsumidor().IsMatch(consumidor))
            return Error(stderr, "El consumidor debe cumplir [a-z0-9-] y tener entre 3 y 50 caracteres.", CodigoErrorUso);

        var (clave, prefijo) = ClaveApiFormato.Generar();
        var hashHex = Convert.ToHexString(ClaveApiFormato.Hash(clave));

        try
        {
            var info = new FileInfo(ruta);
            if (Directory.Exists(ruta))
                return Error(stderr, "--salida-archivo indica un directorio.", CodigoErrorArchivo);
            if (info.Directory is null || !info.Directory.Exists)
                return Error(stderr, "El directorio de --salida-archivo no existe.", CodigoErrorArchivo);
            // Se admite un archivo vacio ya creado (mktemp); nunca se sobrescribe un archivo con contenido.
            if (info.Exists && info.Length > 0)
                return Error(stderr, "--salida-archivo ya existe y no esta vacio; no se sobrescribe.", CodigoErrorArchivo);

            using var fs = new FileStream(ruta, info.Exists ? FileMode.Truncate : FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(clave);   // sin BOM ni salto de linea
            fs.Write(bytes);
            fs.Flush(flushToDisk: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return Error(stderr, "No se pudo escribir --salida-archivo: " + ex.GetType().Name, CodigoErrorArchivo);
        }

        stdout.WriteLine($"{prefijo} {hashHex}");
        stdout.Flush();
        return CodigoOk;
    }

    private static int Error(TextWriter stderr, string mensaje, int codigo)
    {
        stderr.WriteLine(mensaje);
        stderr.Flush();
        return codigo;
    }
}

/// <summary>
/// Contrasena temporal (ADR 5.3, politica A.4): 20 caracteres con RandomNumberGenerator,
/// sin caracteres ambiguos (0, O, 1, l, I).
/// </summary>
public static class GeneradorClaveTemporal
{
    public const int Largo = 20;
    public const string Alfabeto = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

    public static string Generar() => RandomNumberGenerator.GetString(Alfabeto, Largo);
}
