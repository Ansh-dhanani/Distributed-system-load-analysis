#!/usr/bin/env bash
# One-command load test (runs k6 inside the cluster).
#
#   ./scripts/run-load.sh                        # demo-shop, k6-realistic.js
#   ./scripts/run-load.sh load-test/k6-capacity.js
#   TARGET_URL=http://php-apache.demo.svc.cluster.local \
#     ./scripts/run-load.sh load-test/k6-capacity.js   # the PHP capacity study
#   TRACE=true ./scripts/run-load.sh             # also export client spans to Jaeger
#
# VUs are env-driven via k6's __ENV and forwarded into the Job: override them
# per run to build a ladder without editing files, e.g.
#   VUS=5 ./scripts/run-load.sh
#   VUS=30 HOLD=2m ./scripts/run-load.sh
#   VUS=30 RAMP=1m    HOLD=3m ./scripts/run-load.sh load-test/k6-capacity.js
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${1:-$REPO_ROOT/apps/demo-shop/load/k6-realistic.js}"
NS=demo
TIMEOUT="${TIMEOUT:-900s}"
JOB_MANIFEST="$REPO_ROOT/load-test/k6-job.yaml"

# Which service k6 should hit. The capacity script targets the php-apache study,
# everything else targets demo-shop; override explicitly with TARGET_URL=...
if [[ -z "${TARGET_URL:-}" ]]; then
  case "$(basename "$SCRIPT")" in
    k6-capacity.js) TARGET_URL="http://php-apache.demo.svc.cluster.local" ;;
    *)              TARGET_URL="http://demo-shop.demo.svc.cluster.local" ;;
  esac
fi

# Render the Job into a temp file: the tracked manifest is never modified, so a
# crashed run can't leave the repo dirty.
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

echo "==> using script: $SCRIPT"
echo "==> target:       $TARGET_URL"

# VU ladder knobs are env-driven and forwarded into the k6 job, so they can be
# set without editing the script:  VUS=30 HOLD=3m ./scripts/run-load.sh
ENV_ARGS=(TARGET_URL="$TARGET_URL")
[[ -n "${VUS:-}" ]]  && ENV_ARGS+=(VUS="$VUS")
[[ -n "${RAMP:-}" ]] && ENV_ARGS+=(RAMP="$RAMP")
[[ -n "${HOLD:-}" ]] && ENV_ARGS+=(HOLD="$HOLD")

kubectl set env --local -f "$JOB_MANIFEST" \
  "${ENV_ARGS[@]}" -o yaml > "$RENDERED"

if [[ "${TRACE:-false}" == "true" ]]; then
  echo "==> enabling k6 -> Jaeger tracing"
  kubectl -n "$NS" set env deploy/demo-shop \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger.demo.svc.cluster.local:4318
  # `set env` rolls the pods; wait so early traffic is actually instrumented.
  kubectl -n "$NS" rollout status deploy/demo-shop --timeout=120s || true
  python3 -c "import yaml" 2>/dev/null || { echo "need PyYAML for the OTLP patch"; exit 1; }
  python3 - "$RENDERED" <<'PY'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p))
c = d["spec"]["template"]["spec"]["containers"][0]
c["args"] = [
    "run",
    "--traces-output=otel=http://jaeger.demo.svc.cluster.local:4318,proto=http",
    "/scripts/k6.js",
]
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
print("    patched k6 Job with --traces-output=otel")
PY
fi

echo "==> creating configmap k6-script"
kubectl -n "$NS" create configmap k6-script --from-file=k6.js="$SCRIPT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> running job"
kubectl -n "$NS" delete job k6 --ignore-not-found --wait=true >/dev/null
kubectl apply -f "$RENDERED"
kubectl -n "$NS" wait --for=condition=complete job/k6 --timeout="$TIMEOUT" || true

echo "==> summary"
kubectl -n "$NS" logs job/k6 | tail -30

echo
echo "==> next steps"
echo "  watch scaling:  kubectl -n demo get hpa demo-shop --watch"
echo "  watch pods:     kubectl -n demo get pods -w"
echo "  prometheus:     kubectl -n demo port-forward svc/prometheus 9090:9090"
echo "  grafana:        kubectl -n demo port-forward svc/grafana 3000:3000"
echo "  jaeger:         kubectl -n demo port-forward svc/jaeger 16686:16686"
echo "  app UI:         kubectl -n demo port-forward svc/demo-shop 8080:80"

if [[ "${TRACE:-false}" == "true" ]]; then
  echo "==> disabling app tracing (was only enabled for this run)"
  kubectl -n "$NS" set env deploy/demo-shop OTEL_EXPORTER_OTLP_ENDPOINT-
fi
