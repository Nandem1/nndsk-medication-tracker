#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
export DATABASE_URL="${TEST_DATABASE_URL:-${DATABASE_URL:?Set TEST_DATABASE_URL or DATABASE_URL}}"
export HTTP_ADDR="${SMOKE_HTTP_ADDR:-127.0.0.1:18080}"
make build
work=$(mktemp -d)
pid=
cleanup() {
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
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
