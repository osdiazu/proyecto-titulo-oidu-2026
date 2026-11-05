# Primera tarea para Claude Code

Requisitos previos:
- El repositorio S10-S15 está descomprimido.
- Este paquete está copiado encima.
- La carpeta está abierta en VS Code.

Copiar y pegar en Claude Code:

```
Lee CLAUDE.md completo. Esta tarea es solo local: no ejecutes ningún comando contra Azure.

1. Usa el agente arquitecto para hacer un inventario del repositorio y compararlo con la
   sección 7 de CLAUDE.md ("Estructura de repositorio esperada"). Entrega:
   - Archivos esperados que existen y que faltan.
   - Archivos presentes que CLAUDE.md no menciona.
   - Respuesta a los PENDIENTE que se resuelven leyendo el repositorio: nombre del proyecto
     de Functions en src/, ubicación de s12_endurecer.sh y nombres completos de los scripts
     SQL 00 a 11.
   No edites CLAUDE.md; propón los cambios y espera mi aprobación.

2. Registra el sistema operativo y las versiones instaladas de: az, bicep, dotnet,
   func (Azure Functions Core Tools), sqlcmd, shellcheck, python3 y git. Guárdalas en
   evidencias/AAAA-MM-DD_versiones_herramientas.txt. Si alguna no está instalada, indícalo
   y no la instales sin preguntarme.

3. Usa el agente desarrollador para ejecutar dotnet restore, dotnet build y dotnet test sobre
   toda la solución. Solo registra los errores, sin corregir nada todavía. Clasifícalos por
   proyecto y por causa. Guarda la salida en evidencias/desarrollo/.

4. Usa el agente devops para ejecutar bicep build, bicep lint y bicep build-params de infra/,
   y bash -n y shellcheck de scripts/. Guarda la salida en evidencias/devops/.

5. Usa el agente qa para revisar los pasos 1 a 4 y emitir su informe con veredicto.

Al final dame un resumen con: qué falta en el repositorio, cuántos errores de compilación
hay y cuál sería el orden recomendado para corregirlos.
```

Segunda tarea (después de revisar el resultado):

```
Usa el agente desarrollador para corregir los errores de compilación en el orden recomendado,
sin cambiar contratos ni lógica de negocio salvo que sea necesario para compilar. Si un cambio
afecta reglas D4, D6 o procedimientos SQL, detente y pregúntame. Luego dotnet build y dotnet
test, y que qa revise.
```

Tercera tarea (requiere la suscripción de Azure y el Object ID del grupo grp-cobranza-sql-admin):

```
Usa el agente devops para completar infra/main.bicepparam con los valores que te entregaré y
ejecutar az deployment group what-if contra rg-cobranza-apt. No ejecutes create. Que arquitecto
y qa revisen el resultado del what-if.
```
