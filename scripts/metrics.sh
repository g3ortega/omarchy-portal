#!/bin/bash
# Watched ports and retained metrics live outside the plugin directory.
set -o pipefail
umask 077   # samples and the watched set are the user's alone
METRICS_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/metrics.sh"
# shellcheck source=lib/files.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/files.sh"

STATE_DIR="$PORTAL_STATE_HOME"
METRICS_DIR="$STATE_DIR/metrics"
WATCHED="$STATE_DIR/watched.json"

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }

case "${1:-}" in
  append-batch)
    printf '%s' "${2:-}" | state metrics "$METRICS_DIR" append "${3:-}" 2>/dev/null || die "could not append metrics"
    exit
    ;;
  query|stats)
    action=$1
    shift
    state metrics "$METRICS_DIR" "$action" "$@" 2>/dev/null || die "could not query metrics"
    exit
    ;;
esac

case "${1:-}" in
  watch|unwatch)
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
    fi
    current=$(read_watched) || die "could not verify the watched-port set"
    printf '{"ok":true,"ports":%s}\n' "$current"
    ;;
  *) echo '{"ok":false,"error":"usage: metrics.sh watched|watch <port>|unwatch <port>|append-batch <json-map>|query <port> <seconds> <end> [buckets]|stats"}' ;;
esac
