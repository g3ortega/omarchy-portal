#!/bin/bash
# Unit tests for the shell side: the portless library, the tunnels.sh
# validators, and metrics.sh's file handling. Everything runs against
# throwaway state directories; nothing here touches the live system.
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
S="$(cd "$HERE/../scripts" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
is()  { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }

# ---- scripts/lib/portless.sh ----------------------------------------------
export PORTLESS_STATE_DIR="$T/portless"; mkdir -p "$PORTLESS_STATE_DIR"
export PORTAL_STATE_DIR="$T/runtime"
export PORTAL_PORTLESS_TLD=test
# shellcheck source=tunnels.sh
source "$S/tunnels.sh"    # sources lib/portless.sh; returns before dispatch

is "configured_tld passes a clean TLD" "$(configured_tld)" "test"
is "configured_tld lowercases and strips" "$(PORTAL_PORTLESS_TLD=' My.Dev ' configured_tld)" "my.dev"
is "configured_tld falls back on junk" "$(PORTAL_PORTLESS_TLD='x;rm -rf /' configured_tld)" "localhost"
is "configured_tld falls back on empty" "$(PORTAL_PORTLESS_TLD='' configured_tld)" "localhost"

printf '["localhost","dev","x;echo pwned","UPPER","a..b","-lead"]' > "$PORTLESS_STATE_DIR/proxy.tlds"
is "running_tlds keeps only DNS labels" "$(portless_running_tlds | tr '\n' ' ')" "localhost dev "
is "tld_arg: configured first, running next, localhost kept" "$(portless_tld_arg)" "test,localhost,dev"
printf 'localhost,internal' > "$PORTLESS_STATE_DIR/proxy.tlds"
is "running_tlds reads the comma form" "$(portless_running_tlds | tr '\n' ' ')" "localhost internal "
rm -f "$PORTLESS_STATE_DIR/proxy.tlds"; printf 'test' > "$PORTLESS_STATE_DIR/proxy.tld"
is "running_tlds reads the legacy file" "$(portless_running_tlds)" "test"
is "tld_arg still appends localhost" "$(portless_tld_arg)" "test,localhost"
rm -f "$PORTLESS_STATE_DIR/proxy.tld"
is "running_tlds defaults to localhost" "$(portless_running_tlds)" "localhost"
case "$(portless_fix_cmd evict)" in
  "sudo fuser -k 443/tcp; sleep 1; PORTLESS_STATE_DIR=\"\$HOME/.portless\" portless proxy start -p 443 --tld test,localhost") ok "fix command composes from validated parts" ;;
  *) bad "fix command: $(portless_fix_cmd evict)" ;;
esac
printf '[{"port":3000,"hostname":"acme.localhost"},{"port":5173,"hostname":"dash.test"}]' > "$PORTLESS_STATE_DIR/routes.json"
is "route_name strips the TLD" "$(portless_route_name 5173)" "dash"
is "route_name is empty for an unknown port" "$(portless_route_name 9)" ""

# ---- tunnels.sh validators -------------------------------------------------
me=$(< /proc/$$/comm)
valid_url "https://a-b.trycloudflare.com" && ok "valid_url accepts a hostname" || bad "valid_url rejected a hostname"
valid_url "http://acme.localhost:1355/x?y=1" && ok "valid_url accepts port and path" || bad "valid_url rejected port+path"
valid_url "javascript:alert(1)" && bad "valid_url accepted javascript:" || ok "valid_url rejects javascript:"
valid_url "https://evil.com/x y" && bad "valid_url accepted a space" || ok "valid_url rejects whitespace"
valid_url "ftp://x" && bad "valid_url accepted ftp" || ok "valid_url rejects other schemes"
valid_url "https://x$(printf '\033')[1m" && bad "valid_url accepted an escape byte" || ok "valid_url rejects control bytes"
is "url_host strips scheme, port and path" "$(url_host 'https://h.example:8443/p/q')" "h.example"
valid_port 65535 && ok "valid_port upper bound" || bad "valid_port rejected 65535"
valid_port 65536 && bad "valid_port accepted 65536" || ok "valid_port rejects 65536"
valid_port 0 && bad "valid_port accepted 0" || ok "valid_port rejects 0"
valid_port 12a && bad "valid_port accepted 12a" || ok "valid_port rejects non-digits"
owned_pid "$$" "$me" && ok "owned_pid matches this shell" || bad "owned_pid rejected this shell ($me)"
owned_pid "$$" ngrok && bad "owned_pid matched the wrong comm" || ok "owned_pid rejects the wrong comm"
owned_pid "0$$" bash && bad "owned_pid accepted a zero-padded pid" || ok "owned_pid rejects a zero-padded pid"
is "slug lowercases nothing, collapses runs, trims" "$(slug 'Hello  World!!')" "Hello-World"
long=$(slug "$(printf 'a%.0s' {1..60})"); is "slug caps length" "${#long}" "40"

# cmd_stop must never signal a pid the pidfile names unless it is still the provider.
mkdir -p "$STATE_DIR"
printf '%s' "$$" > "$STATE_DIR/cloudflared-4444.pid"
printf 'https://x.trycloudflare.com' > "$STATE_DIR/cloudflared-4444.url"
out=$(cmd_stop cloudflared 4444)
is "cmd_stop with a reused pid returns ok without signalling" "$out" '{"ok":true}'
[[ -f $STATE_DIR/cloudflared-4444.url ]] && bad "cmd_stop left the url file" || ok "cmd_stop cleared the state files"

# Concurrent first use: many helpers creating the same missing directory all succeed.
R=$(mktemp -d); for i in $(seq 1 12); do state ensure "$R/a/b/c" & done; wait; [[ -d $R/a/b/c ]] && ok "concurrent ensure creates the directory once, without error" || bad "concurrent ensure failed"; rm -rf "$R"

# The install marker is JSON, so a path with a space survives.
M=$(mktemp -d); mkdir -p "$M/my bin"; printf 'x' > "$M/my bin/cloudflared"; d=$(sha256sum "$M/my bin/cloudflared" | cut -d' ' -f1)
jq -nc --arg p "$M/my bin/cloudflared" --arg s "$d" '{path:$p, sha256:$s}' | state write "$M/installed-cloudflared"
plan=$(PORTAL_BIN_DIR="$M/my bin" PORTAL_METRICS_DIR=$M PORTAL_STATE_DIR=$M/rt "$S/uninstall.sh" --dry 2>&1)
grep -qF "would: state_remove $M/my bin cloudflared" <<<"$plan" && ok "uninstall finds a marked binary in a path with a space" || bad "uninstall lost the marked binary: $plan"
# State roots pointed at a shared directory lose only Portal's own entries.
mkdir -p "$M/shared/metrics" "$M/rt2"; : > "$M/shared/thesis.txt"; : > "$M/shared/trusted-stores"; : > "$M/shared/metrics/3000.jsonl"; : > "$M/rt2/cloudflared-1.url"; : > "$M/rt2/notes.txt"
plan=$(PORTAL_METRICS_DIR=$M/shared PORTAL_STATE_DIR=$M/rt2 "$S/uninstall.sh" --dry 2>/dev/null)
grep -q 'rm -rf' <<<"$plan" && bad "uninstall would remove a state root wholesale" || ok "uninstall never removes a state root wholesale"
is "uninstall removes Portal's entries by name" "$(grep -c -E "would: state_remove $M/(shared trusted-stores|shared/metrics 3000.jsonl|rt2 cloudflared-1.url)$" <<<"$plan")" "3"
grep -qE 'thesis|notes' <<<"$plan" && bad "uninstall would touch files that are not Portal's" || ok "and leaves other files alone"
# A binary that could not be removed keeps its marker, and the removal stops there.
# (omarchy is a stub here so nothing about the live plugin is touched.)
mkdir -p "$M/stub" "$M/held" "$M/st3" "$M/rt3"; printf '#!/bin/bash\n[[ $1 == plugin && $2 == list ]] && { echo "[]"; exit 0; }\nexit 1\n' > "$M/stub/omarchy"; chmod 755 "$M/stub/omarchy"
printf 'x' > "$M/held/cloudflared"; d=$(sha256sum "$M/held/cloudflared" | cut -d' ' -f1)
jq -nc --arg p "$M/held/cloudflared" --arg s "$d" '{path:$p, sha256:$s}' | state write "$M/st3/installed-cloudflared"
chmod 770 "$M/held"
out=$(PATH="$M/stub:$PATH" PORTAL_BIN_DIR="$M/held" PORTAL_METRICS_DIR=$M/st3 PORTAL_STATE_DIR=$M/rt3 "$S/uninstall.sh" 2>&1); rc=$?
is "uninstall stops when the binary cannot be removed" "$rc" "1"
grep -q "$M/held/cloudflared.*its marker is kept" <<<"$out" && ok "and says so" || bad "no message about the kept marker: $out"
[[ -e $M/st3/installed-cloudflared ]] && ok "and the marker survives" || bad "the marker was deleted"
chmod 700 "$M/held"
# A marker whose path is not the bin path Portal installs to is never a delete target.
mkdir -p "$M/ev/st" "$M/ev/rt" "$M/ev/stub" "$M/ev/bin"; printf '#!/bin/bash\n[[ $1 == plugin && $2 == list ]] && { echo "[]"; exit 0; }\nexit 0\n' > "$M/ev/stub/omarchy"; chmod 755 "$M/ev/stub/omarchy"
printf 'secret' > "$M/ev/victim"; ed=$(sha256sum "$M/ev/victim" | cut -d' ' -f1)
jq -nc --arg p "$M/ev/victim" --arg s "$ed" '{path:$p, sha256:$s}' | state write "$M/ev/st/installed-cloudflared"
PATH="$M/ev/stub:$PATH" PORTAL_BIN_DIR="$M/ev/bin" PORTAL_METRICS_DIR=$M/ev/st PORTAL_STATE_DIR=$M/ev/rt "$S/uninstall.sh" --dry 2>/dev/null | grep -qF "$M/ev/victim" && bad "uninstall would delete a file the marker points at outside the bin dir" || ok "uninstall ignores a marker path outside the bin dir"
# A marker that exists but cannot be decoded aborts uninstall and is kept.
mkdir -p "$M/cor/st" "$M/cor/rt" "$M/cor/stub"; printf '#!/bin/bash\n[[ $1 == plugin && $2 == list ]] && { echo "[]"; exit 0; }\nexit 0\n' > "$M/cor/stub/omarchy"; chmod 755 "$M/cor/stub/omarchy"
printf 'not json at all' | state write "$M/cor/st/installed-cloudflared"
out=$(PATH="$M/cor/stub:$PATH" PORTAL_METRICS_DIR=$M/cor/st PORTAL_STATE_DIR=$M/cor/rt "$S/uninstall.sh" 2>&1); rc=$?
is "uninstall aborts on a malformed install marker" "$rc" "1"
[[ -e $M/cor/st/installed-cloudflared ]] && ok "and keeps the malformed marker" || bad "the malformed marker was deleted"
rm -rf "$M"

# stop-own ends only shares with a state file of their own, including one
# still minting its URL (a pidfile, no url yet).
printf 'https://own.trycloudflare.com' > "$STATE_DIR/cloudflared-4447.url"; printf '999999 1' > "$STATE_DIR/cloudflared-4447.pid"
printf '999999 1' > "$STATE_DIR/ngrok-4448.pid"
is "stop-own returns ok" "$(cmd_stop_own)" '{"ok":true}'
[[ -e $STATE_DIR/cloudflared-4447.url ]] && bad "stop-own left a created share" || ok "stop-own cleared the created share"
[[ -e $STATE_DIR/ngrok-4448.pid ]] && bad "stop-own skipped a tunnel still minting its URL" || ok "stop-own covers a tunnel that has a pidfile but no url yet"

# The pidfile binds pid and kernel start time; a matching comm is not enough.
mystart=$(proc_start "$$")
owned_pid "$$" "$me" "$mystart" && ok "owned_pid accepts the true start time" || bad "owned_pid rejected the true start time"
owned_pid "$$" "$me" "$((mystart + 1))" && bad "owned_pid accepted a stale start time" || ok "owned_pid rejects a stale start time"
printf '%s %s' "$$" "$mystart" > "$STATE_DIR/x-1.pid"
alive "$STATE_DIR/x-1.pid" "$me" && ok "alive reads pid and start from the pidfile" || bad "alive rejected a live pidfile"
printf '%s %s' "$$" "$((mystart + 1))" > "$STATE_DIR/x-1.pid"
alive "$STATE_DIR/x-1.pid" "$me" && bad "alive accepted a reused pid" || ok "alive rejects a reused pid"

# The state directory is read in one descriptor-relative pass; a planted FIFO
# cannot block it, a link is not a file, and too many entries fail closed.
mkfifo "$STATE_DIR/cloudflared-4446.pid"; printf 'https://f.trycloudflare.com' > "$STATE_DIR/cloudflared-4446.url"
out=$(timeout 10 bash -c 'source "'"$S"'/tunnels.sh"; cmd_status' 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "status returns with a FIFO planted at a pidfile path" || bad "status blocked or failed (rc=$rc)"
is "and the FIFO-backed entry is not a tunnel" "$(jq -c '[.tunnels[]|select(.port==4446)]|length' <<<"$out")" "0"
[[ -e $STATE_DIR/cloudflared-4446.url ]] && ok "and the unreadable pidfile's records are kept" || bad "status cleared records over an unreadable pidfile"
rm -f "$STATE_DIR/cloudflared-4446".*
crowd=$(mktemp -d); for i in $(seq 1 600); do : > "$crowd/f$i"; done
is "a state directory with too many entries dumps nothing" "$(state_dump "$crowd" | jq -c '.files|length')" "0"
rm -rf "$crowd"
# State is read only from plain files we own; a planted link is not a file.
ln -s /etc/hostname "$STATE_DIR/cloudflared-4445.url"; ln -s /proc/self/stat "$STATE_DIR/cloudflared-4445.pid"
is "read_own returns nothing for a symlink" "$(read_own "$STATE_DIR/cloudflared-4445.url")" ""
before=$(wc -c < /etc/hostname)
write_own "$STATE_DIR/cloudflared-4445.url" "replaced"
[[ -L $STATE_DIR/cloudflared-4445.url ]] && bad "write_own followed a link" || ok "write_own replaces a link with a file"
is "and the target was never touched" "$(wc -c < /etc/hostname)" "$before"
rm -f "$STATE_DIR"/cloudflared-4445.*
mkdir -p "$T/notmine"; chmod 700 "$T/notmine"; ln -s "$T/notmine" "$T/link-dir"
own_dir "$T/link-dir" && bad "own_dir accepted a symlinked directory" || ok "own_dir rejects a symlinked directory"
printf 'x' > "$T/notmine/leaf"; is "a leaf under a symlinked parent is refused" "$(cat_own "$T/link-dir/leaf")" ""
chmod 770 "$T/notmine"; is "a leaf under a group-writable directory is refused" "$(cat_own "$T/notmine/leaf")" ""; chmod 700 "$T/notmine"
is "write_own creates 0600" "$(write_own "$T/notmine/w" v; stat -c %a "$T/notmine/w")" "600"
printf 'x' > "$T/notmine/loose"; chmod 666 "$T/notmine/loose"
is "a leaf writable by others is refused" "$(cat_own "$T/notmine/loose")" ""
chmod 644 "$T/notmine/loose"; is "and read once it is not" "$(cat_own "$T/notmine/loose")" "x"

# Provider binaries run by absolute, validated path only.
mkdir -p "$T/bin"; printf '#!/bin/sh\n' > "$T/bin/fakeprov"; chmod 777 "$T/bin/fakeprov"
PATH="$T/bin:$PATH" resolve_bin fakeprov >/dev/null && bad "resolve_bin accepted a world-writable executable" || ok "resolve_bin rejects a world-writable executable"
chmod 755 "$T/bin/fakeprov"; is "resolve_bin returns the absolute path of a safe one" "$(PATH="$T/bin:$PATH" resolve_bin fakeprov)" "$T/bin/fakeprov"
resolve_bin definitely-not-a-command-xyz >/dev/null && bad "resolve_bin found a ghost" || ok "resolve_bin fails for a missing command"
# Every directory on the way must be root's or ours and swappable by nobody
# else: a world-writable ancestor fails, a sticky one (like /tmp) does not.
mkdir -p "$T/open/bin" "$T/stuck/bin"; cp "$T/bin/fakeprov" "$T/open/bin/"; cp "$T/bin/fakeprov" "$T/stuck/bin/"
chmod 777 "$T/open"; chmod 1777 "$T/stuck"
PATH="$T/open/bin:$PATH" resolve_bin fakeprov >/dev/null && bad "resolve_bin accepted a world-writable ancestor" || ok "resolve_bin rejects a world-writable ancestor"
is "resolve_bin accepts a sticky ancestor" "$(PATH="$T/stuck/bin:$PATH" resolve_bin fakeprov)" "$T/stuck/bin/fakeprov"
state launch "$STATE_DIR" open.log -- "$T/open/bin/fakeprov" >/dev/null 2>&1 && bad "launch ran a binary under a world-writable ancestor" || ok "launch refuses a binary under a world-writable ancestor"

# launch: a session of its own, a private log, pid bound to start time.
out=$(state launch "$STATE_DIR" launch-test.log -- /usr/bin/sleep 20); lpid=${out%% *}; lstart=${out#* }
owned_pid "$lpid" sleep "$lstart" && ok "launch reports a pid whose start time matches" || bad "launch pid/start mismatch: $out"
[[ $(ps -o sid= -p "$lpid" | tr -d ' ') == "$lpid" ]] && ok "the launched process leads its own session" || bad "launched process is not a session leader"
is "the launch log is private" "$(stat -c %a "$STATE_DIR/launch-test.log")" "600"
kill "$lpid" 2>/dev/null
# A launched tunnel keeps only stdio and its executable: any other inherited
# descriptor would stay open for the tunnel's whole life — a lifecycle lock
# held across the launch would never release, failing every later start and
# hanging uninstall's exclusive wait forever.
LT="$T/lockinh"; mkdir -p "$LT"
{ exec 8>"$LT/.lifecycle.lock"; } 2>/dev/null && flock -n -x 8 2>/dev/null || bad "could not hold a test lock"
lout=$(state launch "$LT" inh.log -- /usr/bin/sleep 300); lpid=${lout%% *}
exec 8>&- 2>/dev/null || true
if ls -l "/proc/$lpid/fd" 2>/dev/null | grep -q "lifecycle.lock"; then bad "the tunnel inherited the lifecycle lock"; else ok "the tunnel inherits no lock descriptor"; fi
flock -n -x "$LT/.lifecycle.lock" -c true 2>/dev/null && ok "the lock is acquirable while the tunnel lives" || bad "the tunnel still holds the lock"
kill "$lpid" 2>/dev/null
is "cmd_stop rejects an unknown provider" "$(cmd_stop nope 1 | jq -r .error)" "unknown provider"
# A stub provider: an ELF copy (so the process carries the provider's name)
# whose URL and argv the sourced functions supply. Nothing touches the network.
mkdir -p "$T/prov"; cp /usr/bin/sleep "$T/prov/cloudflared"
stub_env() {   # run a snippet with the stub as cloudflared and no DNS gate
  PATH="$T/prov:$PATH" PORTAL_STATE_DIR="$1" bash -c 'source "'"$S"'/tunnels.sh"
    cloudflared_argv() { echo 300; }; cloudflared_url_from_log() { echo https://stub-one-two.trycloudflare.com; }
    dns_gate() { return 0; }; portless_state_load; '"$2"
}
# A tunnel whose pidfile cannot be written is stopped again, not left public with no record.
R1="$T/rt1"; mkdir -p "$R1/cloudflared-4449.pid"
is "start reports a pidfile it could not write" "$(stub_env "$R1" 'cmd_start cloudflared 4449' | jq -r .error)" "could not record the cloudflared process; it was stopped again"
sleep 0.3; pgrep -f "$T/prov/cloudflared" >/dev/null && bad "the unrecorded tunnel is still running" || ok "and the unrecorded tunnel was stopped"
rmdir "$R1/cloudflared-4449.pid"
is "the same start succeeds once the pidfile can be written" "$(stub_env "$R1" 'cmd_start cloudflared 4449' | jq -r .url)" "https://stub-one-two.trycloudflare.com"
# A status snapshot taken before a replacement started does not clear the replacement.
snap=$(state dump "$R1" 8192 4096); old=$(cat "$R1/cloudflared-4449.pid")
stub_env "$R1" 'cmd_stop cloudflared 4449 >/dev/null'
stub_env "$R1" 'cmd_start cloudflared 4449 >/dev/null'
[[ $(cat "$R1/cloudflared-4449.pid") != "$old" ]] && ok "a replacement wrote its own pidfile" || bad "no replacement pidfile"
SNAP="$snap" stub_env "$R1" 'state() { if [[ $1 == dump && $2 == "$STATE_DIR" ]]; then printf "%s" "$SNAP"; else /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; fi; }; cmd_status >/dev/null'
is "status with a stale snapshot leaves the replacement's records" "$(ls "$R1" | grep -c '^cloudflared-4449\.')" "4"
# A share whose reach record is missing still carries its pid to the check.
rm -f "$R1/cloudflared-4449.reach"
stub_env "$R1" 'cmd_status >/dev/null'
is "status keeps a live share with no reach record" "$(ls "$R1" | grep -c -E '^cloudflared-4449\.(pid|url)$')" "2"
# stop-own refuses to guess when the state cannot be listed.
(cd "$R1" && touch $(seq -f 'crowd-%g' 1 4100))
is "stop-own fails closed when the state cannot be listed" "$(PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" stop-own | jq -r .error)" "could not list Portal's state; nothing was stopped"
is "status fails closed when the state cannot be listed" "$(PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" status | jq -r .error)" "could not list Portal's state"
is "stop-all fails instead of claiming success when the state cannot be listed" "$(PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" stop-all | jq -r .error)" "could not list tunnels; nothing was stopped"
# Rows are capped like the scanner's ports: past the cap, an error, not a document.
RC="$T/rows"; mkdir -p "$RC"; for i in $(seq 1 520); do printf 'https://a-b-%s.trycloudflare.com' "$i" > "$RC/cloudflared-$((10000 + i)).url"; printf '999999 1' > "$RC/cloudflared-$((10000 + i)).pid"; done
is "status reports an error past the row cap" "$(PORTAL_STATE_DIR="$RC" bash -c 'source "'"$S"'/tunnels.sh"; alive_line() { return 0; }; portless_state_load; cmd_status' | jq -r .error)" "more than 512 tunnels"
# When the Portless directory is over its cap, status keeps the portless markers
# rather than reading the refused dump as "the route vanished".
PS="$T/pstate"; mkdir -p "$PS"; for i in $(seq 1 520); do : > "$PS/j$i"; done
PD="$T/prt"; mkdir -p "$PD"; printf 'https://acme.localhost' > "$PD/portless-3000.url"; printf 'acme' > "$PD/portless-3000.name"; printf 'local' > "$PD/portless-3000.reach"
PORTLESS_STATE_DIR="$PS" PORTAL_STATE_DIR="$PD" bash -c 'source "'"$S"'/tunnels.sh"; cmd_status >/dev/null'
is "status keeps portless markers when the Portless state is unreadable" "$(ls "$PD" | grep -c '^portless-3000\.')" "3"
rm -f "$R1"/crowd-*
is "stop-own stops what it can list" "$(PATH="$T/prov:$PATH" PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" stop-own | jq -c .ok)" "true"
sleep 0.3; pgrep -f "$T/prov/cloudflared" >/dev/null && bad "stop-own left the tunnel running" || ok "and the tunnel is gone"
# An expired idle timer in a stale snapshot stops nothing but the snapshot's own process.
stub_env "$R1" 'cmd_start cloudflared 4449 >/dev/null'; old=$(cat "$R1/cloudflared-4449.pid")
printf '%s' $(( $(printf '%(%s)T' -1) - 700 )) > "$R1/cloudflared-4449.idle"
snap=$(state dump "$R1" 8192 4096)
state launch "$R1" cloudflared-4449.log -- "$T/prov/cloudflared" 300 > "$R1/cloudflared-4449.pid"; rm -f "$R1/cloudflared-4449.idle"
SNAP="$snap" stub_env "$R1" 'state() { if [[ $1 == dump && $2 == "$STATE_DIR" ]]; then printf "%s" "$SNAP"; else /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; fi; }; cmd_status >/dev/null'
sleep 0.2; kill -0 "${old%% *}" 2>/dev/null && ok "the snapshot's own process is left to its live status" || bad "the old process was stopped from a stale snapshot"
kill -0 "$(cut -d' ' -f1 "$R1/cloudflared-4449.pid")" 2>/dev/null && ok "and the replacement was not stopped" || bad "the replacement was stopped from a stale snapshot"
kill "${old%% *}" 2>/dev/null
# A stop is a stop only once the process is gone: it fails, keeping the records, when nothing works.
is "cmd_stop fails when the process will not die" "$(stub_env "$R1" 'STOP_TERM_WAIT=2; STOP_KILL_WAIT=2; proc() { :; }; kill() { :; }; cmd_stop cloudflared 4449' | jq -r .error)" "cloudflared on port 4449 did not stop; its records are kept"
is "and keeps its records" "$(ls "$R1" | grep -c -E '^cloudflared-4449\.(pid|url)$')" "2"
# An idle tunnel whose stop failed stays in the status, records and all.
printf '%s' $(( $(printf '%(%s)T' -1) - 700 )) > "$R1/cloudflared-4449.idle"
is "status keeps listing an idle tunnel it could not stop" "$(stub_env "$R1" 'STOP_TERM_WAIT=2; STOP_KILL_WAIT=2; proc() { :; }; kill() { :; }; cmd_status' | jq -c '[.tunnels[]|select(.provider=="cloudflared" and .port==4449)|.port]')" "[4449]"
is "and its records" "$(ls "$R1" | grep -c -E '^cloudflared-4449\.(pid|url)$')" "2"
stub_env "$R1" 'cmd_stop cloudflared 4449 >/dev/null'   # a real stop ends the replacement
# A process that ignores TERM is killed, and the stop reports only once it is gone.
setsid bash -c 'trap "" TERM; exec "'"$T"'/prov/cloudflared" 300' >/dev/null 2>&1 & sleep 0.4
ig=$(ps -eo pid,comm,args | awk -v p="$T/prov/cloudflared 300" '$2=="cloudflared" && index($0, p) {print $1}' | head -1)
printf '%s %s' "$ig" "$(awk '{print $22}' "/proc/$ig/stat")" > "$R1/cloudflared-4449.pid"
is "cmd_stop escalates past an ignored TERM" "$(stub_env "$R1" 'cmd_stop cloudflared 4449' | jq -c .ok)" "true"
kill -0 "$ig" 2>/dev/null && bad "the TERM-ignoring process is still alive after ok:true" || ok "and the process is gone before ok:true"
# stop-all reports a tunnel it could not stop, rather than claiming success.
setsid bash -c 'trap "" TERM; exec "'"$T"'/prov/cloudflared" 300' >/dev/null 2>&1 & sleep 0.4
sg=$(ps -eo pid,comm,args | awk -v p="$T/prov/cloudflared 300" '$2=="cloudflared" && index($0, p) {print $1}' | head -1)
printf '%s %s' "$sg" "$(awk '{print $22}' "/proc/$sg/stat")" > "$R1/cloudflared-4449.pid"
printf 'https://a-b-c.trycloudflare.com' > "$R1/cloudflared-4449.url"; printf 'public' > "$R1/cloudflared-4449.reach"
is "stop-all reports a tunnel it could not stop" "$(stub_env "$R1" 'STOP_TERM_WAIT=2; STOP_KILL_WAIT=2; proc() { :; }; kill() { :; }; cmd_stop_all' | jq -r .ok)" "false"
kill "$sg" 2>/dev/null
# --owner with no value is rejected at once, not spun on.
is "start rejects a bare --owner" "$(timeout 5 bash -c 'source "'"$S"'/tunnels.sh"; portless_state_load; cmd_start cloudflared 3000 --owner' | jq -r .error)" "invalid owner pid"
# stop-own enumerates a portless name-only partial start (alias written, url not yet).
PN="$T/pn"; mkdir -p "$PN"; printf 'acme' > "$PN/portless-4460.name"
is "stop-own enumerates a portless name-only partial" "$(PORTAL_STATE_DIR="$PN" bash -c 'source "'"$S"'/tunnels.sh"; state dump "$STATE_DIR" 8192 "$STATE_FILES_CAP" 2>/dev/null | jq -r '"'"'.files | keys[] | select(test("^[a-z]+-[0-9]+\\.(url|pid|name)$")) | sub("\\.(url|pid|name)$"; "")'"'"'')" "portless-4460"
# A start that names the process it is for refuses a port that process no longer serves.
python3 -m http.server 4470 --bind 127.0.0.1 >/dev/null 2>&1 & lp=$!; sleep 0.6
is "start refuses a port served by another pid" "$(stub_env "$R1" 'cmd_start cloudflared 4470 --owner 1' | jq -r .error)" "port 4470 is no longer served by pid 1"
is "start rejects a malformed owner" "$(stub_env "$R1" 'cmd_start cloudflared 4470 --owner 0x1' | jq -r .error)" "invalid owner pid"
is "start proceeds for the pid that serves the port" "$(stub_env "$R1" "cmd_start cloudflared 4470 --owner $lp" | jq -c .ok)" "true"
stub_env "$R1" 'cmd_stop cloudflared 4470 >/dev/null'; kill "$lp" 2>/dev/null
is "cmd_stop rejects a bad port" "$(cmd_stop cloudflared x | jq -r .error)" "invalid port"
# A pidfile that is present but unreadable is a failure, not an adopt-and-forget.
UB="$T/unread"; mkdir -p "$UB"; : > "$UB/cloudflared-4600.pid"; printf 'https://x-y.trycloudflare.com' > "$UB/cloudflared-4600.url"
is "cmd_stop fails on an empty pidfile rather than clearing state" "$(PORTAL_STATE_DIR="$UB" bash -c 'source "'"$S"'/tunnels.sh"; portless_state_load; cmd_stop cloudflared 4600' | jq -r .error)" "cloudflared on port 4600 has a pidfile that cannot be read; its records are kept"
is "and the records are kept" "$(ls "$UB" | grep -c -E '^cloudflared-4600\.(pid|url)$')" "2"
# owned_pid accepts a process whose executable path shows "(deleted)".
sleep 300 & dpid=$!; dstart=$(cut -d')' -f2- "/proc/$dpid/stat" | awk '{print $20}')
is "owned_pid matches by comm regardless of a deleted exe" "$(bash -c 'source "'"$S"'/tunnels.sh"; owned_pid '"$dpid"' sleep '"$dstart"' && echo yes || echo no')" "yes"
kill "$dpid" 2>/dev/null

# ---- proc.py: capped runs, and signals bound to one process -----------------
PR="$S/lib/proc.py"
is "run passes output and exit status through" "$(/usr/bin/python3 -I -S "$PR" run 1000 5 -- bash -c 'echo hello; exit 3'; echo "rc=$?")" "hello
rc=3"
out=$(/usr/bin/python3 -I -S "$PR" run 100 5 -- bash -c 'sleep 40 & yes | head -c 5000; wait' 2>/dev/null); rc=$?
is "run returns 125 past the output cap" "$rc" "125"
is "and passes nothing on" "${#out}" "0"
sleep 0.2; ps -eo args | grep -q '^sleep 40$' && bad "run left the helper's child behind past the cap" || ok "and ends the whole process group"
out=$(/usr/bin/python3 -I -S "$PR" run 1000 1 -- bash -c 'sleep 41 & wait' 2>/dev/null); rc=$?
is "run returns 124 past the deadline" "$rc" "124"
ps -eo args | grep -q '^sleep 41$' && bad "run left the helper's child behind past the deadline" || ok "and ends that group too"
# A descendant that stays in the group (no setsid), inherits the pipes and
# ignores TERM is still killed once the deadline's grace period passes. It
# records its own pid; run blocks for the deadline plus the grace, so by the
# time it returns the process is gone, not merely a zombie.
dmark="$T/desc.pid"
/usr/bin/python3 -I -S "$PR" run 100000 1 -- bash -c '(trap "" TERM; echo $BASHPID > "'"$dmark"'"; exec sleep 300) & exit 0' >/dev/null 2>&1
dp=$(cat "$dmark" 2>/dev/null)
if [[ -n $dp && -e /proc/$dp && $(awk '{print $3}' "/proc/$dp/stat" 2>/dev/null) != Z ]]; then
  bad "a TERM-ignoring descendant survived the deadline (pid $dp)"; kill -9 "$dp" 2>/dev/null
else ok "run kills a TERM-ignoring descendant after the grace period"; fi
python3 -m http.server 4495 --bind 127.0.0.1 >/dev/null 2>&1 & lp=$!; sleep 0.6
lst=$(cut -d')' -f2- "/proc/$lp/stat" | awk '{print $20}')
/usr/bin/python3 -I -S "$PR" check "$lp" "$lst" && ok "check accepts the pid with its own start time" || bad "check refused the right process"
/usr/bin/python3 -I -S "$PR" check "$lp" "$((lst + 1))" && bad "check accepted a wrong start time" || ok "check refuses a wrong start time"
/usr/bin/python3 -I -S "$PR" signal "$lp" "$((lst + 1))" STOP && bad "signal sent to a wrong start time" || ok "signal refuses a wrong start time"
is "and the process was not touched" "$(cut -d')' -f2- "/proc/$lp/stat" | awk '{print $1}')" "S"
# lifecycle.sh carries the same identity from the scan to every signal.
is "lifecycle refuses a pid that is not the listed process" "$("$S/lifecycle.sh" pause "$lp" "$((lst + 1))" 4495 | jq -r .error)" "pid $lp is no longer the process that was listed"
is "lifecycle refuses a port the process does not own" "$("$S/lifecycle.sh" pause "$lp" "$lst" 4496 | jq -r .error)" "pid $lp no longer owns port 4496"
is "lifecycle pauses the listed process" "$("$S/lifecycle.sh" pause "$lp" "$lst" 4495 | jq -c .ok) $(cut -d')' -f2- "/proc/$lp/stat" | awk '{print $1}')" "true T"
is "lifecycle resumes it" "$("$S/lifecycle.sh" resume "$lp" "$lst" 4495 | jq -c .ok) $(cut -d')' -f2- "/proc/$lp/stat" | awk '{print $1}')" "true S"
is "lifecycle stops it" "$("$S/lifecycle.sh" stop "$lp" "$lst" 4495 | jq -c .ok)" "true"
sleep 0.5; kill -0 "$lp" 2>/dev/null && bad "the listener survived stop" || ok "and it is gone"
scan=$("$S/scan-ports.sh")
is "the scan carries a numeric start time for every attributed port" "$(jq -c '[.ports[] | select(.pid != null) | .start | type == "number"] | all' <<<"$scan")" "true"

# ---- statedir.py: a short write is completed, never reported as done --------
SW=$(mktemp -d); /usr/bin/python3 - "$SW" "$S/lib/statedir.py" <<'PY'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("sd", sys.argv[2]); sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
real = os.write
os.write = lambda fd, data: real(fd, bytes(data)[:5])   # the kernel takes five bytes at a time
dirfd = sd.open_dir(sys.argv[1], create=True)
sd.append_one(dirfd, "3000.jsonl", b'{"t":1,"a":1}\n', 100, 1 << 20)
sd.append_one(dirfd, "3000.jsonl", b'{"t":2,"a":2}\n', 100, 1 << 20)
sd.atomic_write(dirfd, "whole", b"0123456789" * 3)
PY
is "append completes short writes" "$(cat "$SW/3000.jsonl" | tr '\n' ' ')" '{"t":1,"a":1} {"t":2,"a":2} '
is "atomic writes complete short writes" "$(wc -c < "$SW/whole")" "30"
rm -rf "$SW"

# ---- portless-setup.sh status: installed means runnable ---------------------
mkdir -p "$T/pl"; printf '#!/bin/sh\n' > "$T/pl/portless"; chmod 777 "$T/pl/portless"
rep=$(PATH="$T/pl:$PATH" PORTAL_METRICS_DIR=$T/plm "$S/portless-setup.sh" status)
is "a portless the trusted resolver refuses is not installed" "$(jq -c .checks.installed <<<"$rep")" "false"
jq -r '.remaining[0]' <<<"$rep" | grep -q "is not a trusted executable" && ok "and the report says how to fix it" || bad "no fix hint: $(jq -c .remaining <<<"$rep")"
# A cloudflared install shadowed by an untrusted one earlier on PATH is refused,
# not silently installed where provider_bin will never find it.
SH="$T/shadow"; mkdir -p "$SH"; printf '#!/bin/sh\n' > "$SH/cloudflared"; chmod 777 "$SH/cloudflared"
is "install refuses when an untrusted cloudflared shadows the target" "$(PATH="$SH:$PATH" "$S/provider-install.sh" cloudflared 2>/dev/null | jq -r '.error // empty' | grep -c 'shadows the install')" "1"
# A setup step carrying a command arrives split: title for the card, command
# for its copy button. The engine is stubbed; only the split is exercised.
FB="$T/fakebin"; mkdir -p "$FB"; OLD_SD="$SCRIPT_DIR"
printf '#!/bin/bash\necho %s\n' "'{\"ok\":true,\"remaining\":[\"Do the thing\\u001fdo --it --now\"]}'" > "$FB/portless-setup.sh"
chmod +x "$FB/portless-setup.sh"; SCRIPT_DIR="$FB"
is "setup splits a command-carrying step" "$(cmd_setup portless 2>/dev/null | jq -c '{hint,copy}')" '{"hint":"Do the thing","copy":"do --it --now"}'
printf '#!/bin/bash\necho %s\n' "'{\"ok\":true,\"remaining\":[\"Just words\"]}'" > "$FB/portless-setup.sh"
is "setup passes a plain step through with no copy" "$(cmd_setup portless 2>/dev/null | jq -c .)" '{"ok":true,"hint":"Just words"}'
printf '#!/bin/bash\necho %s\n' "'{\"ok\":true,\"remaining\":[]}'" > "$FB/portless-setup.sh"
is "setup with nothing remaining reports bare ok" "$(cmd_setup portless 2>/dev/null | jq -c .)" '{"ok":true}'
SCRIPT_DIR="$OLD_SD"

# ---- portless-setup.sh untrust: a store that keeps the CA stays on record ----
if command -v certutil >/dev/null 2>&1 && [[ -f $HOME/.portless/ca.pem ]]; then
  U=$(mktemp -d); mkdir -p "$U/nss"
  certutil -d "sql:$U/nss" -N --empty-password >/dev/null 2>&1
  # The import itself, through the setup script's own function, and its record.
  PORTAL_METRICS_DIR=$U PORTLESS_STATE_DIR=$HOME/.portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$U"'/nss"' && ok "trust_store imports the CA" || bad "trust_store failed"
  certutil -d "sql:$U/nss" -L -n "portless Local CA" >/dev/null 2>&1 && ok "and the CA is in the store" || bad "the CA is not in the store"
  is "and the store is on record with a fingerprint" "$(cut -f1 "$U/trusted-stores"); $(cut -f2 "$U/trusted-stores" | grep -qE '^[0-9A-F]{64}$' && echo fp-ok)" "$U/nss; fp-ok"
  # A trust whose record cannot be written is undone: the store ends without the CA.
  mkdir -p "$U/rb/nss"; certutil -d "sql:$U/rb/nss" -N --empty-password >/dev/null 2>&1; mkdir -p "$U/rb/trusted-stores"
  PORTAL_METRICS_DIR=$U/rb PORTLESS_STATE_DIR=$HOME/.portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$U"'/rb/nss"' && bad "trust_store reported success without a record" || ok "trust_store fails when the record cannot be written"
  certutil -d "sql:$U/rb/nss" -L -n "portless Local CA" >/dev/null 2>&1 && bad "and left the CA trusted" || ok "and undoes the import"
  [[ -e $U/rb/ca-import.pem ]] && bad "the import file was left behind" || ok "and leaves no import file behind"
  # A record that exists but cannot be read is not treated as empty.
  cp "$U/trusted-stores" "$U/keep"; head -c 70000 /dev/zero | tr '\0' x > "$U/trusted-stores"
  is "untrust refuses an unreadable record" "$(PORTAL_METRICS_DIR=$U "$S/portless-setup.sh" untrust | jq -c .ok)" "false"
  [[ -e $U/trusted-stores ]] && ok "and keeps it" || bad "and deleted it"
  mv "$U/keep" "$U/trusted-stores"
  chmod 500 "$U/nss"
  is "untrust reports a store it could not clear" "$(PORTAL_METRICS_DIR=$U "$S/portless-setup.sh" untrust | jq -c '[.ok, (.remaining|length)]')" "[false,1]"
  chmod 700 "$U/nss"
  is "untrust succeeds once the store is writable" "$(PORTAL_METRICS_DIR=$U "$S/portless-setup.sh" untrust | jq -c .ok)" "true"
  certutil -d "sql:$U/nss" -L -n "portless Local CA" >/dev/null 2>&1 && bad "the CA is still in the store" || ok "and the CA is gone from the store"
  # A certificate that replaced Portal's under the same name is not deleted.
  V=$(mktemp -d); mkdir -p "$V/nss"; certutil -d "sql:$V/nss" -N --empty-password >/dev/null 2>&1
  PORTAL_METRICS_DIR=$V PORTLESS_STATE_DIR=$HOME/.portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$V"'/nss"' >/dev/null
  # replace the cert under the same nickname with a different self-signed CA
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$V/k.pem" -out "$V/other.pem" -days 1 -subj "/CN=portless Local CA" >/dev/null 2>&1
  certutil -d "sql:$V/nss" -D -n "portless Local CA" >/dev/null 2>&1
  certutil -d "sql:$V/nss" -A -t "C,," -n "portless Local CA" -i "$V/other.pem" >/dev/null 2>&1
  out=$(PORTAL_METRICS_DIR=$V "$S/portless-setup.sh" untrust)
  is "untrust reports success when the recorded cert is gone" "$(jq -c .ok <<<"$out")" "true"
  certutil -d "sql:$V/nss" -L -n "portless Local CA" >/dev/null 2>&1 && ok "and leaves a replacement cert under the same name in place" || bad "untrust deleted a cert Portal did not import"
  rm -rf "$V"
  # A ledger that exists but cannot be read is not an empty one: no import may
  # overwrite it and orphan every earlier record.
  W=$(mktemp -d); mkdir -p "$W/nss" "$W/nss2"
  certutil -d "sql:$W/nss" -N --empty-password >/dev/null 2>&1
  certutil -d "sql:$W/nss2" -N --empty-password >/dev/null 2>&1
  PORTAL_METRICS_DIR=$W PORTLESS_STATE_DIR=$HOME/.portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$W"'/nss"' >/dev/null
  chmod 777 "$W/trusted-stores"
  PORTAL_METRICS_DIR=$W PORTLESS_STATE_DIR=$HOME/.portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$W"'/nss2"' >/dev/null 2>&1 \
    && bad "trust_store imported over an unreadable ledger" || ok "trust_store refuses when the ledger cannot be read"
  is "and the earlier record survives" "$(wc -l < "$W/trusted-stores")" "1"
  chmod 700 "$W/trusted-stores"; rm -rf "$W"
  rm -rf "$U"
else
  ok "untrust checks skipped (no certutil or no local Portless CA)"
fi

# ---- metrics.sh --------------------------------------------------------------
export PORTAL_METRICS_DIR="$T/metrics"
M="$S/metrics.sh"
is "watched starts empty" "$("$M" watched)" '{"ok":true,"ports":[]}'
"$M" watch 3000 >/dev/null; "$M" watch 5173 >/dev/null
is "watch appends and dedups" "$("$M" watch 3000 | jq -c .ports)" '[3000,5173]'
printf '{"a":1}' > "$PORTAL_METRICS_DIR/watched.json"
is "a non-array watched file reads as empty" "$("$M" watched | jq -c .ports)" '[]'
printf '[1]\n[2]\n' > "$PORTAL_METRICS_DIR/watched.json"
is "a multi-document watched file reads its first array" "$("$M" watched | jq -c .ports)" '[1]'
is "watch rejects a bad port" "$("$M" watch 70000 | jq -r .error)" "invalid port"
"$M" append-batch '{"3000":{"t":1,"conns":2},"junk":{"t":1}}' >/dev/null
is "append-batch writes one line per valid port" "$(wc -l < "$PORTAL_METRICS_DIR/metrics/3000.jsonl")" "1"
[[ -e $PORTAL_METRICS_DIR/metrics/junk.jsonl ]] && bad "append-batch wrote an invalid port" || ok "append-batch skips an invalid port"
printf '{"t":2,"con' >> "$PORTAL_METRICS_DIR/metrics/3000.jsonl"   # a torn line
is "read survives a torn last line" "$("$M" read 3000 | jq -c '.samples|length')" "1"
ln -s /etc/hostname "$PORTAL_METRICS_DIR/metrics/5000.jsonl"
is "read refuses a symlinked sample file" "$("$M" read 5000 | jq -c '.samples|length')" "0"
"$M" append-batch '{"5000":{"t":1}}' >/dev/null
[[ ! -L $PORTAL_METRICS_DIR/metrics/5000.jsonl && -f $PORTAL_METRICS_DIR/metrics/5000.jsonl && $(wc -c < /etc/hostname) == "$before" ]] && ok "append replaces a planted link with a fresh file and never follows it" || bad "append followed or kept a symlinked path"
mkfifo "$PORTAL_METRICS_DIR/metrics/5001.jsonl"
is "read of a planted FIFO returns at once, empty" "$(timeout 5 "$M" read 5001 | jq -c '.samples|length')" "0"
"$M" append-batch '{"5001":{"t":1}}' >/dev/null; [[ -f $PORTAL_METRICS_DIR/metrics/5001.jsonl && ! -p $PORTAL_METRICS_DIR/metrics/5001.jsonl ]] && ok "append replaces a planted FIFO with a fresh file" || bad "append left or blocked on a FIFO"
big=$(mktemp -p "$PORTAL_METRICS_DIR/metrics"); head -c 9000000 /dev/zero > "$big"; mv "$big" "$PORTAL_METRICS_DIR/metrics/5002.jsonl"
is "read refuses a file past the cap" "$(timeout 5 "$M" read 5002 | jq -c '.samples|length')" "0"
# 19300 x ~130 B is past MAX_BYTES, so the append trims to MAX_LINES.
yes '{"t":1756700000,"conns":0,"cpuPct":0,"rssKb":73000,"latMs":12,"httpCode":200,"pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' | head -n 19300 > "$PORTAL_METRICS_DIR/metrics/4000.jsonl"
"$M" append-batch '{"4000":{"t":2}}' >/dev/null
lines=$(wc -l < "$PORTAL_METRICS_DIR/metrics/4000.jsonl"); bytes=$(wc -c < "$PORTAL_METRICS_DIR/metrics/4000.jsonl")
(( lines > 0 && lines <= 17280 && bytes <= 2097152 )) && ok "append-batch trims to what fits under the cap ($lines lines, $bytes bytes)" || bad "trim left $lines lines, $bytes bytes"
"$M" unwatch 3000 >/dev/null
[[ -e $PORTAL_METRICS_DIR/metrics/3000.jsonl ]] && bad "unwatch left the metric file" || ok "unwatch deletes the metric file"
is "state files are private" "$(stat -c %a "$PORTAL_METRICS_DIR/metrics/4000.jsonl")" "600"

echo; echo "$pass passed, $fail failed"
exit $((fail > 0))
