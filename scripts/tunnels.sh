#!/bin/bash
# Detect available exposure providers, and start/stop them for a given port.
#
# Two different things live here, and the UI must not conflate them:
#
#   reach=public  the port becomes reachable from the internet  (cloudflared, ngrok)
#   reach=local   the port gets a nicer name on this machine only (portless)
#
# portless is a local reverse proxy that maps a port to a stable
# <name>.localhost URL. It does NOT publish anything. Labelling it as a tunnel
# would be a security lie, so it reports reach=local and the panel groups it
# separately.
#
# Provider knowledge lives in exactly two places: the PROVIDERS roster below,
# and one <name>_* function block per provider. reach is decided once, by
# provider_reach, and persisted next to each share's URL so status never has to
# re-derive it. Adding a provider = one roster line + one function block.
#
# The function block's slots, all optional except _status:
#   _status         readiness rung  ->  "state|detail|fix"
#   _argv           the arguments after the binary that start a tunnel for a port
#   _url_from_log   scrape the public URL out of that process's log
#   _setup          make an unready provider ready
#   _setup_clause   what _setup will do to the machine, for the confirmation
#   _adopt          emit "port<TAB>url" for shares this provider owns that
#                   Portal did not create (started from a terminal). cmd_status
#                   dispatches blind and does the dedup centrally, so an
#                   adopter never re-implements "already tracked?".
#   _stop_adopted   tear down one of those, given a port.
#
# Every tunnel runs in a session of its own so a plugin reload does not kill
# it, and is tracked by a pidfile (pid and kernel start time) under the
# runtime dir.

set -o pipefail
umask 077   # pidfiles, logs and URLs under the runtime dir are private

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portless.sh
source "$SCRIPT_DIR/lib/portless.sh"

# ---- provider roster ----------------------------------------------------------
# name:label:reach   (test/test.sh counts these rows)
PROVIDERS=(
  "cloudflared:Cloudflare:public"
  "ngrok:ngrok:public"
  "portless:Portless:local"
)

provider_reach() {
  local row
  for row in "${PROVIDERS[@]}"; do
    [[ ${row%%:*} == "$1" ]] && { printf '%s' "${row##*:}"; return 0; }
  done
  return 1
}
known_provider() { provider_reach "$1" >/dev/null; }

STATE_DIR="$PORTAL_RUNTIME_DIR"
LOG_CAP=4194304   # a provider's log is truncated past this; O_APPEND writers carry on
IDLE_CAP=600      # a public tunnel whose target has been gone this long is stopped
SHARE_FILES=(url reach dns idle log target pid)   # ownership records stay until cleanup reaches them
MAX_ROWS=512      # past this many tunnels, status reports an error, not a growing document
STATE_FILES_CAP=$((MAX_ROWS * (${#SHARE_FILES[@]} + 1)))

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
json_str() { jq -Rn --arg v "$1" '$v'; }
ok_json() { jq -nc --arg h "${1:-}" --arg c "${2:-}" '{ok:true} + (if $h == "" then {} else {hint:$h} end) + (if $c == "" then {} else {copy:$c} end)'; }
have() { command -v "$1" >/dev/null 2>&1; }
url_host() { local h=${1#*://}; h=${h%%/*}; printf '%s' "${h%%:*}"; }
# Provider output is untrusted: a tunnel log, an agent API, a routes file. A
# URL is accepted into a row (and later handed to xdg-open) only in this shape.
valid_url() { (( ${#1} <= 8192 )) && [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:][:cntrl:]]*)?$ ]]; }
valid_identity_line() {
  local pid start extra=""
  IFS=' ' read -r pid start extra <<<"$1"
  [[ $1 != *$'\n'* && $pid =~ ^[1-9][0-9]*$ && $start =~ ^[1-9][0-9]*$ && -z $extra ]] && (( pid > 1 ))
}
# A pid from a pidfile is only ours to signal if it is still the very process
# we launched: same comm and the same kernel start time, which no reused pid
# can reproduce. A pidfile under ~/.cache can outlive a reboot.
proc_start() {  # <pid>: the start-time field of /proc/<pid>/stat
  local s; { s=$(< "/proc/$1/stat"); } 2>/dev/null || return 1
  s=${s##*) }; set -- $s; printf '%s' "${20}"
}
owned_pid() {  # <pid> <name> [start]: the process is that program, and the same incarnation
  # The launcher executes by descriptor; kernels before 6.14 then name the
  # process after the descriptor number, so the executable itself also counts.
  local c e
  [[ $1 =~ ^[1-9][0-9]*$ ]] && { read -r c < "/proc/$1/comm"; } 2>/dev/null || return 1
  [[ $c == "$2" ]] || { e=$(readlink "/proc/$1/exe" 2>/dev/null); e=${e% (deleted)}; [[ ${e##*/} == "$2" ]]; } || return 1
  [[ -z ${3:-} || $(proc_start "$1") == "$3" ]]
}

# A provider binary, resolved once per process to a trusted absolute path.
# Readiness, adoption, start and stop all ask this, so they cannot disagree.
declare -A PROVIDER_BIN=()
provider_bin() {  # <name>
  if [[ -z ${PROVIDER_BIN[$1]+x} ]]; then
    augment_path
    PROVIDER_BIN[$1]=$(resolve_bin "$1") || PROVIDER_BIN[$1]=""
  fi
  [[ -n ${PROVIDER_BIN[$1]} ]] && printf '%s' "${PROVIDER_BIN[$1]}"
}

# The shell process does not inherit an interactive shell's PATH. Tools
# installed through a version manager (mise, nvm, volta, asdf) or into a user
# bin directory are invisible to it, so a provider that is plainly installed
# gets reported as missing. Called only by the commands that actually execute
# provider binaries — `status` runs every poll and needs none of this.
#
# The version-manager install globs are not redundant with the shims dir: mise
# only shims tools it has been told about (a global `npm install -g` binary
# lands in the node install's own bin, unshimmed).
augment_path() {
  local extra=(
    "$HOME/.local/bin"
    "$HOME/.bun/bin"
    "$HOME/.cargo/bin"
    "$HOME/.volta/bin"
    "$HOME/.asdf/shims"
    "$HOME/go/bin"
    /usr/local/bin
  )
  local d concrete=()
  for d in "$HOME"/.local/share/mise/installs/node/*/bin \
           "$HOME"/.local/share/mise/installs/bun/*/bin \
           "$HOME"/.nvm/versions/node/*/bin; do
    [[ -d $d ]] && concrete+=("$d")
  done
  for d in "${concrete[@]}"; do
    [[ ":$PATH:" != *":$d:"* ]] && PATH="$d:$PATH"
  done
  extra+=("$HOME/.local/share/mise/shims")
  for d in "${extra[@]}"; do
    [[ -d $d && ":$PATH:" != *":$d:"* ]] && PATH="$PATH:$d"
  done
  export PATH
}

# ---- per-provider blocks ------------------------------------------------------

cloudflared_status() {
  provider_bin cloudflared >/dev/null || { printf 'setup|Not installed — click installs the official build (or: sudo pacman -S cloudflared for repo signatures)|'; return; }
  printf 'ready|Quick tunnel, no account needed|'
}
cloudflared_argv() { printf '%s\n' tunnel --no-autoupdate --url "http://localhost:$1"; }
cloudflared_setup_clause() { printf 'a checksum-pinned release, into ~/.local/bin'; }
# pid<TAB>port for every cloudflared serving a local port, from its own argv.
# Both the adopter and the stopper read this, so they cannot disagree about
# what a command line means. Pids come from the caller when it already has a
# socket dump to name them; only the one-shot stop path pays for a /proc walk.
cloudflared_targets() {  # [pid...]
  local pid start line target
  for pid in ${*:-$(pgrep -x cloudflared 2>/dev/null)}; do
    line=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    [[ $line == *--url\ * ]] || continue
    target=${line#*--url }; target=${target%% *}
    start=$(proc_start "$pid") || continue
    valid_identity_line "$pid $start" && [[ ${target##*:} =~ ^[0-9]+$ ]] \
      && printf '%s\t%s\t%s\n' "$pid" "$start" "${target##*:}"
  done
}

# The quick tunnel's own hostname is words joined by dashes; the API host the
# log also mentions is not.
cloudflared_url_from_log() { cat_own "$1" "$LOG_CAP" | grep -m1 -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com'; }

NGROK_API_PORT="${NGROK_API_PORT:-4040}"
ngrok_status() {
  local ng; ng=$(provider_bin ngrok) || { printf 'missing|Install with: yay -S ngrok|'; return; }
  if "$ng" config check >/dev/null 2>&1; then
    printf 'ready|Authenticated|'
  else
    printf 'setup|Run: ngrok config add-authtoken <token>|'
  fi
}
ngrok_argv() { printf '%s\n' http "$1" --log stdout --log-format json; }
# The agent's local API. One home for the endpoint, its port, and its timeout.
# Every curl in this file starts with -q: a ~/.curlrc must not be able to add
# redirects, proxies or output files to the request.
ngrok_api_tunnels() {
  curl -q -s --max-time "${1:-0.4}" --max-redirs 0 --max-filesize 65536 \
    "http://127.0.0.1:$NGROK_API_PORT/api/tunnels" 2>/dev/null | head -c 65536
}

ngrok_url_from_log() { cat_own "$1" "$LOG_CAP" | grep -m1 -oP '"url":"\Khttps://[^"]+'; }

portless_status() {
  # Not installed is a setup state with a copyable command: the plugin never
  # runs a package manager itself.
  provider_bin portless >/dev/null || { printf 'setup|Local names need portless|npm install -g portless'; return; }
  if ! portless_probe; then
    printf 'setup|Local names are off|'
    return
  fi
  if ! portless_serving_routes; then
    # Live proxy, but blind to this user's routes — it was started from
    # another state directory (typically root's). Names silently 404 until
    # the proxy is restarted as a user-owned process.
    printf 'setup|Proxy is not reading your routes|%s' "$(portless_fix_cmd evict)"
    return
  fi
  if ! portless_clean_port; then
    # Works, but every URL carries :PORT — which defeats the point of naming.
    printf 'setup|Names carry :%s — bind 443 for clean URLs|%s' "$PROBE_PORT" "$(portless_fix_cmd)"
    return
  fi
  # A proxy serves the TLD set it was started with; a newly configured
  # suffix is dead until a restart adds it. The fix carries the union, so
  # existing .localhost names never break.
  local want_tld; want_tld=$(configured_tld)
  if ! portless_serves_tld "$want_tld"; then
    printf 'setup|Proxy does not serve .%s yet — restart adds it|%s' "$want_tld" "$(portless_fix_cmd)"
    return
  fi
  if ! tld_resolves; then
    # Routes would be created and then silently fail to resolve; the strip is
    # the copyable channel for the one-time resolver fix.
    printf 'setup|Names on .%s do not resolve yet|%s' "$want_tld" "$(tld_fix_cmd)"
    return
  fi
  printf 'ready|Proxy on port %s|' "$PROBE_PORT"
}

portless_setup() {
  local out entry title copy
  out=$("$SCRIPT_DIR/portless-setup.sh" run) || die "$(jq -r '.error // "portless setup failed"' <<<"$out" 2>/dev/null)"
  jq -e '.ok == true' <<<"$out" >/dev/null 2>&1 || die "$(jq -r '.error // "portless setup failed"' <<<"$out" 2>/dev/null)"
  entry=$(jq -r '.remaining[0] // empty' <<<"$out")
  # A remaining step carrying a command joins title and command with a unit
  # separator; the panel shows them as a card with a copy button.
  title=${entry%%$'\x1f'*}
  if [[ $entry == *$'\x1f'* ]]; then copy=${entry#*$'\x1f'}; ok_json "$title" "$copy"; else ok_json "$title"; fi
}

cloudflared_setup() {
  local iout
  iout=$("$SCRIPT_DIR/provider-install.sh" cloudflared) || die "$(jq -r '.error // "install failed"' <<<"$iout" 2>/dev/null)"
  if [[ $(jq -r '.ok' <<<"$iout") != true ]]; then
    die "$(jq -r '.error // "install failed"' <<<"$iout")"
  fi
  local note; note=$(jq -r '.note // empty' <<<"$iout")
  ok_json "${note:+installed: $note}"
}

ngrok_setup() {
  die "ngrok needs an authtoken: ngrok config add-authtoken <token>"
}
portless_setup_clause() { printf 'trusts your Portless CA in Chrome and Firefox and starts the proxy'; }

# The TLD names are composed under: the configured one when the live proxy
# serves it, else the proxy's primary. .localhost is the default on purpose:
# browsers hardcode *.localhost to loopback, so names resolve with zero
# configuration. Any other TLD needs the one-time resolver rule tld_fix_cmd
# hands out.
portless_tld() {
  local want; want=$(configured_tld)
  portless_serves_tld "$want" && { printf '%s' "$want"; return; }
  portless_running_tlds | head -1
}

# Build the URL portless actually serves, from its own state files. Scheme,
# port, and TLD all depend on how the proxy was started, so none can be assumed.
portless_route_url() { portless_host_url "$1.$(portless_tld)"; }

cmd_providers() {
  local portless_ok=1
  portless_state_load || portless_ok=0
  local row name label reach status detail fix pair tld clause tsv=""
  for row in "${PROVIDERS[@]}"; do
    IFS=: read -r name label reach <<<"$row"
    tld=""; clause=""
    if [[ $name == portless ]] && (( portless_ok == 0 )); then
      status=unavailable; detail="State could not be read safely"; fix=""
    else
      pair=$("${name}_status")
      IFS='|' read -r status detail fix <<<"$pair"
      [[ $name == portless ]] && tld=$(portless_tld)
      declare -f "${name}_setup_clause" >/dev/null && clause=$("${name}_setup_clause")
    fi
    tsv+="$name"$'\t'"$label"$'\t'"$status"$'\t'"$detail"$'\t'"$reach"$'\t'"$tld"$'\t'"$fix"$'\t'"$clause"$'\n'
  done
  printf '%s' "$tsv" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
    | {id: .[0], label: .[1], status: .[2], detail: .[3], reach: .[4], tld: .[5], fix: .[6], setupClause: .[7]})
    | {ok: true, providers: .}'
}

slug() { printf '%s' "$1" | tr -c 'a-zA-Z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//' | cut -c1-40; }

pidfile()   { printf '%s/%s-%s.pid'   "$STATE_DIR" "$1" "$2"; }
logfile()   { printf '%s/%s-%s.log'   "$STATE_DIR" "$1" "$2"; }
urlfile()   { printf '%s/%s-%s.url'   "$STATE_DIR" "$1" "$2"; }
namefile()  { printf '%s/%s-%s.name'  "$STATE_DIR" "$1" "$2"; }
reachfile() { printf '%s/%s-%s.reach' "$STATE_DIR" "$1" "$2"; }
dnsfile()   { printf '%s/%s-%s.dns'   "$STATE_DIR" "$1" "$2"; }   # exists while DNS is pending
idlefile()  { printf '%s/%s-%s.idle'  "$STATE_DIR" "$1" "$2"; }   # since when the target has been gone
targetfile(){ printf '%s/%s-%s.target' "$STATE_DIR" "$1" "$2"; }
clear_share() {
  local n=() s
  for s in "${SHARE_FILES[@]}"; do n+=("$1-$2.$s"); done
  state_remove "$STATE_DIR" "${n[@]}"
}
# Ending a tunnel means seeing it gone: TERM, a grace period, then KILL, and
# failure if it is still there, so a record is never cleared over a process
# that is still public. Both waits are in tenths of a second.
STOP_TERM_WAIT=50
STOP_KILL_WAIT=20
stop_line() {   # <"pid start"> <comm>: end the whole session the launcher created, not just its leader
  local pid start i sig; read -r pid start <<<"$1"
  valid_identity_line "$1" || return 2
  if ! alive_line "$1" "$2"; then
    group_alive "$pid" && return 1
    return 0
  fi
  # Gone only when both hold: the leader we launched is gone (by identity) and
  # its process group holds no members. A descendant that inherited the session
  # and ignores TERM keeps the group alive, so the leader's exit alone is not
  # proof the tunnel stopped. Process group signalling requires pid > 1;
  # pid 1 is init, and -1 signals all user processes.
  for sig in TERM KILL; do
    ! alive_line "$1" "$2" && ! group_alive "$pid" && return 0
    # The leader through a pidfd bound to that very process, then the whole
    # group by id (which also reaches descendants the leader left behind).
    proc signal "$pid" "$start" "$sig" 2>/dev/null
    if (( pid > 1 )); then
      kill -"$sig" -- "-$pid" 2>/dev/null
    fi
    local wait; [[ $sig == TERM ]] && wait=$STOP_TERM_WAIT || wait=$STOP_KILL_WAIT
    for ((i = 0; i < wait; i++)); do ! alive_line "$1" "$2" && ! group_alive "$pid" && return 0; sleep 0.1; done
  done
  return 1
}
# Whether the pidfile still says what a status snapshot said: a start since
# the snapshot wrote a new one, and that one is not the snapshot's to act on.
snapshot_current() { [[ $(cat_own "$(pidfile "$1" "$2")" 64) == "$3" ]]; }   # <provider> <port> <pidline>

alive_line() {  # <"pid start"> <comm>
  local pid start; read -r pid start <<<"$1"
  valid_identity_line "$1" || return 1
  owned_pid "$pid" "$2" "$start"
}
alive() { alive_line "$(cat_own "$1" 64)" "$2"; }   # <pidfile> <comm>
group_alive() { (( ${1:-0} > 1 )) && kill -0 -- "-$1" 2>/dev/null; }   # <pid>: its process group still has members

listener_identity() {  # <port>: one currently attributed listener as "pid start"
  local sockets pids pid start
  sockets=$(ss -tlnpH "sport = :$1" 2>/dev/null) || return 1
  pids=$(grep -oE 'pid=[0-9]+' <<<"$sockets" | cut -d= -f2 | sort -u)
  [[ $(grep -c . <<<"$pids") == 1 ]] || return 1
  pid=$pids; start=$(proc_start "$pid") || return 1
  valid_identity_line "$pid $start" || return 1
  proc check "$pid" "$start" >/dev/null 2>&1 || return 1
  printf '%s %s' "$pid" "$start"
}

target_owns_port() {  # <"pid start"> <port>, using the attributed status snapshot
  local pid start _state _rq _sq local_addr _peer procinfo socket_pid matched=0
  read -r pid start <<<"$1"
  proc check "$pid" "$start" >/dev/null 2>&1 || return 1
  if (( ! SOCKS_READY )); then
    SOCKS=$(ss -tlnpH 2>/dev/null) || return 2
    SOCKS_READY=1
  fi
  while read -r _state _rq _sq local_addr _peer procinfo; do
    [[ ${local_addr##*:} == "$2" ]] || continue
    [[ $procinfo == *pid=* ]] || return 1
    while read -r socket_pid; do
      [[ $socket_pid == "$pid" ]] || return 1
      matched=1
    done < <(grep -oE 'pid=[0-9]+' <<<"$procinfo" | cut -d= -f2)
  done <<<"$SOCKS"
  (( matched )) || return 1
  proc check "$pid" "$start" >/dev/null 2>&1
}

# A fresh public hostname is published a beat after it appears in the log.
# Any resolver asked before that caches the NXDOMAIN for the zone's negative
# TTL, the system's upstream included, so the record is confirmed through a
# resolver OUTSIDE the system's path before the system path is ever asked.
DOH_URL=""
DNS_QUERY_TIMEOUT=3
STATUS_DNS_BUDGET=6
dns_published() {  # <host> [timeout]
  local max_time="${2:-$DNS_QUERY_TIMEOUT}"
  (( max_time > 0 )) || return 1
  if [[ -z $DOH_URL ]]; then
    if resolvectl status 2>/dev/null | grep -qE '8\.8\.8\.8|8\.8\.4\.4|dns\.google'; then
      DOH_URL='https://1.1.1.1/dns-query'
    else
      DOH_URL='https://dns.google/resolve'
    fi
  fi
  curl -q -sf --max-time "$max_time" --proto =https --max-redirs 0 --max-filesize 16384 \
    "$DOH_URL?name=$1&type=A" -H 'accept: application/dns-json' 2>/dev/null \
    | head -c 16384 | jq -e '(.Answer // []) | length > 0' >/dev/null 2>&1
}
dns_resolves_here() {  # <host>: the system path answers; flush the stub once if not
  getent hosts "$1" >/dev/null 2>&1 && return 0
  resolvectl flush-caches >/dev/null 2>&1
  getent hosts "$1" >/dev/null 2>&1
}
# 0 = resolves locally, 1 = not yet (unpublished, or an upstream negative
# cache that clears with its TTL).
dns_gate() {  # <host>
  local host="$1" i
  getent hosts "$host" >/dev/null 2>&1 && return 0   # a re-shared static domain
  sleep 3   # the record never exists in the first seconds; asking then only poisons
  for ((i = 0; i < 12; i++)); do
    dns_published "$host" && { dns_resolves_here "$host"; return; }
    sleep 2
  done
  return 1
}

finish_start() {  # <provider> <port> <url> [hint]
  local reach; reach=$(provider_reach "$1")
  write_own "$(reachfile "$1" "$2")" "$reach" || return 1
  write_own "$(urlfile "$1" "$2")" "$3" || return 1
  jq -nc --arg u "$3" --arg r "$reach" --arg h "${4:-}" \
    '{ok:true,url:$u,reach:$r} + (if $h == "" then {} else {hint:$h} end)'
}

rollback_portless() {  # <port> <new name> <old name> <old marker: 0|1> <bin>
  local port="$1" new="$2" old="$3" old_owned="$4" bin="$5" current
  if [[ $new != "$old" ]]; then
    "$bin" alias --remove "$new" >/dev/null 2>&1 || true
    [[ -z $old ]] || "$bin" alias "$old" "$port" --force >/dev/null 2>&1 || return 1
  fi
  portless_state_load || return 1
  current=$(portless_route_name "$port")
  [[ $current == "$old" ]] || return 1
  if (( old_owned )); then
    write_own "$(namefile portless "$port")" "$old"
  else
    clear_share portless "$port" || return 1
    state_remove "$STATE_DIR" "portless-$port.name"
  fi
}

public_start_failed() {  # <provider> <port> <pidline> <reason>
  local provider="$1" port="$2" pidline="$3" reason="$4" rc
  stop_line "$pidline" "$provider"; rc=$?
  if (( rc == 0 )); then
    clear_share "$provider" "$port" \
      || die "$reason; the tunnel stopped, but its ownership records could not be cleared"
    die "$reason"
  elif (( rc == 2 )); then
    die "$reason; the tracked pid record is malformed, so its records were kept"
  fi
  die "$reason; the tunnel did not stop, so its ownership records were kept"
}

cancel_public_start() {  # <provider> <port> <pidline> <exit status>
  trap - TERM INT HUP
  if [[ -n $3 ]] && stop_line "$3" "$1"; then clear_share "$1" "$2" || true; fi
  exit "$4"
}

cmd_start_portless() {  # <port> <name>
  local port="$1" name="$2" out bin old old_owned=0
  bin=$(provider_bin portless) || die "portless is not installed as a trusted executable"
  portless_state_load || die "could not read Portless state safely"
  # A port holds one name; drop the previous alias on rename.
  local n; n=$(slug "${name:-port-$port}")
  [[ -n $n ]] || n="port-$port"
  if [[ -e $(namefile portless "$port") || -L $(namefile portless "$port") ]]; then
    old=$(cat_own "$(namefile portless "$port")" 256) \
      || die "the Portless name record for port $port cannot be read; it was kept"
    [[ -n $old ]] || die "the Portless name record for port $port is malformed; it was kept"
    old_owned=1
  else
    # A route this plugin did not create (portless run / CLI) still renames.
    old=$(portless_route_name "$port")
  fi
  write_own "$(namefile portless "$port")" "$n" || die "could not record the Portless name before creating it"
  if [[ -n $old && $old != "$n" ]] && ! "$bin" alias --remove "$old" >/dev/null 2>&1; then
    if (( old_owned )); then
      write_own "$(namefile portless "$port")" "$old" \
        || die "portless could not remove $old, and its name record could not be restored"
    else
      state_remove "$STATE_DIR" "portless-$port.name" \
        || die "portless could not remove $old, and the pending name record could not be cleared"
    fi
    die "portless could not remove the previous name $old"
  fi
  out=$("$bin" alias "$n" "$port" --force 2>&1 | head -c 4096) || {
    rollback_portless "$port" "$n" "$old" "$old_owned" "$bin" \
      && die "portless alias failed: ${out:0:200}"
    die "portless alias failed and rollback could not be verified; the name record was kept"
  }
  portless_state_load || {
    rollback_portless "$port" "$n" "$old" "$old_owned" "$bin" \
      && die "Portless state could not be read after creating the name; it was rolled back"
    die "Portless state could not be read after creating the name, and rollback could not be verified; the name record was kept"
  }
  [[ $(portless_route_name "$port") == "$n" ]] || {
    rollback_portless "$port" "$n" "$old" "$old_owned" "$bin" \
      && die "Portless did not record the requested name; it was rolled back"
    die "Portless did not record the requested name, and rollback could not be verified; the name record was kept"
  }
  local resolved; resolved=$(portless_route_url "$n")
  [[ -n $resolved ]] || resolved="https://$n.$(portless_tld)"

  # Route must be visible to the LIVE proxy and its host must resolve;
  # either failure comes back as a short outcome — the strip carries the
  # copyable fix, not the toast.
  local hint=""
  if portless_probe && ! portless_serving_routes; then
    hint="the proxy is not reading your routes — the strip has the fix"
  else
    local host; host=$(url_host "$resolved")
    getent hosts "$host" >/dev/null 2>&1 \
      || hint="$host does not resolve yet — the strip has the one-time fix"
  fi
  finish_start portless "$port" "$resolved" "$hint" || {
    rollback_portless "$port" "$n" "$old" "$old_owned" "$bin" \
      && die "could not record the Portless URL; the name was rolled back"
    die "could not record the Portless URL, and rollback could not be verified; the name record was kept"
  }
}

cmd_start() {  # <provider> <port> [name] [--target <pid> <start>]
  local provider="$1" port="$2" name="" target=""; shift 2
  while (( $# )); do
    case $1 in
      --target) (( $# >= 3 )) || die "invalid target identity"; target="$2 $3"; shift 3 ;;
      *) name="$1"; shift ;;
    esac
  done
  valid_port "$port" || die "invalid port"
  known_provider "$provider" || die "unknown provider"
  if [[ $provider == portless ]]; then cmd_start_portless "$port" "$name"; return; fi
  if [[ -n $target ]]; then
    valid_identity_line "$target" || die "invalid target identity"
  else
    target=$(listener_identity "$port") \
      || die "port $port has no single safely attributed listener to approve"
  fi
  local SOCKS="" SOCKS_READY=0 target_rc
  target_owns_port "$target" "$port"; target_rc=$?
  (( target_rc == 0 )) || {
    (( target_rc == 2 )) && die "could not query attributed listening sockets"
    die "port $port is no longer served by the approved process"
  }
  local bin; bin=$(provider_bin "$provider") || die "$provider is not installed as a trusted executable"

  local pf lf pidline existing_url
  pf=$(pidfile "$provider" "$port"); lf=$(logfile "$provider" "$port")
  if [[ -e $pf || -L $pf ]]; then
    pidline=$(cat_own "$pf" 64) || die "$provider on port $port has a pidfile that cannot be read; its records are kept"
    valid_identity_line "$pidline" || die "$provider on port $port has a malformed pidfile; its records are kept"
    if alive_line "$pidline" "$provider"; then
      existing_url=$(read_own "$(urlfile "$provider" "$port")" 8192)
      if valid_url "$existing_url"; then
        write_own "$(targetfile "$provider" "$port")" "$target" || die "could not bind the existing share to the approved process"
        state_remove "$STATE_DIR" "$provider-$port.idle" || die "could not clear the existing share's idle deadline"
        write_own "$(reachfile "$provider" "$port")" public || die "could not record the existing share's reach"
        jq -nc --arg u "$existing_url" '{ok:true,url:$u,reach:"public"}'
        return
      fi
      stop_line "$pidline" "$provider" || die "$provider on port $port has an incomplete start that did not stop; its records are kept"
    else
      stop_line "$pidline" "$provider" \
        || die "$provider on port $port has a dead leader but its process group remains; its records are kept"
    fi
  fi

  clear_share "$provider" "$port" || die "could not clear the previous $provider records"
  write_own "$(targetfile "$provider" "$port")" "$target" \
    || die "could not record the approved process before starting $provider"
  local argv=(); mapfile -t argv < <("${provider}_argv" "$port")
  trap 'cancel_public_start "$provider" "$port" "$pidline" 143' TERM
  trap 'cancel_public_start "$provider" "$port" "$pidline" 130' INT
  trap 'cancel_public_start "$provider" "$port" "$pidline" 129' HUP
  pidline=$(state launch-tracked "$STATE_DIR" "${lf##*/}" "${pf##*/}" -- "$bin" "${argv[@]}") || {
    trap - TERM INT HUP
    clear_share "$provider" "$port" || die "could not start $provider, and its pre-launch records could not be cleared"
    die "could not start $provider"
  }
  valid_identity_line "$pidline" \
    || die "$provider returned a malformed tracked pid; its ownership records were kept"

  # Poll the log for the public URL rather than blocking on the process.
  local url="" i
  for ((i = 0; i < 60; i++)); do
    sleep 0.5
    url=$("${provider}_url_from_log" "$lf")
    [[ -n $url ]] && break
    alive_line "$pidline" "$provider" || break
  done

  if [[ -z $url ]]; then
    local why; why=$(cat_own "$lf" "$LOG_CAP" | tail -c 400 | tr '\n' ' ')
    public_start_failed "$provider" "$port" "$pidline" "no URL after 30s: ${why:-provider produced no URL}"
  fi
  valid_url "$url" || public_start_failed "$provider" "$port" "$pidline" "$provider reported an unexpected URL"

  local host; host=$(url_host "$url")
  local hint=""
  if ! dns_gate "$host"; then
    # The row shows the URL as pending until status sees it resolve.
    write_own "$(dnsfile "$provider" "$port")" pending \
      || public_start_failed "$provider" "$port" "$pidline" "could not record pending DNS state"
    hint="$host is not in DNS yet — the row lights up when it resolves"
  fi
  finish_start "$provider" "$port" "$url" "$hint" \
    || public_start_failed "$provider" "$port" "$pidline" "could not record the active $provider share"
  trap - TERM INT HUP
}

cmd_stop() {
  local provider="$1" port="$2"
  known_provider "$provider" || die "unknown provider"
  valid_port "$port" || die "invalid port"
  local pidline bin
  if [[ $provider == portless ]]; then
    portless_state_load || die "could not read Portless state safely; its records are kept"
    local n nf; nf=$(namefile "$provider" "$port")
    if [[ -e $nf || -L $nf ]]; then
      n=$(cat_own "$nf" 256) || die "the Portless name record for port $port cannot be read; its records are kept"
      [[ -n $n ]] || die "the Portless name record for port $port is malformed; its records are kept"
    else
      n=$(portless_route_name "$port")
    fi
    if [[ -n $n ]]; then
      # The record of a name stays until Portless has actually let it go.
      bin=$(provider_bin portless) || die "portless is not installed as a trusted executable; the name $n is still registered"
      "$bin" alias --remove "$n" >/dev/null 2>&1 || die "portless could not remove the name $n"
      portless_state_load || die "Portless removed $n, but its state could not be verified; the records are kept"
      routes_json | jq -e --arg n "$n" 'any(.[]?; ((.hostname // "") | split(".")[0]) == $n)' >/dev/null 2>&1 \
        && die "Portless reported removing $n, but the route remains; the records are kept"
    fi
    state_remove "$STATE_DIR" "portless-$port.name" \
      || die "the Portless name was removed, but its ownership record could not be cleared"
  else
    local pf; pf=$(pidfile "$provider" "$port")
    if [[ -e $pf || -L $pf ]]; then
      # Ours: a pidfile that is present but unreadable (truncated, a planted
      # link) is a failure, not an invitation to adopt — its records stay.
      pidline=$(cat_own "$pf" 64)
      [[ -n $pidline ]] || die "$provider on port $port has a pidfile that cannot be read; its records are kept"
      valid_identity_line "$pidline" || die "$provider on port $port has a malformed pidfile; its records are kept"
      stop_line "$pidline" "$provider" || die "$provider on port $port did not stop; its records are kept"
    elif [[ -e $(urlfile "$provider" "$port") || -L $(urlfile "$provider" "$port") ]]; then
      die "$provider on port $port has an active record but no pidfile; its records are kept"
    elif [[ -e $(targetfile "$provider" "$port") || -L $(targetfile "$provider" "$port") ]]; then
      : # a pre-launch target with no pid has no provider process to stop
    elif declare -f "${provider}_stop_adopted" >/dev/null; then
      # Not ours to begin with: the provider knows how to end its own.
      "${provider}_stop_adopted" "$port" || die "$provider on port $port did not stop"
    fi
  fi
  clear_share "$provider" "$port" || die "$provider on port $port stopped, but its records could not be cleared"
  echo '{"ok":true}'
}

# Routes portless created on its own — `portless run`, `portless alias` from a
# terminal — live only in routes.json. They are names all the same.
portless_adopt() {
  # One hostname per port: a proxy serving several TLDs holds an alias under
  # each, so prefer the name under the TLD names are composed with.
  local rows rport rhost
  rows=$(routes_json | jq -r --arg tld ".$(portless_tld)" 'group_by(.port)
    | map(first(.[] | select(.hostname | endswith($tld))) // .[0])
    | .[] | [(.port|tostring), .hostname] | @tsv' 2>/dev/null)
  [[ -n $rows ]] || return 0
  # Only routes whose target is actually listening. The probe is the expensive
  # rung (a localhost TLS handshake), so it runs only once a candidate has
  # survived that filter; it memoizes.
  while IFS=$'\t' read -r rport rhost; do
    valid_port "$rport" && valid_tld "$rhost" || continue
    [[ $LIVE_PORTS == *" $rport "* ]] || continue
    portless_probe || return 0
    printf '%s\t%s\n' "$rport" "$(portless_host_url "$rhost")"
  done <<<"$rows"
}

# cloudflared started outside Portal: the local target sits in its argv
# (--url http://localhost:PORT) and a quick tunnel publishes its hostname on
# its own metrics endpoint (/quicktunnel) — the one port that pid listens on.
cloudflared_adopt() {
  provider_bin cloudflared >/dev/null || return 0   # not installed: no processes, no dump, no cost
  # A quick tunnel must be listening on its metrics port for us to learn its
  # hostname at all, so the attributed dump names every cloudflared worth
  # looking at — no process-table walk needed.
  [[ -n $SOCKS ]] || SOCKS=$(ss -tlnpH 2>/dev/null)
  local pids
  pids=$(grep -oP '"cloudflared",pid=\K[0-9]+' <<<"$SOCKS" | sort -u | tr '\n' ' ')
  [[ -n ${pids// /} ]] || return 0
  local targets; targets=$(cloudflared_targets $pids)
  [[ -n $targets ]] || return 0
  local cfpid cfstart tport mport qhost
  while IFS=$'\t' read -r cfpid cfstart tport; do
    mport=$(grep "pid=$cfpid," <<<"$SOCKS" | grep -oP '127\.0\.0\.1:\K[0-9]+' | head -1)
    [[ -n $mport ]] || continue
    qhost=$(curl -q -s --max-time 0.4 --max-redirs 0 --max-filesize 16384 "http://127.0.0.1:$mport/quicktunnel" 2>/dev/null \
      | head -c 16384 | jq -r '.hostname // empty' 2>/dev/null)
    [[ $qhost =~ ^[a-z0-9-]+\.trycloudflare\.com$ ]] || continue
    printf '%s\thttps://%s\n' "$tport" "$qhost"
  done <<<"$targets"
}

cloudflared_stop_adopted() {  # <port>
  local cfpid cfstart tport targets found=0 failed=0 i
  targets=$(cloudflared_targets)
  while IFS=$'\t' read -r cfpid cfstart tport; do
    [[ $tport == "$1" ]] || continue
    found=1
    if ! proc signal "$cfpid" "$cfstart" TERM >/dev/null 2>&1; then
      proc check "$cfpid" "$cfstart" >/dev/null 2>&1 && failed=1
      continue
    fi
    for ((i = 0; i < 25; i++)); do
      proc check "$cfpid" "$cfstart" >/dev/null 2>&1 || break
      sleep 0.1
    done
    proc check "$cfpid" "$cfstart" >/dev/null 2>&1 && failed=1
  done <<<"$targets"
  (( ! found || ! failed ))
}

# ngrok's agent (Portal-started or not) reports every live tunnel on its
# local API. Anything could be listening on that port (an ssh forward, a
# container), so only a socket the kernel attributes to our own ngrok counts.
ngrok_adopt() {
  [[ $LIVE_PORTS == *" $NGROK_API_PORT "* ]] || return 0
  [[ -n $SOCKS ]] || SOCKS=$(ss -tlnpH 2>/dev/null)
  # comm is settable with prctl, so pin the 4040 owner to the ngrok binary by
  # its executable, and accept only ngrok's own public hostnames — a hostile
  # same-uid process cannot then inject an arbitrary "your tunnel" URL.
  local apid; apid=$(grep -F ":$NGROK_API_PORT " <<<"$SOCKS" | grep -oP 'pid=\K[0-9]+' | head -1)
  [[ -n $apid ]] || return 0
  local nbin xe; nbin=$(provider_bin ngrok) || return 0
  xe=$(readlink "/proc/$apid/exe" 2>/dev/null); xe=${xe% (deleted)}
  [[ $xe == "$nbin" ]] || return 0
  ngrok_api_tunnels \
    | jq -r '.tunnels[]?
        | [( .config.addr | capture(":(?<p>[0-9]+)$").p ), .public_url ]
        | select(.[1] | test("^https://[a-z0-9-]+\\.(ngrok-free\\.app|ngrok\\.app|ngrok\\.io|ngrok-free\\.dev|ngrok\\.dev)(/|$)"))
        | @tsv' 2>/dev/null
}

ngrok_stop_adopted() {  # <port>
  local before after tname
  before=$(ngrok_api_tunnels 0.6) || return 1
  tname=$(jq -er --arg p ":$1" 'first(.tunnels[]? | select(.config.addr | endswith($p)) | .name | @uri) // ""' <<<"$before") \
    || return 1
  [[ -n $tname ]] || return 0
  if ! curl -q -fsS --max-time 2 --max-redirs 0 -X DELETE \
    "http://127.0.0.1:$NGROK_API_PORT/api/tunnels/$tname" >/dev/null 2>&1; then
    after=$(ngrok_api_tunnels 0.6) || return 1
    jq -e --arg p ":$1" 'all(.tunnels[]?; (.config.addr | endswith($p) | not))' <<<"$after" >/dev/null 2>&1
    return
  fi
  after=$(ngrok_api_tunnels 0.6) || return 1
  jq -e --arg p ":$1" 'all(.tunnels[]?; (.config.addr | endswith($p) | not))' <<<"$after" >/dev/null 2>&1
}

stop_reconciled_share() {  # <provider> <port> <reason>
  local out
  out=$(cmd_stop "$1" "$2")
  if jq -e '.ok == true' <<<"$out" >/dev/null 2>&1; then return 0; fi
  RECONCILE_STOP_ERROR="$3; $(jq -r '.error // "the share did not stop"' <<<"$out" 2>/dev/null)"
  return 1
}

reconcile_idle() {  # <provider> <port> <idle> <healthy:0|1> <now>
  local provider="$1" port="$2" idle="$3" healthy="$4" now="$5"
  if (( healthy )); then
    [[ -z $idle ]] || state_remove "$STATE_DIR" "$provider-$port.idle" \
      || die "could not clear the idle deadline for $provider on port $port"
    return 0
  fi
  if [[ -z $idle ]]; then
    if write_own "$(idlefile "$provider" "$port")" "$now"; then return 0; fi
    stop_reconciled_share "$provider" "$port" "could not record an idle deadline for $provider on port $port" \
      || die "$RECONCILE_STOP_ERROR"
    return 1
  fi
  [[ $idle =~ ^[0-9]+$ ]] && (( idle <= now )) \
    || die "$provider on port $port has an invalid idle deadline"
  if (( now - idle >= IDLE_CAP )); then
    stop_reconciled_share "$provider" "$port" "$provider on port $port reached its idle deadline" || return 0
    return 1
  fi
  return 0
}

cmd_status() {
  local dns_until=$((SECONDS + STATUS_DNS_BUDGET))
  # Runs every poll. State files first — one descriptor-relative dump of the
  # state directory, no PATH work, no provider binaries — then each provider's
  # _adopt, which is responsible for its own cheap bail.
  # One cheap socket dump answers "is anything on this port", which is all
  # most adopters need. Process attribution costs ~4x more (the kernel walks
  # /proc to name each socket's owner), so it is computed at most once, on
  # demand, by the one adopter that cannot work without it.
  # Live means reachable through localhost, which is what every tunnel and
  # the proxy target: a listener bound only to a LAN address does not count.
  command -v ss >/dev/null 2>&1 || die "ss not found"
  local ss_raw; ss_raw=$(ss -tlnH 2>/dev/null) || die "could not query listening sockets"
  local LIVE_PORTS=" " SOCKS="" SOCKS_READY=0 _l
  while read -r _ _ _ _l _; do
    case ${_l%:*} in 127.*|'*'|0.0.0.0|'[::]'|'[::1]'|'[::ffff:127.'*|::|::1) LIVE_PORTS+="${_l##*:} " ;; esac
  done <<<"$ss_raw"

  local portless_ok=1
  portless_state_load || portless_ok=0
  local dump tsv="" listed=" " now; printf -v now '%(%s)T' -1
  # An unreadable state directory is not an empty one: a tunnel that cannot be
  # listed cannot be cleaned up either, so the caller keeps its last snapshot.
  dump=$(state dump "$STATE_DIR" 8192 "$STATE_FILES_CAP" 2>/dev/null) || die "could not list Portal's state"
  local refused idle_refused portless_refused
  refused=$(jq -r '.refused[]? | select(test("^(cloudflared|ngrok)-[0-9]+\\.(pid|url|reach|dns|target)$"))' <<<"$dump" 2>/dev/null)
  idle_refused=$(jq -r '.refused[]? | select(test("^(cloudflared|ngrok)-[0-9]+\\.idle$"))' <<<"$dump" 2>/dev/null)
  portless_refused=$(jq -r '.refused[]? | select(test("^portless-[0-9]+\\.(url|reach|name)$"))' <<<"$dump" 2>/dev/null)
  [[ -z $portless_refused ]] || portless_ok=0
  [[ -z $refused ]] \
    || die "could not read Portal ownership state safely: $(tr '\n' ' ' <<<"$refused")"
  local partial_provider partial_port partial_out
  while IFS=$'\t' read -r partial_provider partial_port; do
    [[ -n $partial_provider ]] || continue
    partial_out=$(cmd_stop "$partial_provider" "$partial_port")
    jq -e '.ok == true' <<<"$partial_out" >/dev/null 2>&1 \
      || die "incomplete $partial_provider start on port $partial_port could not be reconciled: $(jq -r '.error // "stop failed"' <<<"$partial_out")"
  done < <(jq -r '.files as $f | ($f | keys[]) as $key
    | select($key | test("^(cloudflared|ngrok)-[0-9]+\\.(pid|target)$"))
    | ($key | sub("\\.(pid|target)$"; "")) as $base
    | select($f[$base + ".url"] == null) | $base' <<<"$dump" | sort -u | tr '-' '\t')
  # Fields are joined with a unit separator: a tab is IFS whitespace, so an
  # empty field between tabs would vanish and shift the ones after it.
  local provider port url reach pidline dns idle target target_present base target_rc healthy leader dns_left target_health
  while IFS=$'\x1f' read -r provider port url reach pidline dns idle target target_present; do
    valid_port "$port" && known_provider "$provider" || continue
    valid_url "$url" || die "$provider on port $port has a malformed URL record; its records were kept"
    base="$provider-$port"
    # A legacy share has no trustworthy process identity to migrate. Null
    # health keeps the display neutral; reconcile_idle gives it a fixed window
    # for explicit reapproval to write a target record.
    target_health=""
    # portless routes have no process of their own, but a route removed with
    # the portless CLI is gone all the same; everything else must be alive.
    if [[ $provider == portless ]]; then
      # Only when the Portless state was actually readable does an absent route
      # mean the name is gone; a refused read keeps the markers. Re-read before
      # deleting: an alias registered after this poll's snapshot must not lose
      # its markers to the stale one.
      if (( portless_ok )) && [[ -z $(portless_route_name "$port") ]]; then
        if ! portless_state_load; then
          portless_ok=0
        elif [[ -z $(portless_route_name "$port") ]]; then
          state_remove "$STATE_DIR" "$base".{url,reach,name} \
            || die "could not clear stale Portless records for port $port"
          continue
        fi
      fi
    else
      valid_identity_line "$pidline" \
        || die "$provider on port $port has a malformed pid record; its records were kept"
      alive_line "$pidline" "$provider" || {
        # Only this snapshot's records go: a start since then has written new ones.
        snapshot_current "$provider" "$port" "$pidline" || continue
        leader="${pidline%% *}"
        group_alive "$leader" \
          && die "$provider on port $port has a dead leader but its process group remains; its records were kept"
        clear_share "$provider" "$port" \
          || die "could not clear stale $provider records for port $port"
        continue
      }
      if grep -qxF "$base.idle" <<<"$idle_refused"; then
        snapshot_current "$provider" "$port" "$pidline" || continue
        stop_reconciled_share "$provider" "$port" "could not read the idle deadline for $provider on port $port" \
          || die "$RECONCILE_STOP_ERROR"
        continue
      fi
      # A log is read only while the URL is being minted; afterwards it only
      # grows. stat first: truncate is a helper process.
      if (( $(stat -c %s -- "$(logfile "$provider" "$port")" 2>/dev/null || echo 0) > LOG_CAP )); then
        state_truncate "$(logfile "$provider" "$port")" "$LOG_CAP" \
          || die "could not truncate the $provider log for port $port"
      fi
      healthy=0
      if [[ $target_present == 1 ]]; then
        valid_identity_line "$target" \
          || die "$provider on port $port has a malformed target record; its records were kept"
        target_owns_port "$target" "$port"; target_rc=$?
        if (( target_rc == 0 )); then healthy=1
        elif (( target_rc == 2 )); then die "could not query attributed listening sockets"
        fi
        (( healthy )) && target_health=true || target_health=false
      fi
      snapshot_current "$provider" "$port" "$pidline" || continue
      if [[ $target_present == 1 && $healthy == 0 && $LIVE_PORTS == *" $port "* ]]; then
        stop_reconciled_share "$provider" "$port" "a different process took port $port" \
          || die "$RECONCILE_STOP_ERROR"
        continue
      fi
      reconcile_idle "$provider" "$port" "$idle" "$healthy" "$now" || continue
    fi
    [[ -n $reach ]] || reach=$(provider_reach "$provider")
    # A share whose DNS was still pending at start is re-checked each poll,
    # off-path first, and stops being pending the moment the system resolves it.
    if [[ $dns == pending ]]; then
      dns_left=$((dns_until - SECONDS))
      (( dns_left > DNS_QUERY_TIMEOUT )) && dns_left=$DNS_QUERY_TIMEOUT
      if (( dns_left > 0 )) && dns_published "$(url_host "$url")" "$dns_left" \
          && dns_resolves_here "$(url_host "$url")"; then
        state_remove "$STATE_DIR" "$base.dns" || die "could not clear pending DNS state for $provider on port $port"
        dns=""
      fi
    fi
    tsv+="$provider"$'\t'"$port"$'\t'"$url"$'\t'"$reach"$'\t'"$dns"$'\t'"$target_health"$'\n'
    # One key shape for every provider, so adoption dedup is a single test.
    listed+="$provider:$port "
  done < <(jq -r 'def line1: split("\n")[0];
    def one_line: if contains("\n") then
      if endswith("\n") and ((rtrimstr("\n") | contains("\n")) | not) then rtrimstr("\n") else "!invalid" end
      else . end;
    .files | . as $f | to_entries[]
    | select(.key | test("^[a-z]+-[0-9]+\\.url$"))
    | (.key | sub("\\.url$"; "")) as $b
    | ($b | split("-")) as $p
    | [$p[0], $p[1], (.value | line1),
       (($f[$b + ".reach"] // "") | line1),
       (($f[$b + ".pid"] // "") | one_line),
       (if $f[$b + ".dns"] != null then "pending" else "" end),
       (($f[$b + ".idle"] // "") | one_line),
       (($f[$b + ".target"] // "") | one_line),
       (if $f[$b + ".target"] != null then "1" else "0" end)]
    | join("\u001f")' <<<"$dump")

  local row name aport aurl areach
  for row in "${PROVIDERS[@]}"; do
    name="${row%%:*}"; areach="${row##*:}"
    if [[ $name == portless ]] && (( portless_ok == 0 )); then continue; fi
    declare -f "${name}_adopt" >/dev/null || continue
    while IFS=$'\t' read -r aport aurl; do
      valid_port "$aport" && valid_url "$aurl" || continue
      [[ $listed == *" $name:$aport "* ]] && continue
      tsv+="$name"$'\t'"$aport"$'\t'"$aurl"$'\t'"$areach"$'\t'$'\t'$'\n'
      listed+="$name:$aport "
    done < <("${name}_adopt")
  done

  (( $(grep -c . <<<"$tsv") > MAX_ROWS )) && die "more than $MAX_ROWS tunnels"
  printf '%s' "$tsv" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
    | {provider: .[0], port: (.[1] | tonumber), url: .[2], reach: .[3], dns: (.[4] // ""),
       targetHealthy: (if .[5] == "true" then true elif .[5] == "false" then false else null end)})
    | {ok: true, tunnels: .}'
}

cmd_stop_all() {
  # Everything status would show, not just what has a state file — otherwise a
  # row you can stop on its own survives "stop everything". A stop that fails
  # keeps its records and is reported, so "stop everything" never claims a
  # tunnel it left running.
  local provider port out failed=() status_out
  status_out=$(cmd_status)
  jq -e .ok <<<"$status_out" >/dev/null 2>&1 || die "could not list tunnels; nothing was stopped"
  while IFS=$'\t' read -r provider port; do
    [[ -n $provider && $port =~ ^[0-9]+$ ]] || continue
    out=$(cmd_stop "$provider" "$port")
    jq -e .ok <<<"$out" >/dev/null 2>&1 || failed+=("$provider:$port $(jq -r .error <<<"$out")")
  done < <(jq -r '.tunnels[]? | [.provider, (.port|tostring)] | @tsv' <<<"$status_out")
  if (( ${#failed[@]} )); then
    jq -nc --args '{ok:false, error:("could not stop: " + ($ARGS.positional | join("; ")))}' "${failed[@]}"
  else echo '{"ok":true}'; fi
}

cmd_stop_own() {
  # Only what Portal created: anything with a url file, or a pidfile (a tunnel
  # still minting its URL). Adopted names and tunnels belong to whoever
  # started them and have neither. A stop that fails keeps its records and
  # is reported, so a caller can retry.
  local provider port out rows failed=() bad_markers
  rows=$(state dump "$STATE_DIR" 8192 "$STATE_FILES_CAP" 2>/dev/null) || die "could not list Portal's state; nothing was stopped"
  bad_markers=$(jq -r '.refused[]? | select(test("^(cloudflared|ngrok)-[0-9]+\\.(url|pid|target)$|^portless-[0-9]+\\.(url|name)$"))' <<<"$rows" 2>/dev/null)
  if [[ -n $bad_markers ]]; then
    die "cannot stop safely: ownership markers could not be read safely: $(tr '\n' ' ' <<<"$bad_markers")"
  fi
  while IFS=$'\t' read -r provider port; do
    out=$(cmd_stop "$provider" "$port")
    jq -e .ok <<<"$out" >/dev/null 2>&1 || failed+=("$provider:$port $(jq -r .error <<<"$out")")
  done < <(jq -r '.files | keys[]
    | select(test("^(cloudflared|ngrok)-[0-9]+\\.(url|pid|target)$|^portless-[0-9]+\\.(url|name)$"))
    | sub("\\.(url|pid|target|name)$"; "")' <<<"$rows" | sort -u | tr '-' '\t')
  if (( ${#failed[@]} )); then
    jq -nc --args '{ok:false, error:("could not stop: " + ($ARGS.positional | join("; ")))}' "${failed[@]}"
  else echo '{"ok":true}'; fi
}

# One-click remediation for a provider reporting status=setup. Only actions
# that are safe and unprivileged live here; anything needing a package install
# or a secret stays a printed instruction for the user to run themselves.
cmd_setup() {
  local provider="$1"
  known_provider "$provider" || die "unknown provider"
  [[ $provider != portless ]] || portless_state_load || die "could not read Portless state safely"
  augment_path   # exported: the setup engine is a child process
  declare -f "${provider}_setup" >/dev/null || die "no automatic setup for $provider"
  "${provider}_setup"
}

# Sourced (by the tests) for its functions only; run as a script for the CLI.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

have jq || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }

# A leading --tld applies to every subcommand: rungs judge against it, and
# start/stop compose names with it. Validation happens in configured_tld.
if [[ ${1:-} == --tld ]]; then
  export PORTAL_PORTLESS_TLD="${2:-}"
  shift 2
fi

case "${1:-}" in
  setup|start|stop|status|stop-all|stop-own)
    lifecycle_mutation nowait /usr/bin/bash "$SCRIPT_DIR/tunnels.sh" "$@"
    ;;
esac

# The runtime dir is verified once here for the commands that write; status
# verifies it through its own dump.
[[ ${1:-} == status || ${1:-} == providers ]] || own_dir "$STATE_DIR" || die "state directory is not a private directory of yours: $STATE_DIR"

case "${1:-}" in
  providers) cmd_providers ;;
  setup)     cmd_setup "${2:-}" ;;
  start)     cmd_start "${2:-}" "${3:-}" "${@:4}" ;;
  stop)      cmd_stop "${2:-}" "${3:-}" ;;
  status)    cmd_status ;;
  stop-all)  cmd_stop_all ;;
  stop-own)  cmd_stop_own ;;
  *) echo '{"ok":false,"error":"usage: tunnels.sh providers|setup <provider>|start <provider> <port> [name] [--target <pid> <start>]|stop <provider> <port>|status|stop-all|stop-own"}' ;;
esac
