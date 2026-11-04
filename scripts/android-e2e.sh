#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to a migrated disposable medication_f4_ database}"
: "${ANDROID_SERIAL:?Set ANDROID_SERIAL to the synthetic test device or emulator}"
ANDROID_HOME=${ANDROID_HOME:-"$ROOT/.tmp/android-sdk"}
ADB="$ANDROID_HOME/platform-tools/adb"
LOGS="$ROOT/.tmp/android-e2e"
API_PID=""
EMULATOR_PID=""
cleanup() {
    [ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true
    [ -z "$EMULATOR_PID" ] || kill "$EMULATOR_PID" 2>/dev/null || true
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys deviceidle unforce >/dev/null 2>&1 || true
    "$ADB" -s "$ANDROID_SERIAL" shell dumpsys battery reset >/dev/null 2>&1 || true
    for port in 9099 18083 18084; do "$ADB" -s "$ANDROID_SERIAL" reverse --remove "tcp:$port" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT INT TERM
for port in 9099 18083 18084; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then echo "Port $port is already in use; stop that test server first." >&2; exit 1; fi
done
wait_for() {
    count=0
    until curl -fsS -o /dev/null "$1"; do
        count=$((count + 1)); [ "$count" -lt 120 ] || { echo "Test service did not start. See $LOGS." >&2; exit 1; }
        sleep 1
    done
}
mkdir -p "$LOGS"
cd "$ROOT/infrastructure/firebase"
pnpm dlx firebase-tools@15.34.2 emulators:start --only auth --project demo-medication-local > "$LOGS/auth.log" 2>&1 &
EMULATOR_PID=$!
wait_for http://127.0.0.1:9099/
cd "$ROOT/services/api"
go build -tags=e2e -o "$LOGS/api" ./cmd/e2e
FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 FIREBASE_PROJECT_ID=demo-medication-local "$LOGS/api" > "$LOGS/api.log" 2>&1 &
API_PID=$!
wait_for http://127.0.0.1:18083/healthz
wait_for http://127.0.0.1:18084/healthz
for port in 9099 18083 18084; do "$ADB" -s "$ANDROID_SERIAL" reverse "tcp:$port" "tcp:$port"; done
cd "$ROOT"
sh scripts/android-gradle.sh :app:assembleE2e :app:assembleE2eAndroidTest -PtestBuildType=e2e
"$ADB" -s "$ANDROID_SERIAL" install -r apps/android/app/build/outputs/apk/e2e/app-e2e.apk
"$ADB" -s "$ANDROID_SERIAL" install -r apps/android/app/build/outputs/apk/androidTest/e2e/app-e2e-androidTest.apk
"$ADB" -s "$ANDROID_SERIAL" shell pm grant cl.nndsk.medication.e2e android.permission.POST_NOTIFICATIONS
"$ADB" -s "$ANDROID_SERIAL" shell cmd appops set cl.nndsk.medication.e2e SCHEDULE_EXACT_ALARM allow
"$ADB" -s "$ANDROID_SERIAL" shell am instrument -w -e class cl.nndsk.medication.core.AndroidE2ETest cl.nndsk.medication.e2e.test/androidx.test.runner.AndroidJUnitRunner > "$LOGS/instrumentation.log"
rg -q 'OK \([1-9][0-9]* tests?\)' "$LOGS/instrumentation.log" || { cat "$LOGS/instrumentation.log"; exit 1; }
"$ADB" -s "$ANDROID_SERIAL" exec-out run-as cl.nndsk.medication.e2e cat files/e2e-agenda.png > "$LOGS/agenda.png"
printf 'PASS: Android UI, Doze, notification, offline retries and conflict with real API/PostgreSQL.\n'
