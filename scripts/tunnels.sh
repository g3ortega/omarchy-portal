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
#   _launch         start the process, echo its pid
#   _url_from_log   scrape the public URL out of that process's log
#   _setup          make an unready provider ready
#   _adopt          emit "port<TAB>url" for shares this provider owns that
#                   Portal did not create (started from a terminal). cmd_status
#                   dispatches blind and does the dedup centrally, so an
#                   adopter never re-implements "already tracked?".
#   _stop_adopted   tear down one of those, given a port.
#
# Every tunnel runs detached with setsid so a plugin reload does not kill it,
# and is tracked by a pidfile under the runtime dir.

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

STATE_DIR="${PORTAL_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/portal}"
LOG_CAP=4194304   # a provider's log is truncated past this; O_APPEND writers carry on

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
own_dir "$STATE_DIR" || die "state directory is not a private directory of yours: $STATE_DIR"
json_str() { jq -Rn --arg v "$1" '$v'; }
ok_json() { jq -nc --arg h "${1:-}" '{ok:true} + (if $h == "" then {} else {hint:$h} end)'; }
have() { command -v "$1" >/dev/null 2>&1; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }
url_host() { local h=${1#*://}; h=${h%%/*}; printf '%s' "${h%%:*}"; }
# Provider output is untrusted: a tunnel log, an agent API, a routes file. A
# URL is accepted into a row (and later handed to xdg-open) only in this shape.
valid_url() { [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$ ]]; }
# A pid from a pidfile is only ours to signal if it is still the very process
# we launched: same comm and the same kernel start time, which no reused pid
# can reproduce. A pidfile under ~/.cache can outlive a reboot.
proc_start() {  # <pid>: the start-time field of /proc/<pid>/stat
  local s; s=$(< "/proc/$1/stat") 2>/dev/null || return 1
  s=${s##*) }; set -- $s; printf '%s' "${20}"
}
owned_pid() {  # <pid> <comm> [start]
  local c
  [[ $1 =~ ^[1-9][0-9]*$ ]] && read -r c < "/proc/$1/comm" 2>/dev/null && [[ $c == "$2" ]] || return 1
  [[ -z ${3:-} || $(proc_start "$1") == "$3" ]]
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
    "$HOME/.local/share/mise/shims"
    "$HOME/.bun/bin"
    "$HOME/.cargo/bin"
    "$HOME/.volta/bin"
    "$HOME/.asdf/shims"
    "$HOME/go/bin"
    /usr/local/bin
  )
  local d
  for d in "$HOME"/.local/share/mise/installs/node/*/bin \
           "$HOME"/.local/share/mise/installs/bun/*/bin \
           "$HOME"/.nvm/versions/node/*/bin; do
    [[ -d $d ]] && extra+=("$d")
  done
  for d in "${extra[@]}"; do
    [[ -d $d && ":$PATH:" != *":$d:"* ]] && PATH="$PATH:$d"
  done
  export PATH
}

# ---- per-provider blocks ------------------------------------------------------

cloudflared_status() {
  have cloudflared || { printf 'setup|Not installed — click installs the official build (or: sudo pacman -S cloudflared for repo signatures)|'; return; }
  printf 'ready|Quick tunnel, no account needed|'
}
# Launchers print "pid starttime"; the helper gives the daemon its own session
# and a fresh private log, and PROVIDER_BIN is the resolved absolute path.
cloudflared_launch() { state launch "$STATE_DIR" "${2##*/}" -- "$PROVIDER_BIN" tunnel --no-autoupdate --url "http://localhost:$1"; }
# pid<TAB>port for every cloudflared serving a local port, from its own argv.
# Both the adopter and the stopper read this, so they cannot disagree about
# what a command line means. Pids come from the caller when it already has a
# socket dump to name them; only the one-shot stop path pays for a /proc walk.
cloudflared_targets() {  # [pid...]
  local pid line target
  for pid in ${*:-$(pgrep -x cloudflared 2>/dev/null)}; do
    line=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    [[ $line == *--url\ * ]] || continue
    target=${line#*--url }; target=${target%% *}
    [[ ${target##*:} =~ ^[0-9]+$ ]] && printf '%s\t%s\n' "$pid" "${target##*:}"
  done
}

cloudflared_url_from_log() { cat_own "$1" "$LOG_CAP" | grep -m1 -oE 'https://[a-z0-9-]+\.trycloudflare\.com'; }

NGROK_API_PORT="${NGROK_API_PORT:-4040}"
ngrok_status() {
  have ngrok || { printf 'missing|Install with: yay -S ngrok|'; return; }
  # `ngrok config check` execs the full binary; memoize a pass against the
  # config file's mtime so the 30s poll stops paying for it.
  local cfg="${NGROK_CONFIG:-$HOME/.config/ngrok/ngrok.yml}" cache="$STATE_DIR/ngrok.ok"
  local mt; mt=$(stat -c %Y "$cfg" 2>/dev/null || echo 0)
  if [[ $(read_own "$cache" 64) == "$mt" ]]; then
    printf 'ready|Authenticated|'; return
  fi
  if ngrok config check >/dev/null 2>&1; then
    write_own "$cache" "$mt"
    printf 'ready|Authenticated|'
  else
    state_remove "$STATE_DIR" ngrok.ok
    printf 'setup|Run: ngrok config add-authtoken <token>|'
  fi
}
ngrok_launch() { state launch "$STATE_DIR" "${2##*/}" -- "$PROVIDER_BIN" http "$1" --log stdout --log-format json; }
# The agent's local API. One home for the endpoint, its port, and its timeout.
# Every curl in this file starts with -q: a ~/.curlrc must not be able to add
# redirects, proxies or output files to a reviewed request.
ngrok_api_tunnels() {
  curl -q -s --max-time "${1:-0.4}" --max-redirs 0 --max-filesize 65536 \
    "http://127.0.0.1:$NGROK_API_PORT/api/tunnels" 2>/dev/null | head -c 65536
}

ngrok_url_from_log() { cat_own "$1" "$LOG_CAP" | grep -m1 -oP '"url":"\Khttps://[^"]+'; }

portless_status() {
  # Not installed is a setup state with a copyable command: the plugin never
  # runs a package manager itself.
  have portless || { printf 'setup|Local names need portless|npm install -g portless'; return; }
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
  local out
  out=$("$SCRIPT_DIR/portless-setup.sh" run)
  ok_json "$(jq -r '.remaining[0] // empty' <<<"$out")"
}

cloudflared_setup() {
  local iout
  iout=$("$SCRIPT_DIR/provider-install.sh" cloudflared)
  if [[ $(jq -r '.ok' <<<"$iout") != true ]]; then
    die "$(jq -r '.error // "install failed"' <<<"$iout")"
  fi
  local note; note=$(jq -r '.note // empty' <<<"$iout")
  ok_json "${note:+installed: $note}"
}

ngrok_setup() {
  die "ngrok needs an authtoken: ngrok config add-authtoken <token>"
}

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

# ---- commands -----------------------------------------------------------------

cmd_providers() {
  augment_path
  local row name label reach status detail fix pair tld tsv=""
  for row in "${PROVIDERS[@]}"; do
    IFS=: read -r name label reach <<<"$row"
    pair=$("${name}_status")
    IFS='|' read -r status detail fix <<<"$pair"
    tld=""
    [[ $name == portless ]] && tld=$(portless_tld)
    tsv+="$name"$'\t'"$label"$'\t'"$status"$'\t'"$detail"$'\t'"$reach"$'\t'"$tld"$'\t'"$fix"$'\n'
  done
  printf '%s' "$tsv" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
    | {id: .[0], label: .[1], status: .[2], detail: .[3], reach: .[4], tld: .[5], fix: .[6]})
    | {ok: true, providers: .}'
}

slug() { printf '%s' "$1" | tr -c 'a-zA-Z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//' | cut -c1-40; }

pidfile()   { printf '%s/%s-%s.pid'   "$STATE_DIR" "$1" "$2"; }
logfile()   { printf '%s/%s-%s.log'   "$STATE_DIR" "$1" "$2"; }
urlfile()   { printf '%s/%s-%s.url'   "$STATE_DIR" "$1" "$2"; }
namefile()  { printf '%s/%s-%s.name'  "$STATE_DIR" "$1" "$2"; }
reachfile() { printf '%s/%s-%s.reach' "$STATE_DIR" "$1" "$2"; }
dnsfile()   { printf '%s/%s-%s.dns'   "$STATE_DIR" "$1" "$2"; }   # exists while DNS is pending

alive() {  # <pidfile> <comm>: the pidfile holds "pid start"
  local pid start
  read -r pid start <<<"$(read_own "$1" 64)"
  owned_pid "$pid" "$2" "$start"
}

# A fresh public hostname is published a beat after it appears in the log.
# Any resolver asked before that caches the NXDOMAIN for the zone's negative
# TTL, the system's upstream included, so the record is confirmed through a
# resolver OUTSIDE the system's path before the system path is ever asked.
DOH_URL=""
dns_published() {  # <host>
  if [[ -z $DOH_URL ]]; then
    if resolvectl status 2>/dev/null | grep -qE '8\.8\.8\.8|8\.8\.4\.4|dns\.google'; then
      DOH_URL='https://1.1.1.1/dns-query'
    else
      DOH_URL='https://dns.google/resolve'
    fi
  fi
  curl -q -sf --max-time 3 --proto =https --max-redirs 0 --max-filesize 16384 \
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
  write_own "$(urlfile "$1" "$2")" "$3"
  write_own "$(reachfile "$1" "$2")" "$reach"
  jq -nc --arg u "$3" --arg r "$reach" --arg h "${4:-}" \
    '{ok:true,url:$u,reach:$r} + (if $h == "" then {} else {hint:$h} end)'
}

cmd_start_portless() {  # <port> <name>
  local port="$1" name="$2" out
  # A port holds one name; drop the previous alias on rename.
  local n; n=$(slug "${name:-port-$port}")
  [[ -n $n ]] || n="port-$port"
  local old; old=$(read_own "$(namefile portless "$port")" 256)
  if [[ -z $old ]]; then
    # A route this plugin did not create (portless run / CLI) still renames.
    old=$(portless_route_name "$port")
  fi
  [[ -n $old && $old != "$n" ]] && "$PROVIDER_BIN" alias --remove "$old" >/dev/null 2>&1
  out=$("$PROVIDER_BIN" alias "$n" "$port" --force 2>&1 | head -c 4096) || die "portless alias failed: ${out:0:200}"
  write_own "$(namefile portless "$port")" "$n"
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
  finish_start portless "$port" "$resolved" "$hint"
}

cmd_start() {
  local provider="$1" port="$2" name="$3"
  valid_port "$port" || die "invalid port"
  known_provider "$provider" || die "unknown provider"
  augment_path
  PROVIDER_BIN=$(resolve_bin "$provider") || die "$provider is not installed as a trusted executable"

  if [[ $provider == portless ]]; then cmd_start_portless "$port" "$name"; return; fi

  local pf lf
  pf=$(pidfile "$provider" "$port"); lf=$(logfile "$provider" "$port")
  if alive "$pf" "$provider"; then
    jq -nc --arg u "$(read_own "$(urlfile "$provider" "$port")" 8192)" '{ok:true,url:$u}'
    return
  fi

  state_remove "$STATE_DIR" "$provider-$port".{pid,url,reach,dns}
  local pidline; pidline=$("${provider}_launch" "$port" "$lf") || die "could not start $provider"
  write_own "$pf" "$pidline"

  # Poll the log for the public URL rather than blocking on the process.
  local url="" i
  for i in $(seq 1 60); do
    sleep 0.5
    url=$("${provider}_url_from_log" "$lf")
    [[ -n $url ]] && break
    alive "$pf" "$provider" || break
  done

  if [[ -z $url ]]; then
    local why; why=$(cat_own "$lf" "$LOG_CAP" | tail -c 400 | tr '\n' ' ')
    alive "$pf" "$provider" || state_remove "$STATE_DIR" "$provider-$port.pid"
    die "no URL after 30s: ${why:-see $lf}"
  fi
  valid_url "$url" || die "$provider reported an unexpected URL; see $lf"

  local host; host=$(url_host "$url")
  local hint=""
  if ! dns_gate "$host"; then
    # The row shows the URL as pending until status sees it resolve.
    write_own "$(dnsfile "$provider" "$port")" pending
    hint="$host is not in DNS yet — the row lights up when it resolves"
  fi
  finish_start "$provider" "$port" "$url" "$hint"
}

cmd_stop() {
  local provider="$1" port="$2" pid
  known_provider "$provider" || die "unknown provider"
  valid_port "$port" || die "invalid port"
  if [[ $provider == portless ]]; then
    augment_path
    local n; n=$(read_own "$(namefile "$provider" "$port")" 256)
    [[ -n $n ]] || n=$(portless_route_name "$port")
    if [[ -n $n ]]; then
      PROVIDER_BIN=$(resolve_bin portless) || die "portless is not installed as a trusted executable"
      "$PROVIDER_BIN" alias --remove "$n" >/dev/null 2>&1
    fi
    state_remove "$STATE_DIR" "portless-$port.name"
  elif own_file "$(pidfile "$provider" "$port")"; then
    local start; read -r pid start <<<"$(read_own "$(pidfile "$provider" "$port")" 64)"
    # Kill the whole session the launcher created, not just the leader.
    owned_pid "$pid" "$provider" "$start" && { kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; }
  elif declare -f "${provider}_stop_adopted" >/dev/null; then
    # Not ours to begin with: the provider knows how to end its own.
    "${provider}_stop_adopted" "$port"
  fi
  state_remove "$STATE_DIR" "$provider-$port".{pid,url,reach,dns,idle}
  echo '{"ok":true}'
}

# Routes portless created on its own — `portless run`, `portless alias` from a
# terminal — live only in routes.json. They are names all the same.
portless_adopt() {
  own_file "$PORTLESS_DIR/routes.json" || return 0
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
  # Not installed: no processes, no dump, no cost. status never augments PATH,
  # so the installer's own destination is checked by hand.
  have cloudflared || [[ -x $HOME/.local/bin/cloudflared ]] || return 0
  # A quick tunnel must be listening on its metrics port for us to learn its
  # hostname at all, so the attributed dump names every cloudflared worth
  # looking at — no process-table walk needed.
  [[ -n $SOCKS ]] || SOCKS=$(ss -tlnpH 2>/dev/null)
  local pids
  pids=$(grep -oP '"cloudflared",pid=\K[0-9]+' <<<"$SOCKS" | sort -u | tr '\n' ' ')
  [[ -n ${pids// /} ]] || return 0
  local targets; targets=$(cloudflared_targets $pids)
  [[ -n $targets ]] || return 0
  local cfpid tport mport qhost
  while IFS=$'\t' read -r cfpid tport; do
    mport=$(grep "pid=$cfpid," <<<"$SOCKS" | grep -oP '127\.0\.0\.1:\K[0-9]+' | head -1)
    [[ -n $mport ]] || continue
    qhost=$(curl -q -s --max-time 0.4 --max-redirs 0 --max-filesize 16384 "http://127.0.0.1:$mport/quicktunnel" 2>/dev/null \
      | head -c 16384 | jq -r '.hostname // empty' 2>/dev/null)
    [[ $qhost =~ ^[a-z0-9-]+\.trycloudflare\.com$ ]] || continue
    printf '%s\thttps://%s\n' "$tport" "$qhost"
  done <<<"$targets"
}

cloudflared_stop_adopted() {  # <port>
  local cfpid tport
  while IFS=$'\t' read -r cfpid tport; do
    [[ $tport == "$1" ]] && kill -TERM "$cfpid" 2>/dev/null
  done < <(cloudflared_targets)
  return 0
}

# ngrok's agent (Portal-started or not) reports every live tunnel on its
# local API. Anything could be listening on that port (an ssh forward, a
# container), so only a socket the kernel attributes to our own ngrok counts.
ngrok_adopt() {
  [[ $LIVE_PORTS == *" $NGROK_API_PORT "* ]] || return 0
  [[ -n $SOCKS ]] || SOCKS=$(ss -tlnpH 2>/dev/null)
  grep -F ":$NGROK_API_PORT " <<<"$SOCKS" | grep -qF '"ngrok",pid=' || return 0
  ngrok_api_tunnels \
    | jq -r '.tunnels[]? | [( .config.addr | capture(":(?<p>[0-9]+)$").p ), .public_url] | @tsv' 2>/dev/null
}

ngrok_stop_adopted() {  # <port>
  local tname
  tname=$(ngrok_api_tunnels 0.6 \
    | jq -r --arg p ":$1" 'first(.tunnels[]? | select(.config.addr | endswith($p)) | .name | @uri) // empty')
  [[ -n $tname ]] && curl -q -s --max-time 2 --max-redirs 0 -X DELETE "http://127.0.0.1:$NGROK_API_PORT/api/tunnels/$tname" >/dev/null 2>&1
  return 0
}

IDLE_CAP=600   # a public tunnel whose target has been gone this long is stopped

cmd_status() {
  # Runs every poll. State files first — one descriptor-relative dump of the
  # state directory, no PATH work, no provider binaries — then each provider's
  # _adopt, which is responsible for its own cheap bail.
  # One cheap socket dump answers "is anything on this port", which is all
  # most adopters need. Process attribution costs ~4x more (the kernel walks
  # /proc to name each socket's owner), so it is computed at most once, on
  # demand, by the one adopter that cannot work without it.
  local LIVE_PORTS=" " SOCKS="" _l
  while read -r _ _ _ _l _; do LIVE_PORTS+="${_l##*:} "; done < <(ss -tlnH 2>/dev/null)

  local dump tsv="" listed=" " now; printf -v now '%(%s)T' -1
  dump=$(state_dump "$STATE_DIR" 8192)
  local provider port url reach pidline dns idle base pid start
  while IFS=$'\t' read -r provider port url reach pidline dns idle; do
    valid_port "$port" && valid_url "$url" && known_provider "$provider" || continue
    base="$provider-$port"
    # portless routes have no process of their own, but a route removed with
    # the portless CLI is gone all the same; everything else must be alive.
    if [[ $provider == portless ]]; then
      [[ -n $(portless_route_name "$port") ]] || { state_remove "$STATE_DIR" "$base".{url,name,reach}; continue; }
    else
      read -r pid start <<<"$pidline"
      owned_pid "$pid" "$provider" "$start" || { state_remove "$STATE_DIR" "$base".{url,pid,reach,dns,idle}; continue; }
      # A log is read only while the URL is being minted; afterwards it only grows.
      if (( $(stat -c %s -- "$STATE_DIR/$base.log" 2>/dev/null || echo 0) > LOG_CAP )); then state_truncate "$STATE_DIR/$base.log" "$LOG_CAP"; fi
      # A public tunnel whose target is gone stays up for a while (a restart
      # should not lose the URL), then fails closed: whatever binds that port
      # next must not inherit the exposure.
      if [[ $LIVE_PORTS == *" $port "* ]]; then
        [[ -n $idle ]] && state_remove "$STATE_DIR" "$base.idle"
      elif [[ -z $idle ]]; then
        write_own "$STATE_DIR/$base.idle" "$now"
      elif [[ $idle =~ ^[0-9]+$ ]] && (( now - idle > IDLE_CAP )); then
        cmd_stop "$provider" "$port" >/dev/null; continue
      fi
    fi
    [[ -n $reach ]] || reach=$(provider_reach "$provider")
    # A share whose DNS was still pending at start is re-checked each poll,
    # off-path first, and stops being pending the moment the system resolves it.
    if [[ $dns == pending ]]; then
      if dns_published "$(url_host "$url")" && dns_resolves_here "$(url_host "$url")"; then state_remove "$STATE_DIR" "$base.dns"; dns=""; fi
    fi
    tsv+="$provider"$'\t'"$port"$'\t'"$url"$'\t'"$reach"$'\t'"$dns"$'\n'
    # One key shape for every provider, so adoption dedup is a single test.
    listed+="$provider:$port "
  done < <(jq -r '.files as $f | $f | to_entries[]
    | select(.key | test("^[a-z]+-[0-9]+\\.url$"))
    | (.key | sub("\\.url$"; "")) as $b
    | ($b | split("-")) as $p
    | [$p[0], $p[1], (.value | split("\n")[0]),
       (($f[$b + ".reach"] // "") | split("\n")[0]),
       (($f[$b + ".pid"] // "") | split("\n")[0]),
       (if $f[$b + ".dns"] != null then "pending" else "" end),
       (($f[$b + ".idle"] // "") | split("\n")[0])]
    | @tsv' <<<"$dump")

  local row name aport aurl areach
  for row in "${PROVIDERS[@]}"; do
    name="${row%%:*}"; areach="${row##*:}"
    declare -f "${name}_adopt" >/dev/null || continue
    while IFS=$'\t' read -r aport aurl; do
      valid_port "$aport" && valid_url "$aurl" || continue
      [[ $listed == *" $name:$aport "* ]] && continue
      tsv+="$name"$'\t'"$aport"$'\t'"$aurl"$'\t'"$areach"$'\t'$'\n'
      listed+="$name:$aport "
    done < <("${name}_adopt")
  done

  printf '%s' "$tsv" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
    | {provider: .[0], port: (.[1] | tonumber), url: .[2], reach: .[3], dns: (.[4] // "")})
    | {ok: true, tunnels: .}'
}

cmd_stop_all() {
  # Everything status would show, not just what has a state file — otherwise a
  # row you can stop on its own survives "stop everything".
  local provider port
  while IFS=$'\t' read -r provider port; do
    [[ -n $provider && $port =~ ^[0-9]+$ ]] || continue
    cmd_stop "$provider" "$port" >/dev/null
  done < <(cmd_status | jq -r '.tunnels[]? | [.provider, (.port|tostring)] | @tsv')
  echo '{"ok":true}'
}

# One-click remediation for a provider reporting status=setup. Only actions
# that are safe and unprivileged live here; anything needing a package install
# or a secret stays a printed instruction for the user to run themselves.
cmd_setup() {
  local provider="$1"
  known_provider "$provider" || die "unknown provider"
  augment_path
  declare -f "${provider}_setup" >/dev/null || die "no automatic setup for $provider"
  "${provider}_setup"
}
PROVIDER_BIN=""

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
  providers) cmd_providers ;;
  setup)     cmd_setup "${2:-}" ;;
  start)     cmd_start "${2:-}" "${3:-}" "${4:-}" ;;
  stop)      cmd_stop "${2:-}" "${3:-}" ;;
  status)    cmd_status ;;
  stop-all)  cmd_stop_all ;;
  *) echo '{"ok":false,"error":"usage: tunnels.sh providers|setup <provider>|start <provider> <port> [name]|stop <provider> <port>|status|stop-all"}' ;;
esac
