# Verificación local de F3

F3 se implementó y verificó en el workspace principal sin commits, push ni despliegue. El flujo del cuidador crea una pauta que aparece en GET agenda. El navegador, HTTP y PostgreSQL son reales; la identidad de los flujos automatizados es sintética y está aislada del código productivo.

## Resultados observados

| Comprobación | Resultado |
| --- | --- |
| `make web-install` | Lockfile fijo instalado con pnpm 12.15.0 |
| `make test` | Go con `-race` y 10 pruebas Vitest correctas |
| `make lint` | gofmt, go vet y TypeScript correctos |
| `make build` | API y bundle productivo compilados |
| `make test-integration` | Suite completa con PostgreSQL real y `-race -count=1` correcta |
| `make test-web-e2e` | Cuatro pruebas Playwright correctas |
| Goose `up`, `down-to 0`, `up`, `status` | Cuatro migraciones reversibles en base vacía desechable; versión final 4 |
| OpenAPI Spec Validator 0.7.2 | Contrato OpenAPI 3.1 válido |
| `sh scripts/smoke.sh` | Binario real, healthz 200, readyz 200 y SIGTERM con salida 0 |
| Build Vite con modo `e2e` | Rechazado con el error previsto, no distribuible |
| Inspección del bundle productivo | Sin marcadores de identidad `synthetic-` ni `test-only` |
| `git diff --check` | Sin errores de whitespace |

Las versiones principales se registran en el [README](../../README.md) y las dependencias exactas en [package.json](../../apps/web/package.json) y [pnpm-lock.yaml](../../apps/web/pnpm-lock.yaml). El entorno tenía Node 22.23.4 y PostgreSQL 18.6.

Docker no estaba activo. Se inició un clúster PostgreSQL desechable en loopback, separado de la base de desarrollo. Las pruebas usaron `medication_f3_verification`; las migraciones reversas se ensayaron en `medication_f3_migration_check`, creada vacía. No se usaron datos reales de salud, proyectos Firebase reales ni conexiones de producción. El clúster desechable se detuvo al terminar y sus archivos se conservaron.

## Cobertura

Las [pruebas de aplicación](../../services/api/internal/application/portal_integration_test.go) comprueban conteos fraccionales, replay, conflictos de saldo, auditoría de conteo sin diferencia, cantidades inválidas y concurrencia entre conteo y reposición. El historial append-only rechaza eliminación. La edición de metadatos seguida de revisión de pauta funciona. Archivar conserva declaraciones previas, cancela dosis futuras y restringe generación y proyección al mismo instante.

Las [pruebas HTTP](../../services/api/internal/http/portal_integration_test.go) comprueban vista previa de invitación, aceptación, listado de vínculos, permisos de escritura y revocación del acceso al historial. Las suites anteriores de F1 y F2 permanecen activas y pasaron, incluidas cantidades exactas, DST, consumo único, correcciones y autorización antes de replay.

Las [pruebas de navegador](../../apps/web/tests/portal.e2e.ts) cubren:

1. Dos cuentas sintéticas separadas completan invitación, revisión de permisos y consentimiento. El cuidador crea un tratamiento de 0,5 comprimidos y una petición directa GET agenda devuelve `0.500`. Se prueban reposición, conteo, historial, edición, archivo y revocación. La prueba pierde una respuesta de reposición ya aplicada y confirma que el reintento conserva el identificador y no duplica el incremento.
2. Carga, vacío, error 500 y denegación 404 mediante interceptación de red. Estos casos no se presentan como prueba de la base de datos.
3. Se pierde la respuesta real de creación de invitación. Otro envío crea una operación nueva y permite recuperar el flujo sin reutilizar el token perdido.
4. Otra petición actualiza un tratamiento mientras su formulario está abierto. Después de refetch, el borrador conserva su versión original y recibe conflicto, sin sobrescribir los datos concurrentes.

La captura de agenda se inspeccionó visualmente. Se verificaron etiquetas de controles, estados con texto, unidades y selección de sección mediante `aria-pressed`. No se realizó una auditoría completa de accesibilidad ni compatibilidad entre navegadores.

## Correcciones de revisión

La revisión estática independiente emitió PASS para la correspondencia entre mapas, ADR e implementación. Detectó dos defectos de UI: la creación de invitaciones reutilizaba una operación no recuperable y los formularios abiertos tomaban la versión nueva de una consulta manteniendo campos antiguos. Ambas correcciones tienen las regresiones reales de navegador descritas arriba.

La revisión durante implementación también corrigió cantidades distintas por horario, navegación interna que recargaba la sesión en memoria, carrera entre callbacks de identidad y el instante único de archivo. El resultado de un conteo sin diferencia usa un `count_id` y `movement_id` nulo, conforme al contrato.

## Reproducción

Instalar las dependencias con `make web-install`. Si Chromium falta, ejecutar `pnpm --dir apps/web exec playwright install chromium`.

Crear una base desechable local cuyo nombre comience por `medication_f3_`. Configurar `TEST_DATABASE_URL` hacia esa base sin imprimir su valor. Aplicar las migraciones antes de las suites:

```sh
GOOSE_DRIVER=postgres GOOSE_DBSTRING="$TEST_DATABASE_URL" .bin/goose-v3.29.0 -dir infrastructure/migrations up
make test
make lint
make build
make test-integration
make test-web-e2e
sh scripts/smoke.sh
```

Las pruebas del navegador ocupan temporalmente los puertos 5173 y 18083. Playwright inicia y detiene ambos servidores. `cmd/e2e` exige una base local desechable con prefijo F3 y escucha sólo en loopback. Vite selecciona el adaptador sintético únicamente en modo `e2e`; no permite compilarlo para distribución.

Para repetir la reversión, crear otra base vacía y asignar su conexión a `F3_MIGRATION_DATABASE_URL`. No usar la base que ya contiene ajustes e historial de pruebas:

```sh
export GOOSE_DRIVER=postgres
export GOOSE_DBSTRING="$F3_MIGRATION_DATABASE_URL"
.bin/goose-v3.29.0 -dir infrastructure/migrations up
.bin/goose-v3.29.0 -dir infrastructure/migrations down-to 0
.bin/goose-v3.29.0 -dir infrastructure/migrations up
.bin/goose-v3.29.0 -dir infrastructure/migrations status
```

La reversa de F3 restaura restricciones que no admiten `manual_adjustment`. Si hay esos datos, falla en vez de eliminarlos para forzar la reversión. El ensayo exitoso acredita una base vacía desechable, no una estrategia de rollback de producción.

## Bloqueos y límites

El login contra un proyecto Firebase real no se verificó porque no se configuraron proyecto ni cuentas de prueba. El SDK cliente y el verificador productivo están implementados; las pruebas locales de firmas de F2 siguen pasando. La siguiente comprobación precisa es configurar las variables públicas web y el mismo proyecto en la API, y repetir el consentimiento con dos cuentas de prueba reales.

El build emite advertencias por un chunk JavaScript de aproximadamente 534 kB y directivas `use client` de dependencias. No impidieron compilar. No se hizo optimización de carga ni prueba de rendimiento.

El sandbox bloqueó inicialmente la caché de Go, la red de instalación y la memoria compartida de PostgreSQL. Las operaciones se repitieron con la escalación autorizada y terminaron correctamente. No queda un bloqueo de herramientas para las pruebas locales. pnpm informa skills opcionales de TanStack pendientes de aprobación; no se necesitan para compilar ni ejecutar. Los scripts opcionales Firebase/protobuf permanecen denegados explícitamente.

No se verificó producción ni se desplegó. No hay soporte offline de escritura, edición de perfiles, apps móviles, worker, notificaciones o métricas de adherencia nuevas. F4 y las fases posteriores permanecen pendientes.

## Architecture Impact

- Límites y runtime cambiados. Se añade el portal web, su cliente Firebase y su adaptador HTTP.
- Modelo de datos y API cambiados. Se añade archivo, auditoría de tratamientos, conteos físicos y consultas de consentimiento e inventario.
- Autorización backend conservada. Los endpoints nuevos aplican los alcances existentes dentro de las transacciones. El cliente descarta sesión y caché ante 401, 403 o 404.
- Reglas ampliadas para archivo y conteo físico. Se mantienen consumo único, correcciones, exactitud decimal y DST.
- Routing local cambiado mediante proxy Vite. Infraestructura de despliegue y jobs sin cambios.
- Documentación actualizada en README, PLAN, mapas general/web y ADR F3. La validación está limitada a los comandos y casos registrados en este documento.

Los principios Model the Domain y Prove It Works guiaron, respectivamente, el estado tipado de sesión/editor y las pruebas con navegador, API y PostgreSQL reales. Un único propietario implementó el código acoplado en worktree aislado; la integración, documentación y verificación final se realizaron en el workspace principal.
