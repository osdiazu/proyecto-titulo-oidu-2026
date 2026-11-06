# 2026-11-05 Desarrollo: build en verde (NU1902/NU1903) y M-05 (429 de ACS)

Agente: `desarrollador`. Estado: validado localmente (build y pruebas unitarias). Nada desplegado ni ejecutado contra Azure. Sin commit. Sin cambios en `sql/`, `infra/`, `scripts/`, `docs/` ni CLAUDE.md. No se tocaron `src/Cobranza.Api/Seguridad/` ni `wwwroot/`.

Entorno: Windows 11 Pro 10.0.26200, SDK .NET 10.0.303 (ver `evidencias/desarrollo/2026-11-05_dotnet_info.txt`).

## 1. Resultado

| Comando | Salida | Resultado |
| --- | --- | --- |
| `dotnet restore Cobranza.slnx --force` | `01_restore.txt` | exit 0, 4 proyectos |
| `dotnet build Cobranza.slnx --no-restore --no-incremental` | `02_build.txt` | exit 0, 0 advertencias, 0 errores (`TreatWarningsAsErrors=true`, sin NoWarn) |
| `dotnet test Cobranza.slnx --no-build` | `03_test.txt` | exit 0, 23 de 23 correctas |
| `dotnet list Cobranza.slnx package --vulnerable --include-transitive` | `04_paquetes_vulnerables.txt` | ningún proyecto con paquetes vulnerables |
| `dotnet list Cobranza.slnx package` | `05_paquetes.txt` | inventario de paquetes directos |

## 2. Paquetes

| Proyecto | Paquete | Anterior | Nueva | Motivo |
| --- | --- | --- | --- | --- |
| Api, Functions | System.Security.Cryptography.Pkcs (transitivo de Microsoft.Data.SqlClient 6.0.1, ahora referencia directa) | 9.0.0 | 9.0.21 | GHSA-846f-f764-76mx (CVE-2026-84008, alta, DoS) y GHSA-2fmv-rv2c-59x7 (CVE-2026-70162, moderada, DoS). Rango vulnerable 9.0.0 a 9.0.20; primera versión parcheada de la rama 9.x: 9.0.21 |
| Functions | Microsoft.Azure.Functions.Worker.Sdk | 2.0.0 | 2.0.5 | 2.0.0 no reconoce `net10.0` (error "Invalid combination of TargetFramework and AzureFunctionsVersion"). El `net10-isolated` aparece en el .targets desde 2.0.3; se usa 2.0.5 como mínimo para .NET 10 según la documentación de Microsoft (dato no reverificado en esta sesión) |
| Functions | Microsoft.Azure.Functions.Worker | 2.0.0 | 2.50.0 | Primera versión con activos `net10.0` (2.0.0 a 2.2.0 llegan solo hasta net9.0) |
| Functions | Microsoft.Extensions.Options.DataAnnotations | (no estaba) | 10.0.0 | `ValidateDataAnnotations()` de `Program.cs` no compilaba (CS1061); alineado con Microsoft.Extensions.Options 10.0.0 que trae Worker 2.50.0 |
| Tests | Microsoft.NET.Test.Sdk / xunit / xunit.runner.visualstudio | (nuevo) | 18.11.0 / 2.9.3 / 3.1.5 | Proyecto de pruebas nuevo |

Alternativa no aplicada para Pkcs: subir Microsoft.Data.SqlClient a 6.1.8 (primera que depende de Pkcs 9.0.21). Se descartó en esta ronda para no cambiar el cliente SQL antes del primer despliegue. El comentario del csproj indica que hay que retirar la referencia fija cuando se actualice SqlClient.

## 3. Cambios por archivo

| Archivo:línea | Cambio | Motivo |
| --- | --- | --- |
| `src/Cobranza.Api/Cobranza.Api.csproj:19-23` | Referencia directa a Pkcs 9.0.21, con comentario | NU1902/NU1903 |
| `src/Cobranza.Functions/Cobranza.Functions.csproj:19-20` | Worker 2.50.0, Worker.Sdk 2.0.5 | Soporte net10.0 |
| `src/Cobranza.Functions/Cobranza.Functions.csproj:25-26` | Options.DataAnnotations 10.0.0 | CS1061 en `Program.cs` |
| `src/Cobranza.Functions/Cobranza.Functions.csproj:28-32` | Referencia directa a Pkcs 9.0.21 | NU1902/NU1903 |
| `src/Cobranza.Functions/Funciones/NotificacionesFunction.cs` (completo; 429 en 65-78; otros errores en 79-85; pausa en 47-48) | Captura `RequestFailedException` con filtro `LimiteAcs.EsRechazoPorLimite`. En un 429 no llama a `sp_RegistrarNotificacion` (no suma `Intentos`), registra un Warning con EventId 4290 `LimiteAcs429` (factura, tipo, diferidos y Retry-After) y corta el lote con `break`. Los demás errores siguen igual: `Fallido` y continúa. La pausa ahora va solo entre envíos y usa `TimeProvider`. Nuevo `ProcesarAsync` devuelve `ResultadoNotificaciones` | M-05 (c) |
| `src/Cobranza.Functions/Servicios/LimiteAcs.cs` (nuevo) | Detección del 429 (Status 429 o ErrorCode `TooManyRequests`), lectura de `retry-after-ms`, `x-ms-retry-after-ms` y `Retry-After` (segundos o fecha HTTP), y `PoliticaReintentoSinLimite`, que mantiene los reintentos de Azure.Core salvo para el 429 | Evita que el SDK espere el Retry-After dentro de la ejecución (hasta 3 reintentos) y agote `functionTimeout` (10 min) |
| `src/Cobranza.Functions/Servicios/IRepositorioNotificaciones.cs` (nuevo) | Interfaz con `ObtenerAvisosPendientesAsync` y `RegistrarNotificacionAsync` | Permite probar el job sin base de datos |
| `src/Cobranza.Functions/Servicios/RepositorioCobranza.cs:12` | Implementa `IRepositorioNotificaciones` | Ídem |
| `src/Cobranza.Functions/Program.cs:26-27` | Registra `IRepositorioNotificaciones` y `TimeProvider.System` | Inyección de dependencias |
| `src/Cobranza.Functions/Program.cs:33-35` | `EmailClient` con `EmailClientOptions { RetryPolicy = new PoliticaReintentoSinLimite() }` | Ídem LimiteAcs |
| `src/Cobranza.Functions/Modelos/OpcionesCobranza.cs:28-38` | `PausaEntreCorreosMs` pasa de `[Range(0, 60000)]` a `[Range(1, 60000)]`; comentarios actualizados a H1 (5/min y 10/h) y D12 DEMO (10 y 15000) | Sin el ajuste, la pausa valía 0 en silencio y superaba 5 por minuto; ahora el arranque falla por `ValidateOnStart`. Corrige B-06 en este archivo |
| `src/Cobranza.Functions/local.settings.example.json:20-21` | 90/2100 pasa a 10/15000 | D12 DEMO aprobado; B-06 |
| `Cobranza.slnx` | Se agrega `tests/Cobranza.Functions.Tests` | Proyecto de pruebas |
| `tests/Cobranza.Functions.Tests/*` (nuevo) | 23 pruebas xUnit con dobles en memoria (sin red ni base de datos) | Punto 3 de la tarea |

## 4. SQL (sin cambios)

- `sql/04_jobs_bitacoras.sql:137` (`sp_GenerarAlertasVencimiento`) excluye un aviso cuando `cob.LogNotificacion` tiene una fila con `EstadoEnvio = 'Aceptado'` o `Intentos >= 3`. `sp_RegistrarNotificacion` (04:148-183) solo admite `Aceptado` o `Fallido` y suma 1 a `Intentos` en cada llamada.
- La corrección no requiere un estado nuevo: en un 429 no se llama a `sp_RegistrarNotificacion`, así que no se crea ni se actualiza ninguna fila y el aviso vuelve a salir en la siguiente ejecución. El rastro del 429 queda en Application Insights (EventId 4290), no en `cob.LogNotificacion`.

## 5. Pruebas (resumen)

- `Rechazo429_NoRegistraIntento_YCortaElLote`: con 5 avisos y un 429 en el tercero, hay 3 envíos, solo 2 registros `Aceptado`, ningún registro del aviso 3 y 3 diferidos.
- `Rechazo429_EnPrimerEnvio_NoRegistraNada`, `CodigoTooManyRequests_SinStatus429_SeTrataComoLimite`, `Rechazo429_SeRegistraEnLogConEventoYRetryAfter`.
- `OtrosErrores_RegistranFallido_YContinuan` (400, 500, 503), `TodosLosEnviosFallidos_CadaUnoSeRegistraComoFallido`, `Aceptado_RegistraIdOperacion`, `UsaMaximoYPausaDeConfiguracion` (10 envíos y 9 pausas de 15000 ms).
- `LimiteAcsTests`: detección, Retry-After en sus 3 formatos o ausente, política sobre un pipeline real de Azure.Core (429 con 1 llamada; 503 con 4 llamadas) y validación de opciones sin lote o sin pausa.
