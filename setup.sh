#!/usr/bin/env bash
# One-time setup helper for the Codex Telegram Assistant.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Codex Telegram Assistant -- setup =="

# 1) dependency check
missing=0
for c in codex sqlite3 curl python3; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  ok: $c"
  else
    echo "  MISSING: $c"; missing=1
  fi
done
if [ "$missing" = 1 ]; then
  echo
  echo "Install the missing tools first. On macOS:"
  echo "  brew install sqlite3 curl python3"
  echo "  npm install -g @openai/codex     # the Codex CLI"
  exit 1
fi

# 2) .env
if [ ! -f "$HERE/.env" ]; then
  cp "$HERE/.env.example" "$HERE/.env"
  echo
  echo "Created .env -- now edit it and fill in:"
  echo "  TELEGRAM_TOKEN   (from @BotFather)"
  echo "  ALLOWED_USER_ID  (from @userinfobot)"
else
  echo "  ok: .env already exists"
fi

# 3) codex login reminder
if codex login status >/dev/null 2>&1; then
  echo "  ok: codex is logged in"
else
  echo
  echo "Codex is not logged in. Run once (opens a browser):"
  echo "  codex login"
fi

chmod +x "$HERE/bin/assistant.sh" 2>/dev/null || true

cat <<EOF

Next steps:
  1. Edit .env (token + your user id).
  2. codex login   (sign in with your ChatGPT account, once).
  3. Start it:     bash bin/assistant.sh
     (or install the launchd service -- see README.md to run it 24/7.)
  4. Message your bot on Telegram. Only your user id gets answered.

EOF
