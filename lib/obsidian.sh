#!/usr/bin/env bash
# Obsidian vault helpers. A "vault" is just a folder of markdown notes, so this
# works with a dedicated store/vault or an existing Obsidian vault (set
# OBSIDIAN_VAULT). Short facts -> SQLite memory; longer docs/notes -> the vault.
# Source AFTER lib/db.sh (needs $ROOT).

VAULT="${OBSIDIAN_VAULT:-$ROOT/store/vault}"

vault_init() { mkdir -p "$VAULT"; }
_note_path() { printf '%s/%s.md' "$VAULT" "$(printf '%s' "$1" | tr '/:' '--')"; }

note_write()  { vault_init; printf '%s\n' "$2" >  "$(_note_path "$1")"; }   # title content
note_append() { vault_init; printf '%s\n' "$2" >> "$(_note_path "$1")"; }   # title content
note_read()   { cat "$(_note_path "$1")" 2>/dev/null; }                     # title
note_list()   { ls -1 "$VAULT"/*.md 2>/dev/null | sed 's#.*/##; s/\.md$//'; }
note_search() { grep -rli "$1" "$VAULT"/*.md 2>/dev/null | sed 's#.*/##; s/\.md$//'; }  # term
