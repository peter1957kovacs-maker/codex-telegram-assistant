# Codex Assistant — a Marveen-style AI system on your ChatGPT subscription

> **Épült a [Marveen](https://github.com/Szotasz/marveen) rendszerre, amelyet [Szotasz](https://github.com/Szotasz) készített. · Built on [Marveen](https://github.com/Szotasz/marveen) by [Szotasz](https://github.com/Szotasz).**

## Magyar

Egy több-ügynökös, **Telegram-alapú** személyi asszisztens rendszer, amit az
**OpenAI Codex CLI** (a ChatGPT-előfizetésed) hajt. A [Marveen](https://github.com/Szotasz/marveen)
rendszer felépítését követi — réteges memória, kanban, proaktív heartbeat, több
együttműködő ügynök, web dashboard, Obsidian jegyzetek, hang és több —, de
**Codexen fut Claude Code helyett**, **per-token API-költség nélkül**. Mivel
minden üzenet egy friss hívás, korlátozott memória-ablakkal, **sosem lassul be
vagy fagy le** úgy, mint a böngészős ChatGPT egy hosszú beszélgetésben.

## English

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
- **Images** — send a photo on Telegram and the model actually sees it
  (`codex exec -i`); images also travel between agents as paths. See *Images* below.
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
lib/{db,memory,codex,obsidian,channels,voice,vault}.sh   helpers (codex.sh = model resolution)
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
| `CODEX_MODEL` | ad-hoc model override for all agents (per-agent: see below) |
| `OBSIDIAN_VAULT` | vault folder (default `store/vault`) |
| `SLACK_WEBHOOK`, `DISCORD_WEBHOOK` | extra outbound notification channels |
| `VOICE_REPLY`, `WHISPER_MODEL`, `WHISPER_LANG` | voice behavior |
| `DREAM_TIME`, `BRIEFING_TIME`, `HEARTBEAT_INTERVAL`, `DASHBOARD_PORT` | timing |
| `FEDERATION_NAME`, `FEDERATION_TOKEN` | federation identity + shared secret |

- **Agents:** `config/agents.json` (re-run `bin/scaffold.sh` after edits); each
  agent's persona is `agents/<name>/AGENTS.md`.
- **Durable / cross-agent knowledge → `AGENTS.md`.** What an agent must always
  know — its role, rules, and **which other agents it collaborates with** — goes
  in its `AGENTS.md` (loaded every call), not just the rolling conversation
  window. Shared facts across agents can also go in the `shared` memory tier.
- **Secrets:** `bin/vault.sh set ID VALUE`, then use `vault:ID` in configs.

## Modellválasztás · Model selection

**Magyar.** Minden ügynök saját modellen futhat, és a modell **egyetlen helyen**
él: `agents/<név>/.model`. Ezt a `config/agents.json` `"model"` mezőjéből írja ki
a scaffold, vagy közvetlenül állítod:

```bash
bin/ctl.sh model                          # melyik ügynök melyik modellen fut
bin/ctl.sh model <ügynök> <modell>        # átállítás (+ az ügynök újraindítása)
bin/ctl.sh model <ügynök> default         # vissza a Codex alapértelmezettre
```

Minden `codex exec` hívás (fő híd, sub-agentek, dream engine, heartbeat, kanban
felbontás) innen veszi a modellt, `-m` flagként. Ha a modell több helyre lenne
bemásolva, egy váltás több szerkesztés lenne, amelyek szétcsúsznak: az ügynök
papíron az egyik modellen "fut", valójában a másikon. `CODEX_MODEL` a `.env`-ben
mindet felülírja (eseti használatra).

**English.** Each agent can run on its own model, kept in **one place**:
`agents/<name>/.model` (from the `"model"` field in `config/agents.json`, or via
`bin/ctl.sh model <agent> <model|default>`, which also restarts that agent). Every
`codex exec` call site — bridge, sub-agents, dream engine, heartbeat, kanban
breakdown — reads it and passes `-m`. `CODEX_MODEL` in `.env` overrides all of
them ad hoc. One source of truth means a model switch can't half-apply.

## Ki kap választ · Who gets a reply

**Magyar.** Az ügynök csak **regisztrált ügynöknek** válaszol vissza az
inter-agent soron. Cron-jobok, scriptek, külső feederek is írhatnak a sorba;
azoknak válaszolni felesleges (senki nem olvassa) és a runtime-ok között pattoghat.
A feladat így is lefut, csak a válasz marad el, és a napló megmondja miért.

**English.** An agent replies only to **registered agents** (a row in the `agents`
table). Cron jobs, scripts and external feeders can also write to the queue;
answering those posts a message nobody reads and can bounce between runtimes. The
work still runs — only the reply is skipped, and the log says why.

## Batching · Több üzenet, egy válasz

One thought usually arrives as several Telegram messages (typing in bursts,
forwarding a run of related messages). Answering each separately gives
disconnected replies that miss the whole, so the bridge batches:

- after the first message it long-polls with a short timeout; Telegram returns as
  soon as a message arrives, so an empty response IS the "operator went quiet"
  signal;
- every new message restarts the window (`DEBOUNCE_SECS`, default 8);
- the parts are merged into ONE numbered user turn (`[1] … [2] …`) with a line
  saying they arrived separately but belong together — otherwise the model tends
  to answer only the last fragment;
- every image in the batch is attached to that single call (`-i` per image), and
  if any part was a voice message the voice-reply path still applies;
- `BATCH_MAX` (default 25) caps a flood.

One `codex exec`, one reply per batch. Approval commands (`approve 12`) are still
executed immediately and never join a batch.

Note for hackers: `poll_updates` runs inside `$(...)`, i.e. a subshell, so
anything it assigns is lost. Per-call state belongs in a file; the offset and the
batch buffers are mutated by `collect`, which is called directly.

## Images · Képek

Send a photo on Telegram and `main` sees it: the bridge downloads the bytes and
attaches them with `codex exec -i <FILE>`. Two non-obvious things make this work.

1. **A Telegram photo has no `text` field.** It carries `photo[]` plus an optional
   `caption`. A bridge that reads only `message.text` gets an empty string and
   drops the update — before it logs anything, so the failure is completely silent
   and looks like "the model ignores images". The bridge now reads `caption`, takes
   the **largest** `photo[]` size (or an `image/*` `document`, which is Telegram's
   "send as file" at full quality), downloads via `getFile` into
   `agents/<name>/inbox/`, and passes the path to `-i`. A caption-less photo still
   works: it gets a default instruction ("describe what you see").
2. **Inter-agent messages are text only**, so an image travels between agents as a
   **path**. `bin/agent.sh` scans each message for absolute paths to existing image
   files and attaches them with `-i` — otherwise the receiving agent only sees a
   file name and will confidently answer about an image it never got.

A `file_id` is worthless to the model: Codex reads images from disk, so the bytes
must land there first. Verified end to end on both paths.

Bash note (macOS bash 3.2 + `set -u`): expand optional arg arrays as
`${IMG_ARGS[@]+"${IMG_ARGS[@]}"}`, never `"${IMG_ARGS[@]}"` — the latter aborts the
script whenever there is no image.

## Security

- `.env`, `config/agents.json`, `config/peers.json`, `store/` (DB, secrets, key,
  vault) are **git-ignored** — nothing secret is committed.
- Only `ALLOWED_USER_ID` drives the bot; the dashboard binds to **127.0.0.1**;
  federation requires a shared token.
- Codex runs sandboxed per `~/.codex/config.toml` (`read-only` /
  `workspace-write` / `danger-full-access`).

## Köszönet · Credits

**Magyar.** Ez a projekt a [**Marveen**](https://github.com/Szotasz/marveen)
rendszerre épül, amelyet [**Szotasz**](https://github.com/Szotasz) készített. A
Marveen ("AI csapatod, ami fut amíg te alszol") egy kiváló, átgondolt,
mérnökileg igényes multi-agent AI-keretrendszer — az egész ötlet és architektúra,
amire ez a munka támaszkodik, az ő érdeme. Hálás köszönet Szotasznak a Marveenért
és azért, hogy nyíltan megosztja. Nézd meg a munkáit:

- Marveen: <https://github.com/Szotasz/marveen>
- Marveen Marketplace: <https://github.com/Szotasz/marveen-marketplace>
- Szotasz GitHub: <https://github.com/Szotasz>

**English.** This project builds on [**Marveen**](https://github.com/Szotasz/marveen)
by [**Szotasz**](https://github.com/Szotasz). Marveen ("your AI team that runs
while you sleep") is an excellent, thoughtfully engineered multi-agent AI
framework — the whole idea and architecture this work rests on is theirs. Huge
thanks to Szotasz for Marveen and for sharing it openly. Check out their work at
the links above.

## License

MIT.
