#!/usr/bin/env bash
# deploy.sh — pull latest submodule pins + compose files, then bring the
# stack up. Runs on the VPS as the deploy user. Idempotent.
#
# Architecture rule 8 applies to the services: each container's startup runs
# its own bootstrap (migrations + env-driven asset registration). This script
# does not seed assets — that's seed-assets.sh on the host side.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/opt/lighthouse}"
ENV_FILE="${ENV_FILE:-/etc/lighthouse/.env}"

usage() {
    cat <<EOF
Usage: deploy.sh [--build] [--pull-only] [--restart] [--help]

Pulls latest code + submodules + images, then brings the compose stack up.

Options:
  --build      Build images locally instead of pulling from GHCR. Use this on
               a dev box; production should always pull pre-built images
               (docker-compose.prod.yml has 'image:' set; --build adds
               build context so a 'docker compose up --build' works).
  --pull-only  Pull updates from git + images, do not start anything.
  --restart    Restart already-running services without re-pulling.

Env:
  REPO_ROOT    Local clone path. Default: /opt/lighthouse.
  ENV_FILE     Path to the .env file the compose stack consumes.
               Default: /etc/lighthouse/.env (owned by deploy user, 0400).
EOF
}

MODE="up"
COMPOSE_FILES=(-f "${REPO_ROOT}/docker/docker-compose.yml" -f "${REPO_ROOT}/docker/docker-compose.prod.yml")
EXTRA_UP_FLAGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)
            COMPOSE_FILES=(-f "${REPO_ROOT}/docker/docker-compose.yml")
            EXTRA_UP_FLAGS+=("--build")
            shift
            ;;
        --pull-only)
            MODE="pull"
            shift
            ;;
        --restart)
            MODE="restart"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

log() { echo "[deploy] $*"; }

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "env file ${ENV_FILE} not found — copy docker/env.example and edit" >&2
    exit 1
fi

cd "${REPO_ROOT}"

if [[ "${MODE}" != "restart" ]]; then
    log "git pull"
    git pull --ff-only
    log "git submodule update --recursive --remote (track configured branch)"
    # NOTE: --remote fetches the latest commit on each submodule's tracked
    # branch. To pin specific SHAs instead, drop --remote and bump pins by
    # cd-ing into each submodule and committing the SHA bump.
    git submodule update --init --recursive --remote
fi

DOCKER_COMPOSE=(docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}")

if [[ "${MODE}" == "pull" ]]; then
    log "docker compose pull"
    "${DOCKER_COMPOSE[@]}" pull
    exit 0
fi

if [[ "${MODE}" == "restart" ]]; then
    log "docker compose restart"
    "${DOCKER_COMPOSE[@]}" restart
    exit 0
fi

if [[ ${#EXTRA_UP_FLAGS[@]} -eq 0 ]]; then
    log "docker compose pull"
    "${DOCKER_COMPOSE[@]}" pull
fi

log "docker compose up -d --remove-orphans${EXTRA_UP_FLAGS[*]:+ }${EXTRA_UP_FLAGS[*]:-}"
"${DOCKER_COMPOSE[@]}" up -d --remove-orphans "${EXTRA_UP_FLAGS[@]}"

log "docker compose ps"
"${DOCKER_COMPOSE[@]}" ps
