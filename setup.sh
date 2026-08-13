#!/usr/bin/env bash
# One-time setup helper for the Codex Assistant system.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Codex Assistant -- setup =="

# 1) dependency check
missing=0
for c in codex sqlite3 curl python3; do
  if command -v "$c" >/dev/null 2>&1; then echo "  ok: $c"; else echo "  MISSING: $c"; missing=1; fi
done
if [ "$missing" = 1 ]; then
  echo; echo "Install the missing tools first. On macOS:"
  echo "  brew install sqlite curl python3"
  echo "  npm install -g @openai/codex     # the Codex CLI"
  exit 1
fi

# 2) .env
if [ ! -f "$HERE/.env" ]; then
  cp "$HERE/.env.example" "$HERE/.env"
  echo "  created .env -- edit it: TELEGRAM_TOKEN (@BotFather) + ALLOWED_USER_ID (@userinfobot)"
else
  echo "  ok: .env exists"
fi

# 3) agents config
if [ ! -f "$HERE/config/agents.json" ]; then
  cp "$HERE/config/agents.example.json" "$HERE/config/agents.json"
  echo "  created config/agents.json -- edit to define your agents"
else
  echo "  ok: config/agents.json exists"
fi

# 4) init db + scaffold agents
ROOT="$HERE" bash "$HERE/bin/scaffold.sh" 2>/dev/null && echo "  ok: database + agents scaffolded"

# 5) codex login reminder
if codex login status >/dev/null 2>&1; then
  echo "  ok: codex is logged in"
else
  echo "  Codex not logged in. Run once (opens a browser):  codex login"
fi

chmod +x "$HERE"/bin/*.sh 2>/dev/null || true

cat <<EOF

Next:
  1. Edit .env (token + your user id).
  2. codex login          (sign in with your ChatGPT account, once)
  3. bash bin/ctl.sh start
  4. Message your bot on Telegram; open the dashboard at http://127.0.0.1:3420

Manage: bin/ctl.sh status | stop | logs
EOF
