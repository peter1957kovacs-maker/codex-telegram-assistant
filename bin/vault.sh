#!/usr/bin/env bash
# Operator CLI for the secret vault.
#   bin/vault.sh set <id> <value>   store an encrypted secret
#   bin/vault.sh get <id>           print the decrypted secret
#   bin/vault.sh list               list secret ids
# Then reference it anywhere as  vault:<id>  (resolved by the runtime).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/db.sh"; . "$ROOT/lib/vault.sh"

case "${1:-}" in
  set)  vault_set "${2:?id}" "${3:?value}";;
  get)  vault_get "${2:?id}" || { echo "no such secret"; exit 1; };;
  list) vault_list;;
  *) echo "usage: bin/vault.sh set <id> <value> | get <id> | list"; exit 1;;
esac
