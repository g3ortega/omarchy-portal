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
  # An unreadable plugin state is not "disabled": a service still polling
  # would recreate what is removed below.
  listed=$(omarchy plugin list --json 2>/dev/null) && enabled=$(jq -r '.[] | select(.id == "g3ortega.portal") | .enabled' <<<"$listed" 2>/dev/null) \
    || { echo "could not read the plugin state; nothing was removed" >&2; exit 1; }
  if [[ $enabled == true ]]; then
    run omarchy plugin disable g3ortega.portal || { echo "could not disable the plugin; nothing was removed" >&2; exit 1; }
  fi
fi

echo "shares and names created by Portal"
if (( DRY )); then run "$HERE/tunnels.sh" stop-own
else
  out=$("$HERE/tunnels.sh" stop-own)
  jq -e .ok <<<"$out" >/dev/null || { echo "$(jq -r '.error' <<<"$out"); their records are kept; nothing else was removed" >&2; exit 1; }
fi

echo "browser trust Portal added for the Portless CA"
if (( DRY )); then run "$HERE/portless-setup.sh" untrust
else
  out=$("$HERE/portless-setup.sh" untrust)
  jq -e .ok <<<"$out" >/dev/null || { echo "$(jq -r '.error + ": " + (.remaining | join(", "))' <<<"$out"); the record is kept; nothing else was removed" >&2; exit 1; }
fi

echo "cloudflared, if it is still the copy Portal installed"
MARKER="$PORTAL_STATE_HOME/installed-cloudflared"
EXPECT_BIN="${PORTAL_BIN_DIR:-$HOME/.local/bin}/cloudflared"
if [[ -e $MARKER || -L $MARKER ]]; then
  # A marker that exists but cannot be read or decoded is not "no marker": it
  # is the only record that the binary is Portal's, so a bad read aborts rather
  # than dropping it below.
  mark=$(cat_own "$MARKER" 4096) || { echo "the cloudflared install marker cannot be read; nothing was removed" >&2; exit 1; }
  path=$(jq -r '.path // empty' <<<"$mark" 2>/dev/null)
  sum=$(jq -r '.sha256 // empty' <<<"$mark" 2>/dev/null)
  [[ -n $path && -n $sum ]] || { echo "the cloudflared install marker is malformed; nothing was removed" >&2; exit 1; }
  # Only the one path Portal installs to is ever a delete candidate, and the
  # digest is taken from the bytes the state helper binds, not from a pathname.
  # The marker is removed only together with the binary; a binary that is gone,
  # changed, or not at our path leaves the record in place for a retry.
  if [[ $path == "$EXPECT_BIN" && ( -e $path || -L $path ) ]]; then
    own_file "$path" 134217728 || { echo "could not read $path safely; its marker is kept; nothing else was removed" >&2; exit 1; }
    if [[ $(cat_own "$path" 134217728 | sha256sum | cut -d' ' -f1) == "$sum" ]]; then
      run state_remove "${path%/*}" "${path##*/}" || { echo "could not remove $path; its marker is kept; nothing else was removed" >&2; exit 1; }
      run state_remove "$PORTAL_STATE_HOME" installed-cloudflared
    fi
  fi
fi

echo "Portal state"
# Only entries Portal writes, by name, then the directory if that emptied it:
# a state root pointed at a directory holding other things keeps them.
remove_known() {  # <dir> <name regex>
  [[ -d $1 && ! -L $1 && -O $1 ]] || return 0
  local names=()
  mapfile -t names < <(find "$1" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | grep -E -- "$2")
  (( ${#names[@]} )) && run state_remove "$1" "${names[@]}"
  run rmdir --ignore-fail-on-non-empty -- "$1"
  (( DRY )) || [[ ! -d $1 ]] || echo "left in place: $1 holds files that are not Portal's"
}
remove_known "$PORTAL_RUNTIME_DIR" '^[a-z]+-[0-9]+\.(pid|url|reach|dns|idle|log|name)$|^\..*\.tmp$'
remove_known "$PORTAL_STATE_HOME/metrics" '^[0-9]+\.jsonl$|^\..*\.tmp$'
remove_known "$PORTAL_STATE_HOME" '^(trusted-stores|watched\.json)$|^\..*\.tmp$'   # the install marker is removed with its binary above

echo
echo "left in place: the portless package (npm uninstall -g portless), ~/.portless,"
echo "and any resolver rule you pasted with sudo (/etc/dnsmasq.d/portless-*.conf,"
echo "/etc/systemd/resolved.conf.d/portless-*.conf). Finish with:"
echo "  omarchy plugin remove g3ortega.portal"
