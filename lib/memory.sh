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
mem_search() { # agent term
  local a="$1" t; t=$(sql_escape "$2")
  dbq "SELECT category||' | '||content FROM memories WHERE agent_id='$(sql_escape "$a")' AND (content LIKE '%$t%' OR keywords LIKE '%$t%') ORDER BY id DESC LIMIT 20;"
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
kanban_set() { dbq "UPDATE kanban SET status='$2', updated_at=strftime('%s','now') WHERE id=$1;"; }

# --- daily log ---
log_add() { local ec; ec=$(sql_escape "$2"); dbq "INSERT INTO daily_log(agent_id,entry) VALUES('$(sql_escape "$1")','$ec');"; }
