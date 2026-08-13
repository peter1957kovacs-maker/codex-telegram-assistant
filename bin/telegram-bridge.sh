#!/usr/bin/env bash
# Telegram bridge for the 'main' agent.
#   - Operator (you) <-> main: your Telegram messages run through main's Codex
#     with a bounded chat window + memory as context; the reply comes back.
#   - Sub-agent -> operator: inter-agent messages addressed to 'main' from other
#     agents are surfaced to your Telegram (so delegated work reaches you).
# Only ALLOWED_USER_ID may drive it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"; . "$ROOT/lib/codex.sh"; . "$ROOT/lib/voice.sh"

ENV_FILE="$ROOT/.env"
[ -f "$ENV_FILE" ] || { echo "[bridge] missing .env"; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${TELEGRAM_TOKEN:?set in .env}"; : "${ALLOWED_USER_ID:?set in .env}"
CONTEXT_TURNS="${CONTEXT_TURNS:-12}"
CODEX="${CODEX_BIN:-codex}"

SELF="main"
AGENT_DIR="$ROOT/agents/$SELF"
MODEL_ARGS=(); while IFS= read -r _a; do MODEL_ARGS+=("$_a"); done < <(codex_model_args "$SELF")
API="https://api.telegram.org/bot${TELEGRAM_TOKEN}"
OFFSET_FILE="$ROOT/store/.tg_offset"

db_init
[ -d "$AGENT_DIR" ] || bash "$ROOT/bin/scaffold.sh" >/dev/null 2>&1
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [bridge] $*"; }
send() { curl -s "$API/sendMessage" --data-urlencode "chat_id=$1" --data-urlencode "text=$2" >/dev/null 2>&1; }

offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
log "started; operator=$ALLOWED_USER_ID; context=$CONTEXT_TURNS"

while true; do
  # 1) Surface sub-agent replies addressed to 'main' -> operator's Telegram.
  pend="$(msg_pending "$SELF")"
  if [ -n "$pend" ]; then
    while IFS='|' read -r mid from; do
      [ -z "$mid" ] && continue
      c="$(dbq "SELECT content FROM agent_messages WHERE id=$mid;")"
      msg_claim "$mid"; msg_done "$mid" "(forwarded to operator)"
      send "$ALLOWED_USER_ID" "[$from]: $c"
    done <<< "$pend"
  fi

  # 2) Operator messages from Telegram.
  resp="$(curl -s --max-time 20 "$API/getUpdates?timeout=12&offset=${offset}&allowed_updates=%5B%22message%22%5D")"
  [ -z "$resp" ] && { sleep 1; continue; }

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
    voice=(m.get("voice") or {}).get("file_id","")
    sys.stdout.write(str(uid)+"\t"+str(frm)+"\t"+str(chat)+"\t"+base64.b64encode(text.encode()).decode()+"\t"+str(voice)+"\n")
')"
  [ -z "$parsed" ] && continue

  max_id="$offset"
  while IFS=$'\t' read -r uid frm chat b64 voice; do
    [ -z "$uid" ] && continue
    [ "$((uid+1))" -gt "$max_id" ] && max_id="$((uid+1))"
    text="$(printf '%s' "$b64" | base64 --decode 2>/dev/null)"
    if [ "$frm" != "$ALLOWED_USER_ID" ]; then
      [ -n "$chat" ] && send "$chat" "This is a private assistant."; continue
    fi

    # Voice message -> download + transcribe (Whisper) into text.
    was_voice=0
    if [ -z "$text" ] && [ -n "$voice" ]; then
      was_voice=1
      fp="$(curl -s "$API/getFile?file_id=$voice" | python3 -c 'import json,sys;print((json.load(sys.stdin).get("result") or {}).get("file_path",""))' 2>/dev/null)"
      if [ -n "$fp" ]; then
        oga="$(mktemp).oga"
        curl -s "https://api.telegram.org/file/bot${TELEGRAM_TOKEN}/$fp" -o "$oga" 2>/dev/null
        text="$(stt "$oga")"; rm -f "$oga"
      fi
      [ -z "$text" ] && { send "$chat" "(nem sikerült a hangot leiratozni; telepítve van a whisper?)"; continue; }
    fi
    [ -z "$text" ] && continue

    # Approval commands from the operator (approve/deny an id).
    case "$text" in
      approve\ [0-9]*|jovahagy\ [0-9]*|elfogad\ [0-9]*)
        aid="${text##* }"; approval_resolve "$aid" approved; audit "$ALLOWED_USER_ID" "approval.approved" "#$aid"
        send "$chat" "Jóváhagyva: #$aid"; continue;;
      deny\ [0-9]*|elutasit\ [0-9]*|elutasít\ [0-9]*)
        aid="${text##* }"; approval_resolve "$aid" denied; audit "$ALLOWED_USER_ID" "approval.denied" "#$aid"
        send "$chat" "Elutasítva: #$aid"; continue;;
    esac

    if ! "$CODEX" login status >/dev/null 2>&1; then
      send "$chat" "A Codex nincs bejelentkezve. Futtasd egyszer: codex login"; continue
    fi

    chat_save "$SELF" user "$text"
    win="$(chat_window "$SELF" "$CONTEXT_TURNS")"
    mem="$(mem_recent "$SELF" 8)"
    prompt="Ez a beszelgetes eddigi menete (memoria-ablak). Valaszolj a LEGUTOLSO 'user' uzenetre termeszetesen, a kontextust figyelembe veve. Ha mas ugynoknek kell delegalnod, azt a rendszer inter-agent csatornajan teszed.

Hosszutavu memoria (relevans tenyek):
${mem}

--- beszelgetes ---
${win}
--- vege ---"

    out="$(mktemp)"
    if printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} -o "$out" ) >/dev/null 2>&1; then
      reply="$(cat "$out")"; [ -z "$reply" ] && reply="(ures valasz)"
    else
      reply="[hiba: a Codex most nem tudott valaszolni. Probald ujra.]"
    fi
    rm -f "$out"
    chat_save "$SELF" assistant "$reply"
    # Voice reply if the inbound was voice and VOICE_REPLY is on.
    if [ "$was_voice" = 1 ] && [ "${VOICE_REPLY:-0}" = 1 ]; then
      ogg="$(mktemp).ogg"
      if tts "$reply" "$ogg"; then
        curl -s "$API/sendVoice" -F "chat_id=$chat" -F "voice=@$ogg" >/dev/null 2>&1
      else
        send "$chat" "$reply"
      fi
      rm -f "$ogg"
    else
      send "$chat" "$reply"
    fi
    log "answered operator (${#reply} chars)"
  done <<< "$parsed"

  offset="$max_id"
  printf '%s' "$offset" > "$OFFSET_FILE"
done
