#!/bin/bash
# Owner-only state files, through scripts/lib/statedir.py: every read and
# write is descriptor-relative to a directory walked from / without following
# links, leaves are bound after open (regular, ours, one link, capped), writes
# are exclusive temporaries renamed into place. Third-party state (Portless's
# directory) is read the same way.
STATEDIR_PY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/statedir.py"
PROC_PY="${STATEDIR_PY%/*}/proc.py"
state() { /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; }   # -I: no env or cwd can redirect the interpreter
proc()  { /usr/bin/python3 -I -S "$PROC_PY" "$@"; }       # signal <pid> <start> <SIG> | check <pid> <start>
own_dir()   { state ensure "$@" 2>/dev/null; }                   # create 0700 and verify
own_file()  { state read "$1" "${2:-1048576}" >/dev/null 2>&1; }  # a plain owned file under the cap
cat_own()   { state read "$1" "${2:-1048576}" 2>/dev/null; }      # whole file, capped
read_own()  { cat_own "$1" "${2:-4096}" | head -n 1; }           # first line
write_own() { printf '%s' "$2" | state write "$1" 2>/dev/null; }  # atomic replace
state_dump()     { state dump "$1" "${2:-65536}" 2>/dev/null || echo '{"files":{}}'; }
state_remove()   { state remove "$@" 2>/dev/null; }              # <dir> <name>...
state_truncate() { state truncate "$1" "$2" 2>/dev/null; }       # <path> <cap>
state_append()   { state append "$1" "$2" "${3:-8388608}" 2>/dev/null; }   # stdin; <path> <maxlines> [maxbytes]

# Where Portal keeps state: tunnel pidfiles, logs and URLs under the runtime
# dir (gone at logout), metrics and install markers under the state home.
PORTAL_RUNTIME_DIR="${PORTAL_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/portal}"
PORTAL_STATE_HOME="${PORTAL_METRICS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/portal}"

lifecycle_lock_shared() {
  command -v flock >/dev/null 2>&1 || return 0
  own_dir "$PORTAL_RUNTIME_DIR" 2>/dev/null || return 0
  { exec 8>"$PORTAL_RUNTIME_DIR/.lifecycle.lock"; } 2>/dev/null || return 0
  flock -n -s 8 2>/dev/null
}

valid_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }

# The executable a provider action runs: resolved to an absolute path that is
# a regular file owned by root or the user and not writable by anyone else,
# with every directory from / down owned by root or the user and such that
# nobody else can swap an entry in it (not group/other writable, or sticky).
# Never a bare name through PATH. The launcher walks the same chain again by
# descriptor and executes the file it validated, so nothing can be swapped in
# between.
resolve_bin() {  # <name>
  local p d
  p=$(command -v -- "$1" 2>/dev/null) || return 1
  p=$(readlink -f -- "$p" 2>/dev/null) || return 1
  [[ -f $p && -x $p ]] || return 1
  _trusted_owner "$p" || return 1
  d=${p%/*}
  while :; do _trusted_dir "${d:-/}" || return 1; [[ -n $d ]] || break; d=${d%/*}; done
  printf '%s' "$p"
}
_trusted_owner() {  # <path>: owned by root or us, not group/other writable
  local o m
  read -r o m < <(stat -c '%u %a' -- "$1" 2>/dev/null) || return 1
  [[ $o == 0 || $o == "$UID" ]] && (( (8#$m & 8#022) == 0 ))
}
_trusted_dir() {  # <dir>: owned by root or us; entries swappable by nobody else
  local o m
  read -r o m < <(stat -c '%u %a' -- "$1" 2>/dev/null) || return 1
  [[ $o == 0 || $o == "$UID" ]] && { (( (8#$m & 8#022) == 0 )) || (( (8#$m & 8#1000) != 0 )); }
}
