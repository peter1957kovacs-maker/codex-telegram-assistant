#!/usr/bin/env bash
# Federation CLI: talk to another Codex-Assistant instance.
#   bin/federate.sh send  <peer>  <message>   send a message to a configured peer
#   bin/federate.sh hello <url>               probe a peer's capabilities
#   bin/federate.sh peers                     list configured peers
#
# Peers live in config/peers.json: {"peers":[{"name":"bob","url":"http://host:3420","token":"..."}]}
# A message sent to a peer lands in its operator's inbox (as fed:<us>).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
CFG="$ROOT/config/peers.json"; [ -f "$CFG" ] || CFG="$ROOT/config/peers.example.json"
ME="${FEDERATION_NAME:-codex-assistant}"

peer_field() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(next((p.get(sys.argv[3],"") for p in d.get("peers",[]) if p.get("name")==sys.argv[2]),""))' "$CFG" "$1" "$2"; }

case "${1:-}" in
  peers)
    python3 -c 'import json,sys;[print(p["name"],p.get("url","")) for p in json.load(open(sys.argv[1])).get("peers",[])]' "$CFG";;
  hello)
    curl -s "${2:?url}/federation/hello";;
  send)
    peer="${2:?peer}"; msg="${3:?message}"
    url="$(peer_field "$peer" url)"; tok="$(peer_field "$peer" token)"
    [ -n "$url" ] || { echo "unknown peer: $peer"; exit 1; }
    curl -s -X POST "$url/federation/inbox" -H "X-Fed-Token: $tok" \
      --data-urlencode "from=$ME" --data-urlencode "message=$msg"
    echo;;
  *) echo "usage: bin/federate.sh send <peer> <message> | hello <url> | peers"; exit 1;;
esac
