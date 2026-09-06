#!/bin/bash
# Developer commands for the installed Portal clone.
#
#   dev/portal.sh status          show checkout and shell health
#   dev/portal.sh parity          compare the worktree with the installed clone
#   dev/portal.sh stage           copy the staged index to the installed clone
#   dev/portal.sh sync            push a proved commit and fast-forward the clone
#   dev/portal.sh reload [--hard] ask the watcher to reload, or rebuild the plugin
#   dev/portal.sh restart-shell   start a fresh shell engine
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL="$HOME/.config/omarchy/plugins/g3ortega.portal"
SETTINGS="$HOME/.config/omarchy/shell.json"
ID="g3ortega.portal"

fail() { echo "portal.sh: $*" >&2; exit 1; }
shell_pid() { pgrep -f "[q]uickshell -n" | head -1; }

parity() {
  diff -r --exclude=.git --exclude=tmp --exclude=__pycache__ --exclude=dev \
    "$ROOT" "$INSTALL" 2>&1
}

untracked() { git -C "$1" ls-files --others --exclude-standard; }

require_install() {
  [[ -d $INSTALL/.git ]] || fail "install is not a git checkout"
}

restore_stage_snapshot() {  # <snapshot dir>
  rsync -a --delete-delay --delay-updates --exclude=/.git --exclude=/dev --exclude=/tmp \
    --exclude=__pycache__ "$1/backup/" "$INSTALL/" \
    && cp -- "$1/index" "$INSTALL/.git/index"
}

cmd_parity() {
  require_install
  local out
  if out=$(parity); then
    echo "parity: IDENTICAL"
  else
    printf 'parity: DIFFERS\n%s\n' "$out"
    return 1
  fi
}

cmd_status() {
  echo "workdir:  $(cd "$ROOT" && git log --oneline -1 && git status -sb | head -1)"
  if [[ -d $INSTALL/.git ]]; then
    echo "install:  $(cd "$INSTALL" && git log --oneline -1 && git status -sb | head -1)"
    cmd_parity || true
  else
    echo "install:  not a git checkout"
    echo "parity:   UNAVAILABLE"
  fi
  echo "shell pid: $(shell_pid || echo MISSING)"
  omarchy plugin list --json 2>/dev/null | python3 -c \
    "import json,sys; [print('plugin:  ', p['id'], 'enabled='+str(p.get('enabled')), 'active='+str(p.get('active'))) for p in json.load(sys.stdin) if 'portal' in p['id']]"
}

cmd_stage() {
  require_install
  local source_head install_head ignored tmp

  git -C "$ROOT" diff --quiet \
    || fail "worktree has unstaged changes; stage the complete change first"
  [[ -z $(untracked "$ROOT") ]] \
    || fail "worktree has untracked files; stage or remove them first"
  [[ -z $(git -C "$ROOT" ls-files -u) ]] || fail "worktree has unresolved index entries"
  git -C "$ROOT" diff --cached --check || fail "staged change fails git diff --check"

  source_head=$(git -C "$ROOT" rev-parse HEAD) || fail "cannot read worktree HEAD"
  install_head=$(git -C "$INSTALL" rev-parse HEAD) || fail "cannot read install HEAD"
  [[ $source_head == "$install_head" ]] \
    || fail "worktree and install must start at the same commit"
  git -C "$INSTALL" diff --quiet \
    || fail "install has unstaged changes; remove installed-only probes first"
  [[ -z $(untracked "$INSTALL") ]] \
    || fail "install has untracked files; remove installed-only probes first"
  git -C "$INSTALL" diff --cached --quiet -- dev \
    || fail "install has staged changes under dev"
  ignored=$(git -C "$INSTALL" ls-files --others --ignored --exclude-standard \
    --directory --no-empty-directory -- . \
    ':(exclude,top)dev' ':(exclude,top)dev/**' \
    ':(exclude,top)tmp' ':(exclude,top)tmp/**' \
    ':(exclude,glob)**/__pycache__' ':(exclude,glob)**/__pycache__/**' | \
    sed -n '1p') \
    || fail "cannot inspect ignored paths in install"
  [[ -z $ignored ]] \
    || fail "install has ignored paths outside stage exclusions; remove them first"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/portal-stage.XXXXXX") \
    || fail "cannot create a private staging directory"
  mkdir "$tmp/tree" "$tmp/backup" || { rm -rf -- "$tmp"; fail "cannot create the index snapshots"; }
  if ! git -C "$ROOT" checkout-index --all --prefix="$tmp/tree/"; then
    rm -rf -- "$tmp"
    fail "cannot read the staged index"
  fi
  if ! git -C "$INSTALL" checkout-index --all --prefix="$tmp/backup/" \
      || ! cp -- "$INSTALL/.git/index" "$tmp/index"; then
    rm -rf -- "$tmp"
    fail "cannot snapshot the installed clone"
  fi
  if ! rsync -a --delete-delay --delay-updates --exclude=/.git --exclude=/dev --exclude=/tmp \
      --exclude=__pycache__ "$tmp/tree/" "$INSTALL/"; then
    restore_stage_snapshot "$tmp" || fail "stage failed and rollback also failed; snapshot kept at $tmp"
    rm -rf -- "$tmp"
    fail "cannot mirror the staged index"
  fi
  if ! git -C "$INSTALL" add -A -- . ':(exclude)dev/**' || ! cmd_parity >/dev/null; then
    restore_stage_snapshot "$tmp" || fail "stage verification failed and rollback also failed; snapshot kept at $tmp"
    rm -rf -- "$tmp"
    fail "staged install differs from the worktree"
  fi
  rm -rf -- "$tmp"
  echo "stage: IDENTICAL; install changes are staged"
}

cmd_sync() {
  require_install
  local branch out

  git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet \
    || fail "commit the proved work before sync"
  [[ -z $(untracked "$ROOT") ]] || fail "worktree has untracked files"
  branch=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD) \
    || fail "worktree is detached"
  git -C "$INSTALL" diff --quiet \
    || fail "install has unstaged changes; remove installed-only probes first"
  [[ -z $(untracked "$INSTALL") ]] \
    || fail "install has untracked files; remove installed-only probes first"
  git -C "$INSTALL" diff --cached --quiet -- dev \
    || fail "install has staged changes under dev"

  if out=$(parity); then
    echo "sync pre-push parity: IDENTICAL"
  else
    printf 'sync pre-push parity: DIFFERS\n%s\n' "$out" >&2
    return 1
  fi
  git -C "$ROOT" push origin "$branch" \
    || fail "push failed; install was not changed"
  git -C "$INSTALL" fetch origin "$branch" \
    || fail "install fetch failed; staged proof remains"
  git -C "$INSTALL" merge --ff-only FETCH_HEAD \
    || fail "install cannot fast-forward to origin/$branch"

  if out=$(parity); then
    echo "sync post-merge parity: IDENTICAL"
  else
    printf 'sync post-merge parity: DIFFERS\n%s\n' "$out"
    return 1
  fi
}

journal_cursor() {
  local out cursor
  out=$(journalctl --user -n 0 --show-cursor --no-pager 2>&1) || return 1
  cursor=$(sed -n 's/^-- cursor: //p' <<<"$out" | tail -1)
  [[ -n $cursor ]] || return 1
  printf '%s' "$cursor"
}

wait_reload() {
  local cursor="$1" i logs n
  for i in $(seq 1 8); do
    sleep 2
    if logs=$(journalctl --user --after-cursor="$cursor" --no-pager 2>&1); then
      n=$(grep -cF "reloading: $ID" <<<"$logs" || true)
      if (( n > 0 )); then
        echo "reload: $n new reload line(s)"
        return 0
      fi
    fi
  done
  echo "reload: no new reload line in 16s" >&2
  return 1
}

RELOAD_TMP=""
RELOAD_BACKUP=""
restore_settings() {
  cp -- "$RELOAD_BACKUP" "$SETTINGS" \
    && cmp -s -- "$RELOAD_BACKUP" "$SETTINGS"
}

reload_exit() {
  local rc=$? remove_tmp=1
  trap - EXIT HUP INT TERM
  if [[ -n $RELOAD_BACKUP && -f $RELOAD_BACKUP ]]; then
    if restore_settings; then
      RELOAD_BACKUP=""
    else
      echo "portal.sh: cannot verify restored settings; backup kept at $RELOAD_BACKUP" >&2
      rc=1
      remove_tmp=0
    fi
  fi
  if (( remove_tmp == 1 )); then
    [[ -z $RELOAD_TMP ]] || rm -rf -- "$RELOAD_TMP"
  fi
  exit "$rc"
}

cmd_hard_reload() {
  local error=""
  RELOAD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/portal-reload.XXXXXX") \
    || fail "cannot create a private reload directory"
  RELOAD_BACKUP="$RELOAD_TMP/shell.json"
  cp -- "$SETTINGS" "$RELOAD_BACKUP" \
    || { rm -rf -- "$RELOAD_TMP"; RELOAD_TMP=""; RELOAD_BACKUP=""; fail "cannot back up $SETTINGS"; }

  trap reload_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! omarchy plugin disable "$ID" >/dev/null 2>&1; then
    error="disable failed"
  else
    sleep 2
    if ! omarchy plugin enable "$ID" >/dev/null 2>&1; then
      error="enable failed"
    else
      sleep 2
      omarchy plugin list --json 2>/dev/null | ID="$ID" python3 -c \
        'import json,os,sys; sys.exit(0 if any(p.get("id")==os.environ["ID"] and p.get("enabled") for p in json.load(sys.stdin)) else 1)' \
        || error="plugin missing or disabled after enable"
    fi
  fi

  if ! restore_settings; then
    trap - EXIT HUP INT TERM
    fail "cannot verify restored settings; backup kept at $RELOAD_BACKUP"
  fi
  RELOAD_BACKUP=""
  [[ -z $RELOAD_TMP ]] || rm -rf -- "$RELOAD_TMP"
  RELOAD_TMP=""
  trap - EXIT HUP INT TERM

  [[ -z $error ]] || fail "$error"
  echo "reload: hard done; settings restored"
}

cmd_reload() {
  local cursor files
  if [[ ${1:-} == --hard ]]; then
    cmd_hard_reload
    return
  fi
  cursor=$(journal_cursor) || fail "cannot capture the user journal cursor"
  files=("$INSTALL"/*.qml)
  [[ -e ${files[0]} ]] || fail "install has no QML files"
  touch -- "${files[@]}" || fail "cannot touch installed QML files"
  wait_reload "$cursor" || fail "soft reload unconfirmed; use --hard for panel code"
}

cmd_restart_shell() {
  local before after i
  before=$(shell_pid) || fail "no shell running"
  omarchy-restart-shell >/dev/null 2>&1 || fail "restart refused; is the session locked?"
  for i in $(seq 1 15); do
    sleep 2
    after=$(shell_pid)
    if [[ -n $after && $after != "$before" ]]; then
      omarchy-shell shell ping 2>/dev/null | grep -q ok \
        && { echo "restart-shell: $before -> $after"; return 0; }
    fi
  done
  fail "no healthy replacement shell after 30s; old PID was $before"
}

case "${1:-status}" in
  status)        cmd_status ;;
  parity)        cmd_parity ;;
  stage)         cmd_stage ;;
  sync)          cmd_sync ;;
  reload)        cmd_reload "${2:-}" ;;
  restart-shell) cmd_restart_shell ;;
  *) fail "usage: dev/portal.sh status|parity|stage|sync|reload [--hard]|restart-shell" ;;
esac
