#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
export FIXTURE PORTAL_STATE_DIR="$FIXTURE/runtime" PORTAL_METRICS_DIR="$FIXTURE/state"
mkdir -m 700 "$PORTAL_STATE_DIR" "$PORTAL_METRICS_DIR"
source "$ROOT/scripts/tunnels.sh"
provider_bin() { printf /usr/bin/true; }
proc() { [[ $1 == check ]]; }
kill() { printf 'forbidden\n' >> "$FIXTURE/signals"; return 99; }
state() { [[ $1 == launch-tracked ]] && printf '999998 1'; }
write_own() {
  [[ $MODE != final || $1 != *.dns ]] || : > "$FIXTURE/changed"
  return 0
}
clear_share() { printf 'cleared\n' >> "$FIXTURE/cleanup"; }
stop_line() {
  printf '%s\n' "$1" >> "$FIXTURE/stopped"
  [[ $MODE != cleanup-failed ]]
}
ss() {
  if [[ -e $FIXTURE/changed ]]; then
    case $MODE in
      socket-failed) return 2 ;;
      absent) return 0 ;;
      *) printf 'LISTEN 0 128 127.0.0.1:4488 0.0.0.0:* users:(("replacement",pid=999997,fd=3))\n'; return ;;
    esac
  fi
  printf 'LISTEN 0 128 127.0.0.1:4488 0.0.0.0:* users:(("approved",pid=999999,fd=3))\n'
}
sleep() {
  case $MODE:$1 in
    url:0.5|absent:0.5|socket-failed:0.5|cleanup-failed:0.5|dns-wait:3|dns-retry:2)
      : > "$FIXTURE/changed" ;;
  esac
}
cloudflared_url_from_log() { printf https://fixture-example.trycloudflare.com; }
dns_published() {
  [[ $MODE != dns-published ]] || : > "$FIXTURE/changed"
  [[ $MODE != dns-retry && $MODE != pending && $MODE != final ]]
}
dns_resolves_here() {
  [[ $MODE != dns-resolved ]] || : > "$FIXTURE/changed"
  return 0
}
finish_start() { printf '{"ok":true}\n'; }
for MODE in url absent socket-failed dns-wait dns-retry dns-published dns-resolved final cleanup-failed ready pending; do
  rm -f "$FIXTURE/changed" "$FIXTURE/stopped" "$FIXTURE/cleanup"
  result=$(cmd_start cloudflared 4488 --target 999999 1)
  [[ ! -e $FIXTURE/signals ]]
  if [[ $MODE == ready || $MODE == pending ]]; then
    jq -e '.ok == true' <<<"$result" >/dev/null
    [[ ! -e $FIXTURE/stopped ]]
  else
    jq -e '.ok == false' <<<"$result" >/dev/null
    [[ $(cat "$FIXTURE/stopped") == '999998 1' ]]
    if [[ $MODE == cleanup-failed ]]; then
      jq -e '.error | contains("ownership records were kept")' <<<"$result" >/dev/null
      [[ $(wc -l < "$FIXTURE/cleanup") == 1 ]]
    else
      [[ $(wc -l < "$FIXTURE/cleanup") == 2 ]]
    fi
  fi
  printf 'PASS public start revalidation %s\n' "$MODE"
done
