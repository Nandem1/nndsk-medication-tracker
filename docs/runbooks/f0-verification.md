# Verificación F0

Ejecutada el 2026-11-02 en macOS 27.2 arm64, rama main sin commits.

## Entorno

Se inspeccionaron sw_vers, command -v, brew list --versions, go version,
psql --version, make --version, node --version y pnpm --version.
Go 1.27.3, PostgreSQL host 18.6, Make 3.81, Node 22.23.4 y pnpm 12.15.0 estaban instalados.
Xcode 27.2 existe en /Applications/Xcode.app; xcode-select apunta a Command Line Tools.
No se encontró SDK Android. Ninguna herramienta móvil es requisito de F0.

Se ejecutó `brew install docker docker-compose colima` con autorización.
Instaló Docker 29.9.2, Compose 5.6.1, Colima 0.10.3 y Lima 2.2.1.
`colima start --cpu 2 --memory 2 --disk 20` creó el runtime local.
Se registró Compose mediante un enlace en ~/.docker/cli-plugins/docker-compose al plugin de Homebrew.
Colima seleccionó el contexto Docker colima.

## Comandos y resultados

| Comando | Resultado |
| --- | --- |
| `docker compose up -d --wait db` | PostgreSQL 18.6-trixie healthy, volumen persistente |
| `make build test lint` | Build, go test -race y go vet correctos |
| `make migrate-up`, `make migrate-down`, `make migrate-up` | Ciclo completo correcto sobre base nueva del contenedor |
| `make migrate-status` | 00001_create_users.sql aplicada |
| `TEST_DATABASE_URL=... make test-integration` | Tests con PostgreSQL real correctos |
| `sh scripts/smoke.sh` | healthz 200, readyz 200 y SIGTERM termina con código 0 |
| `sh scripts/verify-db-outage.sh` | DB activa 200; DB detenida healthz 200 y readyz 503; DB recuperada readyz 200 |
| `shellcheck -x scripts/*.sh` | Correcto |
| `actionlint` | Workflow correcto estáticamente |
| `git check-ignore .env .bin/api` | Ambos excluidos |
| `make generate` | Falla deliberadamente con explicación, generación fuera de F0 |

Las ejecuciones Go usaron GOMODCACHE=/tmp/medication-f0-gomod y GOCACHE=/tmp/medication-f0-gocache para mantener las cachés de verificación aisladas.
Los comandos Go equivalentes son `go build ./cmd/api`, `go test -race ./...` y `go vet ./...` desde services/api.
La integración requiere TEST_DATABASE_URL con la URL local documentada en README.

## Incidencias resueltas y límites

El sandbox bloqueó memoria compartida y conexiones locales; se ejecutaron las verificaciones con los permisos solicitados.
Un PostgreSQL previo ocupa 127.0.0.1:5432. La primera migración falló porque ese servidor no tenía medication_dev; no modificó su esquema.
Se fijó 55433 como puerto host de Compose y DATABASE_URL. El puerto dentro del contenedor sigue siendo 5432.
Se repitió toda la verificación sobre el contenedor correcto.

Antes de instalar Docker se inició una instancia temporal vacía en /tmp/medication-f0-check, puerto 55432.
Se apagó al finalizar. No se usó para las migraciones ni como sustituto de la verificación Docker.

Sin bloqueos de F0. GitHub Actions está configurado y validado con actionlint, pero no se ejecutó remotamente porque no hay commits ni push.
El contrato OpenAPI fue revisado contra las respuestas de los tests; no se instaló un validador OpenAPI específico.
Colima y el servicio db quedan activos para desarrollo. Las API de smoke terminaron.
No se implementaron funciones de F1 ni UI, identidad, Firebase o worker. No hubo commits, push ni despliegues.
