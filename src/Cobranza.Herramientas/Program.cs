// Proyecto APT Cobranza Automatizada - Cobranza.Herramientas (ADR-001 5.9)
// Regla SEG-H01: solo la ejecuta un integrante humano en su propia terminal, nunca un agente.
namespace Cobranza.Herramientas;

internal static class Programa
{
    // Main explicito (sin sentencias de nivel superior) para no generar una clase Program global
    // que choque con la de Cobranza.Api en el proyecto de pruebas.
    private static int Main(string[] args) =>
        Comandos.Ejecutar(args, Console.Out, Console.Error, new TerminalSistema());
}
