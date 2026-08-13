#!/usr/bin/env bash
# Encrypted secret vault. Secrets are AES-256-CBC (PBKDF2) encrypted at rest in
# store/secrets/<id>.enc, keyed by a random master passphrase kept in the macOS
# Keychain (or a chmod-600 key file fallback on Linux). Reference a secret in
# any config/.env value as  vault:ID  and resolve it with vault_resolve.
# Needs: openssl. Source AFTER lib/db.sh (needs $ROOT).

SECRETS_DIR="${SECRETS_DIR:-$ROOT/store/secrets}"
VAULT_SERVICE="codex-vault"

vault_master() {
  local key
  if command -v security >/dev/null 2>&1; then          # macOS Keychain
    key="$(security find-generic-password -s "$VAULT_SERVICE" -w 2>/dev/null || true)"
    if [ -z "$key" ]; then
      key="$(head -c 32 /dev/urandom | base64)"
      security add-generic-password -s "$VAULT_SERVICE" -a "${USER:-codex}" -w "$key" -U >/dev/null 2>&1
    fi
    printf '%s' "$key"; return
  fi
  local kf="$ROOT/store/.vaultkey"                        # file fallback
  if [ ! -f "$kf" ]; then umask 077; head -c 32 /dev/urandom | base64 > "$kf"; chmod 600 "$kf"; fi
  cat "$kf"
}

vault_set() { # id value
  command -v openssl >/dev/null 2>&1 || { echo "openssl required"; return 1; }
  mkdir -p "$SECRETS_DIR"; local m; m="$(vault_master)"
  printf '%s' "$2" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "pass:$m" -base64 > "$SECRETS_DIR/$1.enc" 2>/dev/null \
    && echo "stored secret: $1"
}
vault_get() { # id -> plaintext on stdout
  local m f; m="$(vault_master)"; f="$SECRETS_DIR/$1.enc"; [ -f "$f" ] || return 1
  openssl enc -d -aes-256-cbc -pbkdf2 -salt -pass "pass:$m" -base64 -in "$f" 2>/dev/null
}
vault_resolve() { # value -> decrypt if "vault:ID", else echo unchanged
  case "$1" in vault:*) vault_get "${1#vault:}";; *) printf '%s' "$1";; esac
}
vault_list() { ls -1 "$SECRETS_DIR"/*.enc 2>/dev/null | sed 's#.*/##; s/\.enc$//'; }
