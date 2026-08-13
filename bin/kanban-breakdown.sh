#!/usr/bin/env bash
# AI auto-breakdown: split a kanban card into concrete subtasks via Codex.
# Usage: bin/kanban-breakdown.sh <card_id>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"; . "$ROOT/lib/codex.sh"
CODEX="${CODEX_BIN:-codex}"
MODEL_ARGS=(); while IFS= read -r _a; do MODEL_ARGS+=("$_a"); done < <(codex_model_args "main")
AGENT_DIR="$ROOT/agents/main"
db_init

cid="${1:?usage: kanban-breakdown.sh <card_id>}"
title="$(dbq "SELECT title FROM kanban WHERE id=$cid;")"
[ -z "$title" ] && { echo "no such card $cid"; exit 1; }
desc="$(dbq "SELECT COALESCE(description,'') FROM kanban WHERE id=$cid;")"

prompt="Bontsd fel ezt a feladatot 3-6 konkret, vegrehajthato alfeladatra. CSAK egy JSON tombot adj vissza magyar stringekkel, semmi mast. Pl: [\"elso lepes\",\"masodik lepes\"].

Feladat: ${title}
Leiras: ${desc}"

out="$(mktemp)"
if ! printf '%s' "$prompt" | ( cd "$AGENT_DIR" && "$CODEX" exec --skip-git-repo-check ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} -o "$out" ) >/dev/null 2>&1; then
  echo "codex exec failed"; rm -f "$out"; exit 1
fi

# Parse the JSON array (fallback: bullet/line list) and insert each as a subtask.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  kanban_subtask "$cid" "$line"
  echo "  + subtask: $line"
done < <(cat "$out" | python3 -c '
import json,sys,re
raw=sys.stdin.read()
m=re.search(r"\[.*\]", raw, re.S); items=[]
if m:
    try: items=[str(x).strip() for x in json.loads(m.group(0)) if str(x).strip()]
    except Exception: items=[]
if not items:
    items=[l.strip(" -*\t0123456789.") for l in raw.splitlines() if l.strip(" -*\t0123456789.")][:6]
print("\n".join(items[:8]))
')
rm -f "$out"
echo "breakdown done for card $cid"
