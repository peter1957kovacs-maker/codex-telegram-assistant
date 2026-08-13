#!/usr/bin/env bash
# Voice helpers (fully local, no external API):
#   stt <audiofile>        -> transcript on stdout (OpenAI Whisper CLI)
#   tts <text> <out.ogg>   -> Telegram-ready opus voice note (macOS `say` /
#                             Linux `espeak`, muxed to opus by ffmpeg)
# Requires: whisper (pip install openai-whisper) and ffmpeg. TTS also needs
# `say` (macOS, built-in) or `espeak`. Everything degrades gracefully if absent.

WHISPER_MODEL="${WHISPER_MODEL:-small}"
WHISPER_LANG="${WHISPER_LANG:-Hungarian}"

stt() { # audio_file -> transcript
  command -v whisper >/dev/null 2>&1 || { echo ""; return 0; }
  local d; d="$(mktemp -d)"
  whisper "$1" --language "$WHISPER_LANG" --model "$WHISPER_MODEL" \
    --output_format txt --output_dir "$d" --verbose False >/dev/null 2>&1
  cat "$d"/*.txt 2>/dev/null | tr '\n' ' '
  rm -rf "$d"
}

tts() { # text out.ogg  -> 0 on success
  command -v ffmpeg >/dev/null 2>&1 || return 1
  local text="$1" out="$2" aiff; aiff="$(mktemp).aiff"
  if command -v say >/dev/null 2>&1; then
    say -o "$aiff" "$text" 2>/dev/null
  elif command -v espeak >/dev/null 2>&1; then
    espeak -w "$aiff" "$text" 2>/dev/null
  else
    return 1
  fi
  ffmpeg -y -i "$aiff" -c:a libopus -b:a 32k "$out" >/dev/null 2>&1
  local rc=$?; rm -f "$aiff"; return $rc
}
