#!/usr/bin/env bash
# Read config/agents.json and create each agent: a working dir with an AGENTS.md
# (its persona/system prompt) and a row in the agents table.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/memory.sh"
db_init

CFG="$ROOT/config/agents.json"
[ -f "$CFG" ] || CFG="$ROOT/config/agents.example.json"
[ -f "$CFG" ] || { echo "no agents config"; exit 1; }

python3 - "$CFG" <<'PY' | while IFS=$'\t' read -r name role enabled model; do
import json,sys
d=json.load(open(sys.argv[1]))
for a in d.get("agents",[]):
    if a.get("name","").startswith("_"): continue
    print("\t".join([a.get("name",""), a.get("role",""), "1" if a.get("enabled",True) else "0", a.get("model","")]))
PY
  [ -z "$name" ] && continue
  dir="$ROOT/agents/$name"
  mkdir -p "$dir"
  # Model: one place per agent (agents/<name>/.model). Empty = Codex default.
  # Change later with: bin/ctl.sh model <name> <model>
  [ -n "${model:-}" ] && printf '%s\n' "$model" > "$dir/.model"
  if [ ! -f "$dir/AGENTS.md" ]; then
    cat > "$dir/AGENTS.md" <<EOF
# ${name}

Szerep: ${role}

Te egy Codex-alapu ugynok vagy a rendszerben. A felhasznalo nyelven valaszolj
(magyarul, ha magyarul irnak). Tomor, oszinte. Ha mas ugynoknek uzennel, azt a
rendszer inter-agent csatornajan teszed (a runtime kezeli a valaszod tovabbitasat).

Memoria: rovid tenyek/preferenciak -> a rendszer SQLite memoriaja (hot/warm/cold).
Hosszabb doksik, jegyzetek, kontextus -> az Obsidian vault (markdown fajlok az
OBSIDIAN_VAULT mappaban). Shell-hozzaferessel .md fajlt irhatsz/olvashatsz ott.

Tartos tudas: a szereped, szabalyaid, ES hogy KIVEL dolgozol egyutt (mas ugynokok,
munkamegosztas) ebbe az AGENTS.md-be kerul -- a Codex minden hivasnal betolti,
tehat ezt mindig tudod. Ugynokok kozti kozos tudas mehet a 'shared' memoriaba is.
EOF
  fi
  dbq "INSERT INTO agents(name,role,enabled) VALUES('$(sql_escape "$name")','$(sql_escape "$role")',$enabled)
       ON CONFLICT(name) DO UPDATE SET role=excluded.role, enabled=excluded.enabled;"
  echo "scaffolded agent: $name (enabled=$enabled)"
done
