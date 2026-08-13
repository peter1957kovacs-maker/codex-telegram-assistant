# Codex Assistant — a Marveen-style AI system on your ChatGPT subscription

A multi-agent, **Telegram-native** personal-assistant system powered by the
**OpenAI Codex CLI** (your ChatGPT subscription). It mirrors the building blocks
of a "Marveen"-style AI fleet — tiered memory, kanban, a proactive heartbeat,
inter-agent collaboration, a web dashboard, Obsidian notes, voice, and more —
but runs on Codex instead of Claude Code, with **no per-token API bill**.

## Why not just use ChatGPT in the browser?

A browser tab keeps **one ever-growing conversation** — it slows down, lags, and
eventually **freezes** as it fills up. This system runs every message as a
**fresh headless `codex exec`** call and feeds back only a **bounded window** of
recent history + relevant memory from SQLite. Context never grows without bound,
so it **never bloats or freezes**. Plus it runs 24/7, is proactive, multi-agent,
multi-channel, and has a dashboard.

## Features

- **Multiple agents** on Codex, collaborating via an **inter-agent** message queue.
- **Tiered memory** (hot / warm / cold / shared) with **FTS5 full-text search**.
- **Kanban** with **AI auto-breakdown** (split a card into subtasks), **stuck-card**
  flagging, and **auto-archive** of old done cards.
- **Proactive heartbeat** — surfaces what matters, stays silent otherwise.
- **Dream engine + morning briefing** — nightly consolidation, morning summary.
- **Obsidian** vault integration — long notes/docs as markdown, browsable in the dashboard.
- **Web dashboard** (localhost, **installable PWA**): kanban, memory, agents,
  inter-agent messages, Obsidian, approvals, audit log, daily log.
- **Approvals** flow + **audit log** for traceability.
- **Multi-channel** outbound (Telegram + Slack + Discord webhooks); two-way on Telegram.
- **Voice** — transcribes Telegram voice messages (Whisper) and can reply with
  speech (`say`/`espeak`), fully local.
- **Encrypted secret vault** (AES-256, Keychain-backed) with `vault:ID` refs.
- **Federation** — link multiple instances over HTTP.

## Setup

**Requirements:** macOS or Linux with `codex`, `sqlite3`, `curl`, `python3`.
Optional: `ffmpeg` + `whisper` (voice), `openssl` (vault).

```bash
npm install -g @openai/codex && codex login     # sign in with ChatGPT (once)
# Telegram: create a bot with @BotFather (token); get your id from @userinfobot.

git clone <this-repo> codex-assistant && cd codex-assistant
bash setup.sh          # deps check, .env + config/agents.json, DB + agent scaffold
#   edit .env: TELEGRAM_TOKEN + ALLOWED_USER_ID (+ optional extras)

bash bin/ctl.sh start  # dashboard + sub-agents + Telegram bridge + heartbeat + scheduler
bash bin/ctl.sh status
```

Message your bot on Telegram; open **http://127.0.0.1:3420**. Always-on: see
`launchd/com.codexassistant.plist.template`.

## Layout

```
db/schema.sql            data model (memory FTS5, kanban, inter-agent, approvals, audit, ...)
lib/{db,memory,obsidian,channels,voice,vault}.sh   helpers
bin/agent.sh             generic Codex agent runtime (inter-agent)
bin/telegram-bridge.sh   operator <-> main (text + voice), surfaces sub-agent replies
bin/heartbeat.sh         proactive checks -> notify()
bin/scheduler.sh         dream engine (nightly), briefing (07:30), kanban audit (4h)
bin/dream.sh briefing.sh kanban-audit.sh kanban-breakdown.sh
bin/dashboard.py         web dashboard + JSON API + PWA + federation endpoints
bin/vault.sh federate.sh ctl.sh   CLIs
config/agents.json       agent registry     config/peers.json   federated peers
```

## Configure

All optional keys are documented in `.env.example`. Highlights:

| key | meaning |
|---|---|
| `TELEGRAM_TOKEN`, `ALLOWED_USER_ID` | the bot + the only user it serves |
| `CONTEXT_TURNS` | memory window per reply (default 12) |
| `OBSIDIAN_VAULT` | vault folder (default `store/vault`) |
| `SLACK_WEBHOOK`, `DISCORD_WEBHOOK` | extra outbound notification channels |
| `VOICE_REPLY`, `WHISPER_MODEL`, `WHISPER_LANG` | voice behavior |
| `DREAM_TIME`, `BRIEFING_TIME`, `HEARTBEAT_INTERVAL`, `DASHBOARD_PORT` | timing |
| `FEDERATION_NAME`, `FEDERATION_TOKEN` | federation identity + shared secret |

- **Agents:** `config/agents.json` (re-run `bin/scaffold.sh` after edits); each
  agent's persona is `agents/<name>/AGENTS.md`.
- **Secrets:** `bin/vault.sh set ID VALUE`, then use `vault:ID` in configs.

## Security

- `.env`, `config/agents.json`, `config/peers.json`, `store/` (DB, secrets, key,
  vault) are **git-ignored** — nothing secret is committed.
- Only `ALLOWED_USER_ID` drives the bot; the dashboard binds to **127.0.0.1**;
  federation requires a shared token.
- Codex runs sandboxed per `~/.codex/config.toml` (`read-only` /
  `workspace-write` / `danger-full-access`).

## License

MIT.
