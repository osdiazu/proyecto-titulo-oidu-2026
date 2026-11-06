using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Cobranza.Herramientas;

/// <summary>
/// Escribe directamente en la terminal del operador, sin pasar por la salida estandar
/// (ADR-001 5.9, politica A.4 regla 2).
/// - Linux y macOS: /dev/tty (terminal de control del proceso).
/// - Windows: CONOUT$ (bufer de pantalla de la consola), solo si la entrada estandar es una consola
///   real. En Git Bash (mintty) sin pseudoconsola (ConPTY) la entrada estandar es una tuberia y la
///   consola del proceso es invisible: en ese caso el comando FALLA en vez de escribir en un lugar
///   que el operador no ve o en la salida estandar. Si la version instalada de Git Bash usa ConPTY:
///   PENDIENTE de verificacion por un integrante humano (README.md, seccion Verificacion).
/// </summary>
public sealed class TerminalSistema : ITerminal
{
    public bool TryEscribir(string texto, out string? error)
    {
        error = null;
        try
        {
            if (OperatingSystem.IsWindows()) return EscribirWindows(texto, out error);

            using var tty = new FileStream("/dev/tty", FileMode.Open, FileAccess.Write, FileShare.ReadWrite);
            var bytes = new UTF8Encoding(false).GetBytes(texto);
            tty.Write(bytes);
            tty.Flush();
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            error = "no se pudo abrir /dev/tty (" + ex.GetType().Name + ").";
            return false;
        }
    }

    [SupportedOSPlatform("windows")]
    private static bool EscribirWindows(string texto, out string? error)
    {
        error = null;
        if (Console.IsInputRedirected)
        {
            error = "la entrada estandar no es una consola (por ejemplo, Git Bash/mintty sin pseudoconsola o entrada redirigida).";
            return false;
        }

        using var handle = NativoWindows.CreateFileW("CONOUT$", NativoWindows.GenericRead | NativoWindows.GenericWrite,
            NativoWindows.FileShareRead | NativoWindows.FileShareWrite, IntPtr.Zero, NativoWindows.OpenExisting, 0, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            error = "no se pudo abrir CONOUT$ (error " + Marshal.GetLastPInvokeError() + ").";
            return false;
        }

        // Texto solo ASCII (la contrasena usa un alfabeto ASCII): independiente de la pagina de codigos.
        var bytes = Encoding.ASCII.GetBytes(texto.Replace("\n", "\r\n", StringComparison.Ordinal));
        if (!NativoWindows.WriteFile(handle, bytes, bytes.Length, out var escritos, IntPtr.Zero) || escritos != bytes.Length)
        {
            error = "no se pudo escribir en CONOUT$ (error " + Marshal.GetLastPInvokeError() + ").";
            return false;
        }
        return true;
    }
}

[SupportedOSPlatform("windows")]
internal static class NativoWindows
{
    public const uint GenericRead = 0x80000000;
    public const uint GenericWrite = 0x40000000;
    public const uint FileShareRead = 0x00000001;
    public const uint FileShareWrite = 0x00000002;
    public const uint OpenExisting = 3;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WriteFile(SafeFileHandle hFile, byte[] lpBuffer, int nNumberOfBytesToWrite,
        out int lpNumberOfBytesWritten, IntPtr lpOverlapped);
}
