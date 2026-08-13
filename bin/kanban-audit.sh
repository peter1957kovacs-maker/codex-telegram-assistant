#!/usr/bin/env bash
# Kanban hygiene (run periodically by the scheduler):
#   - flag in_progress cards untouched for > STUCK_DAYS as stuck (and notify)
#   - archive done cards older than ARCHIVE_DAYS
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"
db_init

STUCK_DAYS="${STUCK_DAYS:-3}"
ARCHIVE_DAYS="${ARCHIVE_DAYS:-7}"
now=$(date +%s)
stuck_cut=$(( now - STUCK_DAYS*86400 ))
arch_cut=$(( now - ARCHIVE_DAYS*86400 ))

# Flag stuck (only if not already flagged) and collect their titles.
stuck_titles="$(dbq "SELECT id||': '||title FROM kanban WHERE status='in_progress' AND stuck=0 AND updated_at < $stuck_cut;")"
dbq "UPDATE kanban SET stuck=1 WHERE status='in_progress' AND updated_at < $stuck_cut;"
# Clear the flag if it moved on.
dbq "UPDATE kanban SET stuck=0 WHERE status!='in_progress' AND stuck=1;"
# Archive old done cards.
n_arch=$(dbq "SELECT count(*) FROM kanban WHERE status='done' AND archived_at IS NULL AND updated_at < $arch_cut;")
dbq "UPDATE kanban SET archived_at=$now WHERE status='done' AND archived_at IS NULL AND updated_at < $arch_cut;"

[ -n "$stuck_titles" ] && log_add "main" "kanban-audit stuck: $stuck_titles"
[ "${n_arch:-0}" -gt 0 ] && log_add "main" "kanban-audit archived $n_arch done card(s)"

# Optional nudge about stuck cards (fan out to configured channels).
if [ -n "$stuck_titles" ] && [ -f "$ROOT/.env" ]; then
  . "$ROOT/lib/channels.sh"
  set -a; . "$ROOT/.env"; set +a
  notify "⚠️ Beragadt kanban kártyák (${STUCK_DAYS}+ nap in_progress):
${stuck_titles}"
fi
echo "kanban-audit: stuck flagged, $n_arch archived"
