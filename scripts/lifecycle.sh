#!/bin/bash
# Process lifecycle actions for a port's process. Everything here signals or
# re-executes processes the user already owns — kill(2) refuses cross-user
# signals, so there is no privilege to escalate and none is requested.
#
#   pause <pid> <start> <port>        SIGSTOP (freeze; resume brings it back)
#   resume <pid> <start> <port>       SIGCONT
#   stop <pid> <start> <port>         SIGTERM
#   restart <pid> <start> <port> <cwd> <argv-json>
#           (cwd is what the scan saw; the process's live cwd is what is used)
#
# <start> is the kernel start time the scan saw (field 22 of /proc/<pid>/stat):
# pid and start time together name one process, so a pid reused since the
# scan is refused. Every action re-checks that identity and that the process
# still owns the listening socket on <port>, and signals through a pidfd
# bound to that same process (scripts/lib/proc.py), never a bare pid.
#
# restart re-executes the process's own exact argv (NUL-split by the scanner,
# passed as JSON) in its own cwd and with its own environment, read from
# /proc before the process is signalled — so a server started through a
# version manager's shell hook comes back the same way. No shell ever parses
# the argv, and the environment is applied with builtins, never on a command
# line where another user could read it.
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/files.sh
source "$HERE/lib/files.sh"

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }

port_busy() { ss -tlnH "sport = :$1" 2>/dev/null | grep -q .; }
owns_port() { ss -tlnpH "sport = :$2" 2>/dev/null | grep -qF "pid=$1,"; }

target() {  # <pid> <start> <port>: validated, the process the scan listed, and still the socket's owner
  [[ $1 =~ ^[1-9][0-9]*$ && $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] && (( $3 > 0 && $3 < 65536 )) || die "invalid pid/start/port"
  proc check "$1" "$2" || die "pid $1 is no longer the process that was listed"
  owns_port "$1" "$3" || die "pid $1 no longer owns port $3"
}

case "${1:-}" in
  pause|resume|stop)
    case $1 in pause) sig=STOP ;; resume) sig=CONT ;; stop) sig=TERM ;; esac
    target "${2:-}" "${3:-}" "${4:-}"
    proc signal "$2" "$3" "$sig" || die "could not $1 pid $2"
    echo '{"ok":true}'
    ;;
  restart)
    pid="${2:-}" start="${3:-}" port="${4:-}" cwd="${5:-}" argv_json="${6:-}"
    target "$pid" "$start" "$port"
    # The working directory and environment are read from the live process,
    # then its identity is checked again, so both belong to that process.
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || die "could not read the working directory of pid $pid"
    [[ -d $cwd ]] || die "working directory is gone: $cwd"
    # Rebuild the exact argv, NUL-separated so an argument may hold anything,
    # newlines included. jq validates; bash mapfile keeps each element intact —
    # no word splitting, no glob, no shell -c anywhere.
    mapfile -d '' argv < <(jq --raw-output0 '.[] | strings' <<<"$argv_json" 2>/dev/null)
    [[ ${#argv[@]} -gt 0 ]] || die "no command line recorded for pid $pid"
    # The process's environment and executable, while it still exists; the
    # identity is checked again afterwards, so what was read is that process's.
    envs=(); mapfile -d '' envs < "/proc/$pid/environ" 2>/dev/null
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null); exe=${exe% (deleted)}
    proc check "$pid" "$start" || die "pid $pid exited while its environment was read"
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

    proc signal "$pid" "$start" TERM || die "could not stop pid $pid"
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
      cd "$cwd" && exec /usr/bin/setsid -f "${argv[@]}" >/dev/null 2>&1 </dev/null
    )
    # Report success only once the port is serving again; the relaunch is
    # detached, so give it a moment. An exec that failed leaves the port free.
    for ((i = 0; i < 50; i++)); do port_busy "$port" && break; sleep 0.1; done
    port_busy "$port" || die "restart did not bring a listener back on port $port"
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":false,"error":"usage: lifecycle.sh pause|resume|stop <pid> <start> <port> | restart <pid> <start> <port> <cwd> <argv-json>"}' ;;
esac
