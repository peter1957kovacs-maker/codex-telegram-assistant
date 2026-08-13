# Codex Assistant — a Marveen-style system on your ChatGPT subscription

A multi-agent, **Telegram-native** personal assistant system powered by the
**OpenAI Codex CLI** (your ChatGPT subscription) — with **tiered persistent
memory**, a **kanban board**, a **proactive heartbeat**, inter-agent
collaboration, and a **web dashboard**. It mirrors the building blocks of a
"Marveen"-style assistant, but runs on Codex instead of Claude Code.

## Why not just use ChatGPT in the browser?

A browser tab keeps **one ever-growing conversation** — it gets slow, laggy, and
eventually **freezes / stops responding** as it fills up. This system avoids
that entirely:

- Every message is a **fresh headless `codex exec`** call.
- It feeds back only a **bounded window** of recent history + relevant memory
  from SQLite. Context never grows without bound → **no bloat, no freeze**.
- It runs **24/7**, reaches you on **Telegram**, remembers across restarts, is
  **proactive** (the heartbeat pings you when something needs attention), can
  run **multiple collaborating agents**, and has a **dashboard**.
- Uses your **ChatGPT subscription** — no per-token API bill.

## Architecture

```
Telegram ⇄ bin/telegram-bridge.sh (main agent)  ── operator <-> main
                     │
              SQLite (store/system.db)
   ┌─────────────────┼──────────────────────────┐
 memory (hot/warm/   kanban   agent_messages   daily_log
  cold/shared)                     │
                       bin/agent.sh <name>  ── sub-agents, inter-agent
 bin/heartbeat.sh  ── proactive checks -> Telegram
 bin/dashboard.py  ── http://127.0.0.1:3420 (kanban/memory/agents/log)
```

- **Data layer** — `db/schema.sql`, `lib/db.sh`, `lib/memory.sh`.
- **Agents** — `bin/agent.sh` (generic Codex worker), `config/agents.json`
  (registry), `bin/scaffold.sh` (materializes agents + `agents/<name>/AGENTS.md`).
- **Main bridge** — `bin/telegram-bridge.sh` (you ⇄ main; surfaces sub-agent replies).
- **Heartbeat** — `bin/heartbeat.sh` (proactive; silent unless something matters).
- **Dashboard** — `bin/dashboard.py` (zero-dependency, stdlib).
- **Control** — `bin/ctl.sh start|stop|status|logs`.

## Setup

**Requirements:** macOS or Linux with `codex` (OpenAI Codex CLI), `sqlite3`,
`curl`, `python3`.

```bash
# 1) Codex CLI + sign in with your ChatGPT account (once)
npm install -g @openai/codex
codex login

# 2) A Telegram bot (@BotFather -> token) and your numeric id (@userinfobot)

# 3) Configure
git clone <this-repo> codex-assistant && cd codex-assistant
bash setup.sh                 # checks deps, creates .env + config/agents.json
#   edit .env: TELEGRAM_TOKEN + ALLOWED_USER_ID
#   (optional) edit config/agents.json to define your agents

# 4) Start everything
bash bin/ctl.sh start         # scaffolds agents, starts bridge/heartbeat/dashboard/sub-agents
bash bin/ctl.sh status
```

Then message your bot on Telegram (only your user id is served), and open the
dashboard at **http://127.0.0.1:3420**.

### Always-on (macOS launchd)

`launchd/` holds plist templates. Replace `__PROJECT_DIR__` with the project path,
copy into `~/Library/LaunchAgents/`, and `launchctl bootstrap`. See each template.

## Configure & customize

- **Agents:** `config/agents.json` — name, role, enabled. `main` is the one you
  chat with; others collaborate via inter-agent messages. Re-run
  `bin/scaffold.sh` after editing.
- **Persona:** each agent's `agents/<name>/AGENTS.md` is its system prompt.
- **Memory window:** `CONTEXT_TURNS` in `.env` (default 12).
- **Heartbeat cadence:** `HEARTBEAT_INTERVAL` seconds in `.env` (default 1800).
- **Dashboard port:** `DASHBOARD_PORT` (default 3420).
- **What agents may do:** `~/.codex/config.toml` `sandbox_mode`
  (`read-only` / `workspace-write` / `danger-full-access`) — see `config.example.toml`.

## Memory tiers

`hot` (active) · `warm` (config/preference) · `cold` (long-term lesson) ·
`shared` (relevant to other agents). Plain SQLite (`store/system.db`), inspectable
and searchable from the dashboard or any SQLite tool.

## Security

- `.env` (bot token), `config/agents.json`, `store/` (all your data) and generated
  agent dirs are **git-ignored** — nothing secret is committed.
- Only `ALLOWED_USER_ID` can drive the bot.
- The dashboard binds to **127.0.0.1** only (localhost).
- Codex runs sandboxed per `~/.codex/config.toml` — keep `read-only` unless you
  deliberately want agents to act on the machine.

## License

MIT.
