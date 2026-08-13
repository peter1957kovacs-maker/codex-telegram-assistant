#!/usr/bin/env bash
# Outbound notification channels.
#   - Telegram is the TWO-WAY chat channel (long-poll bridge).
#   - Slack and Discord are OUTBOUND notification targets via incoming webhooks
#     (set SLACK_WEBHOOK / DISCORD_WEBHOOK in .env). Two-way Slack/Discord would
#     need a websocket gateway client, which is out of scope for this lean stack.
# notify() fans a message out to every configured channel. Expects the relevant
# .env vars to be already sourced.

_json() { python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'; }

ch_telegram() { # text
  [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${ALLOWED_USER_ID:-}" ] || return 0
  curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${ALLOWED_USER_ID}" --data-urlencode "text=$1" >/dev/null 2>&1
}
ch_slack() { # text
  [ -n "${SLACK_WEBHOOK:-}" ] || return 0
  curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
    --data "{\"text\":$(printf '%s' "$1" | _json)}" >/dev/null 2>&1
}
ch_discord() { # text
  [ -n "${DISCORD_WEBHOOK:-}" ] || return 0
  curl -s -X POST "$DISCORD_WEBHOOK" -H 'Content-Type: application/json' \
    --data "{\"content\":$(printf '%s' "$1" | _json)}" >/dev/null 2>&1
}
notify() { ch_telegram "$1"; ch_slack "$1"; ch_discord "$1"; }
