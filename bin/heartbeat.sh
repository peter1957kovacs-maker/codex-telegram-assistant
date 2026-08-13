#!/usr/bin/env bash
# Proactive heartbeat -- the "soul" of a Marveen-like system.
# Every HEARTBEAT_INTERVAL seconds it asks the main agent's Codex whether there
# is anything worth proactively telling the operator (open kanban items, pending
# things, time-sensitive notes). If nothing substantive, it stays SILENT. It
# also appends a line to the daily log when it does surface something.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"; . "$ROOT/lib/channels.sh"

ENV_FILE="$ROOT/.env"
[ -f "$ENV_FILE" ] || { echo "[heartbeat] missing .env"; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${TELEGRAM_TOKEN:?set in .env}"; : "${ALLOWED_USER_ID:?set in .env}"
CODEX="${CODEX_BIN:-codex}"
INTERVAL="${HEARTBEAT_INTERVAL:-1800}"   # seconds between ticks (default 30 min)
SELF="main"; AGENT_DIR="$ROOT/agents/$SELF"
API="https://api.telegram.org/bot${TELEGRAM_TOKEN}"

db_init
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [heartbeat] $*"; }
send() { curl -s "$API/sendMessage" --data-urlencode "chat_id=$1" --data-urlencode "text=$2" >/dev/null 2>&1; }

log "started; interval=${INTERVAL}s"
# Small initial delay so it doesn't fire the instant the service boots.
sleep 20

while true; do
  if "$CODEX" login status >/dev/null 2>&1; then
    kanban="$(dbq "SELECT priority||' | '||status||' | '||title FROM kanban WHERE status!='done' ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END LIMIT 15;")"
    hot="$(dbq "SELECT content FROM memories WHERE agent_id='$SELF' AND category='hot' ORDER BY id DESC LIMIT 8;")"

    prompt="Csendes proaktiv ellenorzes. Az alabbi a nyitott kanban es a friss hot memoria. Dontsd el van-e barmi ERDEMI amit MOST jelezni kell a felhasznalonak (surgos feladat, hatarido, valami ami ra var). Ha NINCS erdemi, a valaszod PONTOSAN ennyi legyen: CSEND. Ha VAN, ird meg tomoren 1-3 mondatban mit.

Nyitott kanban:
${kanban:-(nincs)}

Friss hot memoria:
${hot:-(nincs)}"

    out="$(mktemp)"
    if printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check -o "$out" ) >/dev/null 2>&1; then
      reply="$(cat "$out")"
      trimmed="$(printf '%s' "$reply" | tr -d '[:space:]')"
      if [ -n "$trimmed" ] && [ "$trimmed" != "CSEND" ]; then
        notify "🫧 $reply"
        log_add "$SELF" "heartbeat surfaced: $reply"
        log "surfaced to operator"
      else
        log "silent tick"
      fi
    fi
    rm -f "$out"
  else
    log "codex auth pending -- skipping tick"
  fi
  sleep "$INTERVAL"
done
