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

die_effect() { jq -nc --arg e "$1" --arg effect "${2:-none}" '{ok:false,error:$e,effect:$effect}'; exit 0; }
die() { die_effect "$1" none; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq not found","effect":"none"}'; exit 0; }

port_busy() {
  local sockets
  sockets=$(ss -tlnH "sport = :$1" 2>/dev/null) || return 2
  [[ -n $sockets ]]
}
owns_port() {
  local sockets
  sockets=$(ss -tlnpH "sport = :$2" 2>/dev/null) || return 2
  grep -qF "pid=$1," <<<"$sockets"
}

target() {  # <pid> <start> <port>: validated, the process the scan listed, and still the socket's owner
  [[ $1 =~ ^[1-9][0-9]*$ && $2 =~ ^[1-9][0-9]*$ && $3 =~ ^[0-9]+$ ]] \
    && (( $1 > 1 && $3 > 0 && $3 < 65536 )) || die "invalid pid/start/port"
  proc check "$1" "$2" || die "pid $1 is no longer the process that was listed"
  owns_port "$1" "$3"; local owner_rc=$?
  (( owner_rc == 0 )) || {
    (( owner_rc == 2 )) && die "could not query attributed listening sockets"
    die "pid $1 no longer owns port $3"
  }
  proc check "$1" "$2" || die "pid $1 exited while its port ownership was checked"
}

cancel_restart() {  # <pid> <start> <log> <pidfile> <exit status>
  trap - TERM INT HUP
  proc end "$1" "$2" >/dev/null 2>&1 || true
  state_remove "$PORTAL_RUNTIME_DIR" "$3" "$4" >/dev/null 2>&1 || true
  exit "$5"
}

case "${1:-}" in
  pause|resume|stop|restart)
    lifecycle_mutation nowait /usr/bin/bash "$HERE/lifecycle.sh" "$@"
    ;;
esac

case "${1:-}" in
  pause|resume|stop)
    case $1 in pause) sig=STOP ;; resume) sig=CONT ;; stop) sig=TERM ;; esac
    target "${2:-}" "${3:-}" "${4:-}"
    proc signal "$2" "$3" "$sig" || die "could not $1 pid $2"
    [[ $1 == stop ]] && effect=stopped || effect=none
    jq -nc --arg effect "$effect" '{ok:true,effect:$effect}'
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
    jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' <<<"$argv_json" >/dev/null 2>&1 \
      || die "invalid command line recorded for pid $pid"
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
    proc_path="" exec_path=""
    for kv in "${envs[@]}"; do [[ $kv == PATH=* ]] && proc_path=${kv#PATH=}; done
    exec_path=$(PATH="${proc_path:-$PATH}" command -v "${argv[0]}" 2>/dev/null) || true
    [[ -z $exec_path && -x ${argv[0]} ]] && exec_path=${argv[0]}
    [[ -z $exec_path && -x $cwd/${argv[0]} ]] && exec_path=$cwd/${argv[0]}
    [[ -n $exec_path ]] && exec_path=$(readlink -f -- "$exec_path" 2>/dev/null)
    [[ -n $exec_path && -x $exec_path ]] || exec_path=$exe
    [[ -n $exec_path && -x $exec_path ]] || die "launcher not found: ${argv[0]}"

    proc signal "$pid" "$start" TERM || die "could not stop pid $pid"
    # Wait for the port to actually free before relaunching into EADDRINUSE.
    for ((i = 0; i < 25; i++)); do
      port_busy "$port"; busy_rc=$?
      (( busy_rc == 2 )) && die_effect "could not query port $port after stopping pid $pid" stopped
      (( busy_rc == 1 )) && break
      sleep 0.2
    done
    port_busy "$port"; busy_rc=$?
    (( busy_rc == 2 )) && die_effect "could not query port $port after stopping pid $pid" stopped
    (( busy_rc == 0 )) && die_effect "port $port did not free up" stopped

    restart_log=".restart-$port.log"; restart_pid=".restart-$port.pid"
    relaunched=$(
      if (( ${#envs[@]} > 0 )); then
        for v in $(compgen -e); do unset "$v"; done
        for kv in "${envs[@]}"; do [[ $kv =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && export "$kv"; done
      fi
      cd "$cwd" && state launch-tracked "$PORTAL_RUNTIME_DIR" "$restart_log" "$restart_pid" \
        --exec "$exec_path" -- "${argv[@]}"
    ) || die_effect "could not launch the replacement process" stopped
    read -r new_pid new_start <<<"$relaunched"
    [[ $new_pid =~ ^[1-9][0-9]*$ && $new_start =~ ^[1-9][0-9]*$ ]] && (( new_pid > 1 )) \
      || die_effect "the replacement process returned an invalid identity" stopped
    trap 'cancel_restart "$new_pid" "$new_start" "$restart_log" "$restart_pid" 143' TERM
    trap 'cancel_restart "$new_pid" "$new_start" "$restart_log" "$restart_pid" 130' INT
    trap 'cancel_restart "$new_pid" "$new_start" "$restart_log" "$restart_pid" 129' HUP
    # Report success only once the port is serving again; the relaunch is
    # detached, so give it a moment. An exec that failed leaves the port free.
    for ((i = 0; i < 50; i++)); do
      port_busy "$port"; busy_rc=$?
      (( busy_rc == 2 )) && die_effect "could not query port $port after restart" stopped
      (( busy_rc == 0 )) && break
      sleep 0.1
    done
    port_busy "$port"; busy_rc=$?
    (( busy_rc == 2 )) && die_effect "could not query port $port after restart" stopped
    (( busy_rc == 0 )) || die_effect "restart did not bring a listener back on port $port" stopped
    # The listener must be the relaunched service: anything else that grabbed
    # the port in the meantime is not a successful restart.
    restart_ok=""
    for lpid in $(ss -tlnpH "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\),.*/\1/p' | sort -u); do
      [[ $(ps -o sid= -p "$lpid" 2>/dev/null | tr -d ' ') == "$new_pid" ]] && { restart_ok=1; break; }
    done
    if [[ -z $restart_ok ]]; then
      proc end "$new_pid" "$new_start" >/dev/null 2>&1 || true
      die_effect "port $port is held by another process after restart" stopped
    fi
    state_remove "$PORTAL_RUNTIME_DIR" "$restart_log" "$restart_pid" \
      || die_effect "restart succeeded, but its temporary identity could not be cleared" restarted
    trap - TERM INT HUP
    echo '{"ok":true,"effect":"restarted"}'
    ;;
  *) echo '{"ok":false,"error":"usage: lifecycle.sh pause|resume|stop <pid> <start> <port> | restart <pid> <start> <port> <cwd> <argv-json>","effect":"none"}' ;;
esac
