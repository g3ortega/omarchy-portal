#!/bin/bash
# Emit every listening TCP port as JSON, with the facts needed to infer what is
# running there. Classification lives in lib/Detect.js — this script gathers
# evidence only, and only from an allowlist, so nothing unexpected leaves the
# process.
#
# Contract: { "version": 1, "ports": [ ... ] }
# projectName is the raw package.json name (or empty) — display fallbacks such
# as "use the directory basename" belong to Detect.js, where they are testable.

set -o pipefail
set -f          # addresses contain '*'; never let the shell glob them
MAX_PORTS=512   # past this the scan reports an error, not a growing document
MAX_ESTABLISHED=16384
MAX_ESTABLISHED_BYTES=4194304
MAX_PROBES=64   # direct callers stay bounded; Service normally requests eight
ARGV_LOGICAL_CAP=8192
ARGV_SAMPLE_CAP=$((ARGV_LOGICAL_CAP + 1))
ARGV_SAMPLE_B64_LEN=$((4 * ((ARGV_SAMPLE_CAP + 2) / 3)))

command -v ss >/dev/null 2>&1 || { echo '{"version":1,"error":"ss not found","ports":[]}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"version":1,"error":"jq not found","ports":[]}'; exit 0; }

# --probe "8080 3000": GET / on these ports (1s cap) and report latency +
# status. Only ports the caller names are ever probed — the scanner never
# fires requests at services on its own initiative.
PROBE_DIR=""
if [[ ${1:-} == --probe ]]; then
  # All probes fire concurrently before the /proc walk and are awaited once —
  # one slow service delays the scan by its own latency, not the sum's.
  PROBE_DIR=$(mktemp -d)
  trap 'rm -rf "$PROBE_DIR"' EXIT
  _probes=()
  _probe_seen=" "
  _probe_count=0
  for _pp in ${2:-}; do
    [[ $_pp =~ ^[0-9]{1,5}$ ]] && (( 10#$_pp > 0 && 10#$_pp < 65536 )) || continue
    _pp=$((10#$_pp))
    [[ $_probe_seen == *" $_pp "* ]] && continue
    (( _probe_count >= MAX_PROBES )) && break
    _probe_seen+="$_pp "
    _probe_count=$((_probe_count + 1))
    curl -q -so /dev/null -w '%{http_code} %{time_total}' --max-redirs 0 --max-filesize 65536 \
      --max-time 1 "http://localhost:$_pp/" > "$PROBE_DIR/$_pp" 2>/dev/null &
    _probes+=("$!")
  done
  (( ${#_probes[@]} )) && wait "${_probes[@]}"
fi

# Marker files that identify a project's stack — exactly the set lib/Detect.js
# tests. Adding a rule that reads a new marker means adding it here too;
# test/detect.test.mjs asserts the two lists stay in sync.
MARKERS=(
  package.json angular.json
  Gemfile config.ru bin/rails
  manage.py
  mix.exs artisan
  go.mod Cargo.toml
  pom.xml build.gradle build.gradle.kts
)

# package.json dependency names Detect.js tests. Same sync contract as MARKERS;
# we never emit the raw dependency map, only which of these are present.
FRAMEWORK_DEPS=(
  next nuxt astro @sveltejs/kit svelte @angular/core
  react-router @remix-run/react vite
  storybook @storybook/react @nestjs/core @nestjs/platform-express @nestjs/platform-fastify
  @react-router/dev @react-router/serve @remix-run/serve
  vitepress @docusaurus/core gatsby @adonisjs/core @strapi/strapi elysia
  @hapi/hapi webpack-dev-server parcel preact socket.io ws
  react vue express fastify koa hapi
  hono @solidjs/start solid-js
)

printf -v ALLOW_JSON '"%s",' "${FRAMEWORK_DEPS[@]}"; ALLOW_JSON="[${ALLOW_JSON%,}]"

# Walk up from a directory looking for a project root. Dev servers are often
# started from a subdirectory. $HOME itself is never a root: stray marker files
# in a home directory would label every unrelated daemon with it. Nor is a
# directory we do not own: a package.json planted in /tmp by another user must
# not name every process that runs under it.
find_project_root() {
  local dir="$1" depth=0
  local home="${HOME%/}"
  while [[ -n $dir && $dir != "/" && $depth -lt 5 ]]; do
    [[ $dir == "$home" ]] && return 0
    [[ -O $dir ]] || return 0
    # Any marker a rule can read also marks a root — a standalone Django app
    # (manage.py, nothing else) or a Laravel checkout must not be invisible
    # just because it lacks package.json-class files. Every rule marker comes
    # from MARKERS, plus two root-only hints no rule reads.
    local m
    for m in "${MARKERS[@]}" pyproject.toml composer.json; do
      [[ -e "$dir/$m" ]] && { printf '%s' "$dir"; return 0; }
    done
    dir="${dir%/*}"
    [[ -z $dir ]] && dir="/"
    depth=$((depth + 1))
  done
  return 0
}

# Per-root facts, memoized for the scan: several ports usually share one
# project (web + HMR + API). Sets PROJ_NAME, PROJ_DEPS, PROJ_MARKERS.
declare -A ROOT_CACHE
project_info() {
  local root="$1"
  PROJ_NAME=""; PROJ_DEPS=""; PROJ_MARKERS=""
  [[ -n $root && -d $root ]] || return 0

  if [[ -n ${ROOT_CACHE[$root]+x} ]]; then
    IFS=$'\x1f' read -r PROJ_NAME PROJ_DEPS PROJ_MARKERS <<<"${ROOT_CACHE[$root]}"
    return 0
  fi

  local m out=()
  for m in "${MARKERS[@]}"; do
    [[ -e "$root/$m" ]] && out+=("$m")
  done
  PROJ_MARKERS="${out[*]}"

  if [[ -f "$root/package.json" ]]; then
    # One jq pass returns the name and the allowlist intersection together.
    # Cap the read: a generated package.json should not be unbounded.
    local info
    info=$(head -c 262144 -- "$root/package.json" 2>/dev/null \
      | jq -r --argjson allow "$ALLOW_JSON" '
          [ (if (.name | type) == "string" then .name[:256] else "" end),
            ( ((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {}))
              | keys | map(select(. as $d | $allow | index($d))) | join(" ") )
          ] | @tsv' 2>/dev/null)
    IFS=$'\t' read -r PROJ_NAME PROJ_DEPS <<<"$info"
  fi

  ROOT_CACHE[$root]="${PROJ_NAME}"$'\x1f'"${PROJ_DEPS}"$'\x1f'"${PROJ_MARKERS}"
}

declare -A ARGV_CACHE
argv_info() {
  local pid=$1 encoded cut=0
  if [[ -z ${ARGV_CACHE[$pid]+x} ]]; then
    encoded=$(head -c "$ARGV_SAMPLE_CAP" -- "/proc/$pid/cmdline" 2>/dev/null \
      | base64 -w0 2>/dev/null) || encoded=""
    if (( ${#encoded} == ARGV_SAMPLE_B64_LEN )) && [[ ${encoded: -1} != "=" ]]; then
      cut=1
    fi
    ARGV_CACHE[$pid]="${encoded}"$'\x1f'"${cut}"
  fi
  IFS=$'\x1f' read -r ARGV_B64 ARGV_CUT <<<"${ARGV_CACHE[$pid]}"
}

# ---- gather listening sockets -------------------------------------------------
raw=$(ss -tlnpH 2>/dev/null) \
  || { echo '{"version":1,"error":"could not query listening sockets","ports":[]}'; exit 0; }

# Established peers per local port: one ss call covers every row. Unprivileged.
# With a state filter ss omits the State column, so Local is the third field.
declare -A PORT_CONNS PORT_RTTS PORT_RTT_COUNTS
established=$(ss -tniHO state established 2>/dev/null | head -c "$((MAX_ESTABLISHED_BYTES + 1))" \
  | LC_ALL=C awk -v maxbytes="$MAX_ESTABLISHED_BYTES" -v maxrows="$MAX_ESTABLISHED" '
    {
      bytes += length($0) + 1
      if (bytes > maxbytes) error = "established socket snapshot exceeds byte limit"
      if (NF < 3) next
      if (++rows > maxrows && error == "") error = "established socket snapshot exceeds row limit"
      if (error != "") next
      port = $3
      sub(/^.*:/, "", port)
      if (port !~ /^[0-9]+$/ || length(port) > 5 || port + 0 < 1 || port + 0 > 65535) next
      port = sprintf("%d", port)
      conns[port]++
      for (i = 5; i <= NF; i++) {
        if ($i !~ /^rtt:[0-9]+([.][0-9]+)?\/[0-9]+([.][0-9]+)?$/) continue
        split(substr($i, 5), rtt, "/")
        if (length(rtt[1]) <= 18) { total[port] += rtt[1]; count[port]++ }
        break
      }
    }
    END {
      if (error != "") { print "error\t" error; exit }
      for (port in conns)
        printf "%s\t%d\t%.17g\t%d\n", port, conns[port], count[port] ? total[port] / count[port] : 0, count[port] + 0
    }') \
  || { echo '{"version":1,"error":"could not query established sockets","ports":[]}'; exit 0; }
if [[ $established == error$'\t'* ]]; then
  jq -nc --arg error "${established#*$'\t'}" '{version:1,error:$error,ports:[]}'
  exit 0
fi
while IFS=$'\t' read -r cport conns rtt count; do
  [[ -n $cport ]] || continue
  PORT_CONNS[$cport]=$conns
  PORT_RTT_COUNTS[$cport]=$count
  (( count > 0 )) && PORT_RTTS[$cport]=$rtt
done <<<"$established"

CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
PAGE_KB=$(( $(getconf PAGESIZE 2>/dev/null || echo 4096) / 1024 ))
read -r UPTIME_NOW _ < /proc/uptime

declare -A PORT_ADDRS PORT_PID PORT_AMBIGUOUS
while read -r _state _rq _sq local_addr _peer procinfo; do
  [[ -n $local_addr ]] || continue
  port="${local_addr##*:}"
  addr="${local_addr%:*}"
  [[ $port =~ ^[0-9]+$ ]] || continue
  if (( ${#PORT_ADDRS[@]} >= MAX_PORTS )) && [[ -z ${PORT_ADDRS[$port]+x} ]]; then
    echo "{\"version\":1,\"error\":\"more than $MAX_PORTS listening ports\",\"ports\":[]}"; exit 0
  fi
  addr="${addr%\%*}"          # strip %iface
  addr="${addr#[}"; addr="${addr%]}"
  addr="${addr#::ffff:}"      # v4-mapped

  PORT_ADDRS[$port]="${PORT_ADDRS[$port]}${PORT_ADDRS[$port]:+ }$addr"
  row_attributed=0
  proc_rest="$procinfo"
  while [[ $proc_rest =~ pid=([0-9]+) ]]; do
    pid="${BASH_REMATCH[1]}"
    proc_rest="${proc_rest#*"${BASH_REMATCH[0]}"}"
    row_attributed=1
    if [[ -z ${PORT_PID[$port]} ]]; then
      PORT_PID[$port]="$pid"
    elif [[ ${PORT_PID[$port]} != "$pid" ]]; then
      PORT_AMBIGUOUS[$port]=1
    fi
  done
  (( row_attributed )) || PORT_AMBIGUOUS[$port]=1
done <<<"$raw"

# ---- emit one tab-separated record per port, assemble with ONE jq -------------
# Fields: port, addrs(space), pid, comm, cmdline, cwd, root, pname,
#         markers(space), deps(space), ... Free text is stripped of control
# characters so a hostile cmdline can neither smuggle extra fields nor carry
# terminal escapes into the CLI's output.
emit() {
  local port
  for port in "${!PORT_ADDRS[@]}"; do
    local pid="${PORT_PID[$port]}" comm="" cmdline="" cwd="" root="" exclusive_owner=false
    local argv_b64="" argv_cut="" cpu_ticks="" rss_kb="" up_sec="" pstate="" st=()
    local lat_ms="" http_code=""
    if [[ -n $PROBE_DIR && -f "$PROBE_DIR/$port" ]]; then
      local probe_out t_int t_frac
      probe_out=$(< "$PROBE_DIR/$port")
      http_code="${probe_out%% *}"
      t_int="${probe_out##* }"; t_frac="${t_int#*.}000000"; t_int="${t_int%%.*}"
      lat_ms="$(( t_int * 1000 + 10#${t_frac:0:3} )).${t_frac:3:3}"
      [[ $http_code == 000 ]] && { http_code=""; lat_ms=""; }
    fi
    if [[ -n $pid && -r /proc/$pid/comm ]]; then
      { comm=$(< "/proc/$pid/comm"); } 2>/dev/null
      comm="${comm%-MainThread}"   # node names its main thread; the process is still node
      argv_info "$pid"
      argv_b64=$ARGV_B64
      argv_cut=$ARGV_CUT
      cwd=$(readlink -- "/proc/$pid/cwd" 2>/dev/null); cwd="${cwd:0:4096}"
      # stat: field 3 is run state; utime+stime are 14+15; starttime is 22 —
      # but comm (field 2) may contain spaces, so parse after the closing paren.
      local statline
      { statline=$(< "/proc/$pid/stat"); } 2>/dev/null
      local st=(${statline##*) })
      pstate="${st[0]}"
      cpu_ticks=$(( ${st[11]:-0} + ${st[12]:-0} ))
      up_sec=$(( ${UPTIME_NOW%%.*} - ${st[19]:-0} / CLK_TCK ))
      local rss_pages
      read -r _ rss_pages _ < "/proc/$pid/statm" 2>/dev/null
      rss_kb=$(( ${rss_pages:-0} * PAGE_KB ))
    fi
    [[ -n $cwd && -d $cwd ]] && root=$(find_project_root "$cwd")
    project_info "$root"
    [[ -n $pid && -z ${PORT_AMBIGUOUS[$port]} ]] && exclusive_owner=true

    local f joined=""
    for f in "$port" "${PORT_ADDRS[$port]}" "$pid" "$comm" "$cmdline" "$cwd" \
             "$root" "$PROJ_NAME" "$PROJ_MARKERS" "$PROJ_DEPS" \
             "${PORT_CONNS[$port]:-0}" "$cpu_ticks" "$rss_kb" "$up_sec" "$pstate" "$argv_b64" \
             "$lat_ms" "$http_code" "$argv_cut" "${st[19]}" "$exclusive_owner" "${PORT_RTTS[$port]}" "${PORT_RTT_COUNTS[$port]:-0}"; do
      f="${f//$'\t'/ }"; f="${f//$'\n'/ }"
      f="${f//[$'\x01'-$'\x1f'$'\x7f']/}"   # no C0 control survives; argv is already escaped
      joined+="${joined:+$'\t'}$f"
    done
    printf '%s\n' "$joined"
  done
}

emit | jq -Rsc '
  def words: if . == "" then [] else split(" ") end;
  def num: if . == "" then null else tonumber end;
  def argv: if . == "" then [] else
    (@base64d | split("\u0000") | if length > 0 and .[-1] == "" then .[:-1] else . end)
    end;
  split("\n")
  | map(select(length > 0) | split("\t"))
  | map({
      port: (.[0] | tonumber),
      addresses: (.[1] | words | unique),
      pid: (.[2] | num),
      comm: .[3],
      cmdline: .[4],
      cwd: .[5],
      projectRoot: .[6],
      projectName: .[7],
      markers: (.[8] | words),
      deps: (.[9] | words),
      conns: (.[10] | num // 0),
      cpuTicks: (.[11] | num),
      rssKb: (.[12] | num),
      upSec: (.[13] | num),
      procState: .[14],
      argv: (.[15] | argv),
      latMs: (.[16] | num),
      httpCode: (.[17] | num),
      argvTruncated: (.[18] == "1"),
      start: (.[19] | num),
      exclusiveOwner: (.[20] == "true"),
      tcpRttMs: (.[21] | num),
      tcpRttCount: (.[22] | num)
    }
    | .cmdline = ([.argv[] | gsub("[\u0000-\u001f\u007f]"; "")] | join(" ") | .[:2048])
    | .scope = (if (.addresses | any(. == "0.0.0.0" or . == "*" or . == "::")) then "all"
                elif (.addresses | all(. == "127.0.0.1" or . == "::1" or startswith("127."))) then "local"
                else "lan" end))
  | {version: 1, ports: sort_by(.port)}'
