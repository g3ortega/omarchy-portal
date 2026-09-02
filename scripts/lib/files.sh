#!/bin/bash
# Owner-only state files, through scripts/lib/statedir.py: every read and
# write is descriptor-relative to a directory walked from / without following
# links, leaves are bound after open (regular, ours, one link, capped), writes
# are exclusive temporaries renamed into place. Third-party state (Portless's
# directory) is read the same way.
STATEDIR_PY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/statedir.py"
state() { /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; }   # -I: no env or cwd can redirect the interpreter
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

valid_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }

# The executable a provider action runs: resolved to an absolute path that is
# a regular file owned by root or the user and writable by neither group nor
# others. Never a bare name through PATH.
resolve_bin() {  # <name>
  local p o m
  p=$(command -v -- "$1" 2>/dev/null) || return 1
  p=$(readlink -f -- "$p" 2>/dev/null) || return 1
  [[ -f $p && -x $p ]] || return 1
  read -r o m < <(stat -c '%u %a' -- "$p" 2>/dev/null) || return 1
  [[ $o == 0 || $o == "$(id -u)" ]] || return 1
  (( (8#$m & 8#022) == 0 )) || return 1
  printf '%s' "$p"
}
