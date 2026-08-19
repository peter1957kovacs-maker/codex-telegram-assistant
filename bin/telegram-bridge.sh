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
save_offset() { printf '%s' "$offset" > "$OFFSET_FILE"; }

# --- batching --------------------------------------------------------------
# One thought often arrives as SEVERAL messages (typing in bursts, forwarding a
# run of related messages). Answering each separately gives disconnected replies
# that miss the whole. So: after the first message, wait for DEBOUNCE_SECS of
# silence, then answer everything as ONE turn. Every new message restarts the
# window, so a burst of ten messages produces one answer, not ten.
DEBOUNCE_SECS="${DEBOUNCE_SECS:-8}"
BATCH_MAX="${BATCH_MAX:-25}"

# Long-poll and print parsed TSV. Telegram returns as soon as a message arrives,
# so a short timeout IS the "wait for silence" primitive: empty output = quiet.
poll_updates() { # <timeout_secs>
  local t="$1" resp
  resp="$(curl -s --max-time "$((t + 10))" "$API/getUpdates?timeout=${t}&offset=${offset}&allowed_updates=%5B%22message%22%5D")"
  [ -z "$resp" ] && return 1
  printf '%s' "$resp" | python3 -c '
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
    # NEVER emit an empty field: bash treats TAB as IFS-whitespace, so `read`
    # collapses a run of tabs into ONE delimiter and every later field shifts
    # left. A voice message or a caption-less photo (empty b64) would put the
    # file_id into the text slot, where base64-decoding it yields BINARY garbage
    # that codex then rejects outright. "-" means empty.
    b=base64.b64encode(text.encode()).decode()
    sys.stdout.write(str(uid)+"\t"+str(frm)+"\t"+str(chat)+"\t"+(b or "-")+"\t"+(str(voice) or "-")+"\t"+(str(img) or "-")+"\n")
'
}

# Fold parsed lines into the batch buffers. Approval commands are executed right
# away (they are commands, not conversation) and never join the batch. Returns 0
# if at least one usable operator message was added, 1 otherwise.
collect() { # <parsed_tsv>
  local added=1 uid frm chat b64 voice img_file_id text img fp oga
  while IFS=$'\t' read -r uid frm chat b64 voice img_file_id; do
    [ -z "$uid" ] && continue
    img_file_id="${img_file_id:-}"
    [ "$b64" = "-" ] && b64=""
    [ "$voice" = "-" ] && voice=""
    [ "$img_file_id" = "-" ] && img_file_id=""
    [ "$((uid+1))" -gt "$offset" ] && offset="$((uid+1))"
    if [ "$frm" != "$ALLOWED_USER_ID" ]; then
      [ -n "$chat" ] && send "$chat" "This is a private assistant."; continue
    fi
    text="$(printf '%s' "$b64" | base64 --decode 2>/dev/null)"
    # Never let non-UTF-8 bytes reach codex: it rejects the WHOLE stdin on a
    # single invalid byte, and once such a row lands in the chat memory every
    # later call fails too, not just the one that caused it.
    if [ -n "$text" ] && ! printf '%s' "$text" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
      log "dropping non-UTF-8 text (${#text} bytes)"; text=""
    fi

    # Voice message -> download + transcribe (Whisper) into text.
    if [ -z "$text" ] && [ -n "$voice" ]; then
      BATCH_VOICE=1
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
    [ -z "$text" ] && text="(kép kísérőszöveg nélkül: $(basename "$img"))"

    # Approval commands from the operator (approve/deny an id) -- act now.
    case "$text" in
      approve\ [0-9]*|jovahagy\ [0-9]*|elfogad\ [0-9]*)
        aid="${text##* }"; approval_resolve "$aid" approved; audit "$ALLOWED_USER_ID" "approval.approved" "#$aid"
        send "$chat" "Jóváhagyva: #$aid"; continue;;
      deny\ [0-9]*|elutasit\ [0-9]*|elutasít\ [0-9]*)
        aid="${text##* }"; approval_resolve "$aid" denied; audit "$ALLOWED_USER_ID" "approval.denied" "#$aid"
        send "$chat" "Elutasítva: #$aid"; continue;;
    esac

    [ ${#BATCH_TEXTS[@]} -ge "$BATCH_MAX" ] && break
    BATCH_CHAT="$chat"
    BATCH_TEXTS+=("$text")
    [ -n "$img" ] && BATCH_IMGS+=("$img")
    added=0
  done <<< "$1"
  return $added
}

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

  # 2) Operator messages from Telegram, batched.
  parsed="$(poll_updates 12)" || { sleep 1; continue; }
  [ -z "$parsed" ] && continue

  BATCH_TEXTS=(); BATCH_IMGS=(); BATCH_CHAT=""; BATCH_VOICE=0
  collect "$parsed" || { save_offset; continue; }
  save_offset

  while [ ${#BATCH_TEXTS[@]} -lt "$BATCH_MAX" ]; do
    more="$(poll_updates "$DEBOUNCE_SECS")" || break
    [ -z "$more" ] && break            # silence -> the thought is finished
    collect "$more" || { save_offset; break; }
    save_offset
  done

  if ! "$CODEX" login status >/dev/null 2>&1; then
    send "$BATCH_CHAT" "A Codex nincs bejelentkezve. Futtasd egyszer: codex login"; continue
  fi

  # Merge into ONE user turn. Numbering the parts tells the model they arrived
  # separately but belong together, so it answers the whole, not the fragment.
  n=${#BATCH_TEXTS[@]}
  if [ "$n" -eq 1 ]; then
    merged="${BATCH_TEXTS[0]}"
  else
    merged="(A felhasznalo $n uzenetben irta le ugyanezt az egy dolgot, egyben kezeld, egy valaszt adj ra:)"
    i=1
    for t in "${BATCH_TEXTS[@]}"; do
      merged="$merged
[$i] $t"
      i=$((i+1))
    done
  fi

  IMG_ARGS=(); img_note=""
  if [ ${#BATCH_IMGS[@]} -gt 0 ]; then
    for p in "${BATCH_IMGS[@]}"; do IMG_ARGS+=(-i "$p"); done
    img_note="
Az uzenethez ${#BATCH_IMGS[@]} KEP is tartozik, csatolva kapod. Nezd meg, es azokra is valaszolj."
    merged="$merged
(csatolt kepek: ${BATCH_IMGS[*]})"
  fi

  chat_save "$SELF" user "$merged"
  win="$(chat_window "$SELF" "$CONTEXT_TURNS")"
  mem="$(mem_recent "$SELF" 8)"
  prompt="Ez a beszelgetes eddigi menete (memoria-ablak). Valaszolj a LEGUTOLSO 'user' uzenetre termeszetesen, a kontextust figyelembe veve. Ha mas ugynoknek kell delegalnod, azt a rendszer inter-agent csatornajan teszed.${img_note}

Hosszutavu memoria (relevans tenyek):
${mem}

--- beszelgetes ---
${win}
--- vege ---"

  out="$(mktemp)"
  if printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} ${IMG_ARGS[@]+"${IMG_ARGS[@]}"} -o "$out" ) >/dev/null 2>&1; then
    reply="$(cat "$out")"; [ -z "$reply" ] && reply="(ures valasz)"
  else
    reply="[hiba: a Codex most nem tudott valaszolni. Probald ujra.]"
  fi
  rm -f "$out"
  chat_save "$SELF" assistant "$reply"
  # Voice reply if any part of the batch was voice and VOICE_REPLY is on.
  if [ "$BATCH_VOICE" = 1 ] && [ "${VOICE_REPLY:-0}" = 1 ]; then
    ogg="$(mktemp).ogg"
    if tts "$reply" "$ogg"; then
      curl -s "$API/sendVoice" -F "chat_id=$BATCH_CHAT" -F "voice=@$ogg" >/dev/null 2>&1
    else
      send "$BATCH_CHAT" "$reply"
    fi
    rm -f "$ogg"
  else
    send "$BATCH_CHAT" "$reply"
  fi
  log "answered operator (batch=$n msg, images=${#BATCH_IMGS[@]}, ${#reply} chars)"
  save_offset
done
