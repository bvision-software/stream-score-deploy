#!/usr/bin/env bash
set -Eeuo pipefail

# --------------------------------------------------
# Paths
# --------------------------------------------------
REPO_ROOT="$(dirname "$(realpath "$0")")/.."

COMPOSE_AGENT="$REPO_ROOT/docker-compose.agent.yaml"
COMPOSE_STACK="$REPO_ROOT/docker-compose.stack.yaml"
LOG_FILE="$REPO_ROOT/logs/updater.log"
STATE_FILE="$REPO_ROOT/state/state.json"

mkdir -p "$(dirname "$LOG_FILE")"

# --------------------------------------------------
# Logging
# --------------------------------------------------
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# --------------------------------------------------
# GUARD: state file
# --------------------------------------------------
if [[ ! -f "$STATE_FILE" ]]; then
    log "State file not found, skipping update. path=$STATE_FILE"
    exit 0
fi

# --------------------------------------------------
# Read state
# --------------------------------------------------
AGENT_TARGET=$(jq -r '.agent.target // empty' "$STATE_FILE")
AGENT_CURRENT=$(jq -r '.agent.version // empty' "$STATE_FILE")
AGENT_REPO=$(jq -r '.agent.image_repo // empty' "$STATE_FILE")

STACK_TARGET=$(jq -r '.stack."stream-score".target // empty' "$STATE_FILE")
STACK_CURRENT=$(jq -r '.stack."stream-score".version // empty' "$STATE_FILE")
STACK_REPO=$(jq -r '.stack."stream-score".image_repo // empty' "$STATE_FILE")


update_stack() {
    if [[ -z "$STACK_TARGET" ]]; then
        log "stream-score target missing, skipping update."
        return
    fi

    if [[ "$STACK_TARGET" == "$STACK_CURRENT" ]]; then
        log "stream-score already at target version ($STACK_CURRENT)"
        return
    fi

    if [[ -z "$STACK_REPO" ]]; then
        log "stream-score image_repo missing, skipping stack update."
        return
    fi

    STACK_IMAGE="${STACK_REPO}:${STACK_TARGET}"
    export STREAM_SCORE_IMAGE="$STACK_IMAGE"

    log "Updating stream-score $STACK_CURRENT -> $STACK_TARGET"
    log "Using image: $STACK_IMAGE"

    if ! docker pull "$STACK_IMAGE"; then
        log FATAL "Failed to pull image $STACK_IMAGE. Aborting update."
        return 0
    fi

    if docker compose -f "$COMPOSE_STACK" ps -q stream-score >/dev/null; then
        docker compose -f "$COMPOSE_STACK" rm -sf stream-score
    else
        log INFO "stream-score container not found, skipping removal."
    fi

    if docker compose -f "$COMPOSE_STACK" up -d stream-score; then
        log "stream-score container started"

        jq --arg v "$STACK_TARGET" \
           '.stack."stream-score".version=$v' \
           "$STATE_FILE" > "$STATE_FILE.tmp" \
           && mv "$STATE_FILE.tmp" "$STATE_FILE"

        log "stream-score successfully updated to $STACK_TARGET"
    else
        log FATAL "stream-score update FAILED"
    fi
}

update_agent() {
    if [[ -z "$AGENT_TARGET" ]]; then
        log "edge-agent target missing, skipping update."
        return
    fi

    if [[ "$AGENT_TARGET" == "$AGENT_CURRENT" ]]; then
        log "edge-agent already at target version ($AGENT_CURRENT)"
        return
    fi

    if [[ -z "$AGENT_REPO" ]]; then
        log "edge-agent image missing, skipping stack update."
        return
    fi

    AGENT_IMAGE="${AGENT_REPO}:${AGENT_TARGET}"
    export EDGE_AGENT_IMAGE="$AGENT_IMAGE"

    log "Updating edge-agent $AGENT_CURRENT -> $AGENT_TARGET"
    log "Using image: $AGENT_IMAGE"

    if ! docker pull "$AGENT_IMAGE"; then
        log FATAL "Failed to pull image $AGENT_IMAGE. Aborting update."
        return 0
    fi

    if docker compose -f "$COMPOSE_AGENT" ps -q edge-agent >/dev/null; then
        docker compose -f "$COMPOSE_AGENT" rm -sf edge-agent
    else
        log INFO "edge-agent container not found, skipping removal."
    fi

    if docker compose -f "$COMPOSE_AGENT" up -d edge-agent; then
        log "edge-agent container started"

        jq --arg v "$AGENT_TARGET" \
           '.agent.version=$v' \
           "$STATE_FILE" > "$STATE_FILE.tmp" \
           && mv "$STATE_FILE.tmp" "$STATE_FILE"

        log "edge-agent successfully updated to $AGENT_TARGET"
    else
        log FATAL "edge-agent update FAILED"
    fi
}

# --- MAIN EXECUTION ---
log "Updater triggered."
update_stack
update_agent
log "Updater run completed."