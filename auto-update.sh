#!/usr/bin/env bash
# ==============================================================================
# Script: /opt/qoder2api-hub/auto-update.sh
# Symlink: /usr/local/bin/qoder-auto-update
# Description: Automated update checker for qoder2api-hub.
#
# Why this exists: upstream only publishes a :latest image on GHCR and that
# image can lag far behind the source tree (2026-10-19: image had v1.1.4 while
# source was v1.5.2). Pulling can therefore never update this service, so this
# script pulls the source, builds the image locally and deploys it.
#
# Features:
#   * flock locking so two runs cannot overlap
#   * --check only reports, --force rebuilds even when up to date
#   * refuses to run on a dirty worktree (tracked modifications)
#   * pre-update backup of compose files, dashboard.html, settings.json
#   * pre-update image tagged for rollback
#   * health check with automatic rollback on failure
#   * prunes old backups / rollback tags
#
# Usage: qoder-auto-update [--check|--force]
# ==============================================================================

set -uo pipefail

REPO="/opt/qoder2api-hub"
CONTAINER="qoder-proxy"
IMAGE_BASE="qoder2api-hub"
OVERRIDE="$REPO/docker-compose.override.yml"
LOG="/var/log/qoder-auto-update.log"
LOCK="/var/lock/qoder-auto-update.lock"
HEALTH_TIMEOUT=120

exec >>"$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*"; }

MODE="${1:-}"
exec 9>"$LOCK"
if ! flock -n 9; then
    say "another run is in progress, exiting"
    exit 0
fi

say "=== qoder2api-hub auto-update start (mode=${MODE:-update}) ==="

cd "$REPO" || { say "ERROR: $REPO missing"; exit 1; }

# --- worktree guard -----------------------------------------------------------
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    say "ERROR: tracked files are modified, refusing to update:"
    git status --porcelain --untracked-files=no | head -10
    exit 1
fi

# --- fetch --------------------------------------------------------------------
if ! git fetch --all --tags --prune --quiet; then
    say "ERROR: git fetch failed"
    exit 1
fi

LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse origin/main)
LOCAL_VER=$(grep -m1 '^VERSION' qoder_proxy.py 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')

say "local=$LOCAL_SHA ($LOCAL_VER) remote=$REMOTE_SHA"

if [ "$LOCAL_SHA" = "$REMOTE_SHA" ] && [ "$MODE" != "--force" ]; then
    say "already up to date, nothing to do"
    exit 0
fi

if [ "$MODE" = "--check" ]; then
    say "update available: ${LOCAL_SHA:0:7} -> ${REMOTE_SHA:0:7}"
    git log --oneline "$LOCAL_SHA..$REMOTE_SHA" | head -10
    exit 0
fi

# --- move to remote head ------------------------------------------------------
if ! git reset --hard "$REMOTE_SHA" --quiet; then
    say "ERROR: git reset failed"
    exit 1
fi

NEW_VER=$(grep -m1 '^VERSION' qoder_proxy.py 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
TS=$(date +%Y%m%d-%H%M%S)
NEW_TAG="${IMAGE_BASE}:${NEW_VER:-unknown}-${REMOTE_SHA:0:7}"
ROLLBACK_TAG="${IMAGE_BASE}:rollback-${TS}"

say "target version: $NEW_VER ($NEW_TAG)"

# --- backup -------------------------------------------------------------------
BK="$REPO/backups/$TS"
mkdir -p "$BK"
cp docker-compose.yml "$BK/" 2>/dev/null || true
cp "$OVERRIDE" "$BK/" 2>/dev/null || true
cp dashboard.html "$BK/" 2>/dev/null || true
cp accounts/settings.json "$BK/settings.json" 2>/dev/null || true
say "backup written to $BK"

# --- remember the image currently deployed ------------------------------------
PREV_IMAGE=$(grep -m1 '^[[:space:]]*image:' "$OVERRIDE" 2>/dev/null | sed 's/.*image:[[:space:]]*//' | tr -d '"')
if [ -z "$PREV_IMAGE" ]; then
    PREV_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null)
fi
if [ -n "$PREV_IMAGE" ] && docker image inspect "$PREV_IMAGE" >/dev/null 2>&1; then
    docker tag "$PREV_IMAGE" "$ROLLBACK_TAG" && say "rollback image: $ROLLBACK_TAG (from $PREV_IMAGE)"
else
    say "WARN: previous image '$PREV_IMAGE' not found, rollback will rely on the backup only"
    ROLLBACK_TAG=""
fi

# --- build --------------------------------------------------------------------
say "building $NEW_TAG ..."
if ! docker build -t "$NEW_TAG" . ; then
    say "ERROR: build failed, keeping the running container untouched"
    exit 1
fi
say "build ok"

# --- deploy -------------------------------------------------------------------
if grep -qE '^[[:space:]]*image:' "$OVERRIDE"; then
    sed -i -E "s#^([[:space:]]*image:[[:space:]]*).*#\1${NEW_TAG}#" "$OVERRIDE"
else
    sed -i -E "0,/^  ${CONTAINER}:[[:space:]]*$/s//  ${CONTAINER}:\n    image: ${NEW_TAG}/" "$OVERRIDE"
fi
say "override image -> $(grep -m1 'image:' "$OVERRIDE")"

if ! docker compose up -d; then
    say "ERROR: docker compose up failed"
fi

# --- health check -------------------------------------------------------------
healthy=0
for _ in $(seq 1 $((HEALTH_TIMEOUT / 5))); do
    sleep 5
    st=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)
    if [ "$st" = "healthy" ]; then healthy=1; break; fi
    if [ "$st" = "unhealthy" ]; then break; fi
done

if [ "$healthy" != "1" ]; then
    ping=$(curl -s --max-time 5 http://127.0.0.1:8790/ping 2>/dev/null)
    [ "$ping" = "pong" ] && healthy=1
fi

if [ "$healthy" = "1" ]; then
    RUN_VER=$(docker exec "$CONTAINER" sh -c "grep -m1 '^VERSION' /app/qoder_proxy.py" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
    say "update OK: running $RUN_VER ($NEW_TAG)"
    say "=== done ==="
else
    say "ERROR: health check failed, rolling back"
    docker logs --tail 30 "$CONTAINER" 2>&1 | sed 's/^/    /'
    if [ -n "$ROLLBACK_TAG" ]; then
        sed -i -E "s#^([[:space:]]*image:[[:space:]]*).*#\1${ROLLBACK_TAG}#" "$OVERRIDE"
        docker compose up -d
        sleep 10
        st=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)
        say "rollback result: health=$st image=$ROLLBACK_TAG"
    else
        say "no rollback image available, manual intervention required"
    fi
    say "=== failed ==="
    exit 1
fi

# --- prune --------------------------------------------------------------------
cd "$REPO"
ls -1dt backups/*/ 2>/dev/null | tail -n +16 | xargs -r rm -rf
docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^${IMAGE_BASE}:rollback-" | sort -r | tail -n +6 \
    | xargs -r -n1 docker rmi >/dev/null 2>&1
say "prune done"

exit 0