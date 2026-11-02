# Medication Tracker

F0 prepara la API Go y PostgreSQL local. Las apps iOS, Android y web son carpetas reservadas. No hay autenticación, tratamientos, inventario ni worker implementados.

## Herramientas y versiones

| Componente | Versión fijada |
| --- | --- |
| Go | 1.27.3 |
| PostgreSQL Docker | 18.6-trixie |
| pgx | v5.12.0 |
| goose | v3.29.0 |
| OpenAPI | 3.1.0 |

Go usa go.mod y go.sum. Goose se instala en `.bin` con versión explícita. Las versiones de pgx y goose se consultaron en proxy.golang.org. La imagen se verificó en el [registro oficial de imágenes](https://github.com/docker-library/official-images/blob/master/library/postgres). PostgreSQL 18 monta el volumen en `/var/lib/postgresql`.

En macOS se requieren Go, Make y Docker con Compose y un runtime activo. Docker Desktop o Colima sirven. Homebrew puede instalar `go docker docker-compose colima`. Con Colima, ejecutar `colima start`; comprobar `docker info` y `docker compose version`. Si Compose no aparece, seguir las instrucciones que imprime `brew info docker-compose` para configurar su directorio de plugins.

El equipo inspeccionado tenía macOS 27.2 arm64, Go 1.27.3, psql 18.6, GNU Make 3.81 y Node 22.23.4. Xcode 27.2 estaba instalado con Command Line Tools como selección activa. No se encontró SDK Android. Las herramientas móviles no son necesarias para F0. Se instalaron Docker 29.9.2, Compose 5.6.1 y Colima 0.10.3 con Homebrew. Consulta los [resultados de verificación](docs/runbooks/f0-verification.md).

## Primer arranque

Desde la raíz del repositorio:

```sh
cp .env.example .env
docker compose up -d --wait db
make migrate-up
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

La API requiere DATABASE_URL con esquema postgres/postgresql, host y nombre de base. HTTP_ADDR usa host:puerto y por defecto es `127.0.0.1:8080`. APP_ENV admite development, test y production; production exige `sslmode=verify-full`. F0 no configura un despliegue de producción.

`/healthz` devuelve 200 y `{"status":"ok"}` sin consultar la DB. `/readyz` hace Ping real y devuelve 200 con `{"status":"ready"}` o 503 con `{"status":"not_ready"}`. Tiene un límite de dos segundos. Readiness sólo comprueba conectividad; las migraciones se ejecutan aparte. Los errores de conexión no salen en JSON ni logs. SIGINT y SIGTERM dejan hasta diez segundos para completar peticiones antes de cerrar el pool.

## Comandos

| Comando | Efecto |
| --- | --- |
| `make dev` | Ejecutar API con `.env` |
| `make build` | Compilar `.bin/api` |
| `make test` | Pruebas unitarias con detector de carreras |
| `make lint` | Comprobar gofmt y ejecutar go vet |
| `make migrate-up` | Aplicar migraciones goose |
| `make migrate-down` | Revertir una migración, elimina users en F0 |
| `make migrate-status` | Ver estado de migraciones |
| `make test-integration` | Prueba HTTP con PostgreSQL real; exige TEST_DATABASE_URL |
| `sh scripts/smoke.sh` | Arrancar binario, probar probes y verificar SIGTERM |
| `make generate` | Fallar con explicación; generación aún no configurada |

No ejecutar migrate-down sobre información que se quiera conservar. Para comprobar up/down/up usar una base nueva y desechable. No borrar volúmenes como parte del arranque normal.

```sh
make migrate-up
make migrate-down
make migrate-up
TEST_DATABASE_URL='postgres://medication_dev:local_only_change_me@127.0.0.1:55433/medication_tracker?sslmode=disable' make test-integration
sh scripts/smoke.sh
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

## Estructura y siguientes fases

`services/api/cmd/api` compone configuración, pool y servidor. `internal/config` valida entorno y `internal/http` implementa las probes. `infrastructure/migrations` contiene únicamente users. `packages/contracts/openapi.yaml` documenta las rutas. `docs/decisions/0001-bootstrap.md` registra las alternativas y límites.

Los directorios futuros usan `.gitkeep`. No hay .xcodeproj, Gradle Wrapper, package.json web, sqlc ni generación de clientes hasta sus fases correspondientes. F1 requiere una solicitud nueva y comienza por pruebas de invariantes del dominio.

## Mapa de arquitectura

El [mapa del monorepo](docs/00-home.md) describe el sistema implementado y enlaza los mapas locales de iOS, Android y web. La [política Living Architecture](AGENTS.md#living-architecture) define cuándo actualizarlos.
