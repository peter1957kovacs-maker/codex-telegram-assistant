#!/usr/bin/env bash
# Tiered memory + kanban + inter-agent + chat helpers. Source AFTER lib/db.sh.

# --- tiered memory ---
mem_save() { # agent category keywords content
  local a c k content ea ek ec
  a="$1"; c="${2:-hot}"; k="$3"; content="$4"
  ea=$(sql_escape "$a"); ek=$(sql_escape "$k"); ec=$(sql_escape "$content")
  dbq "INSERT INTO memories(agent_id,category,keywords,content) VALUES('$ea','$c','$ek','$ec');"
}
mem_recent() { # agent [limit]
  local a="$1" n="${2:-10}"
  dbq "SELECT category||' | '||content FROM memories WHERE agent_id='$(sql_escape "$a")' ORDER BY id DESC LIMIT $n;"
}
mem_search() { # agent term  -- FTS5 ranked, with a LIKE fallback
  local a="$1" ea et rt
  ea=$(sql_escape "$a"); et=$(sql_escape "$2"); rt=$(sql_escape "$2")
  sqlite3 "$DB" "SELECT m.category||' | '||m.content FROM memories_fts f JOIN memories m ON m.id=f.rowid WHERE memories_fts MATCH '$et' AND m.agent_id='$ea' ORDER BY rank LIMIT 20;" 2>/dev/null \
    || dbq "SELECT category||' | '||content FROM memories WHERE agent_id='$ea' AND (content LIKE '%$rt%' OR keywords LIKE '%$rt%') ORDER BY id DESC LIMIT 20;"
}

# --- chat window (bounded conversation memory) ---
chat_save() { # agent role content
  local ec; ec=$(sql_escape "$3")
  dbq "INSERT INTO chat_log(agent_id,role,content) VALUES('$(sql_escape "$1")','$2','$ec');"
}
chat_window() { # agent [turns]
  local a="$1" n="${2:-12}"
  sqlite3 "$DB" -separator ': ' "SELECT role, content FROM (SELECT * FROM chat_log WHERE agent_id='$(sql_escape "$a")' ORDER BY id DESC LIMIT $n) ORDER BY id ASC;"
}

# --- inter-agent messages ---
msg_send() { # from to content
  local ec; ec=$(sql_escape "$3")
  dbq "INSERT INTO agent_messages(from_agent,to_agent,content) VALUES('$(sql_escape "$1")','$(sql_escape "$2")','$ec');"
}
msg_pending() { # agent  -> "id|from" lines
  dbq "SELECT id||'|'||from_agent FROM agent_messages WHERE to_agent='$(sql_escape "$1")' AND status='pending' ORDER BY id;"
}
msg_claim()  { dbq "UPDATE agent_messages SET status='delivered' WHERE id=$1;"; }
msg_done()   { local ec; ec=$(sql_escape "$2"); dbq "UPDATE agent_messages SET status='done', result='$ec', completed_at=strftime('%s','now') WHERE id=$1;"; }
msg_fail()   { local ec; ec=$(sql_escape "$2"); dbq "UPDATE agent_messages SET status='failed', result='$ec', completed_at=strftime('%s','now') WHERE id=$1;"; }

# --- kanban ---
kanban_add() { # title priority agent
  dbq "INSERT INTO kanban(title,priority,agent_id) VALUES('$(sql_escape "$1")','${2:-normal}','$(sql_escape "$3")');"
}
kanban_subtask() { # parent_id title
  dbq "INSERT INTO kanban(title,parent_id) VALUES('$(sql_escape "$2")',$1);"
}
kanban_set()     { dbq "UPDATE kanban SET status='$2', updated_at=strftime('%s','now') WHERE id=$1;"; }
kanban_archive() { dbq "UPDATE kanban SET archived_at=strftime('%s','now') WHERE id=$1;"; }
kanban_stuck()   { dbq "UPDATE kanban SET stuck=$2 WHERE id=$1;"; }

# --- daily log ---
log_add() { local ec; ec=$(sql_escape "$2"); dbq "INSERT INTO daily_log(agent_id,entry) VALUES('$(sql_escape "$1")','$ec');"; }

# --- approvals ---
approval_request() { # agent action  -> prints new id
  local ea ec; ea=$(sql_escape "$1"); ec=$(sql_escape "$2")
  dbq "INSERT INTO approvals(agent_id,action) VALUES('$ea','$ec'); SELECT last_insert_rowid();"
}
approval_resolve() { dbq "UPDATE approvals SET status='$2', resolved_at=strftime('%s','now') WHERE id=$1;"; }  # id approved|denied
approval_status()  { dbq "SELECT status FROM approvals WHERE id=$1;"; }

# --- audit ---
audit() { local ea ec; ea=$(sql_escape "$2"); ec=$(sql_escape "$3"); dbq "INSERT INTO audit_log(who,action,detail) VALUES('$(sql_escape "$1")','$ea','$ec');"; }
