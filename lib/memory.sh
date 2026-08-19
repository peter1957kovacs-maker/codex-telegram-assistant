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

# --- prompt budget ---------------------------------------------------------
# Codex has a smaller working context than a Claude Code session, and the prompt
# is rebuilt from scratch on every call: memory window + the whole (possibly
# batched) new turn. Bound it explicitly. Priority: the NEW messages always
# survive, the OLD turns are what gets dropped.
PROMPT_MAX_CHARS="${PROMPT_MAX_CHARS:-40000}"   # ~10-12k tokens, deliberate margin

fit_window() { # agent max_turns reserved_chars -> largest window that still fits
  local a="$1" maxt="$2" reserved="$3" budget t w
  budget=$((PROMPT_MAX_CHARS - reserved))
  [ "$budget" -lt 500 ] && budget=500
  for t in "$maxt" 12 8 6 4 2 1; do
    [ "$t" -gt "$maxt" ] && continue
    w="$(chat_window "$a" "$t")"
    if [ ${#w} -le "$budget" ]; then
      # log to STDERR: this function's stdout IS the window, so a log line on
      # stdout would land inside the prompt and vanish from the log.
      [ "$t" -lt "$maxt" ] && echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [memory] window trimmed to $t turns (${#w} chars)" >&2
      printf '%s' "$w"
      return 0
    fi
  done
  w="$(chat_window "$a" 1)"
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [memory] last turn (${#w} chars) over budget, keeping its last $budget chars" >&2
  # Tell the MODEL too, not just the log: a silently cut beginning makes the
  # answer confidently wrong about what it was given.
  printf '%s' "[... a beszelgetes eleje nem fert be a Codex ablakaba, csak az utolso $budget karakter latszik; ha a korabbi resz kell, kerd el kulon ...]
${w: -$budget}"
}

# Cap a merged batch: keep the head and the tail, and SAY that the middle is
# missing, so the model does not answer as if it had read everything.
cap_batch() { # <text> -> possibly truncated text
  local txt="$1" cap half
  cap=$((PROMPT_MAX_CHARS * 2 / 3))
  [ ${#txt} -le "$cap" ] && { printf '%s' "$txt"; return 0; }
  half=$((cap / 2))
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [memory] batch too long (${#txt} chars), keeping first+last $half" >&2
  printf '%s' "${txt:0:$half}

[... a kozeprol ${#txt} karakterbol $((${#txt} - cap)) kimaradt, mert nem fert a Codex ablakaba; ha kell, kerd el kulon ...]

${txt: -$half}"
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
