# Medication Tracker

F3 incorpora el portal web del cuidador con login Firebase, consentimiento, tratamientos, inventario y agenda. F4 añade la app iOS del paciente, con el flujo completo verificado en simulador; en iPhone físico se verificaron instalación y login. La API Go autoriza cada operación y PostgreSQL conserva auditoría. F5 añade Android del paciente, con pruebas locales en emulador y aceptación del usuario en Android físico; quedan casos físicos pendientes en el runbook. F6 incorpora worker, alertas push y recuperación; PostgreSQL, API y worker están desplegados en Railway staging. El usuario aceptó el flujo completo en staging como MVP; la entrega push real sigue pendiente. Consulta [Railway staging](docs/runbooks/railway-staging.md).

## Herramientas y versiones

| Componente | Versión fijada |
| --- | --- |
| Go | 1.27.3 |
| PostgreSQL Docker | 18.6-trixie |
| pgx | v5.12.0 |
| Firebase Admin Go | v4.22.0 |
| goose | v3.29.0 |
| OpenAPI | 3.1.0 |
| Node verificado | 22.23.4 |
| pnpm | 12.15.0 |
| React | 19.3.1 |
| Vite | 8.3.5 |
| TypeScript | 7.0.2 |
| Tailwind | 4.3.4 |
| TanStack Query / Router | 5.105.3 / 1.170.46 |
| Firebase cliente | 13.2.0 |
| Zod | 4.3.6 |
| Vitest / Playwright | 4.1.0 / 1.64.1 |
| Xcode / SDK iOS verificados | 27.2 / 27.2 (destino iOS 17.0) |
| Swift | 6 en la app, 5 en XCUITest |
| XcodeGen | 2.46.0, commit fijado en el Makefile |
| firebase-tools, sólo emulador E2E | 15.34.2 |

Go usa go.mod y go.sum. Goose se instala en `.bin` con versión explícita. Las versiones de pgx y goose se consultaron en proxy.golang.org. La imagen se verificó en el [registro oficial de imágenes](https://github.com/docker-library/official-images/blob/master/library/postgres). PostgreSQL 18 monta el volumen en `/var/lib/postgresql`.

En macOS se requieren Go, Make y Docker con Compose y un runtime activo. Docker Desktop o Colima sirven. Homebrew puede instalar `go docker docker-compose colima`. Con Colima, ejecutar `colima start`; comprobar `docker info` y `docker compose version`. Si Compose no aparece, seguir las instrucciones que imprime `brew info docker-compose` para configurar su directorio de plugins.

El equipo inspeccionado tenía macOS 27.2 arm64, Go 1.27.3, psql 18.6, GNU Make 3.81 y Node 22.23.4. Xcode 27.2 estaba instalado con Command Line Tools como selección activa. No se encontró SDK Android. Las herramientas móviles no son necesarias para F0. Se instalaron Docker 29.9.2, Compose 5.6.1 y Colima 0.10.3 con Homebrew. Consulta los [resultados de verificación](docs/runbooks/f0-verification.md).

## Primer arranque

Desde la raíz del repositorio:

```sh
cp .env.example .env
docker compose up -d --wait db
make migrate-up
# Configurar FIREBASE_PROJECT_ID en .env antes de arrancar.
make dev
```

En otra terminal:

```sh
curl -i http://127.0.0.1:8080/healthz
curl -i http://127.0.0.1:8080/readyz
make test
make lint
```

`make dev` carga `.env` y ejecuta la API en el host. El archivo debe contener asignaciones válidas de shell. Las credenciales de `.env.example` son exclusivamente de desarrollo. PostgreSQL y HTTP escuchan en loopback. Si 55433 está ocupado, cambiar POSTGRES_PORT y el puerto de DATABASE_URL juntos.

La API requiere DATABASE_URL con esquema postgres/postgresql, host y nombre de base. HTTP_ADDR usa host:puerto y por defecto es `127.0.0.1:8080`. APP_ENV admite development, test y production; production exige `sslmode=verify-full`. No hay un despliegue de producción configurado. FIREBASE_PROJECT_ID identifica el proyecto cuyos ID tokens acepta la API. El valor demo de `.env.example` permite arrancar las probes, pero no habilita identidades ficticias. El ejecutable rechaza FIREBASE_AUTH_EMULATOR_HOST en cualquier entorno. Los verificadores sintéticos existen en pruebas y en `cmd/e2e`, excluido del ejecutable normal por el build tag `e2e`. Ese servidor exige una base local desechable con prefijo `medication_f3_` o `medication_f4_`.

`/healthz` devuelve 200 y `{"status":"ok"}` sin consultar la DB. `/readyz` hace Ping real y devuelve 200 con `{"status":"ready"}` o 503 con `{"status":"not_ready"}`. Tiene un límite de dos segundos. Readiness sólo comprueba conectividad; las migraciones se ejecutan aparte. Los errores de conexión no salen en JSON ni logs. SIGINT y SIGTERM dejan hasta diez segundos para completar peticiones antes de cerrar el pool.

## Comandos

| Comando | Efecto |
| --- | --- |
| `make dev` | Ejecutar API con `.env` |
| `make build` | Compilar `.bin/api` y el portal productivo |
| `make test` | Go con detector de carreras y pruebas Vitest |
| `make lint` | gofmt, go vet y comprobación TypeScript |
| `make migrate-up` | Aplicar migraciones goose |
| `make migrate-down` | Revertir una migración; puede eliminar tablas y sus datos |
| `make migrate-status` | Ver estado de migraciones |
| `make test-integration` | API, permisos y casos de uso con PostgreSQL real; exige TEST_DATABASE_URL y migraciones aplicadas |
| `sh scripts/smoke.sh` | Arrancar binario, probar probes y verificar SIGTERM |
| `make web-install` | Instalar dependencias web con lockfile fijo |
| `make web-dev` | Portal en `http://127.0.0.1:5173`, proxy API al puerto 8080 |
| `make test-web-e2e` | Playwright con HTTP y PostgreSQL reales; exige base F3 desechable migrada |
| `make ios-project` | Compilar XcodeGen fijado si falta y generar el proyecto Xcode |
| `make build-ios` | Compilar la app para simulador |
| `make test-ios` | Pruebas unitarias iOS en simulador, con dobles de red |
| `make lint-ios` | Compilar app y pruebas con advertencias como errores |
| `make dev-lan` | API en la red local, puerto 8081 o `LAN_PORT`, para un iPhone de desarrollo |
| `make run-ios-device` | Compilar, instalar y abrir la app en el iPhone conectado |
| `make test-ios-e2e` | XCUITest con simulador, API y PostgreSQL reales y emulador Firebase; exige base `medication_f4_` desechable migrada |
| `make generate` | Fallar con explicación; generación aún no configurada |

No ejecutar migrate-down sobre información que se quiera conservar. Para comprobar up/down/up usar una base nueva y desechable. No borrar volúmenes como parte del arranque normal. Las pruebas de F1 insertan fixtures sintéticos y conservan su historial append-only; requieren una base de pruebas dedicada.

```sh
docker compose exec db sh -c 'createdb -U "$POSTGRES_USER" medication_f1_test'
export DATABASE_URL='postgres://medication_dev:local_only_change_me@127.0.0.1:55433/medication_f1_test?sslmode=disable'
export TEST_DATABASE_URL="$DATABASE_URL"
# Goose recibe directamente la URL de la base desechable.
GOOSE_DRIVER=postgres GOOSE_DBSTRING="$DATABASE_URL" .bin/goose-v3.29.0 -dir infrastructure/migrations up
make test-integration
GOOSE_DRIVER=postgres GOOSE_DBSTRING="$DATABASE_URL" .bin/goose-v3.29.0 -dir infrastructure/migrations down
GOOSE_DRIVER=postgres GOOSE_DBSTRING="$DATABASE_URL" .bin/goose-v3.29.0 -dir infrastructure/migrations up
```

Las pruebas unitarias simulan resultados de Ping para cubrir contrato, cancelación y errores. La prueba con tag integration exige una DB real, consulta por HTTP y cierra su pool para comprobar 503 sin detener PostgreSQL. No se omite silenciosamente si falta TEST_DATABASE_URL.

Para comprobar pérdida y recuperación reales con la API encendida:

```sh
docker compose stop db
curl -i http://127.0.0.1:8080/healthz
curl -i http://127.0.0.1:8080/readyz
docker compose up -d --wait db
curl -i http://127.0.0.1:8080/readyz
```

Los códigos esperados son 200, 503 y 200. `sh scripts/verify-db-outage.sh` automatiza esta prueba y reinicia db al terminar. `docker compose down` apaga los contenedores y conserva el volumen. `docker compose down -v` elimina los datos y no forma parte del flujo habitual.

## API e identidad

Las rutas `/v1/` requieren `Authorization: Bearer <ID token>`. El backend obtiene el actor del token verificado. Un identificador de paciente o recurso en la URL nunca concede acceso por sí mismo. Un recurso inexistente o inaccesible devuelve el mismo error 404.

El paciente autoriza los alcances al aceptar una invitación. El cuidador necesita `read` para consultar y, además, `treatments`, `doses` o `inventory` para la mutación correspondiente. Crear un tratamiento permite registrar su stock inicial. Reponer una cuenta existente requiere `inventory`.

Las mutaciones JSON usan `client_operation_id`. El cliente debe conservarlo junto con el contenido original al reintentar. Reutilizarlo con otro contenido produce 409. La creación de invitaciones entrega el token una sola vez y devuelve conflicto al repetir la operación. La revocación por DELETE es idempotente sin cuerpo. Ningún reintento evita la comprobación de permisos vigentes.

Las cantidades son cadenas como `"0.500"`. La agenda recibe fechas locales `from` inclusiva y `to` exclusiva, con un máximo de 30 días. El contrato especifica paginación y las respuestas de cada ruta. La consulta genera las ocurrencias que falten y mantiene sus identificadores estables. Las páginas se ordenan por UUID; el cliente debe obtenerlas y ordenar las dosis por horario.

Las peticiones JSON tienen un máximo de 64 KiB. La API genera un request ID, propaga un deadline de ocho segundos y aplica un límite inicial por IP directa. No confía en `X-Forwarded-For`. No se configura CORS permisivo. Los límites están en memoria por proceso y no coordinan varias réplicas.

El SDK verifica firmas mediante certificados públicos sin credenciales de servicio. No se activa revocación de tokens en Firebase Admin. Los permisos del cuidador se revisan en PostgreSQL en cada operación. Las pruebas de firma locales usan claves y certificados sintéticos; no acreditan conexión a un proyecto Firebase desplegado.

## App iOS

Los comandos usan `/Applications/Xcode.app` mediante `DEVELOPER_DIR`, sin cambiar la selección global; `XCODE_DEVELOPER_DIR` e `IOS_DESTINATION` los sobrescriben. `make test` y `make lint` no incluyen iOS porque CI corre en Linux.

Para ejecutarla, crear `apps/ios/Config/Local.xcconfig`, ignorado por Git, con `FIREBASE_API_KEY`, `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE = Automatic` y `API_BASE_URL = http:/$()/<nombre-del-mac>.local:8081`. Luego iniciar `make dev-lan` y ejecutar `make run-ios-device`. La cuenta de Apple se añade una vez en Xcode. Release sólo acepta HTTPS. Las cuentas se crean fuera de la app, igual que en el portal. Consulta la [verificación F4](docs/runbooks/f4-verification.md).

## Estructura y siguientes fases

`services/api/cmd/api` compone configuración, pool, verificador Firebase y servidor. `internal/config` valida entorno, `internal/auth` verifica identidad e `internal/http` adapta JSON a los servicios. `internal/domain` contiene cantidades exactas, estados y calendario local. `internal/application` aplica permisos, consentimiento y casos de uso transaccionales. `infrastructure/migrations` contiene usuarios, dominio e invitaciones. `packages/contracts/openapi.yaml` describe las probes y las rutas implementadas de F2 y F3.

El worker Go comparte módulo con la API y ejecuta planificación y outbox sin modificar el ledger. iOS y Android tienen apps nativas del paciente; sus resultados y pendientes están en los runbooks F4 y F5. No hay clientes móviles generados. La [decisión F1](docs/decisions/0002-f1-domain.md) documenta pgx sin sqlc; la [decisión F2](docs/decisions/0003-f2-http-identity.md), identidad y permisos; y la [decisión F3](docs/decisions/0004-f3-caregiver-portal.md), sesión, archivo y conteos físicos. F4 se cerró con pendientes por decisión del usuario. F5 se cerró por aceptación del usuario con cobertura física pendiente; F5b no se ejecutó. F6 se implementó con los límites de verificación indicados en su runbook.

## Iniciar el portal

Con Node y pnpm instalados, ejecutar `make web-install`. Copiar `apps/web/.env.example` a `apps/web/.env.local` y sustituir los tres valores por la configuración pública de una app Firebase del mismo proyecto que usa la API. Habilitar correo y contraseña y preparar cuentas de prueba desde Firebase. No incluir credenciales de servicio en variables `VITE_`.

Iniciar la API con `make dev` y, en otra terminal, `make web-dev`. Abrir `http://127.0.0.1:5173`. El portal envía `/v1` mediante el proxy de Vite al puerto 8080. La compilación productiva requiere que el servidor de alojamiento enrute `/v1` hacia la API bajo el mismo origen y resuelva las rutas del portal al HTML. No se configuró ni ejecutó ese despliegue.

La sesión y los datos permanecen en memoria. Recargar la página exige volver a entrar. Cerrar sesión o recibir 401, 403 o 404 retira la caché y cierra la sesión local. No hay cola offline de mutaciones. Un reintento conserva su operación mientras el formulario y el contenido sigan iguales. Crear invitaciones es la excepción explícita: cada envío genera una nueva porque el token sólo se entrega una vez.

La persona que acepta una invitación se convierte en el paciente del vínculo y revisa sus permisos antes de consentir. Las referencias de personas son identificadores neutros; F3 no incorpora edición de perfiles o nombres. Archivar un tratamiento conserva su historial y corta las dosis futuras. No es una recomendación clínica.

## Verificar F3

Usar exclusivamente una base desechable local con prefijo `medication_f3_`, migrada a versión 4. Configurar `TEST_DATABASE_URL` hacia ella sin registrar la conexión. Para instalar Chromium si falta, ejecutar `pnpm --dir apps/web exec playwright install chromium`.

```sh
make web-install
make test
make lint
make build
make test-integration
make test-web-e2e
```

Playwright inicia el servidor Go con tag `e2e` y Vite en modo `e2e`. Sólo sustituye la identidad; HTTP, autorización y PostgreSQL son reales. El build productivo rechaza ese modo y excluye el adaptador sintético. Las pruebas de red interceptadas están separadas del flujo integrado.

El [runbook F3](docs/runbooks/f3-verification.md) contiene resultados, límites y reproducción de las migraciones. El login contra Firebase real y el flujo manual en staging fueron aceptados por el usuario al cerrar F6. La instalación no necesita aprobar skills opcionales de TanStack ni ejecutar los scripts opcionales de Firebase/protobuf que el workspace deniega.

## Mapa de arquitectura

El [mapa del monorepo](docs/00-home.md) describe el sistema implementado y enlaza los mapas locales de iOS, Android y web. La [política Living Architecture](AGENTS.md#living-architecture) define cuándo actualizarlos.


## Android F5

La app del paciente está en `apps/android`. El proyecto y wrapper provienen de Android CLI oficial. No se necesita un generador durante el build. Android Studio puede importar esa carpeta; su sincronización en Studio no fue verificada en este equipo.

Versiones fijadas: JDK de toolchain 21, Gradle 9.4.1 con checksum, AGP 9.2.0, Kotlin/Compose compiler 2.3.20, Compose BOM 2026.03.01, Material 3 a través del BOM, Navigation 3 1.0.1, Room 2.8.5, KSP 2.3.13, Retrofit 3.0.0 y serialization JSON 1.9.0. El catálogo y `apps/android/app/gradle.lockfile` fijan las dependencias directas y transitivas resueltas. minSdk 26 y target/compile SDK 37. La compatibilidad con teléfonos concretos aún requiere sus modelos y versiones.

Instalar JDK 21 y SDK Android 37 con build tools 36.0.0, configurar `JAVA_HOME` y `ANDROID_HOME`, o indicar `sdk.dir` en `apps/android/local.properties`. El script también detecta las herramientas locales de esta sesión bajo `.tmp/android-tools` y `.tmp/android-sdk`. Esas descargas no forman parte del repositorio. Las cachés de Gradle se guardan en `.tmp/gradle-home` por defecto.

```sh
make build-android
make test-android
make lint-android
ANDROID_SERIAL=emulator-5554 make test-android-device
```

`test-android-device` ejecuta Room, Keystore y permisos/fallback. Usa un paquete debug de pruebas sin permiso de notificaciones ni alarmas exactas al iniciar; la prueba concede notificaciones. Para repetir sobre ese paquete sintético, revoca previamente sus notificaciones con `adb shell pm revoke cl.nndsk.medication.debug android.permission.POST_NOTIFICATIONS`. No ejecutar pruebas sobre una instalación que contenga información que se quiera conservar.

Configurar una compilación debug con propiedades Gradle locales, sin claves privadas:

```sh
sh scripts/android-gradle.sh :app:assembleDebug \
  -PapiBaseUrl=https://api.example.invalid \
  -PfirebaseApiKey=replace-with-public-client-key
```

El valor inicial `example.invalid` no conecta con un servicio. HTTP sólo se admite en debug/e2e contra loopback, `10.0.2.2` o nombre `.local`. Para un teléfono por USB, `adb reverse` permite usar los servicios locales sin exponerlos a la red. Release exige HTTPS y rechaza el emulador de identidad. No se proporcionan credenciales de producción ni claves de servicio.

Para el E2E, crear una base local desechable `medication_f4_android_*`, aplicar las migraciones existentes y exportar `TEST_DATABASE_URL`. Se conserva el prefijo admitido por el servidor E2E existente; no se modificó su contrato para Android.

```sh
ANDROID_SERIAL=emulator-5554 make test-android-e2e
ANDROID_SERIAL=emulator-5554 make test-android-reboot
```

El primer comando arranca Firebase Auth emulado y API Go, conecta los puertos por `adb reverse` y prueba UI, consentimiento, Doze, entrega de alarma, offline, retries y conflictos. Sólo usa el paquete `cl.nndsk.medication.e2e` y datos sintéticos. Restaura el estado de batería/Doze al salir. El segundo reinicia exclusivamente un emulador y comprueba que el receptor de arranque restaura una alarma; no reinicia teléfonos físicos automáticamente.

`make test` y `make lint` siguen comprobando Go y web. Android usa los targets explícitos anteriores para no exigir SDK a colaboradores del backend. Resultado y límites en [verificación F5](docs/runbooks/f5-verification.md). No hay vista de cuidador móvil ni despliegue remoto verificado.


## Alertas y recuperación F6

`make build-worker` compila el worker. `make dev-worker` lo ejecuta con la configuración local. Push está desactivado por defecto mediante `WORKER_PUSH_MODE=disabled`; habilitarlo requiere proveedores y preferencias explícitas por vínculo. No hay un umbral predeterminado de aviso por dosis sin confirmar.

Desde `services/api`, `go run ./cmd/worker --once` ejecuta un ciclo y `go run ./cmd/worker --reconcile` inspecciona consistencia sin reparar el ledger. API y worker sirven métricas privadas en los puertos 9090 y 9091 respectivamente.

`make backup`, `make restore-test` y `make test-backup` usan PostgreSQL 18.6 y cifrado autenticado. Consulta [recuperación y staging](docs/runbooks/f6-recovery.md), [decisión F6](docs/decisions/0007-f6-alerts-resilience.md) y [verificación F6](docs/runbooks/f6-verification.md). Los mapas nativos documentan la configuración APNs y FCM. La UI de cuidador F5b y F7 no forman parte de este cambio.
