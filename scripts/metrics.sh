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
set -o pipefail
umask 077   # samples and the watched set are the user's alone
METRICS_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/metrics.sh"
# shellcheck source=lib/files.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/files.sh"

STATE_DIR="$PORTAL_STATE_HOME"
METRICS_DIR="$STATE_DIR/metrics"
WATCHED="$STATE_DIR/watched.json"
MAX_LINES=17280     # a day of samples at the default scan
MAX_BYTES=2097152   # append trims to the newest lines that fit under this

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }

case "${1:-}" in
  watch|unwatch|append-batch)
    if [[ ${PORTAL_METRICS_LOCKED:-} != "$STATE_DIR" ]]; then
      own_dir "$STATE_DIR" || die "state directory is not a private directory of yours: $STATE_DIR"
      PORTAL_METRICS_LOCKED="$STATE_DIR" state lock "$STATE_DIR" nowait .metrics.lock -- \
        /usr/bin/bash "$METRICS_SCRIPT" "$@"
      lock_rc=$?
      (( lock_rc == 75 )) && die "another watched-port update is in progress"
      exit "$lock_rc"
    fi
    ;;
esac

own_dir "$STATE_DIR" "$METRICS_DIR" || die "state directory is not a private directory of yours: $STATE_DIR"

read_watched() {
  local raw
  if [[ ! -e $WATCHED && ! -L $WATCHED ]]; then echo '[]'; return 0; fi
  raw=$(cat_own "$WATCHED" 65536) || return 1
  jq -cs '.[0] | if type == "array" then . else [] end' <<<"$raw" 2>/dev/null || echo '[]'
}

case "${1:-}" in
  watched)
    current=$(read_watched) || die "could not read the watched-port set safely"
    printf '{"ok":true,"ports":%s}\n' "$current"
    ;;
  watch|unwatch)
    valid_port "${2:-}" || die "invalid port"
    current=$(read_watched) || die "could not read the watched-port set safely"
    if [[ $1 == watch ]]; then
      jq -c --argjson p "$2" '(. + [$p]) | unique' <<<"$current" | state write "$WATCHED" || die "could not save"
    else
      jq -c --argjson p "$2" 'map(select(. != $p))' <<<"$current" | state write "$WATCHED" || die "could not save"
      state_remove "$METRICS_DIR" "$2.jsonl" || die "could not remove metrics for port $2"
    fi
    current=$(read_watched) || die "could not verify the watched-port set"
    printf '{"ok":true,"ports":%s}\n' "$current"
    ;;
  append-batch)
    # Only re-serialized canonical JSON ever reaches disk, whatever was in the
    # argument list; one helper process appends every port's line.
    jq -e 'type == "object"' <<<"${2:-}" >/dev/null 2>&1 || die "not a JSON object"
    jq -r 'to_entries[] | select(.key | test("^[0-9]{1,5}$")) | (.key | tonumber) as $p
           | select($p > 0 and $p < 65536) | "\(.key).jsonl\t\(.value | tojson)"' <<<"${2:-}" 2>/dev/null \
      | state append-many "$METRICS_DIR" "$MAX_LINES" "$MAX_BYTES" 2>/dev/null || die "could not append metrics"
    echo '{"ok":true}'
    ;;
  read)
    valid_port "${2:-}" || die "invalid port"
    f="$METRICS_DIR/$2.jsonl"
    # A line torn by a crash mid-append must not cost the rest of the file.
    raw=$(cat_own "$f" "$MAX_BYTES")
    jq -R 'fromjson?' <<<"$raw" | jq -sc '{ok:true, samples: .}' || echo '{"ok":true,"samples":[]}'
    ;;
  *) echo '{"ok":false,"error":"usage: metrics.sh watched|watch <port>|unwatch <port>|append-batch <json-map>|read <port>"}' ;;
esac
