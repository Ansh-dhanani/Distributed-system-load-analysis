#!/usr/bin/env bash
# Local end-to-end smoke test for demo-shop — no Kubernetes or AWS required.
#
#   ./scripts/smoke-test.sh
#   SKIP_BUILD=1 ./scripts/smoke-test.sh          # reuse an existing image
#   APP_PORT=18080 ./scripts/smoke-test.sh
#   NETWORK=smoke-net ./scripts/smoke-test.sh     # isolated bridge network
#
# Builds the image and verifies BOTH data tiers against a throwaway Postgres+Redis:
#   Phase 1  (SQLite)            -> /health db=sqlite cache=false
#   Phase 3  (Postgres + Redis)  -> /health db=postgres cache=true,
#                                   cache miss->hit, cart/checkout, /metrics
#
# NETWORK=host (default) runs containers on the host network, which also works
# where container-to-container bridge traffic is blocked (some sandboxes).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-demo-shop:smoke}"
APP_PORT="${APP_PORT:-18080}"
NETWORK="${NETWORK:-host}"
PREFIX="demo-shop-smoke-$$"
SQL_APP="$PREFIX-sqlite"; PG="$PREFIX-pg"; REDIS="$PREFIX-redis"; PG_APP="$PREFIX-pgapp"

cleanup() {
  docker rm -f "$SQL_APP" "$PG_APP" "$PG" "$REDIS" >/dev/null 2>&1 || true
  [[ "$NETWORK" != "host" ]] && docker network rm "$NETWORK" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- network / addressing ---------------------------------------------------
if [[ "$NETWORK" == "host" ]]; then
  PG_HOST="localhost"; REDIS_HOST="localhost"; PUBLISH=()
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | grep -q ':5432 ' && fail "host port 5432 busy (stop it or use NETWORK=smoke-net)"
    ss -ltn | grep -q ':6379 ' && fail "host port 6379 busy"
  fi
else
  docker network create "$NETWORK" >/dev/null 2>&1 || true
  PG_HOST="$PG"; REDIS_HOST="$REDIS"; PUBLISH=(-p "$APP_PORT:$APP_PORT")
fi

wait_http() { for _ in $(seq 1 60); do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
wait_pg()   { for _ in $(seq 1 60); do docker exec "$PG" pg_isready -U demo >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
assert_contains() { grep -q -- "$2" <<<"$1" || fail "$3"; }

app_run() {  # name  extra-env...
  local name="$1"; shift
  docker run -d --name "$name" --network "$NETWORK" "${PUBLISH[@]}" "$@" \
    "$IMAGE" uvicorn main:app --host 0.0.0.0 --port "$APP_PORT" >/dev/null
}

# --- build ------------------------------------------------------------------
if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
  echo "==> building $IMAGE"
  docker build -t "$IMAGE" "$REPO_ROOT/apps/demo-shop" >/dev/null
fi

echo "==> Phase 1: SQLite"
app_run "$SQL_APP"
wait_http "http://localhost:$APP_PORT/health" || { docker logs "$SQL_APP"; fail "sqlite app not healthy"; }
H="$(curl -fsS "http://localhost:$APP_PORT/health")"
assert_contains "$H" '"db":"sqlite"'  "health should report sqlite: $H"
assert_contains "$H" '"cache":false'  "health should report cache off: $H"
assert_contains "$(curl -fsS "http://localhost:$APP_PORT/products?limit=2")" '"items"' "products returned nothing"
assert_contains "$(curl -fsS -X POST "http://localhost:$APP_PORT/cart" -H 'Content-Type: application/json' -d '{"user_id":"s1","product_id":1,"qty":1}')" '"added":true' "cart add failed"
assert_contains "$(curl -fsS -X POST "http://localhost:$APP_PORT/checkout/s1")" '"ordered"' "checkout failed"
docker rm -f "$SQL_APP" >/dev/null
echo "    ok"

echo "==> Phase 3: Postgres + Redis"
docker run -d --name "$PG" --network "$NETWORK" -e POSTGRES_USER=demo -e POSTGRES_PASSWORD=demo -e POSTGRES_DB=demo postgres:16-alpine >/dev/null
docker run -d --name "$REDIS" --network "$NETWORK" redis:7-alpine redis-server --save '' --appendonly no >/dev/null
wait_pg || { docker logs "$PG" | tail; fail "postgres not ready"; }
app_run "$PG_APP" \
  -e DATABASE_URL="postgresql://demo:demo@$PG_HOST:5432/demo" \
  -e REDIS_URL="redis://$REDIS_HOST:6379/0"
wait_http "http://localhost:$APP_PORT/health" || { docker logs "$PG_APP"; fail "postgres app not healthy"; }
H="$(curl -fsS "http://localhost:$APP_PORT/health")"
assert_contains "$H" '"db":"postgres"' "health should report postgres: $H"
assert_contains "$H" '"cache":true'    "health should report cache on: $H"

assert_contains "$(curl -fsS "http://localhost:$APP_PORT/products?limit=2")" '"cached":false' "first read should be a cache miss"
assert_contains "$(curl -fsS "http://localhost:$APP_PORT/products?limit=2")" '"cached":true'  "second read should be a cache hit"
assert_contains "$(curl -fsS -X POST "http://localhost:$APP_PORT/cart" -H 'Content-Type: application/json' -d '{"user_id":"s2","product_id":2,"qty":1}')" '"added":true' "cart add failed"
assert_contains "$(curl -fsS -X POST "http://localhost:$APP_PORT/checkout/s2")" '"ordered":1' "checkout should order 1 item"
METRICS="$(curl -fsS "http://localhost:$APP_PORT/metrics")"
assert_contains "$METRICS" 'shop_requests_total' "metrics missing shop_requests_total"
assert_contains "$METRICS" 'shop_cache_events_total{result="hit"}' "metrics missing a cache hit"
echo "    ok"

echo
echo "PASS: demo-shop works locally (SQLite and Postgres+Redis)"
