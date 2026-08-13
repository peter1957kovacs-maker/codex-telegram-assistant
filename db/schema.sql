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

-- Full-text search over memory (SQLite FTS5, no external dependency).
-- Kept in sync with `memories` via triggers.
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
  content, keywords, content='memories', content_rowid='id'
);
CREATE TRIGGER IF NOT EXISTS mem_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid, content, keywords) VALUES (new.id, new.content, new.keywords);
END;
CREATE TRIGGER IF NOT EXISTS mem_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, content, keywords) VALUES('delete', old.id, old.content, old.keywords);
END;
CREATE TRIGGER IF NOT EXISTS mem_au AFTER UPDATE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, content, keywords) VALUES('delete', old.id, old.content, old.keywords);
  INSERT INTO memories_fts(rowid, content, keywords) VALUES (new.id, new.content, new.keywords);
END;

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
  parent_id   INTEGER,                 -- subtask nesting (NULL = top-level)
  stuck       INTEGER DEFAULT 0,       -- flagged by kanban-audit when in_progress too long
  archived_at INTEGER,                 -- set by kanban-audit for old done cards (NULL = active)
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

-- Approvals: an agent requests operator sign-off before a risky action.
CREATE TABLE IF NOT EXISTS approvals (
  id          INTEGER PRIMARY KEY,
  agent_id    TEXT,
  action      TEXT NOT NULL,
  status      TEXT DEFAULT 'pending' CHECK(status IN ('pending','approved','denied')),
  created_at  INTEGER DEFAULT (strftime('%s','now')),
  resolved_at INTEGER
);

-- Audit log: every state-changing action, for traceability.
CREATE TABLE IF NOT EXISTS audit_log (
  id          INTEGER PRIMARY KEY,
  who         TEXT,      -- 'dashboard' | agent name
  action      TEXT,
  detail      TEXT,
  created_at  INTEGER DEFAULT (strftime('%s','now'))
);
