#!/usr/bin/env bash
# =============================================================================
# test-suite.sh  —  All-in-one load & capacity testing for the demo-shop
#
# Usage:
#   ./scripts/test-suite.sh <test-type> [options]
#
# Test types:
#   ladder       — k6 VU ladder: 10 → 20 → 30 → 40 → 50 → 60 (default)
#   single       — one k6 run at a fixed VU count
#   capacity     — php-apache capacity study (k6-capacity.js)
#   db           — pgbench sweep (scale × clients)
#   smoke        — quick health check + single iteration
#   custom       — full control via environment variables
#   hpa          — watch HPA scaling during a run
#
# Options (env vars):
#   VUS          — max VUs for the ladder (default 60)
#   VU           — fixed VUs for single run (default 30)
#   RAMP         — ramp-up duration (default 1m)
#   HOLD         — steady-state duration (default 2m)
#   SCALES       — pgbench scale factors (default "1000 10000 100000")
#   CLIENTS      — pgbench concurrency (default "10 50 100")
#   DURATION     — pgbench duration per step in seconds (default 60)
#   HOLD_SCALE   — capacity study hold scale factor (default 1000)
#   DRY_RUN      — print commands without executing (default false)
#
# Examples:
#   ./scripts/test-suite.sh ladder
#   VUS=100 ./scripts/test-suite.sh ladder
#   ./scripts/test-suite.sh single
#   VU=50 HOLD=3m ./scripts/test-suite.sh single
#   ./scripts/test-suite.sh capacity
#   ./scripts/test-suite.sh db
#   SCALES="5000 50000" CLIENTS="20 80" ./scripts/test-suite.sh db
#   ./scripts/test-suite.sh smoke
#   TRACE=true TARGET_URL=http://demo-shop.demo.svc.cluster.local ./scripts/test-suite.sh custom
#   VUS=40 ./scripts/test-suite.sh hpa
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig}"
NS=demo
K6_REALISTIC="$REPO_ROOT/apps/demo-shop/load/k6-realistic.js"
K6_CAPACITY="$REPO_ROOT/load-test/k6-capacity.js"

# Colours for output
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'

log_info()  { echo -e "${G}[TEST-SUITE]${N} $*"; }
log_warn()  { echo -e "${Y}[TEST-SUITE]${N} $*"; }
log_error() { echo -e "${R}[TEST-SUITE]${N} $*" >&2; }
log_step()  { echo -e "\n${B}══════════════════════════════════════════════════════════════${N}"; echo -e "${B}  $*${N}"; echo -e "${B}══════════════════════════════════════════════════════════════${N}\n"; }

DRY_RUN="${DRY_RUN:-false}"

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${Y}[DRY-RUN]${N} $*"
  else
    eval "$@"
  fi
}

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { log_error "kubectl not found in PATH"; exit 1; }
  command -v aws >/dev/null 2>&1 || { log_warn "aws CLI not found — port-forward will not work locally"; }
  [[ -f "$KUBECONFIG" ]] || { log_error "kubeconfig not found at $KUBECONFIG"; exit 1; }

  if ! kubectl -n "$NS" get svc demo-shop &>/dev/null; then
    log_error "demo-shop service not found in namespace '$NS'."
    log_error "Deploy first:  ./scripts/deploy-app.sh 3"
    exit 1
  fi
  log_info "Prerequisites OK — demo-shop is deployed"
}

# ── Individual test functions ──────────────────────────────────────────────

test_smoke() {
  log_step "SMOKE TEST — health check + single iteration"
  run_cmd "kubectl -n $NS port-forward svc/demo-shop 18080:80 &"
  sleep 4
  run_cmd "curl -s localhost:18080/health"
  echo
  run_cmd "curl -s 'localhost:18080/products?limit=3'"
  echo
  run_cmd "pkill -f 'port-forward svc/demo-shop 18080' 2>/dev/null; true"
  log_info "Smoke test passed"
}

test_ladder() {
  local VUS="${VUS:-60}"
  local RAMP="${RAMP:-1m}"
  local HOLD="${HOLD:-2m}"
  local STEP="${STEP:-10}"

  log_step "k6 LOAD LADDER — ${STEP} → ${VUS} VUs"

  for ((vu = STEP; vu <= VUS; vu += STEP)); do
    log_info "Running k6 at ${vu} VUs (ramp=${RAMP}, hold=${HOLD})"
    run_cmd "VUS=$vu RAMP=$RAMP HOLD=$HOLD ./scripts/run-load.sh"
    log_info "Completed ${vu} VUs"
    [[ "$DRY_RUN" == "true" ]] && continue
    log_info "Cooling down 10s before next step…"
    sleep 10
  done
  log_info "Ladder complete — ${VUS} VUs max"
}

test_single() {
  local VU="${VU:-30}"
  local RAMP="${RAMP:-1m}"
  local HOLD="${HOLD:-2m}"

  log_step "SINGLE k6 RUN — ${VU} VUs (ramp=${RAMP}, hold=${HOLD})"
  run_cmd "VU=$VU RAMP=$RAMP HOLD=$HOLD ./scripts/run-load.sh"
}

test_capacity() {
  local HOLD_SCALE="${HOLD_SCALE:-1000}"
  local RAMP="${RAMP:-1m}"
  local HOLD="${HOLD:-2m}"

  log_step "CAPACITY STUDY — php-apache (scale=${HOLD_SCALE})"
  log_warn "This targets the php-apache study workload, not demo-shop."
  run_cmd "RAMP=$RAMP HOLD=$HOLD HOLD_SCALE=$HOLD_SCALE TARGET_URL=http://php-apache.demo.svc.cluster.local ./scripts/run-load.sh load-test/k6-capacity.js"
}

test_db() {
  local SCALES="${SCALES:-1000 10000 100000}"
  local CLIENTS="${CLIENTS:-10 50 100}"
  local DURATION="${DURATION:-60}"

  log_step "DATABASE BENCHMARK — pgbench sweep"
  log_info "Scales: $SCALES  |  Clients: $CLIENTS  |  Duration: ${DURATION}s"

  run_cmd "SCALES='$SCALES' CLIENTS='$CLIENTS' DURATION=$DURATION ./scripts/db-bench.sh"
}

test_custom() {
  log_step "CUSTOM k6 RUN — full control via env vars"
  log_info "TARGET_URL=${TARGET_URL:-http://demo-shop.demo.svc.cluster.local}"
  log_info "VUS=${VUS:-20}  RAMP=${RAMP:-1m}  HOLD=${HOLD:-2m}"
  log_info "TRACE=${TRACE:-false}"

  local SCRIPT="${SCRIPT:-$K6_REALISTIC}"
  run_cmd "VUS=${VUS:-20} RAMP=${RAMP:-1m} HOLD=${HOLD:-2m} TRACE=${TRACE:-false} TARGET_URL=${TARGET_URL:-http://demo-shop.demo.svc.cluster.local} ./scripts/run-load.sh $SCRIPT"
}

test_hpa() {
  local VUS="${VUS:-40}"
  local HOLD="${HOLD:-2m}"

  log_step "HPA WATCH — autoscaling under ${VUS} VUs"

  log_info "Starting HPA watcher in background…"
  run_cmd "kubectl -n $NS get hpa demo-shop --watch &"
  local HPA_PID=$!

  sleep 2
  log_info "Starting load at ${VUS} VUs…"
  run_cmd "VUS=$VUS HOLD=$HOLD ./scripts/run-load.sh"

  log_info "Stopping HPA watcher…"
  run_cmd "kill $HPA_PID 2>/dev/null; true"

  log_info "Final HPA state:"
  run_cmd "kubectl -n $NS get hpa demo-shop"
  run_cmd "kubectl -n $NS get pods -l app=demo-shop -o wide"
}

test_metrics_snapshot() {
  log_step "METRICS SNAPSHOT — capture current state"
  run_cmd "kubectl -n $NS top nodes"
  run_cmd "kubectl -n $NS top pods"
  run_cmd "kubectl -n $NS get hpa"
  run_cmd "kubectl -n $NS get pods -o wide"
}

test_generate_report() {
  log_step "REPORT — summarise results from all runs"
  local REPORT_DIR="${REPORT_DIR:-$REPO_ROOT/results}"
  mkdir -p "$REPORT_DIR"

  log_info "Collecting k6 job logs…"
  local k6_jobs
  k6_jobs=$(kubectl -n "$NS" get jobs -l app=k6 -o name 2>/dev/null || true)

  if [[ -z "$k6_jobs" ]]; then
    log_warn "No k6 jobs found in namespace $NS"
    return
  fi

  for job in $k6_jobs; do
    local name="${job#job/}"
    log_info "Saving log for $name"
    kubectl -n "$NS" logs "job/$name" > "$REPORT_DIR/${name}.log" 2>&1 || true
  done

  log_info "Results saved to $REPORT_DIR"
  ls -lh "$REPORT_DIR"
}

# ── Usage ──────────────────────────────────────────────────────────────────

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Current environment:"
  echo "  KUBECONFIG=$KUBECONFIG"
  echo "  NS=$NS"
  echo "  VUS=${VUS:-60}  RAMP=${RAMP:-1m}  HOLD=${HOLD:-2m}"
}

# ── Main ───────────────────────────────────────────────────────────────────

TEST_TYPE="${1:-help}"
shift || true

case "$TEST_TYPE" in
  ladder)    check_prereqs; test_ladder ;;
  single)    check_prereqs; test_single ;;
  capacity)  check_prereqs; test_capacity ;;
  db)        check_prereqs; test_db ;;
  smoke)     check_prereqs; test_smoke ;;
  custom)    check_prereqs; test_custom ;;
  hpa)       check_prereqs; test_hpa ;;
  metrics)   check_prereqs; test_metrics_snapshot ;;
  report)    test_generate_report ;;
  all)
    check_prereqs
    test_smoke
    test_ladder
    test_db
    test_generate_report
    ;;
  help|--help|-h) usage ;;
  *)
    log_error "Unknown test type: $TEST_TYPE"
    usage
    exit 1
    ;;
esac

log_info "Done."
