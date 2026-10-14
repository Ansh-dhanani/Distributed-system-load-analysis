#!/usr/bin/env bash
# Build and push the demo-shop image to Docker Hub.
# Usage:  DOCKERHUB_USERNAME=anshdhanani DOCKERHUB_TOKEN=<pat> ./scripts/build-push.sh
# Never hardcode the token in this repo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-anshdhanani/demo-shop:latest}"
USERNAME="${DOCKERHUB_USERNAME:-}"

if [[ -z "$USERNAME" ]]; then
  read -rp "Docker Hub username: " USERNAME
fi

if [[ -z "${DOCKERHUB_TOKEN:-}" ]]; then
  read -rsp "Docker Hub access token: " DOCKERHUB_TOKEN
  echo
fi

echo "$DOCKERHUB_TOKEN" | docker login -u "$USERNAME" --password-stdin

docker build -t "$IMAGE" "$REPO_ROOT/apps/demo-shop"
docker push "$IMAGE"

docker logout >/dev/null 2>&1 || true
unset DOCKERHUB_TOKEN
echo "pushed $IMAGE"
