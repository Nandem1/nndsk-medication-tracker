#!/bin/sh
# Flujo E2E de iOS: simulador, API y PostgreSQL reales, identidad del emulador oficial de Firebase.
# Exige una base desechable medication_f4_ ya migrada. No usa datos ni proyectos reales.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIREBASE_TOOLS_VERSION=15.34.2
PROJECT=demo-medication-local
LOGS="$ROOT/.tmp/ios-e2e"
EMULATOR_PID=""
API_PID=""

cleanup() {
	[ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true
	[ -z "$EMULATOR_PID" ] || kill "$EMULATOR_PID" 2>/dev/null || true
	wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait_for() {
	attempt=0
	until curl -s -o /dev/null "$1"; do
		attempt=$((attempt + 1))
		if [ "$attempt" -ge 120 ]; then
			echo "Timeout waiting for $2. See $LOGS." >&2
			exit 1
		fi
		sleep 1
	done
}

mkdir -p "$LOGS"

for port in 9099 18083 18084; do
	if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
		echo "Port $port is in use. Stop that process: a stale server would invalidate the results." >&2
		exit 1
	fi
done

cd "$ROOT/infrastructure/firebase"
pnpm dlx "firebase-tools@$FIREBASE_TOOLS_VERSION" emulators:start --only auth --project "$PROJECT" >"$LOGS/emulator.log" 2>&1 &
EMULATOR_PID=$!
wait_for http://127.0.0.1:9099/ "the identity emulator"

# Se compila antes de ejecutar: matar `go run` dejaría vivo el binario hijo.
cd "$ROOT/services/api"
go build -tags=e2e -o "$LOGS/e2e-api" ./cmd/e2e
FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 FIREBASE_PROJECT_ID="$PROJECT" "$LOGS/e2e-api" >"$LOGS/api.log" 2>&1 &
API_PID=$!
wait_for http://127.0.0.1:18083/healthz "the API"
wait_for http://127.0.0.1:18084/healthz "the fault proxy"

cd "$ROOT"
# Sin restos de una corrida anterior: una cola heredada cambiaría el flujo que se quiere probar.
SIMULATOR=$(printf '%s' "$IOS_DESTINATION" | sed -n 's/.*name=\(.*\)$/\1/p')
if [ -n "$SIMULATOR" ]; then
	DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
	DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun simctl uninstall "$SIMULATOR" dev.nndsk.MedicationTracker
fi
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
	-project apps/ios/MedicationTracker.xcodeproj \
	-derivedDataPath .tmp/ios-derived \
	-scheme MedicationTrackerE2E \
	-destination "$IOS_DESTINATION" \
	API_BASE_URL='http:/$()/127.0.0.1:18084' \
	FIREBASE_API_KEY=e2e-public-placeholder \
	FIREBASE_AUTH_EMULATOR_ORIGIN='http:/$()/127.0.0.1:9099' \
	${IOS_E2E_ONLY:+-only-testing:"$IOS_E2E_ONLY"} \
	test
