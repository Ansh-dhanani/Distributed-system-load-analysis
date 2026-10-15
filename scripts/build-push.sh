#!/usr/bin/env bash
# Build and push the demo-shop image to any registry (Docker Hub, GHCR, ...).
#
#   # Docker Hub (public repo)
#   IMAGE=<user>/demo-shop:latest \
#     DOCKERHUB_USERNAME=<user> DOCKERHUB_TOKEN=<pat> ./scripts/build-push.sh
#
#   # GitHub Container Registry
#   IMAGE=ghcr.io/<owner>/demo-shop:latest \
#     GHCR_USERNAME=<github-user> GHCR_TOKEN=<pat with write:packages> ./scripts/build-push.sh
#
#   # any other registry
#   IMAGE=registry.example.com/team/demo-shop:v1 \
#     REGISTRY_USERNAME=<user> REGISTRY_TOKEN=<token> ./scripts/build-push.sh
#
# The registry is derived from IMAGE and the matching credentials are used to log
# in — nothing is hardcoded. Use SKIP_LOGIN=true if you are already logged in.
# Never hardcode a token in this repo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/apps/demo-shop"
IMAGE="${IMAGE:-anshdhanani/demo-shop:latest}"

# First path component is a registry only if it has a dot/colon or is localhost.
registry_of() {
  local ref="${1%@*}" first="${1%%/*}"
  if [[ "$ref" != */* || ( "$first" != *.* && "$first" != *:* && "$first" != localhost ) ]]; then
    echo "docker.io"
  else
    echo "$first"
  fi
}
REGISTRY="$(registry_of "$IMAGE")"

case "$REGISTRY" in
  docker.io|index.docker.io|registry-1.docker.io)
    LOGIN_HOST=""                 # `docker login` with no host == Docker Hub
    USER="${DOCKERHUB_USERNAME:-}"
    TOKEN="${DOCKERHUB_TOKEN:-}"
    USER_PROMPT="Docker Hub username"
    CRED_HELP="DOCKERHUB_USERNAME / DOCKERHUB_TOKEN (PAT with Read+Write)"
    ;;
  ghcr.io)
    LOGIN_HOST="ghcr.io"
    # Default the login user to the image owner (ghcr.io/<owner>/...).
    OWNER="${IMAGE#*/}"; OWNER="${OWNER%%/*}"
    USER="${GHCR_USERNAME:-${GITHUB_USERNAME:-$OWNER}}"
    TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
    USER_PROMPT="GitHub username"
    CRED_HELP="GHCR_USERNAME / GHCR_TOKEN (PAT with write:packages)"
    ;;
  *)
    LOGIN_HOST="$REGISTRY"
    USER="${REGISTRY_USERNAME:-}"
    TOKEN="${REGISTRY_TOKEN:-}"
    USER_PROMPT="$REGISTRY username"
    CRED_HELP="REGISTRY_USERNAME / REGISTRY_TOKEN"
    ;;
esac

echo "==> image:    $IMAGE"
echo "==> registry: $REGISTRY"

if [[ "${SKIP_LOGIN:-false}" == "true" ]]; then
  echo "==> SKIP_LOGIN=true: assuming you are already logged in to $REGISTRY"
else
  if [[ -z "$USER" ]]; then
    read -rp "$USER_PROMPT: " USER \
      || { echo "error: no username and stdin is not interactive. Set: $CRED_HELP" >&2; exit 2; }
  fi
  if [[ -z "$TOKEN" ]]; then
    read -rsp "token ($CRED_HELP): " TOKEN \
      || { echo; echo "error: no token and stdin is not interactive. Set: $CRED_HELP" >&2; exit 2; }
    echo
  fi
  if [[ -n "$LOGIN_HOST" ]]; then
    printf '%s' "$TOKEN" | docker login "$LOGIN_HOST" -u "$USER" --password-stdin
  else
    printf '%s' "$TOKEN" | docker login -u "$USER" --password-stdin
  fi
fi

docker build -t "$IMAGE" "$APP_DIR"
docker push "$IMAGE"

echo "==> pushed $IMAGE"
echo "==> deploy with:"
echo "    IMAGE=$IMAGE ./scripts/deploy-app.sh 1     # 1=sqlite, 2=postgres, 3=+redis"

unset TOKEN
