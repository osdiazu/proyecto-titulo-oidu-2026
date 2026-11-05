# Paquete de contexto para Claude Code — Cobranza Automatizada

## Contenido

```
CLAUDE.md                     Contexto maestro (leído automáticamente por Claude Code)
.claude/agents/arquitecto.md  Diseño, impacto y ADR
.claude/agents/devops.md      Bicep, scripts, publicación, CI/CD
.claude/agents/desarrollador.md  API y Functions .NET 10
.claude/agents/dba.md         Esquema cob, permisos, respaldo
.claude/agents/seguridad.md   Red privada, identidad, endurecimiento, WAF (sugerido)
.claude/agents/qa.md          Revisión independiente, nunca modifica
.claude/settings.json         Permite compilar y validar sin preguntar; bloquea borrados en Azure;
                              pide confirmación para desplegar o cambiar recursos
PRIMERA_TAREA.md              Instrucciones listas para pegar (tareas 1, 2 y 3)
docs/                         Documentación del proyecto (ver docs/00_INDICE.md)
```

## Instalación

1. Descomprimir el código de `Repositorio_Cobranza_Automatizada_S10-S15.zip` (y los cambios de `Implementacion_S10_Anexos.zip`) en una carpeta, por ejemplo `cobranza-automatizada/`.
2. Copiar encima el contenido de este paquete (CLAUDE.md, `.claude/`, `docs/`, `LEEME.md`, `.gitignore`). Si ya existe `docs/GUIA_DESPLIEGUE.md`, se conserva; no hay archivos con el mismo nombre.
3. Inicializar git si no existe: `git init` y un primer commit, para que QA pueda revisar con `git diff`.
4. Abrir la carpeta en VS Code con la extensión de Claude Code y verificar que los agentes aparecen con el comando `/agents`.
5. Crear la carpeta `evidencias/` (los agentes guardan ahí sus salidas).

## Herramientas requeridas en el equipo

Azure CLI con Bicep (referencia 0.48.1), SDK de .NET 10, Azure Functions Core Tools, `sqlcmd` (compatible con autenticación Entra ID), ShellCheck, Python 3, git.

Los scripts de `scripts/` son bash. En Windows deben ejecutarse desde WSL o Git Bash; Claude Code debe abrirse en esa misma terminal para que los agentes puedan ejecutarlos. Las versiones instaladas deben registrarse (tabla 3.3 del documento de implementación, PENDIENTE).

## Cómo trabajar

La sesión principal de Claude Code es el orquestador. Ejemplo de primera instrucción:

> Lee CLAUDE.md. Usa el agente desarrollador para compilar la solución completa y registrar los errores; luego usa el agente qa para revisar el resultado.

Para una tarea de despliegue:

> Usa el agente arquitecto para validar el plan de despliegue de la semana 11, luego devops para ejecutar bicep build, lint y what-if, y qa para revisar. No ejecutes nada en Azure sin mi confirmación.

## Orquestador humano

Claude Code no decide quién del equipo aprueba. Se recomienda definir una persona que apruebe cada acción en Azure y registrarla en la sección 10 de `CLAUDE.md`. En la Guía Fase 1 el rol de Líder de Proyecto corresponde a Arnaldo Muñoz González; la decisión final es del equipo.
