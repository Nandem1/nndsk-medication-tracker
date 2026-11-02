SHELL := /bin/sh
GOOSE_VERSION := v3.29.0
GOOSE := $(CURDIR)/.bin/goose-$(GOOSE_VERSION)

.PHONY: dev build test test-integration lint migrate-up migrate-down migrate-status generate

dev:
	@set -a; if [ -f .env ]; then . ./.env; fi; set +a; cd services/api && go run ./cmd/api

build:
	@mkdir -p .bin
	cd services/api && go build -o ../../.bin/api ./cmd/api

test:
	cd services/api && go test -race ./...

test-integration:
	@test -n "$$TEST_DATABASE_URL" || { echo 'Set TEST_DATABASE_URL to a dedicated test database.' >&2; exit 1; }
	cd services/api && go test -race -count=1 -tags=integration ./...

lint:
	@test -z "$$(cd services/api && gofmt -l .)" || { echo 'Run gofmt on services/api.' >&2; exit 1; }
	cd services/api && go vet ./...

$(GOOSE):
	@mkdir -p .bin
	GOBIN=$(CURDIR)/.bin go install -tags='no_clickhouse no_libsql no_mssql no_mysql no_sqlite3 no_vertica no_ydb' github.com/pressly/goose/v3/cmd/goose@$(GOOSE_VERSION)
	mv .bin/goose $(GOOSE)

migrate-up: $(GOOSE)
	@set -a; if [ -f .env ]; then . ./.env; fi; set +a; : "$${DATABASE_URL:?Set DATABASE_URL or copy .env.example to .env}"; GOOSE_DRIVER=postgres GOOSE_DBSTRING="$$DATABASE_URL" $(GOOSE) -dir infrastructure/migrations up

migrate-down: $(GOOSE)
	@set -a; if [ -f .env ]; then . ./.env; fi; set +a; : "$${DATABASE_URL:?Set DATABASE_URL or copy .env.example to .env}"; GOOSE_DRIVER=postgres GOOSE_DBSTRING="$$DATABASE_URL" $(GOOSE) -dir infrastructure/migrations down

migrate-status: $(GOOSE)
	@set -a; if [ -f .env ]; then . ./.env; fi; set +a; : "$${DATABASE_URL:?Set DATABASE_URL or copy .env.example to .env}"; GOOSE_DRIVER=postgres GOOSE_DBSTRING="$$DATABASE_URL" $(GOOSE) -dir infrastructure/migrations status

generate:
	@echo 'F2 uses manual typed HTTP adapters in services/api/internal/http/dto.go. No generator is configured; verify the OpenAPI contract with make test.' >&2
	@exit 1
