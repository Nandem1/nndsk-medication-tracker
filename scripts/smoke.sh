#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
export DATABASE_URL="${TEST_DATABASE_URL:-${DATABASE_URL:?Set TEST_DATABASE_URL or DATABASE_URL}}"
export FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID:-demo-medication-smoke}"
export HTTP_ADDR="${SMOKE_HTTP_ADDR:-127.0.0.1:18080}"
mkdir -p .bin
(cd services/api && go build -o ../../.bin/api ./cmd/api)
work=$(mktemp -d)
pid=
cleanup() {
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
# Probes never contact identity; this fixture only allows ADC initialization.
printf '%s' '{"type":"authorized_user","client_id":"synthetic","client_secret":"synthetic","refresh_token":"synthetic"}' >"$work/adc.json"
export GOOGLE_APPLICATION_CREDENTIALS="$work/adc.json"
.bin/api >"$work/api.log" 2>&1 &
pid=$!
i=0
until curl --silent --fail "http://$HTTP_ADDR/healthz" >"$work/health.json"; do
  if ! kill -0 "$pid" 2>/dev/null; then cat "$work/api.log"; exit 1; fi
  i=$((i+1))
  if [ "$i" -ge 50 ]; then cat "$work/api.log"; echo 'API startup timed out' >&2; exit 1; fi
  sleep 0.1
done
[ "$(cat "$work/health.json")" = '{"status":"ok"}' ]
code=$(curl --silent --show-error --max-time 5 -o "$work/ready.json" -w '%{http_code}' "http://$HTTP_ADDR/readyz")
[ "$code" = 200 ] && [ "$(cat "$work/ready.json")" = '{"status":"ready"}' ] || { cat "$work/ready.json"; echo "Readiness returned $code" >&2; exit 1; }
kill -TERM "$pid"
wait "$pid"
pid=
echo 'PASS healthz=200 readyz=200 SIGTERM=0'
