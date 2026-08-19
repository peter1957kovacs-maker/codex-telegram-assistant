#!/usr/bin/env bash
# Generic Codex agent runtime.  Usage: bin/agent.sh <agent-name>
#
# Each agent is a headless Codex worker. It polls the inter-agent message queue
# for its pending messages, runs each as a fresh `codex exec` (loading its own
# memory as context), records the result, and replies to the sender. This is the
# Marveen inter-agent pattern, Codex-powered.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"; . "$ROOT/lib/codex.sh"

CODEX="${CODEX_BIN:-codex}"
SELF="${1:?usage: agent.sh <agent-name>}"
AGENT_DIR="$ROOT/agents/$SELF"
MODEL_ARGS=(); while IFS= read -r _a; do MODEL_ARGS+=("$_a"); done < <(codex_model_args "$SELF")
POLL="${POLL_INTERVAL:-5}"

db_init
[ -d "$AGENT_DIR" ] || { echo "[agent] no agent dir: $AGENT_DIR (run bin/scaffold.sh)"; exit 1; }
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [$SELF] $*"; }
log "runtime started (dir: $AGENT_DIR)"

# Inter-agent messages are text only, so an image can only travel as a PATH.
# Pull out absolute paths to existing image files and attach them with -i;
# without this the agent gets the file name but never the pixels.
extract_image_paths() { # <content> -> one existing image path per line
  printf '%s' "$1" \
    | grep -oE '/[^[:space:]"'"'"']+\.(jpg|jpeg|png|gif|webp|JPG|JPEG|PNG|GIF|WEBP)' \
    | while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done \
    | sort -u
}

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

    # Long-term memory + the bounded conversation window (so the agent remembers
    # its thread, not just its facts). codex exec is stateless per call.
    mem="$(mem_recent "$SELF" 8)"
    chat_save "$SELF" user "[$from] $content"
    win="$(chat_window "$SELF")"
    prompt="Ez a beszelgeteseid eddigi menete (a memoriad). A LEGUTOLSO uzenet tole: ${from}. Vegezd el a feladatot / valaszolj ra, a korabbi kontextust figyelembe veve. A valaszod lesz a vegso uzenet.

Hosszutavu memoria (relevans tenyek):
${mem}

--- beszelgetes ---
${win}
--- vege ---"

    # Attach any image the sender referenced by path (empty-array safe for set -u).
    IMG_ARGS=()
    while IFS= read -r imgp; do
      [ -n "$imgp" ] || continue
      IMG_ARGS+=(-i "$imgp"); log "attaching image: $imgp"
    done < <(extract_image_paths "$content")

    out="$(mktemp)"
    if printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} ${IMG_ARGS[@]+"${IMG_ARGS[@]}"} -o "$out" ) >/dev/null 2>&1; then
      reply="$(cat "$out")"; [ -z "$reply" ] && reply="(ures valasz)"
      chat_save "$SELF" assistant "$reply"
      msg_done "$mid" "$reply"
      # Reply back to the sender so conversations flow (main relays to Telegram) --
      # but ONLY if the sender is a real agent. Cron jobs, scripts and external
      # feeders can also write to this queue; answering them posts a message
      # nobody reads and can bounce between runtimes.
      if [ -n "$(dbq "SELECT 1 FROM agents WHERE name='$(sql_escape "$from")' LIMIT 1;")" ]; then
        msg_send "$SELF" "$from" "$reply"
        log "msg #$mid done -> replied to $from"
      else
        log "msg #$mid done -> no reply ('$from' is not a registered agent)"
      fi
    else
      msg_fail "$mid" "codex exec failed"
      log "msg #$mid FAILED"
    fi
    rm -f "$out"
  done <<< "$rows"
done
