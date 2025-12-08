#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------
# clean_images.sh - remove images built from this Daneel_template project
#
# Usage:
#   bash scripts/clean_images.sh
# --------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------- load .env if exists --------------------------
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

# ---------------------- derive image names ---------------------------

PROJECT_NAME="${PROJECT_NAME:-template}"
IMAGE_PREFIX="${DANEEL_IMAGE_PREFIX:-${PROJECT_NAME:-daneel_template}}"

DEV_IMAGE="${DANEEL_DEV_IMAGE:-${IMAGE_PREFIX}-dev:latest}"
RUNTIME_IMAGE="${DANEEL_RUNTIME_IMAGE:-${IMAGE_PREFIX}-runtime:latest}"
DEPLOY_IMAGE="${DANEEL_DEPLOY_IMAGE:-${IMAGE_PREFIX}-deploy:latest}"

IMAGES=(
  "${DEV_IMAGE}"
  "${RUNTIME_IMAGE}"
  "${DEPLOY_IMAGE}"
)

echo "[daneel-clean] images to remove:"
for img in "${IMAGES[@]}"; do
  echo "  - ${img}"
done
echo

read -rp "Really remove these images? [y/N]: " ans
case "${ans}" in
  y|Y|yes|YES) ;;
  *)
    echo "[daneel-clean] aborted."
    exit 0
    ;;
esac

# ---------------------- remove if exists -----------------------------

for img in "${IMAGES[@]}"; do
  if docker image inspect "${img}" >/dev/null 2>&1; then
    echo "[daneel-clean] removing ${img}"
    docker image rm "${img}" || echo "[daneel-clean] failed to remove ${img} (maybe in use?)"
  else
    echo "[daneel-clean] not found: ${img} (skip)"
  fi
done

echo "[daneel-clean] done."

