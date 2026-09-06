#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
source "$ROOT/scripts/tunnels.sh"
STATE_DIR=$FIXTURE
kill() { echo 'unexpected signal' >&2; return 99; }
proc() { echo 'unexpected process operation' >&2; return 99; }
stop_reconciled_share() { printf '%s\n' "$*" >> "$FIXTURE/stops"; return "${STOP_RC:-0}"; }

result=$(reconcile_idle cloudflared 3000 3000 2000 0 1000)
[[ -z $result ]]
[[ $(cat "$FIXTURE/cloudflared-3000.idle") == 1000 && ! -e $FIXTURE/stops ]]
reconcile_idle cloudflared 3000 3000 1000 0 1599
[[ ! -e $FIXTURE/stops ]]
if reconcile_idle cloudflared 3000 3000 1000 0 1600; then exit 1; fi
[[ $(wc -l < "$FIXTURE/stops") == 1 ]]
echo 'PASS a backward clock rebases once and expires after the normal grace period'

rm "$FIXTURE/stops"
reconcile_idle cloudflared 3000 3000 0000000000002000 0 1000
[[ $(cat "$FIXTURE/cloudflared-3000.idle") == 1000 ]]
for idle in abc -1 '1+2' 999999999999999999999999 08x; do
  result=$(reconcile_idle cloudflared 3000 3000 "$idle" 0 1000)
  jq -e '.ok == false and (.error | contains("invalid idle deadline"))' <<<"$result" >/dev/null
done
[[ ! -e $FIXTURE/stops ]]
echo 'PASS decimal deadlines are bounded before arithmetic and malformed records stay refused'

(
  write_own() { return 1; }
  if reconcile_idle cloudflared 3000 3000 2000 0 1000; then exit 1; fi
  [[ $(wc -l < "$FIXTURE/stops") == 1 ]]
  STOP_RC=1 RECONCILE_STOP_ERROR='owned stop failed'
  result=$(reconcile_idle cloudflared 3000 3000 2000 0 1000)
  jq -e '.ok == false and .error == "owned stop failed"' <<<"$result" >/dev/null
)
echo 'PASS failed rebasing requests safe stop and surfaces an unconfirmed stop'

reconcile_idle cloudflared 3000 3000 2000 1 1000
[[ ! -e $FIXTURE/cloudflared-3000.idle ]]
echo 'PASS healthy targets clear stale deadlines without rebasing'
