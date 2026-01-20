#!/usr/bin/env bash
set -Eeuo pipefail

# --------------------------------------------------
# Paths
# --------------------------------------------------
REPO_ROOT="$(dirname "$(realpath "$0")")/.."

COMPOSE_AGENT="$REPO_ROOT/docker-compose.agent.yaml"
COMPOSE_STACK="$REPO_ROOT/docker-compose.stack.yaml"
LOG_FILE="$REPO_ROOT/logs/updater.log"
STATE_FILE="/var/lib/edge-agent/state.json"

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
    log "State file not found, skipping update."
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
    log "Using image: $STREAM_SCORE_IMAGE"

    if docker compose -f "$COMPOSE_STACK" up -d stream-score >>"$LOG_FILE" 2>&1; then
        jq --arg v "$STACK_TARGET" \
           '.stack."stream-score".version=$v' \
           "$STATE_FILE" > "$STATE_FILE.tmp" \
           && mv "$STATE_FILE.tmp" "$STATE_FILE"

        log "stream-score successfully updated to $STACK_TARGET"
    else
        log "stream-score update FAILED"
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
    log "Using agent image: $EDGE_AGENT_IMAGE"

    if docker compose -f "$COMPOSE_AGENT" up -d edge-agent >>"$LOG_FILE" 2>&1; then
        jq --arg v "$AGENT_TARGET" \
           '.agent.version=$v' \
           "$STATE_FILE" > "$STATE_FILE.tmp" \
           && mv "$STATE_FILE.tmp" "$STATE_FILE"

        log "edge-agent successfully updated to $AGENT_TARGET"
    else
        log "edge-agent update FAILED"
    fi
}

# --- MAIN EXECUTION ---
log "Updater triggered."
update_stack
update_agent
log "Updater run completed."