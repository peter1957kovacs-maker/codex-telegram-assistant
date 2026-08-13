#!/usr/bin/env bash
# Morning briefing: sends the dream-engine proposals + open kanban to Telegram.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"; . "$ROOT/lib/channels.sh"
db_init
[ -f "$ROOT/.env" ] || { echo "no .env"; exit 0; }
set -a; . "$ROOT/.env"; set +a
[ -n "${TELEGRAM_TOKEN:-}" ] || [ -n "${SLACK_WEBHOOK:-}" ] || [ -n "${DISCORD_WEBHOOK:-}" ] || { echo "no channel configured"; exit 0; }

dream="$(cat "$ROOT/store/dream.md" 2>/dev/null)"
kb="$(dbq "SELECT '• '||priority||' — '||title FROM kanban WHERE status!='done' AND archived_at IS NULL ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END LIMIT 10;")"

text="☀️ Reggeli napindító — $(date +%F)

${dream:-(nincs éjszakai összegzés)}

📋 Nyitott feladatok:
${kb:-(nincs nyitott feladat)}"

notify "$text"
log_add main "morning briefing sent"
echo "briefing sent"
