# Verificación F7

## Alcance

F7 añade seguimiento al portal del cuidador y a la API. Incluye métricas semanales, mensuales y por rango, historial por paciente y tratamiento, calendario de respuestas y antelación configurable para reposición. La [decisión F7](../decisions/0008-f7-dashboard.md) define denominadores, ventana organizativa y límites de proyección.

No incluye F5b ni F8 ni modifica las apps nativas. Los datos de verificación local son sintéticos. El despliegue posterior autorizado se registra al final.

## Reproducción

Preparar PostgreSQL local desechable y aplicar las migraciones existentes hasta la versión 5. No se añade una migración F7. El servidor de pruebas web exige un nombre con prefijo `medication_f3_` o `medication_f4_`; para esta entrega se usa `medication_f3_f7_verify`.

Configurar `TEST_DATABASE_URL` hacia esa base sin imprimir ni registrar la conexión. Goose recibe la misma conexión directamente por variable de entorno, para evitar cargar `.env` de desarrollo o staging.

```sh
GOOSE_DRIVER=postgres GOOSE_DBSTRING="$TEST_DATABASE_URL" .bin/goose-v3.29.0 -dir infrastructure/migrations up
make test
make lint
make build
make test-integration
make test-web-e2e
```

Si los puertos habituales están ocupados, ejecutar `E2E_PORT_OFFSET=2000 make test-web-e2e`. La API de pruebas usa 20083, el proxy de fallos 20084 y el portal 7173, siempre en loopback. Sin la variable se conservan los puertos anteriores. La opción sólo configura el entorno E2E; no cambia la API productiva ni el proxy web hacia staging.

Playwright arranca API en loopback y Vite en modo `e2e`. La identidad es sintética; las peticiones HTTP, los permisos y PostgreSQL son reales. La configuración web habitual dirige las peticiones a staging, por lo que no debe usarse para esta verificación local.

## Resultados

Verificación local del 2026-11-03, con PostgreSQL 18.6 y datos sintéticos.

| Comando | Resultado |
| --- | --- |
| Migraciones existentes con goose `up` | PASS, esquema versión 5 en base desechable |
| `make test` | PASS, Go con detector de carreras y 15 tests web |
| `make lint` | PASS, gofmt, go vet y TypeScript |
| `make build` | PASS, API y bundle productivo web |
| `make test-integration` | PASS, suite completa contra PostgreSQL real |
| `cd services/api && go test -tags=e2e ./cmd/e2e` | PASS, puertos válidos y rechazo de offsets inválidos |
| `E2E_PORT_OFFSET=2000 make test-web-e2e` | PASS, 6 pruebas Chromium con API y PostgreSQL reales |

Los seis casos de aplicación de F7 prueban estados mezclados, denominadores cero, correcciones, extremos de puntualidad, corte temporal estricto, cancelaciones, revisiones, archivo y paginación de 114 dosis. Cubren 31 días, fechas locales de Santiago, DST y fecha de reposición al cruzar ese cambio. Los dos casos HTTP comprueban permisos, tratamiento real de otro paciente, validación, idempotencia, conflictos y rechazo de un reintento previamente exitoso tras revocación.

Los dos flujos nuevos de navegador verifican porcentajes y conteos visibles, calendario que incluye omisiones explícitas, historial filtrado y con unidades, selección mensual, persistencia de antelación al recargar e iniciar sesión, cuenta visible sin controles de edición para un cuidador `read` y retiro de datos tras revocación. También pasaron los cuatro flujos anteriores del portal. Las pruebas de error de red interceptadas se mantienen separadas de los flujos reales.

Se revisaron las capturas de escritorio y ancho 390 px; no se observó corte de contenido. Playwright comprueba que el ancho del documento no supera el viewport. Las capturas se generan en `/private/tmp/medication-f7-dashboard.png` y `/private/tmp/medication-f7-dashboard-mobile.png`.

## Incidencias resueltas

El sandbox bloqueó inicialmente memoria compartida, loopback y escritura en la caché de Go. Las operaciones necesarias pasaron con escalación para el entorno local. Los puertos habituales estaban ocupados por servicios anteriores; se preservaron y se añadieron puertos alternativos al entorno E2E.

pnpm intentó reconstruir dependencias en el sandbox y falló por resolución de red. Se detuvieron los reintentos y `pnpm --dir apps/web install --frozen-lockfile --offline` restauró los paquetes desde la caché. No se cambiaron versiones ni lockfiles.

La primera ejecución de navegador terminó con cinco pruebas aprobadas y una espera incorrecta del test después de reingresar. La app conserva la ruta del paciente; el test esperaba encontrar la lista de pacientes. Se corrigió esa navegación y la suite completa pasó. No se ocultó ni omitió el caso.

El build mantiene advertencias de dependencias sobre directivas `use client`. No impiden compilar. No quedan bloqueos para la verificación local de F7. Al terminar se detuvo únicamente el PostgreSQL temporal de F7; sus datos permanecen en `.tmp/f7/pgdata`. Los servicios anteriores siguieron abiertos.

## Límites

La prueba de F7 no acredita entrega push, uso en teléfonos físicos, revisión clínica de ventanas ni funcionamiento desplegado. El umbral de inventario también alimenta la planificación existente del worker cuando el cuidador ya habilitó sus avisos. Editarlo no habilita push ni garantiza recepción.

La proyección sólo cubre los siguientes 30 días. Una fecha de agotamiento nula significa que no se encontró una dosis sin cobertura dentro de esa ventana. Los porcentajes describen declaraciones y deben leerse junto con sus denominadores y dosis sin confirmar.


## Architecture Impact

- API y runtime web ampliados con métricas e historial filtrable. El cálculo autoritativo permanece en el backend.
- Modelo de datos sin cambios. El umbral utiliza la columna existente y las mutaciones conservan autorización e idempotencia.
- Reglas de métricas ampliadas. Ledger, prescripciones, declaraciones y correcciones conservan sus invariantes.
- Integraciones y jobs sin implementación nueva. El umbral configurado alimenta la planificación existente de alertas cuando está habilitada.
- Infraestructura productiva sin cambios. El entorno E2E admite puertos alternativos de loopback.
- Mapas general y web, README, PLAN y ADR0008 actualizados. Revisión independiente estática sin hallazgos bloqueantes y con consistencia código-documentación PASS; las pruebas de permisos sugeridas se incorporaron y pasaron.

Model the Domain orientó los conteos explícitos y las proporciones nulas sin denominador. Prove It Works orientó la comprobación con PostgreSQL, HTTP y navegador reales. Un propietario implementó el código acoplado en un worktree aislado; la integración y verificación final se hicieron en el workspace principal.

## Despliegue posterior autorizado

El usuario autorizó actualizar staging el 2026-11-03. API y worker F7 alcanzaron `SUCCESS`; salud/readiness devolvieron 200 y los endpoints protegidos devolvieron 401 sin token. El worker completó ciclos con push desactivado. El portal local entrega Seguimiento y dirige las peticiones a la API actualizada. Ver [evidencia e identificadores de Railway](railway-staging.md#actualización-a-f7).

El usuario completó su E2E en staging y aceptó F7 el 2026-11-03 con «excelente, todo correcto». Autorizó el commit de todo el worktree para cerrar la fase. Esta aceptación no acredita casos específicos que no detalló ni sustituye los límites de pruebas anteriores.

El agente no usó sus credenciales ni consultó datos de pacientes para los smoke checks. No hubo push, migraciones ni cambios en production. El siguiente paso es iniciar la fase siguiente en una solicitud separada; F8 no se ejecutó en este cierre.
