#!/usr/bin/env bash
# Deploy the demo-shop app for a phase, with one configurable image reference.
#
#   ./scripts/deploy-app.sh 1                   # Phase 1: SQLite in the pod
#   ./scripts/deploy-app.sh 2                   # Phase 2: PostgreSQL
#   ./scripts/deploy-app.sh 3                   # Phase 3: PostgreSQL + Redis
#   IMAGE=myuser/demo-shop:v2 ./scripts/deploy-app.sh 3
#
# The app image is no longer hardcoded in three manifests: it is rendered here,
# so you build+push ONE image and point IMAGE at it. Postgres/Redis images are
# left untouched. The manifests still work with plain `kubectl apply -f` (they
# keep the default image) if you prefer.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/apps/demo-shop"
DEFAULT_IMAGE="anshdhanani/demo-shop:latest"
IMAGE="${IMAGE:-$DEFAULT_IMAGE}"
PHASE="${1:-1}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() {
  # Replace only the demo-shop image line, leaving postgres/redis alone.
  sed "s#${DEFAULT_IMAGE}#${IMAGE}#g" "$1" > "$2"
}

echo "==> phase: $PHASE   image: $IMAGE"

case "$PHASE" in
  1|sqlite|base)
    render "$APP_DIR/k8s/deployment.yaml" "$TMP/phase1.yaml"
    kubectl apply -f "$TMP/phase1.yaml"
    ;;
  2|postgres)
    render "$APP_DIR/phases/phase2-postgres.yaml" "$TMP/phase2.yaml"
    kubectl apply -f "$TMP/phase2.yaml"
    ;;
  3|cache|redis)
    render "$APP_DIR/phases/phase2-postgres.yaml" "$TMP/phase2.yaml"
    render "$APP_DIR/phases/phase3-cache.yaml" "$TMP/phase3.yaml"
    kubectl apply -f "$TMP/phase2.yaml"
    kubectl apply -f "$TMP/phase3.yaml"
    ;;
  *)
    echo "usage: $0 [1|2|3]   (1=sqlite, 2=postgres, 3=postgres+redis)" >&2
    exit 2
    ;;
esac

echo "==> waiting for demo-shop rollout"
kubectl -n demo rollout status deploy/demo-shop --timeout=180s || true
echo "==> verify:  kubectl -n demo port-forward svc/demo-shop 8080:80  &&  curl localhost:8080/health"
