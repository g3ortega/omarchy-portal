#!/bin/bash
# Reverse everything Portal put on this machine: stop every share and name it
# created, drop the Portless CA from the browser stores, delete the cloudflared
# binary only if Portal installed it, and remove Portal's own state. The
# portless package the user installed and its own state are left alone and
# named at the end.
#
#   uninstall.sh          do it
#   uninstall.sh --dry    say what would happen
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portless.sh
source "$HERE/lib/portless.sh"
DRY=0; [[ ${1:-} == --dry ]] && DRY=1
run() { if (( DRY )); then echo "would: $*"; else "$@"; fi; }

echo "shares and names created by Portal"
run "$HERE/tunnels.sh" stop-all

echo "browser trust for the Portless CA"
run "$HERE/portless-setup.sh" untrust

echo "cloudflared, if Portal installed it"
mark=$(read_own "$PORTAL_STATE_HOME/installed-cloudflared" 4096)
[[ -n $mark ]] && run state_remove "${mark%/*}" "${mark##*/}"

echo "Portal state"
for d in "$PORTAL_RUNTIME_DIR" "$PORTAL_STATE_HOME"; do
  [[ -d $d && ! -L $d && -O $d ]] && run rm -rf -- "$d"   # verify without creating
done

echo
echo "left in place: the portless package (npm uninstall -g portless), ~/.portless,"
echo "and any resolver rule you pasted with sudo (/etc/dnsmasq.d/portless-*.conf,"
echo "/etc/systemd/resolved.conf.d/portless-*.conf)."
