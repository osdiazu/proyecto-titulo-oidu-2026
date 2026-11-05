# Registro de errores de compilación - 2026-11-05

Alcance: validación local en la estación de trabajo del equipo. No se desplegó nada en Azure ni se ejecutó ninguna acción contra recursos de Azure o la base de datos real.

## 1. Cambio realizado

Motivo: los comentarios XML no pueden contener la secuencia `--`. La línea 5 de dos archivos `.csproj` la incluía (`--outdated`) dentro del comentario de cabecera, por lo que MSBuild no podía leer los proyectos.

Corrección: se reemplazó `"dotnet list package --outdated"` por `"dotnet list package" con la opcion outdated`. No se modificó ninguna otra línea; se mantuvieron la codificación (ASCII, sin BOM) y los finales de línea (LF).

| Archivo | Línea | Cambio |
| --- | --- | --- |
| `src/Cobranza.Api/Cobranza.Api.csproj` | 5 | Eliminado `--` del comentario |
| `src/Cobranza.Functions/Cobranza.Functions.csproj` | 5 | Eliminado `--` del comentario |

Nota sobre el diff: en git, la carpeta `src/` está sin seguimiento (los archivos versionados en HEAD están en `Repositorio_Cobranza_Automatizada_S10-S15/` y aparecen como eliminados), así que `git diff` sobre estas rutas no muestra nada. Por eso el diff se obtuvo con `git diff --no-index` contra la versión de HEAD (`git show HEAD:Repositorio_Cobranza_Automatizada_S10-S15/src/...`).

```diff
--- a/Repositorio_Cobranza_Automatizada_S10-S15/src/Cobranza.Api/Cobranza.Api.csproj (HEAD)
+++ b/src/Cobranza.Api/Cobranza.Api.csproj
@@ -2,7 +2,7 @@
   <!--
     Proyecto APT Cobranza Automatizada - API interna de consulta (Evidencia S11)
     Azure App Service Linux, runtime DOTNETCORE|10.0.
-    Versiones de paquetes a confirmar con "dotnet list package --outdated";
+    Versiones de paquetes a confirmar con "dotnet list package" con la opcion outdated;
     el proyecto no se compilo en el entorno de redaccion.
   -->
   <PropertyGroup>

--- a/Repositorio_Cobranza_Automatizada_S10-S15/src/Cobranza.Functions/Cobranza.Functions.csproj (HEAD)
+++ b/src/Cobranza.Functions/Cobranza.Functions.csproj
@@ -2,7 +2,7 @@
   <!--
     Proyecto APT Cobranza Automatizada - Jobs en segundo plano (Evidencia S10)
     Azure Functions v4, modelo de trabajo aislado, .NET 10.
-    Las versiones de paquetes deben confirmarse con "dotnet list package --outdated"
+    Las versiones de paquetes deben confirmarse con "dotnet list package" con la opcion outdated
     antes de la primera compilacion; no se compilo en el entorno de redaccion.
   -->
   <PropertyGroup>
```

## 2. Entorno (según `dotnet --info`)

- SO: Windows 10.0.26200 (Windows 11 Pro), RID win-x64.
- SDK de .NET: 10.0.303 (MSBuild 18.6.14). Host/runtime: 10.0.11.
- Runtimes instalados: Microsoft.NETCore.App 3.1.8, 8.0.33, 10.0.11; Microsoft.AspNetCore.App 10.0.11.
- Workloads: ninguno.
- Variables usadas en la ejecución: `DOTNET_CLI_TELEMETRY_OPTOUT=1`, `DOTNET_NOLOGO=1`.

## 3. Resultado de los comandos

Ejecutados desde la raíz del repositorio sobre `Cobranza.slnx` (contiene Cobranza.Comun, Cobranza.Functions y Cobranza.Api).

| Comando | Código de salida | Errores | Advertencias | Evidencia |
| --- | --- | --- | --- | --- |
| `dotnet --info` | 0 | 0 | 0 | `2026-11-05_dotnet_info.txt` |
| `dotnet restore Cobranza.slnx` | 1 | 4 (NU1902 y NU1903 en Api y Functions) | 0 | `2026-11-05_restore.txt` |
| `dotnet build Cobranza.slnx --no-restore` | 1 | 3 | 0 | `2026-11-05_build.txt` |
| `dotnet test Cobranza.slnx --no-build` | 0 | 0 | 0 | `2026-11-05_test.txt` (vacío) |

Notas:
- Solo Cobranza.Comun compiló (`Cobranza.Comun.dll`).
- `dotnet test` devolvió 0 sin salida porque la solución no contiene proyectos de prueba y la carpeta `tests/` no existe. No se ejecutó ninguna prueba; el 0 no significa que las pruebas pasaron.

## 4. Errores restantes (no corregidos)

| # | Código | Archivo:línea | Mensaje | Proyecto | Causa probable |
| --- | --- | --- | --- | --- | --- |
| 1 | NU1902 | `src/Cobranza.Api/Cobranza.Api.csproj` | Advertencia como error: el paquete "System.Security.Cryptography.Pkcs" 9.0.0 tiene una vulnerabilidad de gravedad moderada conocida (GHSA-2fmv-rv2c-59x7) | Cobranza.Api | Dependencia transitiva de `Microsoft.Data.SqlClient` 6.0.1; `TreatWarningsAsErrors=true` la convierte en error |
| 2 | NU1903 | `src/Cobranza.Api/Cobranza.Api.csproj` | Advertencia como error: el paquete "System.Security.Cryptography.Pkcs" 9.0.0 tiene una vulnerabilidad de gravedad alta conocida (GHSA-846f-f764-76mx) | Cobranza.Api | Igual que el número 1 |
| 3 | NU1902 | `src/Cobranza.Functions/Cobranza.Functions.csproj` | Igual que el número 1 (solo en restore) | Cobranza.Functions | Igual que el número 1 |
| 4 | NU1903 | `src/Cobranza.Functions/Cobranza.Functions.csproj` | Igual que el número 2 (solo en restore) | Cobranza.Functions | Igual que el número 1 |
| 5 | (sin código) | `Microsoft.Azure.Functions.Worker.Sdk.targets(78,5)` (paquete 2.0.0) | Invalid combination of TargetFramework and AzureFunctionsVersion is set. | Cobranza.Functions | La versión 2.0.0 de `Microsoft.Azure.Functions.Worker.Sdk` probablemente no reconoce `net10.0` con `AzureFunctionsVersion` v4 |

Como la restauración falló en Api y Functions, puede haber errores de compilación de C# que todavía no aparecen. Se verán cuando se resuelvan los errores anteriores.

## 5. Estado

- Validado localmente: no (la compilación falla en 2 de 3 proyectos).
- Desplegado en Azure: no.
