using System.Security.Cryptography;
using System.Text;
using Cobranza.Api.Seguridad;
using Cobranza.Comun;
using Cobranza.Herramientas;
using Microsoft.AspNetCore.Identity;

namespace Cobranza.Api.Tests;

/// <summary>Sanitizacion (SEG-H07), formato de claves de API (5.3) y Cobranza.Herramientas (5.9).</summary>
public sealed class UnitariasTests
{
    [Theory]
    [InlineData("finanzas.demo", "finanzas.demo")]
    [InlineData("  Ventas_Demo-1 ", "ventas_demo-1")]
    [InlineData("ab", ServicioAutenticacion.UsuarioNoValido)]
    [InlineData("usuario con espacios", ServicioAutenticacion.UsuarioNoValido)]
    [InlineData("Clave#Secreta2026", ServicioAutenticacion.UsuarioNoValido)]
    [InlineData("usuário", ServicioAutenticacion.UsuarioNoValido)]
    [InlineData("", ServicioAutenticacion.UsuarioNoValido)]
    [InlineData(null, ServicioAutenticacion.UsuarioNoValido)]
    public void SanitizarUsuario(string? entrada, string esperado) =>
        Assert.Equal(esperado, ServicioAutenticacion.SanitizarUsuario(entrada));

    [Fact]
    public void SanitizarUsuario_MasDe50Caracteres_FormatoNoValido() =>
        Assert.Equal(ServicioAutenticacion.UsuarioNoValido, ServicioAutenticacion.SanitizarUsuario(new string('a', 51)));

    [Fact]
    public void ClaveApi_Formato_57Caracteres_PrefijoBase32_SecretoBase64Url()
    {
        for (var i = 0; i < 200; i++)
        {
            var (clave, prefijo) = ClaveApiFormato.Generar();
            Assert.Equal(57, clave.Length);
            Assert.Matches("^cobk_[a-z2-7]{8}_[A-Za-z0-9_-]{43}$", clave);
            Assert.True(ClaveApiFormato.TryObtenerPrefijo(clave, out var p));
            Assert.Equal(prefijo, p);
        }
    }

    [Fact]
    public void ClaveApi_Hash_EsSha256DeLaClaveCompletaEnUtf8()
    {
        var (clave, _) = ClaveApiFormato.Generar();
        Assert.Equal(SHA256.HashData(Encoding.UTF8.GetBytes(clave)), ClaveApiFormato.Hash(clave));
        Assert.Equal(32, ClaveApiFormato.Hash(clave).Length);
    }

    [Fact]
    public void ClaveTemporal_20Caracteres_SinAmbiguos()
    {
        for (var i = 0; i < 500; i++)
        {
            var c = GeneradorClaveTemporal.Generar();
            Assert.Equal(20, c.Length);
            Assert.DoesNotContain(c, ch => "0O1lI".Contains(ch));
            Assert.All(c, ch => Assert.Contains(ch, GeneradorClaveTemporal.Alfabeto));
        }
    }

    private sealed class TerminalFalsa(bool disponible) : ITerminal
    {
        public StringBuilder Texto { get; } = new();
        public bool TryEscribir(string texto, out string? error)
        {
            if (!disponible) { error = "sin terminal (simulado)"; return false; }
            Texto.Append(texto);
            error = null;
            return true;
        }
    }

    [Fact]
    public void HashClave_ContrasenaSoloEnTerminal_StdoutSoloElHash_QueLaApiVerifica()
    {
        var terminal = new TerminalFalsa(true);
        var stdout = new StringWriter();
        var stderr = new StringWriter();

        Assert.Equal(Comandos.CodigoOk, Comandos.Ejecutar(["hash-clave"], stdout, stderr, terminal));

        var hash = stdout.ToString().TrimEnd('\r', '\n');
        Assert.DoesNotContain('\n', hash);
        var clave = terminal.Texto.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim()).Single(l => l.Length == GeneradorClaveTemporal.Largo && !l.Contains(' '));
        Assert.DoesNotContain(clave, stdout.ToString());
        Assert.DoesNotContain(clave, stderr.ToString());
        // El hash lo verifica el mismo PasswordHasher que usa la API (formato V3).
        var resultado = new PasswordHasher<Cobranza.Api.Seguridad.UsuarioPanel>()
            .VerifyHashedPassword(new Cobranza.Api.Seguridad.UsuarioPanel(), hash, clave);
        Assert.Equal(PasswordVerificationResult.Success, resultado);
        Assert.Equal(0x01, Convert.FromBase64String(hash)[0]);   // marcador de formato V3
    }

    [Fact]
    public void HashClave_SinTerminal_Falla_YNoEscribeNadaEnStdout()
    {
        var stdout = new StringWriter();
        var stderr = new StringWriter();
        Assert.Equal(Comandos.CodigoSinTerminal, Comandos.Ejecutar(["hash-clave"], stdout, stderr, new TerminalFalsa(false)));
        Assert.Equal("", stdout.ToString());
        Assert.NotEmpty(stderr.ToString());
    }

    [Fact]
    public void NuevaClaveApi_ClaveSoloEnArchivo_StdoutPrefijoYHash()
    {
        var dir = Directory.CreateTempSubdirectory("cobranza-pruebas-");
        try
        {
            var ruta = Path.Combine(dir.FullName, "clave.tmp");
            File.WriteAllBytes(ruta, []);   // como mktemp: archivo vacio ya creado
            var stdout = new StringWriter();
            var stderr = new StringWriter();

            var codigo = Comandos.Ejecutar(["nueva-clave-api", "--consumidor", "ventas-demo", "--salida-archivo", ruta],
                stdout, stderr, new TerminalFalsa(false));

            Assert.Equal(Comandos.CodigoOk, codigo);
            var bytes = File.ReadAllBytes(ruta);
            Assert.NotEqual(0xEF, bytes[0]);                         // sin BOM
            var clave = Encoding.UTF8.GetString(bytes);
            Assert.False(clave.EndsWith('\n') || clave.EndsWith('\r')); // sin salto de linea final
            Assert.True(ClaveApiFormato.TryObtenerPrefijo(clave, out var prefijo));

            var partes = stdout.ToString().TrimEnd('\r', '\n').Split(' ');
            Assert.Equal(2, partes.Length);
            Assert.Equal(prefijo, partes[0]);
            Assert.Equal(Convert.ToHexString(ClaveApiFormato.Hash(clave)), partes[1]);
            Assert.Matches("^[0-9A-F]{64}$", partes[1]);
            Assert.DoesNotContain(clave, stdout.ToString());
            Assert.DoesNotContain(clave[14..], stdout.ToString());     // ni siquiera el secreto
        }
        finally { dir.Delete(recursive: true); }
    }

    [Fact]
    public void NuevaClaveApi_NoSobrescribeArchivoConContenido()
    {
        var dir = Directory.CreateTempSubdirectory("cobranza-pruebas-");
        try
        {
            var ruta = Path.Combine(dir.FullName, "existente.txt");
            File.WriteAllText(ruta, "contenido previo");
            var stdout = new StringWriter();
            var codigo = Comandos.Ejecutar(["nueva-clave-api", "--consumidor", "ventas-demo", "--salida-archivo", ruta],
                stdout, new StringWriter(), new TerminalFalsa(false));
            Assert.Equal(Comandos.CodigoErrorArchivo, codigo);
            Assert.Equal("contenido previo", File.ReadAllText(ruta));
            Assert.Equal("", stdout.ToString());
        }
        finally { dir.Delete(recursive: true); }
    }

    [Theory]
    [InlineData("nueva-clave-api", "--consumidor", "Ventas_Demo", "--salida-archivo", "x")]
    [InlineData("nueva-clave-api", "--consumidor", "ventas-demo")]
    [InlineData("nueva-clave-api", "--salida-archivo", "x")]
    [InlineData("hash-clave", "--extra")]
    [InlineData("otro-comando")]
    public void ArgumentosInvalidos_ErrorDeUso_SinStdout(params string[] args)
    {
        var stdout = new StringWriter();
        Assert.Equal(Comandos.CodigoErrorUso, Comandos.Ejecutar(args, stdout, new StringWriter(), new TerminalFalsa(true)));
        Assert.Equal("", stdout.ToString());
    }

    [Fact]
    public void OpcionesSeguridad_Coherentes()
    {
        var o = new OpcionesSeguridad
        {
            LongitudMinimaClave = 12, LongitudMaximaClave = 128, MinutosRevalidacionSesion = 5,
            MinutosInactividadSesion = 30, HorasMaximasSesion = 8,
        };
        Assert.True(OpcionesSeguridad.Coherentes(o));
        o.LongitudMinimaClave = 129;
        Assert.False(OpcionesSeguridad.Coherentes(o));
    }

    [Theory]
    [InlineData("https://c.blob.core.windows.net/dataprotection-keys/keys.xml", "https://kv.vault.azure.net/keys/dataprotection-cobranza-api", true)]
    [InlineData("PENDIENTE: lo define infra/main.bicep", "https://kv.vault.azure.net/keys/k", false)]
    [InlineData("https://c.blob.core.windows.net/d/keys.xml", "", false)]
    [InlineData(null, null, false)]
    public void OpcionesDataProtection_Validas(string? blob, string? clave, bool esperado) =>
        Assert.Equal(esperado, new OpcionesDataProtection { BlobUri = blob, KeyIdentifier = clave }.Validas() is not null);
}
