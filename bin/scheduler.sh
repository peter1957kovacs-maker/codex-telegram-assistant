#!/usr/bin/env bash
# Simple portable scheduler: runs time-of-day and interval tasks.
#   - dream engine     at DREAM_TIME     (default 02:07)
#   - morning briefing at BRIEFING_TIME  (default 07:30)
#   - kanban audit      every AUDIT_INTERVAL seconds (default 4h)
# State (last-run markers) in store/.sched/. One lightweight loop; no cron needed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHED_DIR="$ROOT/store/.sched"; mkdir -p "$SCHED_DIR"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
DREAM_TIME="${DREAM_TIME:-02:07}"
BRIEFING_TIME="${BRIEFING_TIME:-07:30}"
AUDIT_INTERVAL="${AUDIT_INTERVAL:-14400}"

ran_today()  { [ "$(cat "$SCHED_DIR/$1.day" 2>/dev/null)" = "$(date +%F)" ]; }
mark_today() { date +%F > "$SCHED_DIR/$1.day"; }
due_every()  { local last; last="$(cat "$SCHED_DIR/$1.ts" 2>/dev/null || echo 0)"; [ $(( $(date +%s) - last )) -ge "$2" ]; }
mark_ts()    { date +%s > "$SCHED_DIR/$1.ts"; }
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [scheduler] $*"; }

log "started (dream=$DREAM_TIME briefing=$BRIEFING_TIME audit=${AUDIT_INTERVAL}s)"
while true; do
  now="$(date +%H:%M)"
  if [ "$now" = "$DREAM_TIME" ] && ! ran_today dream; then
    log "running dream engine"; bash "$ROOT/bin/dream.sh" >/dev/null 2>&1; mark_today dream
  fi
  if [ "$now" = "$BRIEFING_TIME" ] && ! ran_today briefing; then
    log "running morning briefing"; bash "$ROOT/bin/briefing.sh" >/dev/null 2>&1; mark_today briefing
  fi
  if due_every audit "$AUDIT_INTERVAL"; then
    bash "$ROOT/bin/kanban-audit.sh" >/dev/null 2>&1; mark_ts audit
  fi
  sleep 40
done
