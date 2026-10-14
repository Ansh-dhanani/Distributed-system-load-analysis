#!/usr/bin/env bash
# DB-only capacity sweep: varies data size (scale factor) and concurrency (CLIENTS).
# Requires Phase 2 (Postgres) running:  kubectl apply -f apps/demo-shop/phases/phase2-postgres.yaml
#
#   ./scripts/db-bench.sh
#   SCALES="1000 10000 100000" CLIENTS="10 50 100" DURATION=60 ./scripts/db-bench.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/apps/demo-shop/bench/pgbench-job.yaml"
NS=demo

SCALES="${SCALES:-1000 10000 100000}"
CLIENTS="${CLIENTS:-10 50 100}"
DURATION="${DURATION:-60}"
OUT="${OUT:-/tmp/dbbench}"

mkdir -p "$OUT"

kubectl -n "$NS" get statefulset postgres >/dev/null 2>&1 || {
  echo "Postgres not running. Apply apps/demo-shop/phases/phase2-postgres.yaml first."; exit 1; }

for s in $SCALES; do
  for c in $CLIENTS; do
    log="$OUT/pgbench_scale${s}_clients${c}.log"
    echo "=============== scale=$s clients=$c duration=${DURATION}s"

    # render the job with concrete env values (jobs are immutable once created)
    sed -E \
      -e "s/(\{ name: ROWS, value: )\"[^\"]*\"/\1\"$s\"/" \
      -e "s/(\{ name: CLIENTS, value: )\"[^\"]*\"/\1\"$c\"/" \
      -e "s/(\{ name: DURATION, value: )\"[^\"]*\"/\1\"$DURATION\"/" \
      "$MANIFEST" > "$OUT/job.yaml"

    kubectl -n "$NS" delete job pgbench --ignore-not-found --wait=true >/dev/null
    kubectl apply -f "$OUT/job.yaml" >/dev/null
    kubectl -n "$NS" wait --for=condition=complete job/pgbench --timeout=1800s >/dev/null 2>&1 || true
    kubectl -n "$NS" logs job/pgbench | tee "$log"
  done
done

echo
echo "Logs saved under $OUT/pgbench_scale<rows>_clients<c>.log"
echo "Record per run: tps (latency average), latency stddev, failed transactions."
