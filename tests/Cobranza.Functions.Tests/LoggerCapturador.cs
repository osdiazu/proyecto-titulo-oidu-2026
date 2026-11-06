using Microsoft.Extensions.Logging;

namespace Cobranza.Functions.Tests;

internal sealed class LoggerCapturador<T> : ILogger<T>
{
    public List<(LogLevel Nivel, EventId Evento, string Mensaje)> Entradas { get; } = [];

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(LogLevel logLevel) => true;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
        Func<TState, Exception?, string> formatter) =>
        Entradas.Add((logLevel, eventId, formatter(state, exception)));
}
