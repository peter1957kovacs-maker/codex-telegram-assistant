#!/usr/bin/env bash
# Dream engine: nightly consolidation. Reviews the day's memories, daily log and
# open kanban, and via Codex produces 3-4 prioritized proposals for tomorrow.
# Saves to store/dream.md and as a hot memory (the morning briefing reads it).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"
CODEX="${CODEX_BIN:-codex}"; AGENT_DIR="$ROOT/agents/main"
db_init

# start-of-day epoch (macOS `date -v` or GNU `date -d`)
today_start="$(date -v0H -v0M -v0S +%s 2>/dev/null || date -d 'today 00:00' +%s)"
mems="$(dbq "SELECT category||': '||content FROM memories WHERE created_at>=$today_start ORDER BY id;")"
logs="$(dbq "SELECT entry FROM daily_log WHERE created_at>=$today_start ORDER BY id;")"
kb="$(dbq "SELECT priority||' '||status||' '||title FROM kanban WHERE status!='done' AND archived_at IS NULL;")"

prompt="Ejszakai osszegzes. Az alabbi a mai nap memoriai, naploja es a nyitott kanban. Adj 3-4 prioritalt, KONKRET javaslatot HOLNAPRA, tomoren, magyarul. Ha a nap ures volt, egy sor eleg.

Mai memoriak:
${mems:-(nincs)}

Naplo:
${logs:-(nincs)}

Nyitott kanban:
${kb:-(nincs)}"

out="$(mktemp)"
if printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check -o "$out" ) >/dev/null 2>&1; then
  reply="$(cat "$out")"
  { echo "# Dream $(date +%F)"; echo; printf '%s\n' "$reply"; } > "$ROOT/store/dream.md"
  mem_save main hot "dream" "Dream $(date +%F): $reply"
  log_add main "dream engine ran"
  echo "dream saved"
else
  echo "dream: codex exec failed"; exit 1
fi
rm -f "$out"
