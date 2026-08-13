#!/usr/bin/env bash
# Codex invocation helpers. Source AFTER lib/db.sh.
#
# Model selection has ONE source of truth per agent:
#   1. CODEX_MODEL env (ad-hoc override, e.g. for a single run)
#   2. agents/<name>/.model file  (written by scaffold.sh from config/agents.json,
#      or by `bin/ctl.sh model <agent> <model>`)
#   3. Codex default (no -m flag)
#
# Keeping it in a file rather than baking it into every launcher/service means a
# model switch is one edit instead of several that silently drift apart -- an
# agent that "runs on" a model it does not actually use is a nasty bug to spot.

# codex_model_args <agent-name>  -> prints "-m\n<model>" (or nothing)
codex_model_args() {
  local agent="${1:-}" m="${CODEX_MODEL:-}"
  if [ -z "$m" ] && [ -n "$agent" ]; then
    m="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ROOT/agents/$agent/.model" 2>/dev/null | grep -m1 . || true)"
  fi
  [ -n "$m" ] && printf '%s\n%s\n' "-m" "$m"
  return 0
}

# codex_model_show <agent-name>  -> the effective model, human readable
codex_model_show() {
  local out; out="$(codex_model_args "${1:-}" | sed -n '2p')"
  printf '%s' "${out:-(Codex default)}"
}

# Call sites fill their own array (bash 3.2 on macOS has no namerefs):
#   MODEL_ARGS=(); while IFS= read -r a; do MODEL_ARGS+=("$a"); done < <(codex_model_args "$AGENT")
#   "$CODEX" exec ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} ...
