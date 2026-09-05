#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export PORTAL_STATE_DIR="$T/runtime"
mkdir "$PORTAL_STATE_DIR"

set -- noop
source "$ROOT/scripts/lifecycle.sh" >/dev/null
kill() { printf 'kill %s\n' "$*" >> "$T/signals"; return 1; }
proc() { printf 'proc %s\n' "$*" >> "$T/signals"; return 1; }

for ((i = 0; i < 512; i++)); do
  printf '' > "$PORTAL_RUNTIME_DIR/leaf-$i"
done
printf '999999 1' > "$PORTAL_RUNTIME_DIR/.restart-3000.pid"
identity=$(read_restart_identity .restart-3000.pid)
[[ $identity == '999999 1' ]] || { echo 'FAIL restart identity in a 513-entry runtime directory'; exit 1; }
echo 'ok restart identity in a 513-entry runtime directory'

printf '999999 1' > "$T/other-record"
rm -- "$PORTAL_RUNTIME_DIR/.restart-3000.pid"
ln -s "$T/other-record" "$PORTAL_RUNTIME_DIR/.restart-3000.pid"
rc=0
identity=$(read_restart_identity .restart-3000.pid) || rc=$?
[[ $rc == 2 && -z $identity ]] || { echo 'FAIL symlink restart identity was not refused'; exit 1; }
[[ ! -e $T/signals ]] || { echo 'FAIL identity lookup attempted process operations'; exit 1; }
echo 'ok symlink restart identity refused without process operations'
