#!/usr/bin/env bash
# Shared DB helpers. Source this: `. lib/db.sh`
# Expects $ROOT to be the project root; falls back to relative resolution.

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DB="${DB:-$ROOT/store/system.db}"
SCHEMA="$ROOT/db/schema.sql"

db_init() {
  mkdir -p "$(dirname "$DB")"
  sqlite3 "$DB" < "$SCHEMA"
}

# Run a query, print rows.
dbq() { sqlite3 "$DB" "$1"; }

# Escape a value for a single-quoted SQL literal.
sql_escape() { printf "%s" "$1" | sed "s/'/''/g"; }

# JSON-encode stdin (for building API responses / safe embedding).
json_str() { python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'; }
