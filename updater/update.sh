#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(dirname "$(realpath "$0")")/.."

COMPOSE_AGENT="$REPO_ROOT/compose/docker-compose.agent.yaml"
COMPOSE_STACK="$REPO_ROOT/compose/docker-compose.stack.yaml"
LOG_FILE="$REPO_ROOT/logs/updater.log"
STATE_FILE="/var/lib/edge-agent/state.json"

log() {
    echo "[EDGE-UPDATER] $*" | tee -a "$LOG_FILE"
}


[ -f "$STATE_FILE" ] || { log "State file not found, skipping update."; exit 0; }

# --- Read target versions ---
AGENT_TARGET=$(jq -r '.agent.target // empty' "$STATE_FILE")
STACK_TARGET=$(jq -r '.stack."stream-score".target // empty' "$STATE_FILE")

AGENT_CURRENT=$(jq -r '.agent.version' "$STATE_FILE")
STACK_CURRENT=$(jq -r '.stack."stream-score".version' "$STATE_FILE")

# --- STACK FIRST ---
if [[ -n "$STACK_TARGET" && "$STACK_TARGET" != "$STACK_CURRENT" ]]; then
    log "Updating stream-score $STACK_CURRENT -> $STACK_TARGET"

    docker compose -f "$COMPOSE_STACK" pull
    docker compose -f "$COMPOSE_STACK" up -d

    # Update state.json
    jq --arg v "$STACK_TARGET" '.stack."stream-score".version=$v' "$STATE_FILE" > "$STATE_FILE.tmp" \
        && mv "$STATE_FILE.tmp" "$STATE_FILE"
    log "stream-score updated to $STACK_TARGET"
else
    log "stream-score is already at target version $STACK_CURRENT"
fi

# --- AGENT LAST ---
if [[ -n "$AGENT_TARGET" && "$AGENT_TARGET" != "$AGENT_CURRENT" ]]; then
    log "Updating edge-agent $AGENT_CURRENT -> $AGENT_TARGET"

    docker compose -f "$COMPOSE_AGENT" pull
    docker compose -f "$COMPOSE_AGENT" up -d

    # Update state.json
    jq --arg v "$AGENT_TARGET" '.agent.version=$v' "$STATE_FILE" > "$STATE_FILE.tmp" \
        && mv "$STATE_FILE.tmp" "$STATE_FILE"
    log "edge-agent updated to $AGENT_TARGET"
else
    log "edge-agent is already at target version $AGENT_CURRENT"
fi

log "Updater run completed."