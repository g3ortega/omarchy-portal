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
# the argv. Environment bytes travel over stdin and apply only at final exec,
# so target loader settings cannot affect Portal helpers or appear in argv.
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
  local sockets proc_rest row_attributed found=0
  sockets=$(ss -tlnpH "sport = :$2" 2>/dev/null) || return 2
  while read -r _ _ _ _ _ proc_rest; do
    row_attributed=0
    while [[ $proc_rest =~ pid=([0-9]+) ]]; do
      [[ ${BASH_REMATCH[1]} == "$1" ]] || return 1
      proc_rest=${proc_rest#*"${BASH_REMATCH[0]}"}
      row_attributed=1
    done
    (( row_attributed )) || return 1
    found=1
  done <<<"$sockets"
  (( found ))
}

target() {  # <pid> <start> <port>: validated, the process the scan listed, and still the socket's owner
  [[ $1 =~ ^[1-9][0-9]*$ && $2 =~ ^[1-9][0-9]*$ && $3 =~ ^[0-9]+$ ]] \
    && (( $1 > 1 && $3 > 0 && $3 < 65536 )) || die "invalid pid/start/port"
  proc check "$1" "$2" || die "pid $1 is no longer the process that was listed"
  owns_port "$1" "$3"; local owner_rc=$?
  (( owner_rc == 0 )) || {
    (( owner_rc == 2 )) && die "could not query attributed listening sockets"
    die "pid $1 no longer exclusively owns port $3"
  }
  proc check "$1" "$2" || die "pid $1 exited while its port ownership was checked"
}

read_restart_identity() {  # <pidfile>: 0 valid, 1 absent, 2 refused or malformed
  local name=$1 dump rc result
  # Match tunnels.sh's runtime entry cap; dump counts all leaves before filtering.
  dump=$(state dump "$PORTAL_RUNTIME_DIR" 128 4096 "$name" 2>/dev/null)
  rc=$?
  case $rc in 129|130|143) return "$rc" ;; 0) ;; *) return 2 ;; esac
  result=$(jq -r --arg name "$name" '
    if ((.refused // []) | index($name)) != null then "refused"
    elif ((.files // {}) | has($name) | not) then "absent"
    else .files[$name] as $value
      | if ($value | type) == "string"
          and (($value | contains("\u0000") or contains("\r") or contains("\n")) | not)
          and ($value | test("^(?:[2-9]|[1-9][0-9]{1,9}) [1-9][0-9]{0,19}$"))
          and (($value | split(" ")[0] | tonumber) <= 2147483647)
        then "valid\t" + $value
        else "invalid"
        end
    end
  ' <<<"$dump" 2>/dev/null)
  rc=$?
  case $rc in 129|130|143) return "$rc" ;; 0) ;; *) return 2 ;; esac
  case $result in
    valid$'\t'*) printf '%s' "${result#*$'\t'}" ;;
    absent) return 1 ;;
    *) return 2 ;;
  esac
}

cancel_restart() {  # <pidfile> <exit status>
  local identity rc pid start
  trap '' TERM INT HUP
  identity=$(read_restart_identity "$1"); rc=$?
  if (( rc == 0 )); then
    read -r pid start <<<"$identity"
    rollback_replacement "$pid" "$start" "$1" || true
  fi
  exit "$2"
}
group_alive() { (( ${1:-0} > 1 )) && kill -0 -- "-$1" 2>/dev/null; }   # <pid>: its process group still has members
rollback_replacement() {  # <pid> <start> <pidfile>: keep identity if stop cannot be proven
  if proc check "$1" "$2" >/dev/null 2>&1; then
    proc end "$1" "$2" >/dev/null 2>&1 || return 1
  elif group_alive "$1"; then
    return 1
  fi
  state_remove "$PORTAL_RUNTIME_DIR" "$3" >/dev/null 2>&1
}
fail_restart() {  # <pid> <start> <pidfile> <reason>: a replacement that cannot serve is never left half-owned
  trap '' TERM INT HUP
  rollback_replacement "$1" "$2" "$3" \
    || die_effect "$4; the replacement could not be closed out, so its identity record was kept" stopped
  die_effect "$4" stopped
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
    envs=(); mapfile -d '' envs < "/proc/$pid/environ" 2>/dev/null \
      || die "could not read the environment of pid $pid"
    { if (( ${#envs[@]} )); then printf '%s\0' "${envs[@]}"; fi; } | state check-env >/dev/null \
      || die "the environment of pid $pid cannot be restored exactly"
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null); exe=${exe% (deleted)}
    proc check "$pid" "$start" || die "pid $pid exited while its environment was read"
    # argv[0] may be absolute, on the process's own PATH, or relative to its
    # cwd (./bin/dev is common). It is resolved from that cwd, so a same-named
    # file in this helper's directory can never take its place, and a relative
    # PATH entry means what it meant to the process. Checked before touching it.
    proc_path="" exec_path=""
    for kv in "${envs[@]}"; do [[ $kv == PATH=* ]] && proc_path=${kv#PATH=}; done
    cand=$(cd "$cwd" 2>/dev/null && PATH="${proc_path:-$PATH}" command -v -- "${argv[0]}" 2>/dev/null) || true
    [[ -z $cand || $cand == /* ]] || cand="$cwd/$cand"
    [[ -n $cand ]] && cand=$(readlink -f -- "$cand" 2>/dev/null)
    [[ -n $cand && -f $cand && -x $cand ]] && exec_path=$cand
    [[ -z $exec_path && -n $exe ]] && exec_path=$exe
    [[ -n $exec_path && -x $exec_path ]] || die "launcher not found: ${argv[0]}"

    target "$pid" "$start" "$port"
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

    restart_pid=".restart-$port.pid"
    trap 'cancel_restart "$restart_pid" 143' TERM
    trap 'cancel_restart "$restart_pid" 130' INT
    trap 'cancel_restart "$restart_pid" 129' HUP
    (
      # Discarded output: nothing reads a restart's log, and unlinking one that
      # the replacement still holds would park a growing inode nowhere.
      cd "$cwd" && { if (( ${#envs[@]} )); then printf '%s\0' "${envs[@]}"; fi; } \
        | state launch-tracked "$PORTAL_RUNTIME_DIR" --discard-output "$restart_pid" \
          --env-stdin --exec "$exec_path" -- "${argv[@]}" >/dev/null
    )
    launch_rc=$?
    case $launch_rc in 129|130|143) cancel_restart "$restart_pid" "$launch_rc" ;; esac
    if (( launch_rc != 0 )); then
      identity=$(read_restart_identity "$restart_pid"); identity_rc=$?
      case $identity_rc in
        0)
          read -r new_pid new_start <<<"$identity"
          rollback_replacement "$new_pid" "$new_start" "$restart_pid" \
            || die_effect "could not launch the replacement process; its identity record was kept" stopped
          ;;
        2) die_effect "could not launch the replacement process; its unreadable identity record was kept" stopped ;;
        129|130|143) cancel_restart "$restart_pid" "$identity_rc" ;;
      esac
      die_effect "could not launch the replacement process" stopped
    fi
    identity=$(read_restart_identity "$restart_pid"); identity_rc=$?
    case $identity_rc in
      0) read -r new_pid new_start <<<"$identity" ;;
      1) die_effect "the replacement process left no identity record" stopped ;;
      2) die_effect "the replacement process left an invalid identity record; it was kept" stopped ;;
      129|130|143) cancel_restart "$restart_pid" "$identity_rc" ;;
    esac
    # Report success only once the port is serving again; the relaunch is
    # detached, so give it a moment. An exec that failed leaves the port free.
    for ((i = 0; i < 50; i++)); do
      port_busy "$port"; busy_rc=$?
      (( busy_rc == 2 )) && fail_restart "$new_pid" "$new_start" "$restart_pid" "could not query port $port after restart"
      (( busy_rc == 0 )) && break
      sleep 0.1
    done
    port_busy "$port"; busy_rc=$?
    (( busy_rc == 2 )) && fail_restart "$new_pid" "$new_start" "$restart_pid" "could not query port $port after restart"
    (( busy_rc == 0 )) || fail_restart "$new_pid" "$new_start" "$restart_pid" "restart did not bring a listener back on port $port"
    # The listener must be the relaunched service: anything else that grabbed
    # the port in the meantime is not a successful restart.
    restart_ok=""
    for lpid in $(ss -tlnpH "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\),.*/\1/p' | sort -u); do
      [[ $(ps -o sid= -p "$lpid" 2>/dev/null | tr -d ' ') == "$new_pid" ]] && { restart_ok=1; break; }
    done
    [[ -n $restart_ok ]] || fail_restart "$new_pid" "$new_start" "$restart_pid" "port $port is held by another process after restart"
    state_remove "$PORTAL_RUNTIME_DIR" "$restart_pid"; remove_rc=$?
    case $remove_rc in 129|130|143) cancel_restart "$restart_pid" "$remove_rc" ;; esac
    (( remove_rc == 0 )) \
      || die_effect "restart succeeded, but its temporary identity could not be cleared" restarted
    trap - TERM INT HUP
    echo '{"ok":true,"effect":"restarted"}'
    ;;
  *) echo '{"ok":false,"error":"usage: lifecycle.sh pause|resume|stop <pid> <start> <port> | restart <pid> <start> <port> <cwd> <argv-json>","effect":"none"}' ;;
esac
