#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
set -a
. ./.env
set +a
export HTTP_ADDR=127.0.0.1:18081
work=$(mktemp -d)
pid=
cleanup() {
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  docker compose up -d --wait db
  rm -rf "$work"
}
trap cleanup EXIT
.bin/api >"$work/api.log" 2>&1 &
pid=$!
check() {
  code=$(curl -sS --max-time 5 -o "$work/body" -w '%{http_code}' "http://$HTTP_ADDR/$1")
  [ "$code" = "$2" ] || { cat "$work/api.log"; cat "$work/body"; exit 1; }
  printf '%s %s %s\n' "$1" "$code" "$(cat "$work/body")"
}
i=0
until curl -sf "http://$HTTP_ADDR/healthz" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || exit 1
  sleep 0.1
done
check healthz 200
check readyz 200
docker compose stop db
check healthz 200
check readyz 503
docker compose up -d --wait db
check readyz 200
kill -TERM "$pid"
wait "$pid"
pid=
printf 'PASS DB outage, recovery and SIGTERM\n'
