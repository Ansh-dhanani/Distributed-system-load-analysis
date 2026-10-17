#!/usr/bin/env bash
# =============================================================================
# test-suite.sh  —  All-in-one load & capacity testing for the demo-shop
#
# Usage:
#   ./scripts/test-suite.sh <test-type>
#
# Test types:
#   smoke        — health check + 1 request
#   single       — one k6 run (default 30 VUs)
#   ladder       — k6 VU ladder (10→20→30→40→50→60)
#   db           — pgbench sweep
#   hpa          — watch HPA scaling live
#   metrics      — snapshot: top nodes/pods, HPA
#   report       — collect k6 job logs
#   all          — smoke → ladder → db → report
#
# Env vars: VU, VUS, RAMP, HOLD, TRACE, TARGET_URL, SCALES, CLIENTS, DURATION
#
# Examples:
#   ./scripts/test-suite.sh single
#   VU=50 HOLD=3m ./scripts/test-suite.sh single
#   ./scripts/test-suite.sh ladder
#   VUS=100 ./scripts/test-suite.sh ladder
#   ./scripts/test-suite.sh db
#   ./scripts/test-suite.sh all
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig}"
NS=demo

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
log_info()  { echo -e "${G}[TEST]${N} $*"; }
log_warn()  { echo -e "${Y}[TEST]${N} $*"; }
log_error() { echo -e "${R}[TEST]${N} $*" >&2; }
log_step()  { echo -e "\n${B}── $* ──${N}"; }

check_prereqs() {
  [[ -f "$KUBECONFIG" ]] || { log_error "kubeconfig not found"; exit 1; }
  kubectl -n "$NS" get svc demo-shop &>/dev/null || {
    log_error "demo-shop not deployed. Run: ./scripts/deploy-app.sh 3"; exit 1;
  }
  log_info "Ready"
}

test_smoke() {
  log_step "SMOKE"
  kubectl -n $NS port-forward svc/demo-shop 18080:80 &
  sleep 4
  curl -s localhost:18080/health; echo
  curl -s 'localhost:18080/products?limit=2'; echo
  pkill -f "port-forward svc/demo-shop 18080" 2>/dev/null; true
}

test_single() {
  log_step "SINGLE RUN — ${VU:-30} VUs"
  VU="${VU:-30}" RAMP="${RAMP:-1m}" HOLD="${HOLD:-2m}" ./scripts/run-load.sh
}

test_ladder() {
  log_step "LADDER — 10 → ${VUS:-60} VUs"
  for vu in 10 20 30 40 50 60; do
    [[ $vu -gt ${VUS:-60} ]] && break
    log_info "${vu} VUs"
    VU=$vu RAMP="${RAMP:-1m}" HOLD="${HOLD:-2m}" ./scripts/run-load.sh
    sleep 5
  done
}


test_db() {
  log_step "DB BENCHMARK"
  SCALES="${SCALES:-1000 10000 100000}" \
  CLIENTS="${CLIENTS:-10 50 100}" \
  DURATION="${DURATION:-60}" \
    ./scripts/db-bench.sh
}

test_hpa() {
  log_step "HPA WATCH — ${VUS:-40} VUs"
  kubectl -n $NS get hpa demo-shop --watch &
  local pid=$!
  sleep 2
  VUS="${VUS:-40}" HOLD="${HOLD:-2m}" ./scripts/run-load.sh
  kill $pid 2>/dev/null; true
  kubectl -n $NS get hpa demo-shop
  kubectl -n $NS get pods -l app=demo-shop -o wide
}

test_metrics() {
  log_step "METRICS"
  kubectl -n $NS top nodes
  kubectl -n $NS top pods
  kubectl -n $NS get hpa
}

test_report() {
  log_step "REPORT"
  local out="${REPORT_DIR:-$REPO_ROOT/results}"
  mkdir -p "$out"
  for job in $(kubectl -n $NS get jobs -l app=k6 -o name 2>/dev/null || true); do
    local name="${job#job/}"
    kubectl -n $NS logs "job/$name" > "$out/${name}.log" 2>&1 || true
    log_info "Saved $name"
  done
  ls -lh "$out"
}

# ── Main ───────────────────────────────────────────────────────────────────

TYPE="${1:-help}"
shift || true

case "$TYPE" in
  smoke)    check_prereqs; test_smoke ;;
  single)    check_prereqs; test_single ;;
  ladder)    check_prereqs; test_ladder ;;
  db)        check_prereqs; test_db ;;
  hpa)       check_prereqs; test_hpa ;;
  metrics)   check_prereqs; test_metrics ;;
  report)    test_report ;;
  all)       check_prereqs; test_smoke; test_ladder; test_db; test_report ;;
  help|--help|-h)
    sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    log_error "Unknown: $TYPE"
    echo "Run: ./scripts/test-suite.sh help"
    exit 1
    ;;
esac

log_info "Done."
