#!/bin/bash
# Live end-to-end checks for 19 listener fixtures, plus Ruby and Deno when
# available. The fixtures carry the command, directory, marker, and dependency
# evidence that the scanner uses. The test covers scanning, detection, probes,
# traffic, metric retention, lifecycle actions, and matching local IPC.
#
# Everything generated lives in tmp/. Several fixtures use the same Python or
# Node HTTP server because detection reads process and project evidence. The
# marker fixtures copy Python under a stack-specific process name so an earlier
# process-name rule does not hide the marker rule.
#
# Usage: test/e2e-live.sh [--keep]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
S="$ROOT/scripts"
TMP="$ROOT/tmp"
FARM="$TMP/farm"
BIN="$TMP/bin"
PIDS="$TMP/pids"
export PORTAL_METRICS_DIR="$TMP/state"
export PORTAL_STATE_DIR="$TMP/runtime"
PROC="$S/lib/proc.py"
export PORTAL_E2E_RUN="$(< /proc/sys/kernel/random/uuid)"

fails=0
say()  { printf '\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
skip() { printf '  skip %s\n' "$1"; }

command -v jq >/dev/null || { echo "jq required"; exit 1; }
command -v node >/dev/null || { echo "node required"; exit 1; }
PY=$(command -v python3) || { echo "python3 required"; exit 1; }

process_start() {
  local pid="$1" stat fields start
  [[ $pid =~ ^[1-9][0-9]*$ ]] && (( pid > 1 )) || return 1
  IFS= read -r stat 2>/dev/null < "/proc/$pid/stat" || return 1
  read -ra fields <<<"${stat##*) }"
  start="${fields[19]:-}"
  [[ $start =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$start"
}

record_pid() {
  local pid="$1" start i
  for i in $(seq 1 10); do
    if start=$(process_start "$pid") \
        && grep -zqxF -- "PORTAL_E2E_RUN=$PORTAL_E2E_RUN" "/proc/$pid/environ" 2>/dev/null \
        && [[ $(process_start "$pid") == "$start" ]]; then
      printf '%s %s\n' "$pid" "$start" >> "$PIDS"
      return 0
    fi
    sleep 0.01
  done
  return 1
}

recorded_process_alive() {
  local pid start extra
  while read -r pid start extra; do
    [[ -z $extra && $pid =~ ^[1-9][0-9]*$ && $start =~ ^[0-9]+$ ]] || continue
    (( pid > 1 )) || continue
    [[ $(process_start "$pid") == "$start" ]] && return 0
  done < "$PIDS"
  return 1
}

# Teardown checks both fields before either signal. Never pattern-kill here.
teardown() {
  local pid start extra i
  if [[ -f $PIDS ]]; then
    while read -r pid start extra; do
      [[ -z $extra && $pid =~ ^[1-9][0-9]*$ && $start =~ ^[0-9]+$ ]] || continue
      (( pid > 1 )) || continue
      [[ $(process_start "$pid") == "$start" ]] \
        && /usr/bin/python3 -I -S "$PROC" signal "$pid" "$start" TERM >/dev/null 2>&1
    done < "$PIDS"
    for i in $(seq 1 20); do
      recorded_process_alive || return 0
      sleep 0.05
    done
    while read -r pid start extra; do
      [[ -z $extra && $pid =~ ^[1-9][0-9]*$ && $start =~ ^[0-9]+$ ]] || continue
      (( pid > 1 )) || continue
      [[ $(process_start "$pid") == "$start" ]] \
        && /usr/bin/python3 -I -S "$PROC" signal "$pid" "$start" KILL >/dev/null 2>&1
    done < "$PIDS"
    recorded_process_alive && bad "a recorded fixture survived teardown"
  fi
}
[[ ${1:-} == --keep ]] || trap teardown EXIT

say "building the farm in tmp/"
rm -rf "$FARM" "$BIN" "$PIDS" "$PORTAL_METRICS_DIR" "$PORTAL_STATE_DIR"
mkdir -p "$FARM" "$BIN" "$PORTAL_METRICS_DIR" "$PORTAL_STATE_DIR"
: > "$PIDS"
# The private copy has no file capabilities that could hide socket ownership
# from ss.
cp "$(readlink -f "$(command -v node)")" "$BIN/node"
export PATH="$BIN:$PATH"

# One real HTTP server, reused by every fixture.
cat > "$TMP/srv.py" <<'PYEOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("ok:" + sys.argv[2]).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
cat > "$TMP/srv.js" <<'JSEOF'
const http = require("http"), port = +process.argv[2], name = process.argv[3]
http.createServer((q, r) => r.end("ok:" + name)).listen(port, "127.0.0.1")
JSEOF

start() {  # start <port> <cwd> <argv...>
  local cwd="$2"; shift 2
  ( cd "$cwd" && exec setsid "$@" ) </dev/null >/dev/null 2>&1 &
  record_pid "$!" || bad "could not record a fixture process in $cwd"
}

fixture() { mkdir -p "$FARM/$1"; echo "$FARM/$1"; }
pkg() { printf '{"name":"%s","dependencies":{%s}}' "$1" "$2" > "$3/package.json"; }

declare -A EXPECT
# --- node-evidence stacks ---
d=$(fixture next-app);   pkg next-app '"next":"15.0.0","react":"19.0.0"' "$d"; start 45901 "$d" node "$TMP/srv.js" 45901 next;    EXPECT[45901]=next
d=$(fixture vite-app);   pkg vite-app '"vite":"6.0.0","vue":"3.5.0"' "$d";     start 45902 "$d" node "$TMP/srv.js" 45902 vite;    EXPECT[45902]=vite
d=$(fixture express-app);pkg express-app '"express":"5.0.0"' "$d";             start 45903 "$d" node "$TMP/srv.js" 45903 express; EXPECT[45903]=express
d=$(fixture hono-app);   pkg hono-app '"hono":"4.6.0"' "$d";                   start 45904 "$d" node "$TMP/srv.js" 45904 hono;    EXPECT[45904]=hono
d=$(fixture solid-app);  pkg solid-app '"@solidjs/start":"1.0.0"' "$d";        start 45905 "$d" node "$TMP/srv.js" 45905 solid;   EXPECT[45905]=solid
# --- ruby evidence ---
if command -v ruby >/dev/null; then
  d=$(fixture rails-app); touch "$d/Gemfile" "$d/config.ru"
  cat > "$d/server.rb" <<'RBEOF'
require "socket"
s = TCPServer.new("127.0.0.1", 45906)
loop do
  c = s.accept
  c.readpartial(4096) rescue nil
  c.print "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nok:rails"
  c.close
end
RBEOF
  start 45906 "$d" ruby server.rb
  EXPECT[45906]=rails
fi
# --- python evidence ---
d=$(fixture django-app); touch "$d/manage.py";                start 45907 "$d" "$PY" "$TMP/srv.py" 45907 django;  EXPECT[45907]=django
d=$(fixture fastapi-app); cp "$TMP/srv.py" "$d/uvicorn";      start 45908 "$d" "$PY" "$d/uvicorn" 45908 fastapi;  EXPECT[45908]=uvicorn
d=$(fixture jupyter-lab); cp "$TMP/srv.py" "$d/jupyter";      start 45909 "$d" "$PY" "$d/jupyter" 45909 jupyter;  EXPECT[45909]=jupyter
# --- marker stacks: real python server under a stack-shaped process name ---
impersonate() {  # <binname> <port> <fixture> <marker...>
  local name="$1" port="$2" fix="$3"; shift 3
  local d; d=$(fixture "$fix")
  local m; for m in "$@"; do touch "$d/$m"; done
  cp "$PY" "$BIN/$name"
  start "$port" "$d" "$BIN/$name" "$TMP/srv.py" "$port" "$fix"
}
impersonate goapp    45910 go-svc      go.mod;        EXPECT[45910]=go
impersonate rustapp  45911 rust-svc    Cargo.toml;    EXPECT[45911]=rust
impersonate beam.smp 45912 phoenix-app mix.exs;       EXPECT[45912]=phoenix
impersonate java     45913 spring-app  pom.xml;       EXPECT[45913]=javadev
impersonate artisand 45914 laravel-app artisan;       EXPECT[45914]=laravel
# --- scanner edge cases: a node with no evidence, control bytes and an oversized
# argument on the command line, an IPv6-only bind ---
d=$(fixture plain-node); start 45920 "$d" node "$TMP/srv.js" 45920 plain;                      EXPECT[45920]=node
d=$(fixture c0-app); start 45921 "$d" "$PY" "$TMP/srv.py" 45921 "$(printf 'c0\033[31m\tzz')";  EXPECT[45921]=python
d=$(fixture long-app); start 45922 "$d" "$PY" "$TMP/srv.py" 45922 "$(printf 'x%.0s' {1..70000})"; EXPECT[45922]=python
d=$(fixture v6-app); start 45923 "$d" "$PY" -m http.server 45923 --bind ::1;                   EXPECT[45923]=python
# --- a launcher only the process's own PATH knows, plus a marker variable ---
mkdir -p "$FARM/hookbin"; cp "$PY" "$FARM/hookbin/srvlauncher"
d=$(fixture hook-app); PATH="$FARM/hookbin:$PATH" PORTAL_E2E_MARK=carried start 45924 "$d" srvlauncher "$TMP/srv.py" 45924 hook; EXPECT[45924]=unknown
d=$(fixture nl-app); start 45925 "$d" "$PY" "$TMP/srv.py" 45925 "$(printf 'two\nlines and spaces')" "$(printf 'record\036separator')"; EXPECT[45925]=python
# --- deno, when present ---
if command -v deno >/dev/null; then
  d=$(fixture deno-app)
  cat > "$d/server.ts" <<'TSEOF'
Deno.serve({ port: 45915, hostname: "127.0.0.1" }, () => new Response("ok:deno"))
TSEOF
  start 45915 "$d" deno run --allow-net server.ts
  EXPECT[45915]=deno
fi

say "waiting for ${#EXPECT[@]} servers"
up=0
for _ in $(seq 1 40); do
  up=0
  for port in "${!EXPECT[@]}"; do
    ss -tlnH "sport = :$port" 2>/dev/null | grep -q . && up=$((up+1))
  done
  [[ $up -eq ${#EXPECT[@]} ]] && break
  sleep 0.25
done
[[ $up -eq ${#EXPECT[@]} ]] && ok "$up/${#EXPECT[@]} listening" || bad "only $up/${#EXPECT[@]} listening"

# Forked and restarted listeners inherit the run marker. Port attribution
# alone must never make an unrelated process eligible for teardown.
for port in "${!EXPECT[@]}"; do
  while read -r pid; do record_pid "$pid" || bad "could not record PID $pid from port $port"; done \
    < <(ss -tlnpH "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+')
done
sort -u -o "$PIDS" "$PIDS"
for port in "${!EXPECT[@]}"; do
  while read -r pid; do
    start=$(process_start "$pid")
    grep -qxF "$pid $start" "$PIDS" || bad "port $port has untracked process $pid"
  done < <(ss -tlnpH "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+')
done

(( fails == 0 )) || exit 1

say "detection across the farm (scan → Detect)"
PROBES=$(printf '%s ' "${!EXPECT[@]}")
DECORATED=$(node "$S/lib/qmljs.mjs" decorate "$S/scan-ports.sh")
for port in $(printf '%s\n' "${!EXPECT[@]}" | sort -n); do
  got=$(jq -r --argjson p "$port" '.[] | select(.port == $p) | .kind' <<<"$DECORATED")
  if [[ $got == "${EXPECT[$port]}" ]]; then ok "$port -> $got"
  else bad "$port expected ${EXPECT[$port]}, got ${got:-<absent>}"; fi
done

say "scanner normalisation"
row() { jq -c --argjson p "$1" '.ports[] | select(.port == $p)' <<<"$SCAN"; }
SCAN=$("$S/scan-ports.sh")
[[ $(row 45920 | jq -r .comm) == node ]] && ok "node's comm is node, not node-MainThread" || bad "comm on 45920: $(row 45920 | jq -r .comm)"
c0=$(row 45921 | jq -r .cmdline)
if [[ $c0 == *$'\033'* || $c0 == *$'\t'* ]]; then bad "control bytes survived in cmdline"; else ok "control bytes stripped from cmdline"; fi
[[ $(row 45921 | jq -r '.argv | length') == 4 ]] && ok "argv keeps its element count" || bad "argv on 45921: $(row 45921 | jq -c .argv | cut -c1-80)"
[[ $(row 45922 | jq -r .argvTruncated) == true ]] && ok "an oversized command line is flagged truncated" || bad "45922 not flagged truncated"
[[ $(row 45921 | jq -r .argvTruncated) == false ]] && ok "a normal command line is not" || bad "45921 flagged truncated"
[[ $(row 45923 | jq -c .addresses) == '["::1"]' ]] && ok "IPv6 loopback bind reported as ::1" || bad "45923 addresses: $(row 45923 | jq -c .addresses)"
[[ $(row 45923 | jq -r .scope) == local ]] && ok "::1 is scope local" || bad "45923 scope: $(row 45923 | jq -r .scope)"
[[ $(row 45925 | jq -r '.argv[3]') == $'two\nlines and spaces' ]] && ok "an argument with a newline survives the scan" || bad "45925 argv[3]: $(row 45925 | jq -c '.argv[3]')"
[[ $(row 45925 | jq -r '.argv[4]') == $'record\x1eseparator' ]] && ok "an argument with U+001E survives the scan" || bad "45925 argv[4]: $(row 45925 | jq -c '.argv[4]')"

say "traffic + latency probes"
traffic_pids=()
for _ in $(seq 1 10); do
  for port in 45901 45907 45910; do
    curl -s --max-time 2 "http://127.0.0.1:$port/" >/dev/null &
    traffic_pids+=("$!")
  done
done
wait "${traffic_pids[@]}"
PROBED=$("$S/scan-ports.sh" --probe "$PROBES" )
n_lat=$(jq '[.ports[] | select(.latMs != null and .httpCode == 200)] | length' <<<"$PROBED")
[[ $n_lat -eq ${#EXPECT[@]} ]] && ok "latency measured on $n_lat probed fixtures (all 200)" \
  || bad "only $n_lat/${#EXPECT[@]} fixtures returned probed 200s"
body=$(curl -s --max-time 2 http://127.0.0.1:45901/)
[[ $body == ok:next ]] && ok "traffic round-trips ($body)" || bad "unexpected body: $body"

say "metric retention e2e (3 scan cycles into tmp/state)"
"$S/metrics.sh" watch 45901 >/dev/null
"$S/metrics.sh" watch 45910 >/dev/null
for _ in 1 2 3; do
  CYCLE=$("$S/scan-ports.sh" --probe "45901 45910")
  BATCH=$(jq -c '[.ports[] | select(.port == 45901 or .port == 45910)
    | {key: (.port|tostring), value: {t: now|floor, conns, latMs, httpCode, rssKb}}] | from_entries' <<<"$CYCLE")
  "$S/metrics.sh" append-batch "$BATCH" >/dev/null
  sleep 1
done
saved=$("$S/metrics.sh" query 45901 1800 "$(date +%s)")
got=$(jq '.view.count' <<<"$saved")
lat_ok=$(jq '[.view.buckets[].latMs.count] | add' <<<"$saved")
[[ $got -ge 3 && $lat_ok -ge 3 ]] && ok "45901: $got samples persisted, probes recorded" \
  || bad "retention: got=$got lat_ok=$lat_ok"

say "lifecycle e2e (pause / resume / restart the Next.js fixture)"
NPID=$(jq -r '.[] | select(.port == 45901) | .pid' <<<"$DECORATED" | head -1)
if [[ -z $NPID || $NPID == null ]]; then
  bad "no attributable PID on :45901 from the private Node copy"
else
# procState comes from the scanner, so a parsing regression here fails the
# same way the panel would see it.
state_of() { "$S/scan-ports.sh" | jq -r --argjson p 45901 '.ports[] | select(.port == $p) | .procState'; }
NSTART=$(jq -r '.[] | select(.port == 45901) | .start' <<<"$DECORATED" | head -1)
[[ $NSTART =~ ^[0-9]+$ ]] && ok "the scan carries the kernel start time" || bad "no start time in the scan: $NSTART"
out=$("$S/lifecycle.sh" stop "$((NPID + 1))" "$NSTART" 45901)
[[ $(jq -r .ok <<<"$out") == false ]] && ok "a pid that does not own the port is refused" || bad "ownership check: $out"
out=$("$S/lifecycle.sh" stop "$NPID" "$((NSTART + 1))" 45901)
[[ $(jq -r .ok <<<"$out") == false ]] && ok "a start time that is not the process's is refused" || bad "identity check: $out"
kill -0 "$NPID" 2>/dev/null && ok "and the real process was not signalled" || bad "the real process died"
"$S/lifecycle.sh" pause "$NPID" "$NSTART" 45901 >/dev/null
st=$(state_of)
[[ $st == T ]] && ok "paused (state T)" || bad "pause: state=$st"
"$S/lifecycle.sh" resume "$NPID" "$NSTART" 45901 >/dev/null
st=$(state_of)
[[ $st == S || $st == R ]] && ok "resumed (state $st)" || bad "resume: state=$st"
ARGV=$(jq -r --argjson p 45901 '.[] | select(.port == $p) | .argv | @json' <<<"$DECORATED")
CWD="$FARM/next-app"
"$S/lifecycle.sh" restart "$NPID" "$NSTART" 45901 "$CWD" "$ARGV" >/dev/null
sleep 1
NEW=$("$S/scan-ports.sh" | jq -r --argjson p 45901 '.ports[] | select(.port == $p) | .pid')
if [[ -n $NEW && $NEW != "$NPID" ]]; then ok "restarted ($NPID -> $NEW)"; record_pid "$NEW" || bad "could not record restarted PID $NEW"
else bad "restart failed"; fi
fi

say "restart keeps every byte of an argument"
LSCAN=$("$S/scan-ports.sh" | jq -c '.ports[] | select(.port == 45925)')
LPID=$(jq -r .pid <<<"$LSCAN"); LSTART=$(jq -r .start <<<"$LSCAN"); LARGV=$(jq -c .argv <<<"$LSCAN")
"$S/lifecycle.sh" restart "$LPID" "$LSTART" 45925 "$FARM/nl-app" "$LARGV" >/dev/null; sleep 1
LNEW=$("$S/scan-ports.sh" | jq -r '.ports[] | select(.port == 45925) | .pid')
if [[ -n $LNEW && $LNEW != "$LPID" ]]; then
  record_pid "$LNEW" || bad "could not record restarted PID $LNEW"
  [[ $(tr '\0' '\n' < "/proc/$LNEW/cmdline" | sed -n 4,5p) == $'two\nlines and spaces' ]] && ok "the newline argument came back intact" || bad "argv[3] after restart: $(tr '\0' '|' < /proc/$LNEW/cmdline)"
  [[ $(python3 -c 'import sys; print(open(f"/proc/{sys.argv[1]}/cmdline", "rb").read().split(b"\0")[4].hex())' "$LNEW") == 7265636f72641e736570617261746f72 ]] \
    && ok "the U+001E argument came back intact" || bad "argv[4] changed across restart"
else bad "no new pid on 45925"; fi

say "restart carries the process's own environment"
HSCAN=$("$S/scan-ports.sh" | jq -c '.ports[] | select(.port == 45924)')
HPID=$(jq -r .pid <<<"$HSCAN"); HSTART=$(jq -r .start <<<"$HSCAN"); HARGV=$(jq -c .argv <<<"$HSCAN")
out=$("$S/lifecycle.sh" restart "$HPID" "$HSTART" 45924 "$FARM/hook-app" "$HARGV")
[[ $(jq -r .ok <<<"$out") == true ]] && ok "a launcher off this shell's PATH restarts" || bad "restart via process PATH: $out"
sleep 1
HNEW=$("$S/scan-ports.sh" | jq -r '.ports[] | select(.port == 45924) | .pid')
if [[ -n $HNEW && $HNEW != "$HPID" ]]; then
  record_pid "$HNEW" || bad "could not record restarted PID $HNEW"
  tr '\0' '\n' < "/proc/$HNEW/environ" | grep -qx 'PORTAL_E2E_MARK=carried' && ok "the marker variable survived the restart" || bad "environment not carried"
  tr '\0' '\n' < "/proc/$HNEW/environ" | grep -q "^PATH=$FARM/hookbin:" && ok "and so did its PATH" || bad "PATH not carried"
else bad "no new pid on 45924"; fi

say "through the running plugin (IPC), when available"
shell_live=0
ipc_ready=0
ipc_fixture_hits() {
  local live="$1" hits=0 port kind
  jq -e 'type == "array"' <<<"$live" >/dev/null 2>&1 || { printf '0'; return; }
  for port in "${!EXPECT[@]}"; do
    kind=$(jq -r --argjson p "$port" '.[] | select(.port == $p) | .kind' <<<"$live")
    [[ $kind == "${EXPECT[$port]}" ]] && hits=$((hits+1))
  done
  printf '%s' "$hits"
}

if command -v omarchy-shell >/dev/null && [[ $(omarchy-shell shell ping 2>/dev/null) == ok ]]; then
  shell_live=1
  if "$ROOT/dev/portal.sh" parity >/dev/null 2>&1; then
    ipc_ready=1
    omarchy-shell g3ortega.portal refresh >/dev/null 2>&1 || bad "running shell refused refresh"
    LIVE=""
    hits=0
    for _ in $(seq 1 30); do
      LIVE=$(omarchy-shell g3ortega.portal ports 2>/dev/null)
      hits=$(ipc_fixture_hits "$LIVE")
      [[ $hits -eq ${#EXPECT[@]} ]] && break
      sleep 0.5
    done
    [[ $hits -eq ${#EXPECT[@]} ]] && ok "running shell agrees on all $hits fixtures" \
      || bad "shell agrees on $hits/${#EXPECT[@]}"

    tunnels_before=$(omarchy-shell g3ortega.portal tunnels 2>/dev/null)
    invalid_expose=$(omarchy-shell g3ortega.portal expose not-a-provider 0 2>/dev/null)
    invalid_unexpose=$(omarchy-shell g3ortega.portal unexpose not-a-provider 0 2>/dev/null)
    tunnels_after=$(omarchy-shell g3ortega.portal tunnels 2>/dev/null)
    [[ $invalid_expose == error:* ]] && ok "invalid expose IPC is refused" \
      || bad "invalid expose IPC returned: ${invalid_expose:-<empty>}"
    [[ $invalid_unexpose == error:* ]] && ok "invalid unexpose IPC is refused" \
      || bad "invalid unexpose IPC returned: ${invalid_unexpose:-<empty>}"
    if jq -e . <<<"$tunnels_before" >/dev/null 2>&1 && [[ $tunnels_before == "$tunnels_after" ]]; then
      ok "invalid IPC leaves tunnel state unchanged"
    else
      bad "invalid IPC changed tunnel state"
    fi
  else
    skip "installed plugin differs from this checkout; IPC stage"
  fi
else
  skip "shell not running; IPC stage"
fi

# The CLI uses IPC only after the same parity check. Otherwise a small shim
# forces its documented offline path.
say "the CLI"
CLI_PATH="$PATH"
if (( shell_live == 1 && ipc_ready == 0 )); then
  mkdir -p "$BIN/offline"
  printf '#!/bin/sh\nexit 1\n' > "$BIN/offline/omarchy-shell"
  chmod +x "$BIN/offline/omarchy-shell"
  CLI_PATH="$BIN/offline:$PATH"
fi
if out=$(PATH="$CLI_PATH" "$S/portal" list --all 2>&1); then
  miss=0; for port in "${!EXPECT[@]}"; do grep -q "^$port " <<<"$out" || miss=$((miss+1)); done
  [[ $miss -eq 0 ]] && ok "portal list --all shows every fixture" || bad "portal list is missing $miss fixtures"
else bad "portal list failed: $out"; fi
PATH="$CLI_PATH" "$S/portal" shared >/dev/null 2>&1 && ok "portal shared runs" || bad "portal shared failed"

if [[ ${1:-} != --keep ]]; then
  say "teardown"
  trap - EXIT
  teardown
  if stray=$(pgrep -f "sleep [3]00"); then
    bad "sleep 300 process remains after teardown: $(tr '\n' ' ' <<<"$stray")"
  else
    ok "no sleep 300 process remains"
  fi
  for port in "${!EXPECT[@]}"; do
    ss -tlnH "sport = :$port" 2>/dev/null | grep -q . && bad "port $port still listens after teardown"
  done
else
  skip "--keep left the farm running; teardown and stray check"
fi

printf '\n'
if [[ $fails -eq 0 ]]; then echo "e2e-live: all checks passed"; else echo "e2e-live: $fails failed"; fi
exit $((fails > 0))
