#!/usr/bin/env bash
# Codex Telegram Assistant
# ------------------------
# A personal assistant that lives on Telegram and is driven by the OpenAI Codex
# CLI (ChatGPT subscription). Unlike a browser ChatGPT tab -- which keeps one
# ever-growing conversation that slows down and freezes as it fills up -- this
# assistant runs each message as a FRESH headless `codex exec` call and feeds
# back only a bounded window of recent history from a local SQLite store. The
# context never grows without bound, so it never bloats or lags.
#
# Auth: ChatGPT subscription. Run `codex login` once (interactive browser).
# Security: only ALLOWED_USER_ID (you) can talk to the bot; anyone else who
# finds it gets a polite refusal and cannot drive Codex.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$HERE/.env"
DB="$HERE/store/memory.db"
OFFSET_FILE="$HERE/store/.offset"
CODEX="${CODEX_BIN:-codex}"

[ -f "$ENV_FILE" ] || { echo "[assistant] Missing .env -- copy .env.example to .env and fill it in."; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${TELEGRAM_TOKEN:?set TELEGRAM_TOKEN in .env}"
: "${ALLOWED_USER_ID:?set ALLOWED_USER_ID in .env}"
CONTEXT_TURNS="${CONTEXT_TURNS:-12}"   # how many recent messages to feed back

API="https://api.telegram.org/bot${TELEGRAM_TOKEN}"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

# --- persistent, bounded memory (SQLite) ---
init_db() { sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, role TEXT, content TEXT, ts INTEGER);"; }
save_msg() { # role content
  local esc; esc=$(printf '%s' "$2" | sed "s/'/''/g")
  sqlite3 "$DB" "INSERT INTO messages(role,content,ts) VALUES('$1','$esc',strftime('%s','now'));"
}
recent_context() { # last N messages oldest-first, as a transcript
  sqlite3 -separator ': ' "$DB" \
    "SELECT role, content FROM (SELECT * FROM messages ORDER BY id DESC LIMIT $CONTEXT_TURNS) ORDER BY id ASC;"
}

send() { # chat_id text
  curl -s "$API/sendMessage" --data-urlencode "chat_id=$1" --data-urlencode "text=$2" >/dev/null 2>&1
}

# Verify Codex is logged in; if not, tell the operator instead of hanging.
codex_ready() { "$CODEX" login status >/dev/null 2>&1; }

init_db
offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
log "started; operator=$ALLOWED_USER_ID; context window=$CONTEXT_TURNS msgs"

while true; do
  resp="$(curl -s --max-time 40 "$API/getUpdates?timeout=25&offset=${offset}&allowed_updates=%5B%22message%22%5D")"
  [ -z "$resp" ] && { sleep 2; continue; }

  # Emit one TSV line per message: update_id \t from_id \t chat_id \t base64(text)
  parsed="$(printf '%s' "$resp" | python3 -c '
import json,sys,base64
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
if not d.get("ok"): sys.exit(0)
for u in d.get("result",[]):
    m=u.get("message") or {}
    uid=u.get("update_id","")
    frm=(m.get("from") or {}).get("id","")
    chat=(m.get("chat") or {}).get("id","")
    text=m.get("text","") or ""
    sys.stdout.write(str(uid)+"\t"+str(frm)+"\t"+str(chat)+"\t"+base64.b64encode(text.encode()).decode()+"\n")
')"
  [ -z "$parsed" ] && continue

  max_id="$offset"
  while IFS=$'\t' read -r uid frm chat b64; do
    [ -z "$uid" ] && continue
    [ "$((uid+1))" -gt "$max_id" ] && max_id="$((uid+1))"
    text="$(printf '%s' "$b64" | base64 --decode 2>/dev/null)"

    if [ "$frm" != "$ALLOWED_USER_ID" ]; then
      [ -n "$chat" ] && send "$chat" "This is a private assistant."
      continue
    fi
    [ -z "$text" ] && continue
    log "message from operator (${#text} chars)"

    if ! codex_ready; then
      send "$chat" "A Codex nincs bejelentkezve. A gepen futtasd egyszer: codex login"
      continue
    fi

    save_msg user "$text"
    ctx="$(recent_context)"
    prompt="Ez a beszelgetes eddigi menete (a memoriad). Valaszolj a LEGUTOLSO 'user' uzenetre termeszetesen, a korabbi kontextust figyelembe veve. Ne ismeteld meg a beszelgetest, csak a valaszt add.

--- beszelgetes ---
$ctx
--- vege ---"

    out="$(mktemp)"
    if printf '%s' "$prompt" | ( cd "$HERE" && "$CODEX" exec --skip-git-repo-check -o "$out" ) >/dev/null 2>&1; then
      reply="$(cat "$out")"; [ -z "$reply" ] && reply="(ures valasz)"
    else
      reply="[hiba: a Codex most nem tudott valaszolni. Probald ujra, vagy ellenorizd a codex login-t.]"
    fi
    rm -f "$out"
    save_msg assistant "$reply"
    send "$chat" "$reply"
    log "replied (${#reply} chars)"
  done <<< "$parsed"

  offset="$max_id"
  printf '%s' "$offset" > "$OFFSET_FILE"
done
