#!/bin/bash
# Reverse what Portal put on this machine: disable the plugin so nothing
# polls meanwhile, stop every share and name Portal created (adopted ones
# belong to whoever started them), drop the Portless CA from the browser
# stores Portal imported into, delete cloudflared only if it is still the
# copy Portal installed, and remove Portal's own state. The portless package
# the user installed and its own state are left alone and named at the end.
#
#   uninstall.sh          do it
#   uninstall.sh --dry    say what would happen
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portless.sh
source "$HERE/lib/portless.sh"
case "${1:-}" in
  "") DRY=0 ;;
  --dry) DRY=1 ;;
  *) echo "usage: uninstall.sh [--dry]" >&2; exit 2 ;;
esac
run() { if (( DRY )); then echo "would: $*"; else "$@"; fi; }

echo "the plugin, so nothing polls while state is removed"
if command -v omarchy >/dev/null 2>&1; then
  if [[ $(omarchy plugin list --json 2>/dev/null | jq -r '.[] | select(.id == "g3ortega.portal") | .enabled') == true ]]; then
    run omarchy plugin disable g3ortega.portal || { echo "could not disable the plugin; nothing was removed" >&2; exit 1; }
  fi
fi

echo "shares and names created by Portal"
run "$HERE/tunnels.sh" stop-own

echo "browser trust Portal added for the Portless CA"
run "$HERE/portless-setup.sh" untrust

echo "cloudflared, if it is still the copy Portal installed"
read -r path sum <<<"$(read_own "$PORTAL_STATE_HOME/installed-cloudflared" 4096)"
if [[ -n $path && -f $path && $(sha256sum -- "$path" | cut -d' ' -f1) == "$sum" ]]; then
  run state_remove "${path%/*}" "${path##*/}"
fi

echo "Portal state"
for d in "$PORTAL_RUNTIME_DIR" "$PORTAL_STATE_HOME"; do
  [[ -d $d && ! -L $d && -O $d ]] && run rm -rf -- "$d"   # verify without creating
done

echo
echo "left in place: the portless package (npm uninstall -g portless), ~/.portless,"
echo "and any resolver rule you pasted with sudo (/etc/dnsmasq.d/portless-*.conf,"
echo "/etc/systemd/resolved.conf.d/portless-*.conf). Finish with:"
echo "  omarchy plugin remove g3ortega.portal"
