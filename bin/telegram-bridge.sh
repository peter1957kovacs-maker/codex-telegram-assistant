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

INBOX="$AGENT_DIR/inbox"   # downloaded attachments (images)

# Download a Telegram photo / image document and print the local path. Codex
# reads images from DISK (`codex exec -i <FILE>`), so a file_id alone is useless:
# the bytes have to land somewhere first.
download_tg_file() { # <file_id> -> stdout: local path (empty on failure)
  local fid="$1" fp ext dest
  fp="$(curl -s "$API/getFile?file_id=$fid" \
        | python3 -c 'import json,sys; print((json.load(sys.stdin).get("result") or {}).get("file_path",""))' 2>/dev/null)"
  [ -z "$fp" ] && return 1
  ext="$(printf '%s' "${fp##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in jpg|jpeg|png|gif|webp) : ;; *) ext="jpg" ;; esac
  mkdir -p "$INBOX"
  dest="$INBOX/tg-$(date '+%Y%m%d-%H%M%S')-$$.$ext"
  curl -s "https://api.telegram.org/file/bot${TELEGRAM_TOKEN}/$fp" -o "$dest" 2>/dev/null
  [ -s "$dest" ] || { rm -f "$dest"; return 1; }
  printf '%s' "$dest"
}

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
    # A photo message has NO "text" field (photo[] + optional caption), so reading
    # only "text" drops every image silently. Largest photo size, or image/* doc.
    text=m.get("text","") or m.get("caption","") or ""
    voice=(m.get("voice") or {}).get("file_id","")
    img=""
    photos=m.get("photo") or []
    if photos:
        img=max(photos, key=lambda p: p.get("file_size") or 0).get("file_id","")
    else:
        doc=m.get("document") or {}
        if str(doc.get("mime_type","")).startswith("image/"):
            img=doc.get("file_id","")
    sys.stdout.write(str(uid)+"\t"+str(frm)+"\t"+str(chat)+"\t"+base64.b64encode(text.encode()).decode()+"\t"+str(voice)+"\t"+str(img)+"\n")
')"
  [ -z "$parsed" ] && continue

  max_id="$offset"
  while IFS=$'\t' read -r uid frm chat b64 voice img_file_id; do
    [ -z "$uid" ] && continue
    img_file_id="${img_file_id:-}"
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

    # Image -> download BEFORE the empty-text check, otherwise a caption-less
    # photo falls through here and disappears without a trace.
    img=""
    if [ -n "$img_file_id" ]; then
      img="$(download_tg_file "$img_file_id" || true)"
      [ -z "$img" ] && { send "$chat" "(a képet nem sikerült letölteni a Telegramról)"; continue; }
      log "image saved: $img"
    fi
    [ -z "$text" ] && [ -z "$img" ] && continue
    [ -z "$text" ] && text="(kép, kísérőszöveg nélkül -- mondd el mit látsz rajta)"

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

    chat_save "$SELF" user "$text${img:+ [kep: $img]}"
    win="$(chat_window "$SELF" "$CONTEXT_TURNS")"
    mem="$(mem_recent "$SELF" 8)"
    prompt="Ez a beszelgetes eddigi menete (memoria-ablak). Valaszolj a LEGUTOLSO 'user' uzenetre termeszetesen, a kontextust figyelembe veve. Ha mas ugynoknek kell delegalnod, azt a rendszer inter-agent csatornajan teszed.${img:+
A legutolso uzenethez KEP is tartozik, csatolva kapod (${img}). Nezd meg, es arra is valaszolj.}

Hosszutavu memoria (relevans tenyek):
${mem}

--- beszelgetes ---
${win}
--- vege ---"

    # -i attaches the image to the prompt (empty-array safe under set -u).
    IMG_ARGS=(); [ -n "$img" ] && IMG_ARGS=(-i "$img")
    out="$(mktemp)"
    if printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} ${IMG_ARGS[@]+"${IMG_ARGS[@]}"} -o "$out" ) >/dev/null 2>&1; then
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
