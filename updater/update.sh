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

log "Updater triggered."

# --------------------------------------------------
# Preconditions
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

STACK_TARGET=$(jq -r '.stack."stream-score".target // empty' "$STATE_FILE")
STACK_CURRENT=$(jq -r '.stack."stream-score".version // empty' "$STATE_FILE")
STACK_REPO=$(jq -r '.stack."stream-score".image_repo // empty' "$STATE_FILE")
AGENT_REPO=$(jq -r '.agent.image_repo // empty' "$STATE_FILE")

# --------------------------------------------------
# STACK UPDATE (FIRST)
# --------------------------------------------------
if [[ -n "$STACK_TARGET" && "$STACK_TARGET" != "$STACK_CURRENT" ]]; then
    if [[ -z "$STACK_REPO" ]]; then
        log "stream-score image_repo missing, skipping stack update."
    else
        STACK_IMAGE="${STACK_REPO}:${STACK_TARGET}"
        export STREAM_SCORE_IMAGE="$STACK_IMAGE"

        log "Updating stream-score $STACK_CURRENT -> $STACK_TARGET"
        log "Using image: $STREAM_SCORE_IMAGE"

        if docker compose -f "$COMPOSE_STACK" pull stream-score >>"$LOG_FILE" 2>&1 \
           && docker compose -f "$COMPOSE_STACK" up -d stream-score >>"$LOG_FILE" 2>&1; then

            jq --arg v "$STACK_TARGET" \
               '.stack."stream-score".version=$v' \
               "$STATE_FILE" > "$STATE_FILE.tmp" \
               && mv "$STATE_FILE.tmp" "$STATE_FILE"

            log "stream-score successfully updated to $STACK_TARGET"
        else
            log "stream-score update FAILED"
        fi
    fi
else
    log "stream-score already at target version ($STACK_CURRENT)"
fi

# --------------------------------------------------
# AGENT UPDATE (LAST)
# --------------------------------------------------
if [[ -z "$AGENT_REPO" || -z "$AGENT_TARGET" ]]; then
    log "edge-agent image_repo or target missing, skipping agent update."
else
    AGENT_IMAGE="${AGENT_REPO}:${AGENT_TARGET}"
    export EDGE_AGENT_IMAGE="$AGENT_IMAGE"

    log "Using agent image: $EDGE_AGENT_IMAGE"

    if docker compose -f "$COMPOSE_AGENT" pull edge-agent >>"$LOG_FILE" 2>&1 \
       && docker compose -f "$COMPOSE_AGENT" up -d edge-agent >>"$LOG_FILE" 2>&1; then

        jq --arg v "$AGENT_TARGET" \
           '.agent.version=$v' "$STATE_FILE" > "$STATE_FILE.tmp" \
           && mv "$STATE_FILE.tmp" "$STATE_FILE"

        log "edge-agent successfully updated to $AGENT_TARGET"
    else
        log "edge-agent update FAILED"
    fi
fi

log "Updater run completed."