# Verificación local de F1

La verificación usó Go 1.27.3 y PostgreSQL 18.6 local en la base desechable `medication_f1_verification`. No se migró la base de desarrollo ni se usaron conexiones de producción.

## Resultados

| Comprobación | Resultado observado |
| --- | --- |
| `make build` | Compilación de API correcta |
| `make test` | Pruebas unitarias con `-race` correctas |
| `make lint` | gofmt y go vet correctos |
| Goose `down-to 0` seguido de `up` | Ambas migraciones revertidas y aplicadas; versión final 2 |
| `make test-integration` | Pruebas con PostgreSQL real y `-race -count=1` correctas |

Las pruebas de dominio se escribieron antes de la implementación. F1 no añade handlers. Las [pruebas unitarias](../../services/api/internal/domain/domain_test.go) cubren cantidades exactas, fracciones inválidas, DST de Santiago y Nueva York, colisiones de horarios, año bisiesto, cambio de mes y distinción entre pendiente, sin confirmar y omitida.

Las [12 pruebas de aplicación](../../services/api/internal/application/service_integration_test.go) comprueban lo siguiente contra PostgreSQL:

- Una confirmación efectiva ante 12 comandos concurrentes con claves diferentes.
- Reintentos simultáneos de una misma confirmación o corrección con respuesta estable.
- Conflicto al reutilizar una clave con otro contenido y al corregir un evento que ya no está vigente.
- Compensaciones de inventario y ausencia de consumo adicional al cambiar tomada a tomada tarde.
- Stock exacto con reposiciones y dos dosis concurrentes, omisiones, pendientes y saldo negativo.
- Rollback de evento, estado e idempotencia ante un fallo de escritura de inventario; retry posterior correcto.
- Conservación de IDs e historia pasada, incluidas pendientes, al cambiar la pauta.
- Generación concurrente con una revisión y regeneración sin duplicados.
- Límites de fechas y de vigencia de revisiones alrededor de DST.
- Proyección independiente de la materialización, primer agotamiento y horizonte local de 30 días.
- Rechazo de IDs desconocidos y declaraciones de dosis futuras.
- FKs que impiden mezclar pacientes, historial protegido frente a UPDATE/DELETE y motivo obligatorio en correcciones.

## Reproducción

El [README](../../README.md#comandos) muestra cómo crear una base desechable, aplicar migraciones y ejecutar la integración. `TEST_DATABASE_URL` debe apuntar a esa base. Los tests no se omiten si falta la variable y sus fixtures son sintéticos.

Para repetir la reversión completa, usar Goose directamente con `GOOSE_DRIVER=postgres` y `GOOSE_DBSTRING` apuntando a la base desechable. Ejecutar `down-to 0`, `up` y después `make test-integration`. No usar la base que se quiera conservar. Los targets `make migrate-*` cargan `.env`, por lo que no se usaron para este ciclo aislado.

## Límites y revisión

No quedan bloqueos locales de F1. El sandbox requirió permisos para Docker, la caché de Go y la conexión local; las ejecuciones autorizadas terminaron correctamente. No se verificó CI remoto ni producción. No hubo commits, push ni despliegues.

La revisión independiente de Living Architecture emitió PASS para la consistencia estática de código y documentos. La validación final ejecutó las pruebas sobre los archivos integrados en el repositorio. La revisión detectó y se corrigieron el filtrado DST fuera de vigencia y la definición del horizonte de proyección.

Architecture Impact cambia los límites internos, el esquema y las reglas de negocio. Mantiene sin cambios el contrato HTTP, la autenticación, las integraciones, los jobs, el proceso API y el routing de infraestructura. El [mapa general](../00-home.md) y el [ADR F1](../decisions/0002-f1-domain.md) documentan el resultado.

F2 sigue pendiente. Antes de exponer los casos de uso se requieren contrato HTTP, identidad verificada y autorización por operación. La política DST técnica debe revisarse con el usuario o profesional antes de presentarla en configuración de medicamentos.
