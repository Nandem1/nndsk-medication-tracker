# Verificación local de F2

F2 se verificó con Go 1.27.3, Firebase Admin Go v4.22.0 y PostgreSQL 18.6 local. La base desechable fue `medication_f2_verification`. No se migró la base de desarrollo ni se usaron datos de salud reales.

## Resultados

| Comprobación | Resultado observado |
| --- | --- |
| `make build` | Compilación correcta del ejecutable |
| `make test` | Pruebas unitarias con detector de carreras correctas |
| `make lint` | gofmt y go vet correctos |
| Goose `down-to 0`, `up`, `status` | Tres migraciones revertidas y reaplicadas; versión final 3 |
| `make test-integration` | Aplicación y HTTP contra PostgreSQL real, con `-race -count=1`, correctos |
| `sh scripts/smoke.sh` | Binario real; healthz 200, readyz 200 y SIGTERM con salida 0 |
| OpenAPI Spec Validator 0.7.2 | Contrato OpenAPI 3.1 válido |
| `TestOpenAPIManualAdapterFields` | Campos de los adaptadores tipados coinciden con los esquemas |
| `git diff --check` | Sin errores de whitespace |

Las comprobaciones finales se ejecutaron sobre los archivos integrados en el repositorio. Las suites de F1 permanecen activas y pasaron con las nuevas firmas que exigen actor.

## Cobertura y límites de las pruebas

Las [pruebas HTTP integradas](../../services/api/internal/http/api_integration_test.go) usan un servidor HTTP y PostgreSQL reales. Solo sustituyen la verificación de identidad mediante un verificador definido en `_test.go`. Cubren paciente propio, cuidador sin vínculo, alcances limitados, recursos ajenos, revocación y reintentos denegados después de revocar. Comprueban declaraciones, correcciones, reposiciones, revisiones de pauta, stock decimal, paginación y ausencia de escrituras ante denegaciones.

Las [pruebas de consentimiento](../../services/api/internal/application/access_integration_test.go) comprueban replay con reloj real, separación entre generaciones de consentimiento, conflicto de claves y bloqueo de revocación mientras una transacción conserva acceso. La aceptación concurrente del mismo token solo permite un consumidor. Los tokens vencidos y la autoaceptación se rechazan.

Las [pruebas Firebase](../../services/api/internal/auth/firebase_test.go) ejecutan el adaptador y el SDK reales con firmas RSA y un servidor TLS local de certificados sintéticos. Comprueban firma válida, firma incorrecta, audiencia, emisor, expiración, fecha de emisión futura, sujeto vacío y token sin firma. No son una prueba contra un proyecto Firebase real. El ejecutable rechaza la variable de emulador y no ofrece un proveedor de identidad ficticio.

Las [pruebas de límites HTTP](../../services/api/internal/http/api_test.go) comprueban autenticación, JSON estricto, tamaño de cuerpo, rate limiting, expiración de ventanas, request IDs, deadline y logs sin el contenido sensible de la petición. No se hizo una prueba de carga ni de múltiples réplicas.

## Defectos encontrados y corregidos

- El replay de aceptación dependía de comparar timestamps obtenidos por separado. Ahora usa `accepted_invitation_id`. La prueba con reloj real confirma el replay y rechaza el de una aceptación antigua tras reactivar el vínculo.
- Una consulta corta de agenda generaba treinta días y podía fallar por DST fuera del intervalo pedido. Ahora la generación HTTP usa la cantidad de días solicitada. La regresión prueba Santiago el 1 de septiembre de 2026 y el día del salto horario.
- La primera prueba criptográfica no interceptaba la descarga de certificados del SDK. Se sustituyó por un servidor TLS local y se repitieron las pruebas. La verificación final no usa aquel resultado fallido como evidencia.

## Reproducción

Usar una base desechable y configurar `TEST_DATABASE_URL` y `GOOSE_DBSTRING` hacia ella. No usar una base con información que se quiera conservar. Goose recibe la conexión directamente para evitar que los targets de migración carguen `.env`.

```sh
export GOOSE_DRIVER=postgres
.bin/goose-v3.29.0 -dir infrastructure/migrations down-to 0
.bin/goose-v3.29.0 -dir infrastructure/migrations up
.bin/goose-v3.29.0 -dir infrastructure/migrations status
make build test lint
make test-integration
sh scripts/smoke.sh
```

El smoke usa `TEST_DATABASE_URL` y un ID de proyecto sintético para iniciar el binario sin credenciales. Eso no habilita tokens sin firma. Para validar la especificación, instalar `openapi-spec-validator==0.7.2` en un entorno Python temporal y ejecutar `validate_spec` sobre el JSON de `packages/contracts/openapi.yaml`. El archivo es JSON válido y, por tanto, YAML válido; las pruebas Go lo leen sin añadir un parser YAML.

## Estado y siguiente paso

No quedan bloqueos locales de F2. No se verificaron Firebase con cuentas reales, CI remoto ni producción. No hubo commits, push ni despliegues. Los permisos de Docker, red local y caché de Go requirieron ejecución fuera del sandbox y las comprobaciones terminaron correctamente.

La revisión independiente de Living Architecture emitió PASS para los documentos revisados. Fue estática y detectó el defecto de agenda antes de la corrección final. La suite integrada confirmó después la regresión corregida.

Architecture Impact cambia los límites HTTP, el modelo de consentimiento, la API, la identidad, los permisos y la composición del proceso API. Añade Firebase como proveedor de identidad. Mantiene las reglas de dosis e inventario, las apps, los jobs y la infraestructura de despliegue. El routing HTTP incorpora `/v1/`. El [mapa general](../00-home.md), el [ADR F2](../decisions/0003-f2-http-identity.md) y el [README](../../README.md) documentan estos cambios.

F3 permanece sin iniciar. El siguiente paso requiere una solicitud nueva para construir el portal web. El rate limiting actual es local al proceso y `VerifyIDToken` no consulta revocación de sesiones del proveedor. Los clientes deben recorrer las páginas de agenda y ordenar por horario; la paginación actual usa UUID. La creación de invitaciones entrega el token una sola vez y devuelve conflicto al repetir la operación.
