#!/bin/bash
# Dev lifecycle for the Portal plugin. The running shell serves the separate
# clone at ~/.config/omarchy/plugins/g3ortega.portal, never this workdir, and
# panel objects outlive file-watcher reloads — so every operation below either
# proves its result or says plainly that it could not.
#
#   dev/portal.sh status          workdir vs install vs shell health
#   dev/portal.sh sync            push branch, pull install, prove parity
#   dev/portal.sh reload [--hard] soft: touch + wait for reload lines (bar
#                               widgets only; a created panel stays stale).
#                               hard: disable/enable, rebuilds everything.
#   dev/portal.sh restart-shell   fresh engine via omarchy-restart-shell
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL="$HOME/.config/omarchy/plugins/g3ortega.portal"
ID="g3ortega.portal"
TMPD="${TMPDIR:-/tmp}/opencode"
mkdir -p "$TMPD" 2>/dev/null
fail() { echo "portal.sh: $*" >&2; exit 1; }

# Files git ignores when proving the install matches the workdir.
parity() {
  diff -r "$ROOT" "$INSTALL" --exclude=.git --exclude=tmp \
    --exclude=__pycache__ --exclude=dev 2>&1
}

shell_pid() { pgrep -f "[q]uickshell -n" | head -1; }

cmd_status() {
  echo "workdir:  $(cd "$ROOT" && git log --oneline -1 && git status -sb | head -1)"
  if [[ -d $INSTALL/.git ]]; then
    echo "install:  $(cd "$INSTALL" && git log --oneline -1 && git status -sb | head -1)"
  else
    echo "install:  not a git checkout"
  fi
  echo "shell pid: $(shell_pid || echo MISSING)"
  omarchy plugin list --json 2>/dev/null | python3 -c \
    "import json,sys; [print('plugin:  ', p['id'], 'enabled='+str(p.get('enabled')), 'active='+str(p.get('active'))) for p in json.load(sys.stdin) if 'portal' in p['id']]"
  if out=$(parity); then echo "parity:   IDENTICAL"; else printf 'parity:   DIFFERS\n%s\n' "$out"; fi
}

cmd_sync() {
  [[ -d $INSTALL/.git ]] || fail "install is not a git checkout"
  local branch; branch=$(cd "$ROOT" && git branch --show-current)
  (cd "$ROOT" && git push origin "$branch") \
    || fail "push failed; not touching the install"
  (cd "$INSTALL" && git pull origin "$branch") \
    || fail "install pull failed"
  if out=$(parity); then echo "sync: IDENTICAL"; else printf 'sync: DIFFERS\n%s\n' "$out"; return 1; fi
}

# Wait up to ~16s for the shell's file watcher to notice; sequence with the
# panel closed, since toggles race reloads and prove nothing.
wait_reload() {
  local i n
  for i in $(seq 1 8); do
    sleep 2
    n=$(journalctl --user --since="-25 sec" --no-pager 2>&1 | grep -c "reloading: $ID")
    if (( n > 0 )); then echo "reload: $n reload line(s)"; return 0; fi
  done
  echo "reload: no reload lines in 16s" >&2; return 1
}

cmd_reload() {
  if [[ ${1:-} == --hard ]]; then
    cp ~/.config/omarchy/shell.json "$TMPD/shell.json.bak" \
      || fail "cannot back up shell.json"
    omarchy plugin disable "$ID" >/dev/null 2>&1; sleep 2
    omarchy plugin enable "$ID" >/dev/null 2>&1 \
      || fail "enable failed; settings backup at $TMPD/shell.json.bak"
    sleep 2
    # Enable rewrites the widget entry and drops its settings keys.
    cp "$TMPD/shell.json.bak" ~/.config/omarchy/shell.json
    omarchy plugin list --json 2>/dev/null | ID="$ID" python3 -c \
      'import json,os,sys; sys.exit(0 if any(p["id"]==os.environ["ID"] for p in json.load(sys.stdin)) else 1)' \
      && echo "reload: hard done, settings restored" \
      || fail "plugin missing after enable"
  else
    touch "$INSTALL"/*.qml
    wait_reload || fail "soft reload unconfirmed; use --hard for panel code"
  fi
}

cmd_restart_shell() {
  local before after i
  before=$(shell_pid) || fail "no shell running"
  omarchy-restart-shell >/dev/null 2>&1 || fail "restart refused (session locked?)"
  for i in $(seq 1 15); do
    sleep 2
    after=$(shell_pid)
    if [[ -n $after && $after != "$before" ]]; then
      omarchy-shell shell ping 2>/dev/null | grep -q ok \
        && { echo "restart-shell: $before -> $after"; return 0; }
    fi
  done
  fail "no healthy replacement shell after 30s (old pid $before)"
}

case "${1:-status}" in
  status)        cmd_status ;;
  sync)          cmd_sync ;;
  reload)        cmd_reload "${2:-}" ;;
  restart-shell) cmd_restart_shell ;;
  *) fail "usage: dev/portal.sh status|sync|reload [--hard]|restart-shell" ;;
esac
