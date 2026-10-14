#!/usr/bin/env bash
# One-command load test (runs k6 inside the cluster, against demo-shop).
#
#   ./scripts/run-load.sh                        # default: apps/demo-shop/load/k6-realistic.js
#   ./scripts/run-load.sh load-test/k6-capacity.js
#   TRACE=true ./scripts/run-load.sh             # also export client spans to Jaeger
#
# VU level is baked into the script (RAMP_VU/HOLD_VU or the stages array).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${1:-$REPO_ROOT/apps/demo-shop/load/k6-realistic.js}"
NS=demo
TIMEOUT="${TIMEOUT:-900s}"
JOB_MANIFEST="$REPO_ROOT/load-test/k6-job.yaml"

# Restore the (possibly TRACE-patched) Job manifest no matter how we exit.
restore_job() {
  if [[ -f "$JOB_MANIFEST.orig" ]]; then
    mv -f "$JOB_MANIFEST.orig" "$JOB_MANIFEST"
  fi
}
trap restore_job EXIT

echo "==> using script: $SCRIPT"

if [[ "${TRACE:-false}" == "true" ]]; then
  echo "==> enabling k6 -> Jaeger tracing"
  cp -f "$JOB_MANIFEST" "$JOB_MANIFEST.orig"
  kubectl -n "$NS" set env deploy/demo-shop \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger.demo.svc.cluster.local:4318
  # `set env` rolls the pods; wait so early traffic is actually instrumented.
  kubectl -n "$NS" rollout status deploy/demo-shop --timeout=120s || true
  python3 -c "import yaml" 2>/dev/null || { echo "need PyYAML for the OTLP patch"; exit 1; }
  python3 - "$JOB_MANIFEST" <<'PY'
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
print("    patched k6-job.yaml with k6 --traces-output=otel")
PY
fi

echo "==> creating configmap k6-script"
kubectl -n "$NS" create configmap k6-script --from-file=k6.js="$SCRIPT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> running job"
kubectl -n "$NS" delete job k6 --ignore-not-found --wait=true >/dev/null
kubectl apply -f "$JOB_MANIFEST"
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
