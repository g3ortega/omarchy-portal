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
runtime_override=0
metrics_override=0
[[ -n ${PORTAL_STATE_DIR:-} ]] && runtime_override=1
[[ -n ${PORTAL_METRICS_DIR:-} ]] && metrics_override=1
PORTAL_RUNTIME_DIR=$(/usr/bin/realpath -ms -- "$PORTAL_RUNTIME_DIR") || exit 1
PORTAL_STATE_HOME=$(/usr/bin/realpath -ms -- "$PORTAL_STATE_HOME") || exit 1
runtime_root=$PORTAL_RUNTIME_DIR
state_root=$PORTAL_STATE_HOME
if [[ $runtime_root == "$state_root" ]] && (( runtime_override || metrics_override )); then
  runtime_override=1
  metrics_override=1
fi
lifecycle_cleanup=()
metrics_cleanup=()
(( runtime_override )) && lifecycle_cleanup+=(--keep-existing-root)
(( metrics_override )) && metrics_cleanup+=(--keep-existing-root)
if [[ $runtime_root == "$state_root"/* ]]; then
  lifecycle_cleanup+=(--prune-to "$state_root")
elif [[ $state_root == "$runtime_root"/* ]]; then
  metrics_cleanup+=(--prune-to "$runtime_root")
fi
outermost=0
if [[ ${PORTAL_LIFECYCLE_LOCKED:-} != "$PORTAL_RUNTIME_DIR" \
      && ${PORTAL_METRICS_LOCKED:-} != "$PORTAL_STATE_HOME" ]]; then
  outermost=1
fi
report_remaining_state() {
  local runtime=$1 state=$2 runtime_kept=$3 state_kept=$4
  report_remaining_root "$runtime" "$runtime_kept"
  [[ $runtime == "$state" ]] || report_remaining_root "$state" "$state_kept"
}
report_remaining_root() {
  local dir=$1 kept=$2
  [[ -d $dir ]] || return 0
  if [[ -n $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
    echo "left in place: $dir holds files that are not Portal's"
  elif (( kept )); then
    echo "left in place: $dir is an explicit state root"
  fi
}

if (( ! DRY )); then
  if [[ $runtime_root == "$state_root"/* && ${PORTAL_METRICS_LOCKED:-} != "$PORTAL_STATE_HOME" ]]; then
    PORTAL_METRICS_LOCKED="$PORTAL_STATE_HOME" state lock-clean "$PORTAL_STATE_HOME" nowait .metrics.lock \
      "${metrics_cleanup[@]}" -- \
      /usr/bin/bash "$HERE/uninstall.sh" "$@"
    rc=$?
    (( rc == 0 && outermost )) && report_remaining_state "$PORTAL_RUNTIME_DIR" "$PORTAL_STATE_HOME" "$runtime_override" "$metrics_override"
    exit "$rc"
  fi
  if [[ ${PORTAL_LIFECYCLE_LOCKED:-} != "$PORTAL_RUNTIME_DIR" ]]; then
    PORTAL_LIFECYCLE_LOCKED="$PORTAL_RUNTIME_DIR" state lock-clean "$PORTAL_RUNTIME_DIR" nowait .lifecycle.lock \
      "${lifecycle_cleanup[@]}" -- /usr/bin/bash "$HERE/uninstall.sh" "$@"
    rc=$?
    (( rc == 0 && outermost )) && report_remaining_state "$PORTAL_RUNTIME_DIR" "$PORTAL_STATE_HOME" "$runtime_override" "$metrics_override"
    exit "$rc"
  fi
  if [[ ${PORTAL_METRICS_LOCKED:-} != "$PORTAL_STATE_HOME" ]]; then
    PORTAL_METRICS_LOCKED="$PORTAL_STATE_HOME" state lock-clean "$PORTAL_STATE_HOME" nowait .metrics.lock \
      "${metrics_cleanup[@]}" -- /usr/bin/bash "$HERE/uninstall.sh" "$@"
    rc=$?
    (( rc == 0 && outermost )) && report_remaining_state "$PORTAL_RUNTIME_DIR" "$PORTAL_STATE_HOME" "$runtime_override" "$metrics_override"
    exit "$rc"
  fi
fi

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
  out=$(PORTAL_STATE_DIR="$PORTAL_RUNTIME_DIR" PORTAL_METRICS_DIR="$PORTAL_STATE_HOME" \
    "$HERE/tunnels.sh" stop-own)
  jq -e .ok <<<"$out" >/dev/null || { echo "$(jq -r '.error' <<<"$out"); their records are kept; nothing else was removed" >&2; exit 1; }
fi

echo "browser trust Portal added for the Portless CA"
if (( DRY )); then run "$HERE/portless-setup.sh" untrust
else
  out=$(PORTAL_STATE_DIR="$PORTAL_RUNTIME_DIR" PORTAL_METRICS_DIR="$PORTAL_STATE_HOME" \
    "$HERE/portless-setup.sh" untrust)
  jq -e .ok <<<"$out" >/dev/null || { echo "$(jq -r '.error + (if (.remaining // []) | length > 0 then ": " + (.remaining | join(", ")) else "" end)' <<<"$out"); the record is kept; nothing else was removed" >&2; exit 1; }
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
  [[ -n $path && $sum =~ ^[0-9a-f]{64}$ ]] || { echo "the cloudflared install marker is malformed; nothing was removed" >&2; exit 1; }
  # Only the one path Portal installs to is ever a delete candidate, and the
  # digest is taken from the bytes the state helper binds, not from a pathname.
  # The marker is removed only together with the binary; a binary that is gone,
  # changed, or not at our path leaves the record in place for a retry.
  [[ $path == "$EXPECT_BIN" ]] || { echo "the cloudflared install marker names an unexpected path; nothing was removed" >&2; exit 1; }
  run state remove-digest "${path%/*}" "${path##*/}" "$sum" 134217728 \
    || { echo "could not remove the exact Portal-installed bytes at $path; its marker is kept; nothing else was removed" >&2; exit 1; }
  run state_remove "$PORTAL_STATE_HOME" installed-cloudflared \
    || { echo "cloudflared was removed, but its install marker could not be cleared; nothing else was removed" >&2; exit 1; }
fi

echo "Portal state"
# Only entries Portal writes, by name, then the directory if that emptied it:
# a state root pointed at a directory holding other things keeps them.
portal_leaf_in_scope() {
  local scope=$1 name=$2 port
  case $scope in
    runtime)
      [[ $name == ngrok.ok ]] && return 0
      if [[ $name =~ ^(cloudflared|ngrok)-([0-9]+)\.(pid|url|reach|dns|idle|log|target)$ ]]; then
        port=${BASH_REMATCH[2]}
      elif [[ $name =~ ^portless-([0-9]+)\.(url|reach|name)$ ]]; then
        port=${BASH_REMATCH[1]}
      elif [[ $name =~ ^\.restart-([0-9]+)\.pid$ ]]; then
        port=${BASH_REMATCH[1]}
      else
        return 1
      fi
      ;;
    metrics)
      [[ $name =~ ^([0-9]+)\.jsonl$ ]] || return 1
      port=${BASH_REMATCH[1]}
      ;;
    state)
      case $name in
        trusted-stores|watched.json|ca-import.pem) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  valid_port "$port"
}
remove_known() {
  local dir="$1" scope="$2" dry_remove_dir="${3:-1}" path name
  [[ -e $dir || -L $dir ]] || return 0
  [[ -d $dir && ! -L $dir && -O $dir && -r $dir && -x $dir ]] || return 1
  local names=()
  for path in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e $path || -L $path ]] || continue
    [[ -d $path && ! -L $path ]] && continue
    name=${path##*/}
    portal_leaf_in_scope "$scope" "$name" && names+=("$name")
  done
  if (( ${#names[@]} )); then
    run state_remove "$dir" "${names[@]}" || return 1
  fi
  if (( DRY )); then
    if (( dry_remove_dir )); then run rmdir --ignore-fail-on-non-empty -- "$dir"; fi
  else rmdir --ignore-fail-on-non-empty -- "$dir" 2>/dev/null || true
  fi
}
dry_plan_root() {
  local dir=$1 keep=$2
  (( keep )) && return 0
  [[ -d $dir && ! -L $dir && -O $dir ]] || return 0
  run rmdir --ignore-fail-on-non-empty -- "$dir"
}
remove_known "$PORTAL_RUNTIME_DIR" runtime 0 \
  || { echo "could not remove Portal runtime state" >&2; exit 1; }
remove_known "$PORTAL_STATE_HOME/metrics" metrics \
  || { echo "could not remove Portal metrics" >&2; exit 1; }
remove_known "$PORTAL_STATE_HOME" state 0 \
  || { echo "could not remove Portal state" >&2; exit 1; }
if (( DRY )); then
  if [[ $runtime_root == "$state_root" ]]; then
    dry_plan_root "$PORTAL_RUNTIME_DIR" "$runtime_override"
  elif [[ $runtime_root == "$state_root"/* ]]; then
    dry_plan_root "$PORTAL_RUNTIME_DIR" "$runtime_override"
    dry_plan_root "$PORTAL_STATE_HOME" "$metrics_override"
  elif [[ $state_root == "$runtime_root"/* ]]; then
    dry_plan_root "$PORTAL_STATE_HOME" "$metrics_override"
    dry_plan_root "$PORTAL_RUNTIME_DIR" "$runtime_override"
  else
    dry_plan_root "$PORTAL_RUNTIME_DIR" "$runtime_override"
    dry_plan_root "$PORTAL_STATE_HOME" "$metrics_override"
  fi
fi

echo
echo "left in place: the portless package (npm uninstall -g portless), ~/.portless,"
echo "and any resolver rule you pasted with sudo (/etc/dnsmasq.d/portless-*.conf,"
echo "/etc/systemd/resolved.conf.d/portless-*.conf). Finish with:"
echo "  omarchy plugin remove g3ortega.portal"
