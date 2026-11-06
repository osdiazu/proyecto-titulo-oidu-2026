using System.Collections.Concurrent;
using System.Security.Cryptography;
using Cobranza.Api.Datos;
using Cobranza.Api.Seguridad;
using Cobranza.Comun;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Logging;

namespace Cobranza.Api.Tests;

/// <summary>Reloj controlable por las pruebas (cookies, bloqueo, vigencias y cache).</summary>
public sealed class RelojFalso : TimeProvider
{
    private DateTimeOffset _ahora = new(2026, 11, 6, 15, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset GetUtcNow() { lock (this) return _ahora; }
    public void Avanzar(TimeSpan t) { lock (this) _ahora += t; }
}

/// <summary>PasswordHasher real que cuenta las verificaciones (iguala el costo de todos los fallos).</summary>
public sealed class HasherContador : IPasswordHasher<UsuarioPanel>
{
    private readonly PasswordHasher<UsuarioPanel> _real = new();
    private int _verificaciones;
    public int Verificaciones => Volatile.Read(ref _verificaciones);
    public string HashPassword(UsuarioPanel user, string password) => _real.HashPassword(user, password);
    public PasswordVerificationResult VerifyHashedPassword(UsuarioPanel user, string hashedPassword, string providedPassword)
    {
        Interlocked.Increment(ref _verificaciones);
        return _real.VerifyHashedPassword(user, hashedPassword, providedPassword);
    }
}

public sealed record EventoAcceso(string Evento, string? Motivo, int? UsuarioId, string? UsuarioIngresado, string? Ip, string? Agente);

/// <summary>Estado mutable de un usuario simulado (equivale a una fila de cob.UsuarioInterno).</summary>
public sealed class FilaUsuario
{
    public int UsuarioId { get; init; }
    public required string Usuario { get; init; }
    public required string Nombre { get; init; }
    public required string Rol { get; set; }
    public bool Activo { get; set; } = true;
    public required string HashClave { get; set; }
    public bool DebeCambiarClave { get; set; }
    public short IntentosFallidos { get; set; }
    public DateTime? BloqueadoHasta { get; set; }
    public DateTime? FechaCambioClave { get; set; }
    public Guid Sello { get; set; } = Guid.NewGuid();
}

public sealed class FilaClaveApi
{
    public int ClaveApiId { get; init; }
    public required string Prefijo { get; init; }
    public required byte[] Hash { get; init; }
    public required string Consumidor { get; init; }
    public string Rol { get; init; } = Roles.Ventas;
    public bool Activa { get; set; } = true;
    public DateTime FechaVencimiento { get; set; }
    public DateTime? FechaRevocacion { get; set; }
}

/// <summary>
/// Simula los procedimientos de sql/12 con la semantica de ADR-001 5.2. Registra todo argumento de
/// texto recibido para verificar que la API nunca envia contrasenas ni claves en texto plano.
/// </summary>
public sealed class RepositorioUsuariosFalso(TimeProvider reloj) : IRepositorioUsuarios
{
    private readonly object _l = new();
    public List<FilaUsuario> Usuarios { get; } = [];
    public List<FilaClaveApi> Claves { get; } = [];
    public List<EventoAcceso> Eventos { get; } = [];
    public ConcurrentBag<string> ArgumentosTexto { get; } = [];
    public int LlamadasValidarClave;
    public int LlamadasObtenerPorId;
    public bool FallarObtenerPorId { get; set; }
    /// <summary>Simula el THROW 50061 de sp_RegistrarLoginExitoso (D-5 de sql/12).</summary>
    public bool UsuarioNoExisteEnLoginExitoso { get; set; }

    private DateTime Ahora => reloj.GetUtcNow().UtcDateTime;

    public FilaUsuario Agregar(string usuario, string rol, string clave, bool debeCambiar = false, DateTime? fechaCambio = null)
    {
        lock (_l)
        {
            var f = new FilaUsuario
            {
                UsuarioId = Usuarios.Count + 1, Usuario = usuario, Nombre = "Nombre " + usuario, Rol = rol,
                HashClave = new PasswordHasher<UsuarioPanel>().HashPassword(new UsuarioPanel(), clave),
                DebeCambiarClave = debeCambiar, FechaCambioClave = fechaCambio ?? Ahora,
            };
            Usuarios.Add(f);
            return f;
        }
    }

    public (string Clave, FilaClaveApi Fila) AgregarClave(string consumidor = "ventas-demo", TimeSpan? vigencia = null)
    {
        var (clave, prefijo) = ClaveApiFormato.Generar();
        lock (_l)
        {
            var f = new FilaClaveApi
            {
                ClaveApiId = Claves.Count + 1, Prefijo = prefijo, Hash = ClaveApiFormato.Hash(clave),
                Consumidor = consumidor, FechaVencimiento = Ahora + (vigencia ?? TimeSpan.FromDays(30)),
            };
            Claves.Add(f);
            return (clave, f);
        }
    }

    public FilaUsuario Fila(string usuario) { lock (_l) return Usuarios.Single(u => u.Usuario == usuario); }

    private void Anotar(params string?[] textos) { foreach (var t in textos) if (t is not null) ArgumentosTexto.Add(t); }

    private static UsuarioInterno Copia(FilaUsuario f, bool hash) => new(f.UsuarioId, f.Usuario, f.Nombre, f.Rol, f.Activo,
        hash ? f.HashClave : null, f.DebeCambiarClave, f.IntentosFallidos, f.BloqueadoHasta, f.Sello, f.FechaCambioClave);

    public Task<UsuarioInterno?> ObtenerUsuarioParaLoginAsync(string usuario, CancellationToken ct)
    {
        Anotar(usuario);
        lock (_l)
        {
            var f = Usuarios.SingleOrDefault(u => string.Equals(u.Usuario, usuario, StringComparison.OrdinalIgnoreCase));
            return Task.FromResult(f is null ? null : Copia(f, hash: true));
        }
    }

    public Task<UsuarioInterno?> ObtenerUsuarioPorIdAsync(int usuarioId, bool incluirHash, CancellationToken ct)
    {
        Interlocked.Increment(ref LlamadasObtenerPorId);
        if (FallarObtenerPorId) throw new InvalidOperationException("Base no disponible (simulado).");
        lock (_l)
        {
            var f = Usuarios.SingleOrDefault(u => u.UsuarioId == usuarioId);
            return Task.FromResult(f is null ? null : Copia(f, incluirHash));
        }
    }

    public Task RegistrarLoginFallidoAsync(int? usuarioId, string usuarioIngresado, string motivo, string? ipOrigen,
        string? agenteUsuario, short maxIntentos, int minutosBloqueo, CancellationToken ct)
    {
        Anotar(usuarioIngresado, motivo, ipOrigen, agenteUsuario);
        lock (_l)
        {
            Eventos.Add(new EventoAcceso("LoginFallido", motivo, usuarioId, usuarioIngresado, ipOrigen, agenteUsuario));
            // Semantica de sql/12: con ClaveIncorrecta reinicia si el bloqueo vencio (BloqueadoHasta <= ahora),
            // suma 1 y, si llega al maximo, bloquea desde ahora. Si la cuenta YA esta bloqueada, el
            // bloqueo se extiende (desviacion D-12): por eso la API nunca debe enviar ClaveIncorrecta
            // para una cuenta bloqueada.
            if (usuarioId is { } id && motivo == MotivosLogin.ClaveIncorrecta)
            {
                var f = Usuarios.Single(u => u.UsuarioId == id);
                if (f.BloqueadoHasta is { } b && b <= Ahora) { f.IntentosFallidos = 0; f.BloqueadoHasta = null; }
                f.IntentosFallidos++;
                if (f.IntentosFallidos >= maxIntentos)
                {
                    f.BloqueadoHasta = Ahora.AddMinutes(minutosBloqueo);
                    Eventos.Add(new EventoAcceso("CuentaBloqueada", null, id, usuarioIngresado, ipOrigen, agenteUsuario));
                }
            }
        }
        return Task.CompletedTask;
    }

    public Task RegistrarLoginExitosoAsync(int usuarioId, string? ipOrigen, string? agenteUsuario, string? hashClaveNuevo, CancellationToken ct)
    {
        Anotar(ipOrigen, agenteUsuario, hashClaveNuevo);
        if (UsuarioNoExisteEnLoginExitoso) throw new UsuarioNoEncontradoException();
        lock (_l)
        {
            var f = Usuarios.Single(u => u.UsuarioId == usuarioId);
            f.IntentosFallidos = 0;
            f.BloqueadoHasta = null;
            if (hashClaveNuevo is not null) f.HashClave = hashClaveNuevo;
            Eventos.Add(new EventoAcceso("LoginExitoso", null, usuarioId, null, ipOrigen, agenteUsuario));
        }
        return Task.CompletedTask;
    }

    public Task RegistrarLogoutAsync(int usuarioId, string? ipOrigen, string? agenteUsuario, CancellationToken ct)
    {
        Anotar(ipOrigen, agenteUsuario);
        lock (_l) Eventos.Add(new EventoAcceso("Logout", null, usuarioId, null, ipOrigen, agenteUsuario));
        return Task.CompletedTask;
    }

    public Task CambiarClaveAsync(int usuarioId, Guid selloActual, string hashClaveNuevo, string? ipOrigen, string? agenteUsuario, CancellationToken ct)
    {
        Anotar(hashClaveNuevo, ipOrigen, agenteUsuario);
        lock (_l)
        {
            var f = Usuarios.Single(u => u.UsuarioId == usuarioId);
            if (!f.Activo || f.Sello != selloActual) throw new CambioClaveRechazadoException();
            f.HashClave = hashClaveNuevo;
            f.DebeCambiarClave = false;
            f.FechaCambioClave = Ahora;
            f.Sello = Guid.NewGuid();
            Eventos.Add(new EventoAcceso("CambioClave", null, usuarioId, null, ipOrigen, agenteUsuario));
        }
        return Task.CompletedTask;
    }

    public Task<ClaveApiValida?> ValidarClaveApiAsync(string prefijo, byte[] hashClave, CancellationToken ct)
    {
        Interlocked.Increment(ref LlamadasValidarClave);
        Anotar(prefijo);
        lock (_l)
        {
            var c = Claves.SingleOrDefault(k => k.Prefijo == prefijo && CryptographicOperations.FixedTimeEquals(k.Hash, hashClave)
                                               && k.Activa && k.FechaRevocacion is null && k.FechaVencimiento > Ahora);
            return Task.FromResult(c is null ? null : new ClaveApiValida(c.ClaveApiId, c.Consumidor, c.Rol));
        }
    }

    public EventoAcceso[] EventosCopia() { lock (_l) return [.. Eventos]; }
}

/// <summary>Consultas de negocio simuladas (datos ficticios).</summary>
public sealed class RepositorioConsultasFalso : IRepositorioConsultas
{
    public Task<EstadoClienteDto?> EstadoClienteAsync(string rut, CancellationToken ct) =>
        Task.FromResult<EstadoClienteDto?>(new EstadoClienteDto(rut, "Cliente DEMO", "Tradicional", "Credito30",
            "AlDia", null, true, 0, 0, 0m, 0m, 0));

    public Task<IReadOnlyList<PedidoDto>> PedidosClienteAsync(string rut, string? estado, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<PedidoDto>>([]);

    public Task<IndicadoresCarteraDto> IndicadoresAsync(CancellationToken ct) =>
        Task.FromResult(new IndicadoresCarteraDto(1, 1, 0, 0, 0, 0m, 0m, 0m, 0m, 0, 0, 0, 0, null, null));

    public Task<IReadOnlyList<SincronizacionDto>> SincronizacionesAsync(int top, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<SincronizacionDto>>([]);

    public Task<bool> SaludAsync(CancellationToken ct) => Task.FromResult(true);
}

/// <summary>Proveedor de logs que guarda todos los mensajes (para verificar que no se registran secretos).</summary>
public sealed class ProveedorLogCapturado : ILoggerProvider
{
    public ConcurrentQueue<string> Mensajes { get; } = new();
    public ILogger CreateLogger(string categoryName) => new Registro(this, categoryName);
    public void Dispose() { }

    private sealed class Registro(ProveedorLogCapturado p, string categoria) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter) =>
            p.Mensajes.Enqueue($"{categoria}|{logLevel}|{formatter(state, exception)}|{exception}");
    }
}
