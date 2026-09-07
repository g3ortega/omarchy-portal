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
  printf '%s|%s\n' "$1" "$2" >> "$FIXTURE/stopped"
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
cat_own() { cat -- "$1"; }
alive_line() { return 1; }
dns_published() {
  [[ $MODE != dns-published ]] || : > "$FIXTURE/changed"
  [[ $MODE != dns-retry && $MODE != pending && $MODE != final ]]
}
dns_resolves_here() {
  [[ $MODE != dns-resolved ]] || : > "$FIXTURE/changed"
  return 0
}
finish_start() { printf '{"ok":true}\n'; }
for provider in cloudflared ngrok; do
  for MODE in url absent socket-failed dns-wait dns-retry dns-published dns-resolved final cleanup-failed provider-exit ready pending; do
    rm -f "$FIXTURE/changed" "$FIXTURE/stopped" "$FIXTURE/cleanup"
    log=$(logfile "$provider" 4488)
    if [[ $MODE == provider-exit ]]; then
      printf 'authentication failed\n' > "$log"
    elif [[ $provider == cloudflared ]]; then
      printf 'https://fixture-example.trycloudflare.com\n' > "$log"
    else
      printf '{"url":"https://fixture-example.ngrok.app"}\n' > "$log"
    fi
    result=$(cmd_start "$provider" 4488 --target 999999 1)
    [[ ! -e $FIXTURE/signals ]]
    if [[ $MODE == ready || $MODE == pending ]]; then
      jq -e '.ok == true' <<<"$result" >/dev/null
      [[ ! -e $FIXTURE/stopped ]]
    else
      jq -e '.ok == false' <<<"$result" >/dev/null
      [[ $(cat "$FIXTURE/stopped") == "999998 1|$provider" ]]
      if [[ $MODE == cleanup-failed ]]; then
        jq -e '.error | contains("ownership records were kept")' <<<"$result" >/dev/null
        [[ $(wc -l < "$FIXTURE/cleanup") == 1 ]]
      else
        [[ $(wc -l < "$FIXTURE/cleanup") == 2 ]]
      fi
      if [[ $MODE == provider-exit ]]; then
        jq -e '.error | contains("authentication failed")' <<<"$result" >/dev/null
      fi
    fi
    printf 'PASS %s public start revalidation %s\n' "$provider" "$MODE"
  done
done
