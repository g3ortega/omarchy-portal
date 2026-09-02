#!/bin/bash
# Reverse everything Portal put on this machine, in the order the panel would:
# stop every share and name it created, drop the Portless CA from the browser
# stores it was imported into, delete the cloudflared binary only if Portal
# installed it, and remove Portal's own state. Portless itself (an npm
# package the user installed) and its own state are left alone and named.
#
#   uninstall.sh          do it
#   uninstall.sh --dry    say what would happen
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/files.sh
source "$HERE/lib/files.sh"
DRY=0; [[ ${1:-} == --dry ]] && DRY=1
run() { if (( DRY )); then echo "would: $*"; else "$@"; fi; }

STATE="${PORTAL_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/portal}"
METRICS="${PORTAL_METRICS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/portal}"
NICK="portless Local CA"

echo "shares and names created by Portal"
run "$HERE/tunnels.sh" stop-all

echo "browser trust for the Portless CA"
if command -v certutil >/dev/null 2>&1; then
  [[ -d $HOME/.pki/nssdb ]] && run certutil -d "sql:$HOME/.pki/nssdb" -D -n "$NICK" 2>/dev/null
  for d in "$HOME"/.mozilla/firefox/*/; do
    [[ -f "$d/cert9.db" ]] && run certutil -d "sql:${d%/}" -D -n "$NICK" 2>/dev/null
  done
fi

echo "cloudflared, if Portal installed it"
mark=$(read_own "$METRICS/installed-cloudflared" 4096)
if [[ -n $mark ]]; then run state remove "${mark%/*}" "${mark##*/}"; fi

echo "Portal state"
for d in "$STATE" "$METRICS"; do
  [[ -d $d && ! -L $d && -O $d ]] && run rm -rf -- "$d"
done

echo
echo "left in place: the portless package (npm uninstall -g portless), ~/.portless,"
echo "and any resolver rule you pasted with sudo (/etc/dnsmasq.d/portless-*.conf,"
echo "/etc/systemd/resolved.conf.d/portless-*.conf)."
