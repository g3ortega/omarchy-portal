#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
export FIXTURE PORTAL_STATE_DIR="$FIXTURE/runtime" PORTAL_METRICS_DIR="$FIXTURE/metrics" HOME="$FIXTURE/home"
mkdir -m 700 -p "$PORTAL_STATE_DIR" "$HOME"
source "$ROOT/scripts/tunnels.sh" >/dev/null
(
  proc() { printf 'proc %s\n' "$*" >> "$FIXTURE/signals"; return 1; }
  kill() { printf 'kill %s\n' "$*" >> "$FIXTURE/signals"; return 1; }
  alive_line() { return 0; }
  group_alive() { return 0; }
  STOP_TERM_WAIT=0; STOP_KILL_WAIT=0
  for identity in '1 1' '0 0' '-1 1' '' '999999999999999999999 1' '2 nope'; do
    if stop_line "$identity" cloudflared; then exit 1; fi
  done
  ! grep -Eq -- '(^| )-(0|1)( |$)' "$FIXTURE/signals"
  rm -f "$FIXTURE/signals"
)
/usr/bin/python3 -I -S "$ROOT/test/public-start-boundary.test.py"
provider_bin() { printf /usr/bin/true; }
proc() { [[ $1 == check ]]; }
state() {
  if [[ $1 == launch-tracked ]]; then
    echo launch >> "$FIXTURE/launched"
    printf '999999 1'
  else /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; fi
}
cloudflared_url_from_log() { echo https://fixture.trycloudflare.com; }
sleep() { :; }
dns_gate() { return 0; }
finish_start() { echo '{"ok":true}'; }
kill() { echo forbidden >> "$FIXTURE/signals"; return 99; }
for mode in replacement shared unattributed failed; do
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:4488 0.0.0.0:* users:(("node",pid=999999,fd=3))' > "$FIXTURE/sockets"
  cloudflared_argv() {
    case $mode in
      replacement) printf '%s\n' 'LISTEN 0 128 127.0.0.1:4488 0.0.0.0:* users:(("other",pid=999998,fd=4))' > "$FIXTURE/sockets" ;;
      shared) printf '%s\n' 'LISTEN 0 128 127.0.0.1:4488 0.0.0.0:* users:(("other",pid=999998,fd=4))' >> "$FIXTURE/sockets" ;;
      unattributed) printf '%s\n' 'LISTEN 0 128 127.0.0.1:4488 0.0.0.0:*' > "$FIXTURE/sockets" ;;
      failed) : > "$FIXTURE/socket-failed" ;;
    esac
  }
  ss() { [[ ! -e $FIXTURE/socket-failed ]] && cat "$FIXTURE/sockets"; }
  result=$(cmd_start cloudflared 4488 --target 999999 1)
  jq -e '.ok == false' <<<"$result" >/dev/null
  [[ ! -e $FIXTURE/launched && ! -e $FIXTURE/signals ]]
done
echo 'PASS fresh pre-launch ownership rejects replacement, shared, unattributed, and failed snapshots without launch'
stop_line() { printf '%s\n' "$1" >> "$FIXTURE/stops"; return 1; }
for malformed in '1 1' '0 0' '-1 1' '' '999999 nope'; do
  printf '%s' "$malformed" > "$STATE_DIR/cloudflared-4488.pid"
  rc=0
  (cancel_public_start cloudflared 4488 143) || rc=$?
  [[ $rc == 143 && ! -e $FIXTURE/stops && -e $STATE_DIR/cloudflared-4488.pid ]]
done
rm "$STATE_DIR/cloudflared-4488.pid"
printf '999999 1' > "$FIXTURE/foreign"
ln -s "$FIXTURE/foreign" "$STATE_DIR/cloudflared-4488.pid"
rc=0
(cancel_public_start cloudflared 4488 143) || rc=$?
[[ $rc == 143 && ! -e $FIXTURE/stops && -L $STATE_DIR/cloudflared-4488.pid ]]
[[ $(cat "$FIXTURE/foreign") == '999999 1' ]]
rm "$STATE_DIR/cloudflared-4488.pid"

target_owns_port() { return 0; }
cloudflared_argv() { :; }
state() {
  if [[ $1 == launch-tracked ]]; then
    printf '999999 1' | /usr/bin/python3 -I -S "$STATEDIR_PY" write "$STATE_DIR/cloudflared-4488.pid"
    return 1
  else /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; fi
}
result=$(cmd_start cloudflared 4488 --target 999999 1)
jq -e '.ok == false and (.error | contains("records were kept"))' <<<"$result" >/dev/null
[[ $(cat "$FIXTURE/stops") == '999999 1' && $(cat "$STATE_DIR/cloudflared-4488.pid") == '999999 1' ]]
echo 'PASS invalid cancellation records and failed launches retain durable ownership without unsafe cleanup'
