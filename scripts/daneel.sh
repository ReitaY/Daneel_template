#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------
# daneel.sh - unified helper for Daneel_template
#
# Usage examples:
#   ./scripts/daneel.sh init
#   ./scripts/daneel.sh build --dev
#   ./scripts/daneel.sh build --runtime
#   ./scripts/daneel.sh deploy
#   ./scripts/daneel.sh dev up|down|shell
#   ./scripts/daneel.sh robot up|down
# --------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_DEV="${REPO_ROOT}/compose/dev.yml"
COMPOSE_ROBOT="${REPO_ROOT}/compose/robot.yml"

PROJECT_DOCKER_DIR="${REPO_ROOT}/docker/project"
DEPLOY_DOCKER_DIR="${REPO_ROOT}/docker/deploy"

# ---------------------- load .env if exists --------------------------
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # export 付きで読み込む（Compose と揃える想定）
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

# ---------------------- derive defaults ------------------------------

# プロジェクト名（なければ template）
PROJECT_NAME="${PROJECT_NAME:-template}"

# 画像プレフィックス:
#  1. .env の DANEEL_IMAGE_PREFIX を優先
#  2. 無ければ PROJECT_NAME
#  3. それも無ければ daneel_template
IMAGE_PREFIX="${DANEEL_IMAGE_PREFIX:-${PROJECT_NAME:-daneel_template}}"

# dev / runtime / deploy イメージ名
DEV_IMAGE="${DANEEL_DEV_IMAGE:-${IMAGE_PREFIX}-dev:latest}"
RUNTIME_IMAGE="${DANEEL_RUNTIME_IMAGE:-${IMAGE_PREFIX}-runtime:latest}"
DEPLOY_IMAGE="${DANEEL_DEPLOY_IMAGE:-${IMAGE_PREFIX}-deploy:latest}"

# Base / Desktop イメージ（必要であれば Dockerfile の build-arg などに使用）
ROS_DISTRO="${ROS_DISTRO:-humble}"
DANEEL_BASE_IMAGE="${DANEEL_BASE_IMAGE:-daneel_base:${ROS_DISTRO}}"
DANEEL_DESKTOP_IMAGE="${DANEEL_DESKTOP_IMAGE:-daneel_desktop:${ROS_DISTRO}}"

# docker compose コマンド検出（docker compose を優先）
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  DOCKER_COMPOSE=(docker compose)
elif command -v docker-compose &>/dev/null; then
  DOCKER_COMPOSE=(docker-compose)
else
  echo "ERROR: docker compose (or docker-compose) not found." >&2
  exit 1
fi

# ---------------------------- helpers --------------------------------
usage() {
  cat <<EOF
Usage:
  $(basename "$0") init
  $(basename "$0") build --dev|--runtime
  $(basename "$0") deploy
  $(basename "$0") dev up|down|shell
  $(basename "$0") robot up|down

Environment (via .env or shell):

  # Project / ROS
  PROJECT_NAME          (default: template)
  ROS_DISTRO            (default: humble)

  # Daneel base images (built separately, e.g. from daneel repo)
  DANEEL_BASE_IMAGE     (default: daneel_base:\${ROS_DISTRO})
  DANEEL_DESKTOP_IMAGE  (default: daneel_desktop:\${ROS_DISTRO})

  # Project images
  DANEEL_IMAGE_PREFIX   (default: \${PROJECT_NAME} or daneel_template)
  DANEEL_DEV_IMAGE      (default: \${DANEEL_IMAGE_PREFIX}-dev:latest)
  DANEEL_RUNTIME_IMAGE  (default: \${DANEEL_IMAGE_PREFIX}-runtime:latest)
  DANEEL_DEPLOY_IMAGE   (default: \${DANEEL_IMAGE_PREFIX}-deploy:latest)

  # GUI / noVNC
  DISPLAY_WIDTH         (default: 1470)
  DISPLAY_HEIGHT        (default: 956)
  NOVNC_PORT            (default: 8080)
  VNC_PORT              (default: 5901)

  # ROS networking
  ROS_DOMAIN_ID         (default: 0)
  RMW_IMPLEMENTATION    (default: rmw_cyclonedds_cpp)

  # Robot deploy
  ROBOT_HOST            (default: robot)
  ROBOT_STACK_DIR       (default: /opt/daneel_stack)
  ROBOT_SSH_PORT        (default: 22)

  # Optional: local Daneel repo
  DANEEL_USE_LOCAL_BUILD (default: 0)
  DANEEL_LOCAL_DIR       (default: ./daneel)
EOF
}

ensure_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: required file not found: $path" >&2
    exit 1
  fi
}

prompt_var() {
  # usage: prompt_var VAR_NAME "Prompt message" "default"
  local var_name="$1"
  local prompt_msg="$2"
  local default_val="$3"

  # shellcheck disable=SC2086
  local current_val="${!var_name:-}"

  local show_default
  if [[ -n "${current_val}" ]]; then
    show_default="${current_val}"
  else
    show_default="${default_val}"
  fi

  read -rp "${prompt_msg} [${show_default}]: " input

  if [[ -z "${input}" ]]; then
    printf -v "$var_name" '%s' "${show_default}"
  else
    printf -v "$var_name" '%s' "${input}"
  fi
}

# --------------------------- subcommands ------------------------------

cmd_init() {
  echo "[daneel] init"

  local env_path="${REPO_ROOT}/.env"

  if [[ -f "${env_path}" ]]; then
    echo "Found existing .env at ${env_path}"
    read -rp "Overwrite it? [y/N]: " ans
    case "${ans}" in
      y|Y|yes|YES)
        echo "Overwriting .env..."
        ;;
      *)
        echo "Abort init (keeping existing .env)."
        return 0
        ;;
    esac
  fi

  # ---- Interactive prompts ----
  echo
  echo ">>> Basic project settings"
  prompt_var PROJECT_NAME "Project name" "template"
  prompt_var ROS_DISTRO "ROS distro (humble/jazzy/rolling など)" "humble"

  echo
  echo ">>> GUI / noVNC settings"
  prompt_var DISPLAY_WIDTH  "Display width"  "1470"
  prompt_var DISPLAY_HEIGHT "Display height" "956"
  prompt_var NOVNC_PORT     "noVNC port"     "8080"
  prompt_var VNC_PORT       "VNC port"       "5901"

  echo
  echo ">>> ROS networking"
  prompt_var ROS_DOMAIN_ID      "ROS_DOMAIN_ID"      "0"
  prompt_var RMW_IMPLEMENTATION "RMW_IMPLEMENTATION" "rmw_cyclonedds_cpp"

  echo
  echo ">>> Robot deploy settings"
  prompt_var ROBOT_HOST      "Robot host (SSH hostname or IP)" "robot"
  prompt_var ROBOT_STACK_DIR "Robot stack directory"           "/opt/daneel_stack"
  prompt_var ROBOT_SSH_PORT  "Robot SSH port"                  "22"

  echo
  echo ">>> Optional: local Daneel base images repo"
  prompt_var DANEEL_USE_LOCAL_BUILD "Use local Daneel repo to build base/desktop? (0 or 1)" "0"
  prompt_var DANEEL_LOCAL_DIR       "Local Daneel repo path"                                "./daneel"

  # Derived image names (文字列として .env に書く)
  DANEEL_IMAGE_PREFIX="${PROJECT_NAME}"
  DANEEL_DEV_IMAGE="${DANEEL_IMAGE_PREFIX}-dev:latest"
  DANEEL_RUNTIME_IMAGE="${DANEEL_IMAGE_PREFIX}-runtime:latest"
  DANEEL_DEPLOY_IMAGE="${DANEEL_IMAGE_PREFIX}-deploy:latest"

  # Base / desktop images は ROS_DISTRO からの派生を書く
  DANEEL_BASE_IMAGE="daneel_base:\${ROS_DISTRO}"
  DANEEL_DESKTOP_IMAGE="daneel_desktop:\${ROS_DISTRO}"

  # ---- Write .env ----
  cat > "${env_path}" <<EOF
# Auto-generated by daneel.sh init

PROJECT_NAME=${PROJECT_NAME}
ROS_DISTRO=${ROS_DISTRO}

# ---------- Daneel base images ----------
DANEEL_BASE_IMAGE=${DANEEL_BASE_IMAGE}
DANEEL_DESKTOP_IMAGE=${DANEEL_DESKTOP_IMAGE}

# ---------- Project images ----------
DANEEL_IMAGE_PREFIX=${DANEEL_IMAGE_PREFIX}
DANEEL_DEV_IMAGE=${DANEEL_DEV_IMAGE}
DANEEL_RUNTIME_IMAGE=${DANEEL_RUNTIME_IMAGE}
DANEEL_DEPLOY_IMAGE=${DANEEL_DEPLOY_IMAGE}

# ---------- GUI / noVNC ----------
DISPLAY_WIDTH=${DISPLAY_WIDTH}
DISPLAY_HEIGHT=${DISPLAY_HEIGHT}
NOVNC_PORT=${NOVNC_PORT}
VNC_PORT=${VNC_PORT}

# ---------- ROS networking ----------
ROS_DOMAIN_ID=${ROS_DOMAIN_ID}
RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION}

# ---------- Robot deploy ----------
ROBOT_HOST=${ROBOT_HOST}
ROBOT_STACK_DIR=${ROBOT_STACK_DIR}
ROBOT_SSH_PORT=${ROBOT_SSH_PORT}

# ---------- Optional: local Daneel repo ----------
DANEEL_USE_LOCAL_BUILD=${DANEEL_USE_LOCAL_BUILD}
DANEEL_LOCAL_DIR=${DANEEL_LOCAL_DIR}
EOF

  echo "[daneel] wrote .env:"
  echo "  - PROJECT_NAME = ${PROJECT_NAME}"
  echo "  - ROS_DISTRO   = ${ROS_DISTRO}"
  echo "  - IMAGE_PREFIX = ${DANEEL_IMAGE_PREFIX}"
  echo

  echo "[daneel] init done."
}

cmd_build_dev() {
  echo "[daneel] build dev image: ${DEV_IMAGE}"

  ensure_file "${PROJECT_DOCKER_DIR}/Dockerfile.desktop"

  docker build \
    -f "${PROJECT_DOCKER_DIR}/Dockerfile.desktop" \
    -t "${DEV_IMAGE}" \
    "${REPO_ROOT}"
}

cmd_build_runtime() {
  echo "[daneel] build runtime image: ${RUNTIME_IMAGE}"

  ensure_file "${PROJECT_DOCKER_DIR}/Dockerfile.runtime"

  docker build \
    -f "${PROJECT_DOCKER_DIR}/Dockerfile.runtime" \
    -t "${RUNTIME_IMAGE}" \
    "${REPO_ROOT}"
}

cmd_deploy() {
  echo "[daneel] build deploy image (FROM runtime): ${DEPLOY_IMAGE}"
  ensure_file "${DEPLOY_DOCKER_DIR}/Dockerfile.deploy"

  # runtime イメージが無ければビルド（or pull）を試みる
  if ! docker image inspect "${RUNTIME_IMAGE}" >/dev/null 2>&1; then
    echo "[daneel] runtime image ${RUNTIME_IMAGE} not found. Building..."
    cmd_build_runtime
  fi

  docker build \
    --build-arg RUNTIME_IMAGE="${RUNTIME_IMAGE}" \
    -f "${DEPLOY_DOCKER_DIR}/Dockerfile.deploy" \
    -t "${DEPLOY_IMAGE}" \
    "${REPO_ROOT}"

  echo "[daneel] deploy image built: ${DEPLOY_IMAGE}"
  echo "        (push / save / upload は別スクリプト or 手動で実行してください)"
}

cmd_dev() {
  local sub="${1:-}"; shift || true
  ensure_file "${COMPOSE_DEV}"

  case "${sub}" in
    up)
      echo "[daneel] dev up (compose/dev.yml)"
      "${DOCKER_COMPOSE[@]}" -f "${COMPOSE_DEV}" up -d
      ;;
    down)
      echo "[daneel] dev down (compose/dev.yml)"
      "${DOCKER_COMPOSE[@]}" -f "${COMPOSE_DEV}" down
      ;;
    shell)
      # デフォルトサービス名は dev デスクトップ側を想定（compose の service 名に合わせて調整）
      local svc="${1:-dev_desktop}"
      echo "[daneel] dev shell into service: ${svc}"
      "${DOCKER_COMPOSE[@]}" -f "${COMPOSE_DEV}" exec "${svc}" bash
      ;;
    *)
      echo "Usage: $(basename "$0") dev {up|down|shell [service]}" >&2
      exit 1
      ;;
  esac
}

cmd_robot() {
  local sub="${1:-}"; shift || true
  ensure_file "${COMPOSE_ROBOT}"

  case "${sub}" in
    up)
      echo "[daneel] robot up (compose/robot.yml)"
      "${DOCKER_COMPOSE[@]}" -f "${COMPOSE_ROBOT}" up -d
      ;;
    down)
      echo "[daneel] robot down (compose/robot.yml)"
      "${DOCKER_COMPOSE[@]}" -f "${COMPOSE_ROBOT}" down
      ;;
    *)
      echo "Usage: $(basename "$0") robot {up|down}" >&2
      exit 1
      ;;
  esac
}

# ------------------------------ main ---------------------------------

main() {
  local cmd="${1:-}"; shift || true

  case "${cmd}" in
    init)
      cmd_init "$@"
      ;;
    build)
      local mode="${1:-}"; shift || true
      case "${mode}" in
        --dev)     cmd_build_dev "$@" ;;
        --runtime) cmd_build_runtime "$@" ;;
        *)
          echo "Usage: $(basename "$0") build --dev|--runtime" >&2
          exit 1
          ;;
      esac
      ;;
    deploy)
      cmd_deploy "$@"
      ;;
    dev)
      cmd_dev "$@"
      ;;
    robot)
      cmd_robot "$@"
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: ${cmd}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
