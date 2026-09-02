#!/bin/bash
# Metric retention for watched ports, and the watched-set itself.
#
# Storage: $XDG_STATE_HOME/portal/metrics/<port>.jsonl — one JSON object per
# sample, appended once per scan for each watched port. Raw 5s samples are
# kept for roughly 24h (17280 lines) and trimmed in place past that; history
# beyond a day is not this plugin's job. State lives in XDG_STATE, never in
# the plugin directory (writes there would trigger Omarchy's hot reload).
#
#   watched                     -> {"ok":true,"ports":[...]}
#   watch <port> / unwatch <port>
#   append-batch <json-map>     {"3000":{...},"5173":{...}}, one call per scan
#   read <port>                 -> {"ok":true,"samples":[...]}
#
# Every file goes through scripts/lib/statedir.py: descriptor-relative,
# never through a link, capped, atomic.
set -o pipefail
umask 077   # samples and the watched set are the user's alone
# shellcheck source=lib/files.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/files.sh"

STATE_DIR="${PORTAL_METRICS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/portal}"
METRICS_DIR="$STATE_DIR/metrics"
WATCHED="$STATE_DIR/watched.json"
MAX_LINES=17280
MAX_BYTES=2097152   # a sample file is appended and read through this cap (a day of ~100-byte samples); past it, the newest MAX_LINES are kept

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }
own_dir "$STATE_DIR" && own_dir "$METRICS_DIR" || die "state directory is not a private directory of yours: $STATE_DIR"

valid_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }

read_watched() {
  local raw; raw=$(cat_own "$WATCHED" 65536) || raw=""
  jq -cs '.[0] | if type == "array" then . else [] end' <<<"$raw" 2>/dev/null || echo '[]'
}

case "${1:-}" in
  watched)
    printf '{"ok":true,"ports":%s}\n' "$(read_watched)"
    ;;
  watch|unwatch)
    valid_port "${2:-}" || die "invalid port"
    if [[ $1 == watch ]]; then
      read_watched | jq -c --argjson p "$2" '(. + [$p]) | unique' | state write "$WATCHED" || die "could not save"
    else
      read_watched | jq -c --argjson p "$2" 'map(select(. != $p))' | state write "$WATCHED" || die "could not save"
      state_remove "$METRICS_DIR" "$2.jsonl"
    fi
    printf '{"ok":true,"ports":%s}\n' "$(read_watched)"
    ;;
  append-batch)
    # Only re-serialized canonical JSON ever reaches disk, whatever was in the
    # argument list.
    lines=$(jq -r 'to_entries[] | "\(.key)\t\(.value | tojson)"' <<<"${2:-}" 2>/dev/null) || die "not a JSON object"
    while IFS=$'\t' read -r port line; do
      valid_port "$port" || continue
      printf '%s\n' "$line" | state_append "$METRICS_DIR/$port.jsonl" "$MAX_LINES" "$MAX_BYTES"
    done <<<"$lines"
    echo '{"ok":true}'
    ;;
  read)
    valid_port "${2:-}" || die "invalid port"
    f="$METRICS_DIR/$2.jsonl"
    # A line torn by a crash mid-append must not cost the rest of the file.
    raw=$(cat_own "$f" "$((MAX_BYTES * 2))") || raw=""
    jq -R 'fromjson?' <<<"$raw" | jq -sc '{ok:true, samples: .}' || echo '{"ok":true,"samples":[]}'
    ;;
  *) echo '{"ok":false,"error":"usage: metrics.sh watched|watch <port>|unwatch <port>|append-batch <json-map>|read <port>"}' ;;
esac
