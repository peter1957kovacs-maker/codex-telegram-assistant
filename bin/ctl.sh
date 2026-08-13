#!/usr/bin/env bash
# Start / stop / status for all services. Portable (nohup-based), works on
# macOS and Linux. For always-on macOS auto-start, see launchd/ templates.
#
#   bin/ctl.sh start | stop | status | logs
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"

PIDDIR="$ROOT/store/pids"; mkdir -p "$PIDDIR"
LOGDIR="$ROOT/store"

start_one() { # name cmd...
  local name="$1"; shift
  local pf="$PIDDIR/$name.pid"
  if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
    echo "  already running: $name"; return
  fi
  nohup "$@" >>"$LOGDIR/$name.log" 2>&1 &
  echo $! > "$pf"
  echo "  started: $name (pid $!)"
}

case "${1:-status}" in
  start)
    echo "Initializing..."
    db_init
    bash "$ROOT/bin/scaffold.sh" >/dev/null 2>&1 || true
    # Sub-agents (enabled, not main) run the generic runtime.
    for a in $(dbq "SELECT name FROM agents WHERE enabled=1 AND name!='main';"); do
      start_one "agent-$a" bash "$ROOT/bin/agent.sh" "$a"
    done
    # Dashboard needs no Telegram.
    start_one dashboard python3 "$ROOT/bin/dashboard.py"
    # Scheduler: dream engine, morning briefing, kanban audit.
    start_one scheduler bash "$ROOT/bin/scheduler.sh"
    # Telegram bridge + heartbeat need .env (token + user id).
    if [ -f "$ROOT/.env" ]; then
      start_one bridge    bash "$ROOT/bin/telegram-bridge.sh"
      start_one heartbeat bash "$ROOT/bin/heartbeat.sh"
    else
      echo "  NOTE: no .env -- skipped bridge + heartbeat (need TELEGRAM_TOKEN). Create .env, then re-run start."
    fi
    echo "Dashboard: http://127.0.0.1:${DASHBOARD_PORT:-3420}"
    ;;
  stop)
    for pf in "$PIDDIR"/*.pid; do
      [ -f "$pf" ] || continue
      p="$(cat "$pf" 2>/dev/null)"; n="$(basename "$pf" .pid)"
      if kill "$p" 2>/dev/null; then echo "  stopped: $n"; fi
      rm -f "$pf"
    done
    ;;
  status)
    any=0
    for pf in "$PIDDIR"/*.pid; do
      [ -f "$pf" ] || continue; any=1
      p="$(cat "$pf" 2>/dev/null)"; n="$(basename "$pf" .pid)"
      if kill -0 "$p" 2>/dev/null; then echo "  running: $n (pid $p)"; else echo "  DEAD:    $n"; fi
    done
    [ "$any" = 0 ] && echo "  (nothing started -- run: bin/ctl.sh start)"
    ;;
  logs)
    tail -n 40 "$LOGDIR"/*.log 2>/dev/null
    ;;
  *)
    echo "usage: bin/ctl.sh start|stop|status|logs"; exit 1;;
esac
