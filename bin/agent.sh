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

# --- batching --------------------------------------------------------------
# Several queued messages from the SAME sender usually belong together (a task
# split across messages, a forwarded run). One codex exec per row gives
# disconnected answers, so consecutive rows from one sender are merged into ONE
# call and ONE reply -- the same behaviour the Telegram bridge has.
GIDS=(); GTEXTS=(); GFROM=""

flush_group() {
  [ ${#GIDS[@]} -eq 0 ] && return 0
  local n=${#GIDS[@]} merged i t mid reply out
  if [ "$n" -eq 1 ]; then
    merged="${GTEXTS[0]}"
  else
    merged="(${GFROM} $n uzenetben irta le ugyanezt az egy dolgot, egyben kezeld, egy valaszt adj ra:)"
    i=1
    for t in "${GTEXTS[@]}"; do
      merged="$merged
[$i] $t"
      i=$((i+1))
    done
  fi
  log "processing $n msg(s) from $GFROM (ids: ${GIDS[*]})"

  # Long-term memory + the bounded conversation window (so the agent remembers
  # its thread, not just its facts). codex exec is stateless per call.
  mem="$(mem_context "$SELF" "$merged")"
  merged="$(cap_batch "$merged")"
  chat_save "$SELF" user "[$GFROM] $merged"
  # Reserve room for the new turn plus the fixed prompt frame (~800 chars).
  win="$(fit_window "$SELF" 12 $((${#merged} + 800)))"
  prompt="Ez a beszelgeteseid eddigi menete (a memoriad). A LEGUTOLSO uzenet tole: ${GFROM}. Vegezd el a feladatot / valaszolj ra, a korabbi kontextust figyelembe veve. A valaszod lesz a vegso uzenet.

Hosszutavu memoria (relevans tenyek):
${mem}

--- beszelgetes ---
${win}
--- vege ---

${MEM_INSTRUCTION}"

  # Attach every image referenced by path across the whole group
  # (empty-array safe expansion for bash 3.2 + set -u).
  IMG_ARGS=()
  while IFS= read -r imgp; do
    [ -n "$imgp" ] || continue
    IMG_ARGS+=(-i "$imgp"); log "attaching image: $imgp"
  done < <(extract_image_paths "$merged")

  out="$(mktemp)"
  if printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} ${IMG_ARGS[@]+"${IMG_ARGS[@]}"} -o "$out" ) >/dev/null 2>&1; then
    reply="$(mem_harvest "$SELF" "$(cat "$out")")"; [ -z "$reply" ] && reply="(ures valasz)"
    chat_save "$SELF" assistant "$reply"
    for mid in "${GIDS[@]}"; do msg_done "$mid" "$reply"; done
    # Reply back to the sender so conversations flow (main relays to Telegram) --
    # but ONLY if the sender is a real agent. Cron jobs, scripts and external
    # feeders can also write to this queue; answering them posts a message
    # nobody reads and can bounce between runtimes. ONE reply per group.
    if [ -n "$(dbq "SELECT 1 FROM agents WHERE name='$(sql_escape "$GFROM")' LIMIT 1;")" ]; then
      msg_send "$SELF" "$GFROM" "$reply"
      log "ids ${GIDS[*]} done -> one reply to $GFROM"
    else
      log "ids ${GIDS[*]} done -> no reply ('$GFROM' is not a registered agent)"
    fi
  else
    for mid in "${GIDS[@]}"; do msg_fail "$mid" "codex exec failed"; done
    log "ids ${GIDS[*]} FAILED"
  fi
  rm -f "$out"
  GIDS=(); GTEXTS=(); GFROM=""
}

while true; do
  if ! "$CODEX" login status >/dev/null 2>&1; then
    log "codex auth pending -- idling (run: codex login)"; sleep 30; continue
  fi

  rows="$(msg_pending "$SELF")"
  [ -z "$rows" ] && { sleep "$POLL"; continue; }

  GIDS=(); GTEXTS=(); GFROM=""
  while IFS='|' read -r mid from; do
    [ -z "$mid" ] && continue
    content="$(dbq "SELECT content FROM agent_messages WHERE id=$mid;")"
    msg_claim "$mid"
    # A different sender starts a new group: answer the previous one first, so
    # nobody gets an answer that mixes two conversations.
    if [ -n "$GFROM" ] && [ "$from" != "$GFROM" ]; then
      flush_group
    fi
    GFROM="$from"
    GIDS+=("$mid")
    GTEXTS+=("$content")
  done <<< "$rows"
  flush_group
done
