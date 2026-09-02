#!/bin/bash
# Process lifecycle actions for a port's process. Everything here signals or
# re-executes processes the user already owns — kill(2) refuses cross-user
# signals, so there is no privilege to escalate and none is requested.
#
#   pause <pid> <port>                SIGSTOP (freeze; resume brings it back)
#   resume <pid> <port>               SIGCONT
#   stop <pid> <port>                 SIGTERM
#   restart <pid> <port> <cwd> <argv-json>
#
# Every action re-checks that <pid> still owns the listening socket on <port>
# before signalling: the pid was scanned seconds ago and may have been reused.
#
# restart re-executes the process's own exact argv (NUL-split by the scanner,
# passed as JSON) in its own cwd and with its own environment, read from
# /proc before the process is signalled — so a server started through a
# version manager's shell hook comes back the same way. No shell ever parses
# the argv, and the environment is applied with builtins, never on a command
# line where another user could read it.
set -o pipefail

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }

port_busy() { ss -tlnH "sport = :$1" 2>/dev/null | grep -q .; }
owns_port() { ss -tlnpH "sport = :$2" 2>/dev/null | grep -qF "pid=$1,"; }

target() {  # <pid> <port>: validated, and still the socket's owner
  [[ $1 =~ ^[1-9][0-9]*$ && $2 =~ ^[0-9]+$ ]] && (( $2 > 0 && $2 < 65536 )) || die "invalid pid/port"
  owns_port "$1" "$2" || die "pid $1 no longer owns port $2"
}

case "${1:-}" in
  pause|resume|stop)
    case $1 in pause) sig=STOP ;; resume) sig=CONT ;; stop) sig=TERM ;; esac
    target "${2:-}" "${3:-}"
    kill -"$sig" "$2" 2>/dev/null || die "could not $1 pid $2"
    echo '{"ok":true}'
    ;;
  restart)
    pid="${2:-}" port="${3:-}" cwd="${4:-}" argv_json="${5:-}"
    target "$pid" "$port"
    [[ -d $cwd ]] || die "working directory is gone: $cwd"
    # Rebuild the exact argv, NUL-separated so an argument may hold anything,
    # newlines included. jq validates; bash mapfile keeps each element intact —
    # no word splitting, no glob, no shell -c anywhere.
    mapfile -d '' argv < <(jq --raw-output0 '.[] | strings' <<<"$argv_json" 2>/dev/null)
    [[ ${#argv[@]} -gt 0 ]] || die "no command line recorded for pid $pid"
    # The process's environment and executable, while it still exists.
    envs=(); mapfile -d '' envs < "/proc/$pid/environ" 2>/dev/null
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null); exe=${exe% (deleted)}
    # argv[0] may be absolute, on the process's own PATH, or relative to its
    # cwd (./bin/dev is common); its executable is the fallback for a name
    # only a shell hook could resolve. Checked before touching the process.
    proc_path=""
    for kv in "${envs[@]}"; do [[ $kv == PATH=* ]] && proc_path=${kv#PATH=}; done
    if ! { PATH="${proc_path:-$PATH}" command -v "${argv[0]}" >/dev/null 2>&1 \
           || [[ -x ${argv[0]} || -x "$cwd/${argv[0]}" ]]; }; then
      [[ -x $exe ]] || die "launcher not found: ${argv[0]}"
      argv[0]=$exe
    fi

    kill -TERM "$pid" 2>/dev/null || die "could not stop pid $pid"
    # Wait for the port to actually free before relaunching into EADDRINUSE.
    for ((i = 0; i < 25; i++)); do
      port_busy "$port" || break
      sleep 0.2
    done
    port_busy "$port" && die "port $port did not free up"

    # setsid --fork double-forks: the intermediate exits at once and the server
    # reparents to init, so this script never owns a job to wait on and the
    # caller's pipe is released immediately. The subshell swaps in the
    # process's environment first; an empty environ (nothing readable) keeps
    # this script's.
    (
      if (( ${#envs[@]} > 0 )); then
        for v in $(compgen -e); do unset "$v"; done
        for kv in "${envs[@]}"; do [[ $kv =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && export "$kv"; done
      fi
      cd "$cwd" && exec setsid -f "${argv[@]}" >/dev/null 2>&1 </dev/null
    )
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":false,"error":"usage: lifecycle.sh pause|resume|stop <pid> <port> | restart <pid> <port> <cwd> <argv-json>"}' ;;
esac
