SHELL := /bin/sh
GOOSE_VERSION := v3.29.0
GOOSE := $(CURDIR)/.bin/goose-$(GOOSE_VERSION)

.PHONY: dev build test test-integration lint migrate-up migrate-down migrate-status generate tokens tokens-check

dev:
	@set -a; if [ -f .env ]; then . ./.env; fi; set +a; cd services/api && go run ./cmd/api

build:
	@mkdir -p .bin
	cd services/api && go build -o ../../.bin/api ./cmd/api
	pnpm --dir apps/web build

test:
	cd services/api && go test -race ./...
	pnpm --dir apps/web test

test-integration:
	@test -n "$$TEST_DATABASE_URL" || { echo 'Set TEST_DATABASE_URL to a dedicated test database.' >&2; exit 1; }
	cd services/api && go test -race -count=1 -tags=integration ./...

tokens:
	node packages/design-tokens/build.mjs

tokens-check:
	node packages/design-tokens/build.mjs --check

lint: tokens-check
	@test -z "$$(cd services/api && gofmt -l .)" || { echo 'Run gofmt on services/api.' >&2; exit 1; }
	cd services/api && go vet ./...
	pnpm --dir apps/web lint

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

XCODE_DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
XCODEGEN_VERSION := 2.46.0
XCODEGEN_COMMIT := 8445e778451c7e44237b90281bde622d764b0084
XCODEGEN := $(CURDIR)/.bin/xcodegen-$(XCODEGEN_VERSION)/xcodegen
IOS_DIR := apps/ios
IOS_PROJECT := $(IOS_DIR)/MedicationTracker.xcodeproj
IOS_DESTINATION ?= platform=iOS Simulator,name=iPhone 17
IOS_XCODEBUILD := DEVELOPER_DIR=$(XCODE_DEVELOPER_DIR) xcodebuild -project $(IOS_PROJECT) -derivedDataPath .tmp/ios-derived

.PHONY: ios-project build-ios test-ios lint-ios test-ios-e2e dev-lan run-ios-device

$(XCODEGEN):
	@rm -rf .tmp/xcodegen-src && mkdir -p .tmp .bin/xcodegen-$(XCODEGEN_VERSION)
	git clone --quiet --depth 1 --branch $(XCODEGEN_VERSION) https://github.com/yonaskolb/XcodeGen.git .tmp/xcodegen-src
	@test "$$(git -C .tmp/xcodegen-src rev-parse HEAD)" = "$(XCODEGEN_COMMIT)" || { echo 'XcodeGen tag does not match the pinned commit.' >&2; exit 1; }
	cd .tmp/xcodegen-src && DEVELOPER_DIR=$(XCODE_DEVELOPER_DIR) swift build -c release --product xcodegen
	cp .tmp/xcodegen-src/.build/release/xcodegen $(XCODEGEN)
	cp -R .tmp/xcodegen-src/.build/release/XcodeGen_XcodeGenKit.bundle .bin/xcodegen-$(XCODEGEN_VERSION)/

ios-project: $(XCODEGEN)
	cd $(IOS_DIR) && DEVELOPER_DIR=$(XCODE_DEVELOPER_DIR) $(XCODEGEN) generate --quiet

build-ios: ios-project
	$(IOS_XCODEBUILD) -scheme MedicationTracker -destination '$(IOS_DESTINATION)' build

test-ios: ios-project
	$(IOS_XCODEBUILD) -scheme MedicationTracker -destination '$(IOS_DESTINATION)' test

lint-ios: ios-project
	$(IOS_XCODEBUILD) -scheme MedicationTracker -destination '$(IOS_DESTINATION)' SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build-for-testing

# Expone la API en la red local para un iPhone de desarrollo. Sólo redes de confianza y datos sintéticos.
dev-lan:
	@set -a; if [ -f .env ]; then . ./.env; fi; set +a; HTTP_ADDR=:$${LAN_PORT:-8081}; cd services/api && go run ./cmd/api

run-ios-device: ios-project
	XCODE_DEVELOPER_DIR='$(XCODE_DEVELOPER_DIR)' sh scripts/ios-run-device.sh

test-ios-e2e: ios-project
	@test -n "$$TEST_DATABASE_URL" || { echo "Set TEST_DATABASE_URL to a migrated disposable medication_f4_ database." >&2; exit 1; }
	IOS_DESTINATION='$(IOS_DESTINATION)' XCODE_DEVELOPER_DIR='$(XCODE_DEVELOPER_DIR)' sh scripts/ios-e2e.sh

.PHONY: web-dev web-install test-web-e2e
web-dev:
	pnpm --dir apps/web dev

web-install:
	pnpm --dir apps/web install --frozen-lockfile

test-web-e2e:
	@test -n "$$TEST_DATABASE_URL" || { echo "Set TEST_DATABASE_URL to a migrated disposable medication_f3_ database." >&2; exit 1; }
	pnpm --dir apps/web test:e2e

.PHONY: build-android test-android lint-android test-android-device test-android-e2e
build-android:
	sh scripts/android-gradle.sh :app:assembleDebug

test-android:
	sh scripts/android-gradle.sh :app:testDebugUnitTest

lint-android:
	sh scripts/android-gradle.sh :app:lintDebug :app:lintRelease

test-android-device:
	sh scripts/android-gradle.sh :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=cl.nndsk.medication.core.LocalDatabaseTest,cl.nndsk.medication.core.ReminderTest,cl.nndsk.medication.core.SessionCleanupTest

test-android-e2e:
	sh scripts/android-e2e.sh

.PHONY: test-android-reboot
test-android-reboot:
	sh scripts/android-reboot-test.sh

.PHONY: build-worker dev-worker backup restore-test
build-worker:
	cd services/api && go build -o ../../.bin/worker ./cmd/worker

dev-worker:
	@set -a; if [ -f .env ]; then . ./.env; fi; set +a; cd services/api && go run ./cmd/worker

backup:
	@test -n "$$BACKUP_ARCHIVE" || { echo 'Set BACKUP_ARCHIVE to a new encrypted archive path.' >&2; exit 1; }
	cd services/api && go run ./cmd/backup create "$$BACKUP_ARCHIVE"

restore-test:
	@test -n "$$BACKUP_ARCHIVE" || { echo 'Set BACKUP_ARCHIVE to an encrypted archive path.' >&2; exit 1; }
	cd services/api && go run ./cmd/backup restore-test "$$BACKUP_ARCHIVE"

.PHONY: test-backup
test-backup:
	cd services/api && go build -o ../../.bin/backup ./cmd/backup
	python3 scripts/f6-restore-test.py
