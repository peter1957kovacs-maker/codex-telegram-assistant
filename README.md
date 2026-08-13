# Codex Telegram Assistant

A personal AI assistant that lives on **Telegram** and runs on your **ChatGPT
subscription** (via the OpenAI Codex CLI) — with **persistent, bounded memory**.

## Why this instead of ChatGPT in the browser?

A browser ChatGPT tab keeps **one ever-growing conversation**. As it fills up it
gets slow, laggy, and eventually freezes or stops responding — you've probably
hit this. This assistant avoids that entirely:

- Every message runs as a **fresh headless `codex exec` call**.
- It feeds back only a **bounded window** of recent history from a local SQLite
  store (default: last 12 messages).
- The context **never grows without bound**, so it never bloats, never lags,
  never freezes.

You also get things a browser tab can't do: it runs **24/7 in the background**,
reaches you on **Telegram**, remembers across restarts, and (optionally) can run
tasks on your machine. It uses your **ChatGPT subscription** — no per-token API
bill.

## How it works

```
Telegram message ─▶ assistant.sh (long-poll)
                      │  load last N messages from SQLite (memory)
                      ▼
                    codex exec  ── generates the reply (ChatGPT)
                      │  save the exchange back to SQLite
                      ▼
                    reply on Telegram
```

- `bin/assistant.sh` — the loop: polls Telegram, calls Codex, replies, stores memory.
- `AGENTS.md` — the assistant's system prompt / persona (edit this to taste).
- `store/memory.db` — the SQLite memory (created on first run; git-ignored).
- Only your Telegram user id is allowed to talk to it; everyone else is refused.

## Setup

**Requirements:** macOS or Linux with `codex` (OpenAI Codex CLI), `sqlite3`,
`curl`, `python3`.

```bash
# 1. Install the Codex CLI and sign in with your ChatGPT account (once)
npm install -g @openai/codex
codex login

# 2. Create a Telegram bot with @BotFather -> it gives you a token.
#    Get your numeric user id from @userinfobot.

# 3. Configure
git clone <this-repo> codex-telegram-assistant
cd codex-telegram-assistant
bash setup.sh          # checks deps, creates .env
#   then edit .env: TELEGRAM_TOKEN + ALLOWED_USER_ID

# 4. Run it
bash bin/assistant.sh
#   message your bot on Telegram — it answers only you.
```

### Run it 24/7 (macOS launchd)

```bash
sed "s#__PROJECT_DIR__#$(pwd)#g" launchd/com.codexassistant.plist.template \
  > ~/Library/LaunchAgents/com.codexassistant.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.codexassistant.plist
# logs: store/assistant.log ; stop: launchctl bootout gui/$(id -u)/com.codexassistant
```

## Codex sandbox (what the assistant is allowed to do)

Set in `~/.codex/config.toml` (see `config.example.toml`):

- `read-only` — safest, chat only (default).
- `workspace-write` — can edit files in its working dir (useful for tasks).
- `danger-full-access` — no sandbox; full machine access. Only if you trust it.

## Customize

- **Persona / rules:** edit `AGENTS.md`.
- **How much it remembers per reply:** `CONTEXT_TURNS` in `.env`.
- The memory is a plain SQLite table (`messages`) in `store/memory.db` — you can
  inspect, export, or prune it with any SQLite tool.

## Security notes

- `.env` (your bot token) and `store/` (your memory) are git-ignored — they never
  get committed.
- Only `ALLOWED_USER_ID` can drive the assistant.
- Codex runs sandboxed per `~/.codex/config.toml`; keep it `read-only` unless you
  deliberately want the assistant to act on your machine.

## License

MIT — do what you like.
