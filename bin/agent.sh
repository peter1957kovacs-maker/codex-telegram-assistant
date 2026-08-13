#!/usr/bin/env bash
# Generic Codex agent runtime.  Usage: bin/agent.sh <agent-name>
#
# Each agent is a headless Codex worker. It polls the inter-agent message queue
# for its pending messages, runs each as a fresh `codex exec` (loading its own
# memory as context), records the result, and replies to the sender. This is the
# Marveen inter-agent pattern, Codex-powered.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"

CODEX="${CODEX_BIN:-codex}"
SELF="${1:?usage: agent.sh <agent-name>}"
AGENT_DIR="$ROOT/agents/$SELF"
POLL="${POLL_INTERVAL:-5}"

db_init
[ -d "$AGENT_DIR" ] || { echo "[agent] no agent dir: $AGENT_DIR (run bin/scaffold.sh)"; exit 1; }
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [$SELF] $*"; }
log "runtime started (dir: $AGENT_DIR)"

while true; do
  if ! "$CODEX" login status >/dev/null 2>&1; then
    log "codex auth pending -- idling (run: codex login)"; sleep 30; continue
  fi

  rows="$(msg_pending "$SELF")"
  [ -z "$rows" ] && { sleep "$POLL"; continue; }

  while IFS='|' read -r mid from; do
    [ -z "$mid" ] && continue
    content="$(dbq "SELECT content FROM agent_messages WHERE id=$mid;")"
    msg_claim "$mid"
    log "processing msg #$mid from $from"

    mem="$(mem_recent "$SELF" 8)"
    prompt="Beerkezett uzenet tole: ${from}.
Uzenet:
${content}

A memoriad (kontextus, lehet ures):
${mem}

Vegezd el a feladatot vagy valaszolj. A valaszod lesz a vegso uzenet, azt kapja vissza a felado."

    out="$(mktemp)"
    if printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check -o "$out" ) >/dev/null 2>&1; then
      reply="$(cat "$out")"; [ -z "$reply" ] && reply="(ures valasz)"
      msg_done "$mid" "$reply"
      # Reply back to the sender so conversations flow (main relays to Telegram).
      msg_send "$SELF" "$from" "$reply"
      log "msg #$mid done -> replied to $from"
    else
      msg_fail "$mid" "codex exec failed"
      log "msg #$mid FAILED"
    fi
    rm -f "$out"
  done <<< "$rows"
done
