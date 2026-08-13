-- Codex-Marveen data layer (SQLite).
-- Mirrors the Marveen system's building blocks: tiered memory, a kanban board,
-- inter-agent messaging, per-agent chat memory, and a daily log.

PRAGMA journal_mode = WAL;

-- Registered agents (each backed by the Codex CLI / ChatGPT subscription).
CREATE TABLE IF NOT EXISTS agents (
  name        TEXT PRIMARY KEY,
  role        TEXT,
  enabled     INTEGER DEFAULT 1,
  created_at  INTEGER DEFAULT (strftime('%s','now'))
);

-- Tiered long-term memory.
--   hot    = active task / decision happening now
--   warm   = stable config / preference / project context
--   cold   = long-term lesson / historical decision / archive
--   shared = relevant to other agents too
CREATE TABLE IF NOT EXISTS memories (
  id          INTEGER PRIMARY KEY,
  agent_id    TEXT,
  content     TEXT NOT NULL,
  category    TEXT NOT NULL DEFAULT 'hot' CHECK(category IN ('hot','warm','cold','shared')),
  keywords    TEXT,
  created_at  INTEGER DEFAULT (strftime('%s','now')),
  updated_at  INTEGER DEFAULT (strftime('%s','now'))
);
CREATE INDEX IF NOT EXISTS idx_mem_agent ON memories(agent_id);
CREATE INDEX IF NOT EXISTS idx_mem_cat   ON memories(category);

-- Inter-agent messages (delivered by the runtime poller).
CREATE TABLE IF NOT EXISTS agent_messages (
  id           INTEGER PRIMARY KEY,
  from_agent   TEXT,
  to_agent     TEXT,
  content      TEXT,
  status       TEXT DEFAULT 'pending' CHECK(status IN ('pending','delivered','done','failed')),
  result       TEXT,
  created_at   INTEGER DEFAULT (strftime('%s','now')),
  completed_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_msg_to ON agent_messages(to_agent, status);

-- Kanban board.
CREATE TABLE IF NOT EXISTS kanban (
  id          INTEGER PRIMARY KEY,
  title       TEXT NOT NULL,
  description TEXT,
  status      TEXT DEFAULT 'planned'  CHECK(status IN ('planned','in_progress','waiting','done')),
  priority    TEXT DEFAULT 'normal'   CHECK(priority IN ('low','normal','high','urgent')),
  agent_id    TEXT,
  created_at  INTEGER DEFAULT (strftime('%s','now')),
  updated_at  INTEGER DEFAULT (strftime('%s','now'))
);

-- Per-agent rolling chat memory (the bounded conversation window).
CREATE TABLE IF NOT EXISTS chat_log (
  id        INTEGER PRIMARY KEY,
  agent_id  TEXT,
  role      TEXT,       -- 'user' | 'assistant'
  content   TEXT,
  ts        INTEGER DEFAULT (strftime('%s','now'))
);
CREATE INDEX IF NOT EXISTS idx_chat_agent ON chat_log(agent_id, id);

-- Daily log (automatic summary material).
CREATE TABLE IF NOT EXISTS daily_log (
  id          INTEGER PRIMARY KEY,
  agent_id    TEXT,
  entry       TEXT,
  created_at  INTEGER DEFAULT (strftime('%s','now'))
);
