#!/usr/bin/env bash
# Deploy the demo-shop app for a phase, with one configurable image reference.
#
#   ./scripts/deploy-app.sh 1                   # Phase 1: SQLite in the pod
#   ./scripts/deploy-app.sh 2                   # Phase 2: PostgreSQL
#   ./scripts/deploy-app.sh 3                   # Phase 3: PostgreSQL + Redis
#   IMAGE=ghcr.io/me/demo-shop:v2 ./scripts/deploy-app.sh 3
#
# Private registry? Let the cluster pull it with a pull secret:
#   PULL_SECRET_USER=<user> PULL_SECRET_TOKEN=<token> \
#     IMAGE=ghcr.io/me/demo-shop:v2 ./scripts/deploy-app.sh 3
# Docker Hub images are pulled anonymously, so nothing extra is needed there.
# (Or make the package public in the registry and omit the two vars.)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/apps/demo-shop"
DEFAULT_IMAGE="anshdhanani/demo-shop:latest"
IMAGE="${IMAGE:-$DEFAULT_IMAGE}"
PHASE="${1:-1}"
NS=demo
PULL_SECRET_NAME="${PULL_SECRET_NAME:-demo-pull}"

registry_of() {
  local ref="${1%@*}" first="${1%%/*}"
  if [[ "$ref" != */* || ( "$first" != *.* && "$first" != *:* && "$first" != localhost ) ]]; then
    echo "docker.io"
  else
    echo "$first"
  fi
}
REGISTRY="$(registry_of "$IMAGE")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() {
  # Replace only the demo-shop image line, leaving postgres/redis alone.
  sed "s#${DEFAULT_IMAGE}#${IMAGE}#g" "$1" > "$2"
}

echo "==> phase: $PHASE   image: $IMAGE   registry: $REGISTRY"

# Create the namespace first so a pull secret can exist before the pods start.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Optional private-registry pull secret (skipped for Docker Hub / public packages).
if [[ "$REGISTRY" != "docker.io" && "$REGISTRY" != "index.docker.io" \
      && -n "${PULL_SECRET_TOKEN:-}" ]]; then
  echo "==> creating pull secret $NS/$PULL_SECRET_NAME for $REGISTRY"
  kubectl -n "$NS" create secret docker-registry "$PULL_SECRET_NAME" \
    --docker-server="$REGISTRY" \
    --docker-username="${PULL_SECRET_USER:-}" \
    --docker-password="$PULL_SECRET_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

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

# Wire the pull secret into the app pods when one exists.
if kubectl -n "$NS" get secret "$PULL_SECRET_NAME" >/dev/null 2>&1; then
  echo "==> wiring imagePullSecrets -> $PULL_SECRET_NAME"
  kubectl -n "$NS" patch deploy demo-shop --type=merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":[{\"name\":\"$PULL_SECRET_NAME\"}]}}}}"
fi

echo "==> waiting for demo-shop rollout"
kubectl -n demo rollout status deploy/demo-shop --timeout=180s || true
echo "==> verify:  kubectl -n demo port-forward svc/demo-shop 8080:80  &&  curl localhost:8080/health"
