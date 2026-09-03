#!/bin/bash
# Unit tests for the shell side: the portless library, the tunnels.sh
# validators, and metrics.sh's file handling. Everything runs against
# throwaway state directories; nothing here touches the live system.
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
S="$(cd "$HERE/../scripts" && pwd)"
PR="$S/lib/proc.py"
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
printf '[{"port":3000,"hostname":"acme.localhost","pid":0},{"port":5173,"hostname":"dash.test","pid":0}]' > "$PORTLESS_STATE_DIR/routes.json"
is "route_name strips the TLD" "$(portless_route_name 5173)" "dash"
is "route_name is empty for an unknown port" "$(portless_route_name 9)" ""
BAD_ROUTES="$T/bad-routes"; mkdir -p "$BAD_ROUTES"
printf '["bad",{"port":3000,"hostname":"app.localhost","pid":0}]' > "$BAD_ROUTES/routes.json"
bad_routes=$(PORTLESS_STATE_DIR="$BAD_ROUTES" bash -c '
  source "'"$S"'/lib/portless.sh"
  portless_state_load
  printf "%s|%s" "$?" "$PORTLESS_STATE_ERROR"
')
is "a malformed Portless entry rejects the route snapshot" "$bad_routes" "1|routes.json is malformed"

# ---- tunnels.sh validators -------------------------------------------------
me=$(< /proc/$$/comm)
valid_url "https://a-b.trycloudflare.com" && ok "valid_url accepts a hostname" || bad "valid_url rejected a hostname"
valid_url "http://acme.localhost:1355/x?y=1" && ok "valid_url accepts port and path" || bad "valid_url rejected port+path"
valid_url "javascript:alert(1)" && bad "valid_url accepted javascript:" || ok "valid_url rejects javascript:"
valid_url "https://evil.com/x y" && bad "valid_url accepted a space" || ok "valid_url rejects whitespace"
valid_url "ftp://x" && bad "valid_url accepted ftp" || ok "valid_url rejects other schemes"
valid_url "https://x/a$(printf '\037')b" && bad "valid_url accepted a unit separator" || ok "valid_url rejects a unit separator"
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

signal_log="$T/safety-signals"
SIGNAL_LOG="$signal_log" S="$S" bash -c '
  source "$S/tunnels.sh"
  proc() { printf "proc %s\n" "$*" >> "$SIGNAL_LOG"; return 1; }
  kill() { printf "kill %s\n" "$*" >> "$SIGNAL_LOG"; return 1; }
  alive_line() { return 0; }
  group_alive() { return 0; }
  STOP_TERM_WAIT=0; STOP_KILL_WAIT=0
  stop_line "1 1" cloudflared; [[ $? -ne 0 ]] || exit 11
  for line in "0 0" "-1 1" "" "2 nope"; do stop_line "$line" cloudflared; [[ $? -ne 0 ]] || exit 12; done
  stop_line "999999999999999999999 1" cloudflared; [[ $? -ne 0 ]] || exit 13
' >/dev/null 2>&1; rc=$?
is "dangerous pid records fail before a signal path" "$rc $(grep -Ec -- '(^| )-(0|1)( |$)' "$signal_log" 2>/dev/null || true)" "0 0"

GROUP_ONLY="$T/group-only"; mkdir -p "$GROUP_ONLY"/{stop,start,status}; : > "$GROUP_ONLY/signals"; : > "$GROUP_ONLY/launches"
GROUP_ONLY="$GROUP_ONLY" S="$S" bash -c '
  source "$S/tunnels.sh"
  proc() { printf "proc %s\n" "$*" >> "$GROUP_ONLY/signals"; return 1; }
  kill() { printf "kill %s\n" "$*" >> "$GROUP_ONLY/signals"; return 1; }
  alive_line() { return 1; }
  group_alive() { return 0; }
  state() {
    if [[ $1 == launch-tracked ]]; then printf "launch %s\n" "$*" >> "$GROUP_ONLY/launches"; return 1; fi
    /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"
  }
  provider_bin() { printf /usr/bin/true; }
  target_owns_port() { return 0; }
  cloudflared_argv() { printf "300\n"; }
  ss() { return 0; }
  STOP_TERM_WAIT=0; STOP_KILL_WAIT=0

  stop_line "999999 1" cloudflared; stop_rc=$?
  printf "%s" "$((stop_rc != 0))" > "$GROUP_ONLY/stop-line-failed"

  STATE_DIR="$GROUP_ONLY/stop"
  printf "999999 1" > "$STATE_DIR/cloudflared-4501.pid"
  printf "https://group-only.trycloudflare.com" > "$STATE_DIR/cloudflared-4501.url"
  stop_out=$(cmd_stop cloudflared 4501); printf "%s" "$stop_out" > "$GROUP_ONLY/stop.out"

  STATE_DIR="$GROUP_ONLY/start"
  printf "999999 1" > "$STATE_DIR/cloudflared-4502.pid"
  printf "https://group-only.trycloudflare.com" > "$STATE_DIR/cloudflared-4502.url"
  state dump "$STATE_DIR" 8192 32 | jq -S . > "$GROUP_ONLY/start.before"
  start_out=$(cmd_start cloudflared 4502 --target 999999 1); printf "%s" "$start_out" > "$GROUP_ONLY/start.out"
  state dump "$STATE_DIR" 8192 32 | jq -S . > "$GROUP_ONLY/start.after"

  STATE_DIR="$GROUP_ONLY/status"
  printf "999999 1" > "$STATE_DIR/cloudflared-4503.pid"
  printf "https://group-only.trycloudflare.com" > "$STATE_DIR/cloudflared-4503.url"
  status_out=$(cmd_status); printf "%s" "$status_out" > "$GROUP_ONLY/status.out"
' >/dev/null 2>&1
is "a group-only identity makes stop_line fail closed" "$(cat "$GROUP_ONLY/stop-line-failed")" "1"
is "cmd_stop fails and keeps group-only records" "$(jq -c .ok "$GROUP_ONLY/stop.out") $(find "$GROUP_ONLY/stop" -maxdepth 1 -type f | wc -l)" "false 2"
cmp -s "$GROUP_ONLY/start.before" "$GROUP_ONLY/start.after" && group_start_state=same || group_start_state=changed
is "cmd_start fails without launching or altering group-only records" "$(jq -c .ok "$GROUP_ONLY/start.out") $(wc -l < "$GROUP_ONLY/launches") $group_start_state" "false 0 same"
is "cmd_status fails and keeps group-only records" "$(jq -c .ok "$GROUP_ONLY/status.out") $(find "$GROUP_ONLY/status" -maxdepth 1 -type f | wc -l)" "false 2"
is "group-only records never reach a signal path" "$(wc -l < "$GROUP_ONLY/signals") $(grep -Ec -- '(^| )-(0|1)( |$)' "$GROUP_ONLY/signals" 2>/dev/null || true)" "0 0"

RESTART_GROUP="$T/restart-group"; mkdir -p "$RESTART_GROUP"; : > "$RESTART_GROUP/effects"
printf '999999 1' > "$RESTART_GROUP/.restart-4499.pid"
PORTAL_STATE_DIR="$RESTART_GROUP" EFFECTS="$RESTART_GROUP/effects" S="$S" bash -c '
  set -- noop
  source "$S/lifecycle.sh" >/dev/null
  proc() { printf "proc %s\n" "$*" >> "$EFFECTS"; return 1; }
  kill() {
    printf "kill %s\n" "$*" >> "$EFFECTS"
    [[ $* == "-0 -- -999999" ]]
  }
  for pid in 1 0 -1 "" nope; do group_alive "$pid" >/dev/null 2>&1 || true; done
  rollback_replacement 999999 1 .restart-4499.pid; rollback_rc=$?
  [[ -e $PORTAL_RUNTIME_DIR/.restart-4499.pid ]] && rollback_record=kept || rollback_record=lost
  failure=$(fail_restart 999999 1 .restart-4499.pid "restart did not bring a listener back on port 4499")
  [[ -e $PORTAL_RUNTIME_DIR/.restart-4499.pid ]] && failure_record=kept || failure_record=lost
  printf "%s\t%s\t%s\t%s\t%s\n" "$rollback_rc" "$rollback_record" \
    "$(jq -r .ok <<<"$failure")" "$(jq -r .effect <<<"$failure")" "$failure_record"
' > "$RESTART_GROUP/result"
is "restart rollback keeps a live descendant group's identity record" \
  "$(cat "$RESTART_GROUP/result")" $'1\tkept\tfalse\tstopped\tkept'
is "restart rollback only probes the guarded replacement group" \
  "$(grep -c '^kill -0 -- -999999$' "$RESTART_GROUP/effects") $(grep -Ec ' -- -(0|1)$' "$RESTART_GROUP/effects" || true)" "2 0"

ESCALATE_LOG="$GROUP_ONLY/escalate-signals" S="$S" bash -c '
  source "$S/tunnels.sh"
  checks=0; group_dead=0
  alive_line() { checks=$((checks + 1)); (( checks == 1 )); }
  group_alive() { (( group_dead == 0 )); }
  proc() { printf "proc %s\n" "$*" >> "$ESCALATE_LOG"; return 0; }
  kill() {
    printf "kill %s\n" "$*" >> "$ESCALATE_LOG"
    [[ $1 == -KILL ]] && group_dead=1
    return 0
  }
  STOP_TERM_WAIT=0; STOP_KILL_WAIT=1
  stop_line "999999 1" cloudflared
' >/dev/null 2>&1; rc=$?
is "a verified stop still escalates after its leader exits" "$rc $(grep -c "kill -KILL -- -999999" "$GROUP_ONLY/escalate-signals")" "0 1"

# cmd_stop must never signal a pid the pidfile names unless it is still the provider.
mkdir -p "$STATE_DIR"
printf '%s' "$$" > "$STATE_DIR/cloudflared-4444.pid"
printf 'https://x.trycloudflare.com' > "$STATE_DIR/cloudflared-4444.url"
out=$(cmd_stop cloudflared 4444)
is "cmd_stop refuses a malformed pid record" "$(jq -r .error <<<"$out")" "cloudflared on port 4444 has a malformed pidfile; its records are kept"
is "and keeps malformed ownership records" "$(ls "$STATE_DIR"/cloudflared-4444.* | wc -l)" "2"
rm -f "$STATE_DIR"/cloudflared-4444.*

# Concurrent first use: many helpers creating the same missing directory all succeed.
R=$(mktemp -d); for i in $(seq 1 12); do state ensure "$R/a/b/c" & done; wait; [[ -d $R/a/b/c ]] && ok "concurrent ensure creates the directory once, without error" || bad "concurrent ensure failed"; rm -rf "$R"

# The install marker is JSON, so a path with a space survives.
M=$(mktemp -d); mkdir -p "$M/my bin"; printf 'x' > "$M/my bin/cloudflared"; d=$(sha256sum "$M/my bin/cloudflared" | cut -d' ' -f1)
jq -nc --arg p "$M/my bin/cloudflared" --arg s "$d" '{path:$p, sha256:$s}' | state write "$M/installed-cloudflared"
plan=$(PORTAL_BIN_DIR="$M/my bin" PORTAL_METRICS_DIR=$M PORTAL_STATE_DIR=$M/rt "$S/uninstall.sh" --dry 2>&1)
grep -qF "would: state remove-digest $M/my bin cloudflared $d 134217728" <<<"$plan" && ok "uninstall finds a marked binary in a path with a space" || bad "uninstall lost the marked binary: $plan"
# State roots pointed at a shared directory lose only Portal's own entries.
mkdir -p "$M/shared/metrics" "$M/rt2" "$M/rt2/cloudflared-2.url"; printf keep > "$M/link-target"
: > "$M/shared/thesis.txt"; : > "$M/shared/trusted-stores"; : > "$M/shared/metrics/3000.jsonl"; : > "$M/rt2/cloudflared-1.url"; : > "$M/rt2/notes.txt"
ln -s "$M/link-target" "$M/shared/watched.json"; mkfifo "$M/rt2/ngrok.ok"
ln -s "$M/link-target" "$M/shared/unknown-link"; mkfifo "$M/rt2/unknown-fifo"
plan=$(PORTAL_METRICS_DIR=$M/shared PORTAL_STATE_DIR=$M/rt2 "$S/uninstall.sh" --dry 2>/dev/null)
grep -q 'rm -rf' <<<"$plan" && bad "uninstall would remove a state root wholesale" || ok "uninstall never removes a state root wholesale"
planned_regular=0; for name in trusted-stores 3000.jsonl cloudflared-1.url; do grep -Fq "$name" <<<"$plan" && planned_regular=$((planned_regular + 1)); done
is "uninstall removes Portal's entries by name" "$planned_regular" "3"
planned_special=0; for name in watched.json ngrok.ok; do grep -Fq "$name" <<<"$plan" && planned_special=$((planned_special + 1)); done
is "uninstall includes exact known symlink and FIFO leaves" "$planned_special" "2"
grep -qE 'thesis|notes|unknown-link|unknown-fifo|cloudflared-2\.url' <<<"$plan" && bad "uninstall would touch unknown leaves or directories" || ok "and leaves unknown leaves and directories alone"
remove_rc=0
timeout 5 /usr/bin/python3 -I -S "$S/lib/statedir.py" remove "$M/shared" watched.json >/dev/null 2>&1 || remove_rc=$?
timeout 5 /usr/bin/python3 -I -S "$S/lib/statedir.py" remove "$M/rt2" ngrok.ok cloudflared-2.url >/dev/null 2>&1 || remove_rc=$?
[[ -e $M/shared/watched.json || -L $M/shared/watched.json ]] && removed_link=kept || removed_link=gone
[[ -e $M/rt2/ngrok.ok ]] && removed_fifo=kept || removed_fifo=gone
is "descriptor-relative removal unlinks a symlink and FIFO without blocking" "$remove_rc $removed_link $removed_fifo" "0 gone gone"
is "descriptor-relative removal does not follow the symlink" "$(cat "$M/link-target")" "keep"
[[ -d $M/rt2/cloudflared-2.url ]] && ok "descriptor-relative removal keeps directories" || bad "descriptor-relative removal removed a directory"
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

restart_stop_own() {
  PORTAL_STATE_DIR="$1" GROUP_PRESENT="$2" EFFECTS="$3" LEADER_PRESENT="${4:-0}" S="$S" bash -c '
    source "$S/tunnels.sh"
    proc() { printf "proc %s\n" "$*" >> "$EFFECTS"; [[ $LEADER_PRESENT == 1 ]]; }
    kill() {
      printf "kill %s\n" "$*" >> "$EFFECTS"
      [[ $GROUP_PRESENT == 1 && $* == "-0 -- -999999" ]]
    }
    cmd_stop_own
  '
}
RESTART_OWN="$T/restart-stop-own"; mkdir -p "$RESTART_OWN/dead" "$RESTART_OWN/group" "$RESTART_OWN/live" "$RESTART_OWN/bad" "$RESTART_OWN/refused"
: > "$RESTART_OWN/effects"
printf '999999 1' > "$RESTART_OWN/dead/.restart-4497.pid"
dead_restart=$(restart_stop_own "$RESTART_OWN/dead" 0 "$RESTART_OWN/effects")
is "stop-own removes a restart record only after its group is gone" \
  "$(jq -r .ok <<<"$dead_restart") $(test -e "$RESTART_OWN/dead/.restart-4497.pid" && echo kept || echo gone)" "true gone"
printf '999999 1' > "$RESTART_OWN/group/.restart-4498.pid"
group_restart=$(restart_stop_own "$RESTART_OWN/group" 1 "$RESTART_OWN/effects")
is "stop-own keeps a restart record while its group survives" \
  "$(jq -r .ok <<<"$group_restart") $(test -e "$RESTART_OWN/group/.restart-4498.pid" && echo kept || echo gone)" "false kept"
printf '999999 1' > "$RESTART_OWN/live/.restart-4496.pid"
live_restart=$(restart_stop_own "$RESTART_OWN/live" 0 "$RESTART_OWN/effects" 1)
is "stop-own keeps a restart record while its exact leader survives" \
  "$(jq -r .ok <<<"$live_restart") $(test -e "$RESTART_OWN/live/.restart-4496.pid" && echo kept || echo gone)" "false kept"
printf 'bad identity' > "$RESTART_OWN/bad/.restart-4499.pid"
bad_restart=$(restart_stop_own "$RESTART_OWN/bad" 0 "$RESTART_OWN/effects")
is "stop-own rejects a malformed restart record before a process probe" \
  "$(jq -r .ok <<<"$bad_restart") $(test -e "$RESTART_OWN/bad/.restart-4499.pid" && echo kept || echo gone) $(grep -c '^proc ' "$RESTART_OWN/effects")" \
  "false kept 3"
ln -s /etc/hostname "$RESTART_OWN/refused/.restart-4495.pid"
refused_restart=$(restart_stop_own "$RESTART_OWN/refused" 0 "$RESTART_OWN/effects")
is "stop-own rejects a refused restart record before a process probe" \
  "$(jq -r .ok <<<"$refused_restart") $(test -L "$RESTART_OWN/refused/.restart-4495.pid" && echo kept || echo gone) $(grep -c '^proc ' "$RESTART_OWN/effects")" \
  "false kept 3"
is "restart cleanup only sends guarded group probes" \
  "$(grep -c '^kill -0 -- -999999$' "$RESTART_OWN/effects") $(grep -Ec ' -- -(0|1)$|^kill -(TERM|KILL)' "$RESTART_OWN/effects" || true)" "2 0"

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
is "and reports the refused ownership record" "$(jq -c .ok <<<"$out")" "false"
[[ -e $STATE_DIR/cloudflared-4446.url ]] && ok "and the unreadable pidfile's records are kept" || bad "status cleared records over an unreadable pidfile"
rm -f "$STATE_DIR/cloudflared-4446".*
LOG_STATE="$T/status-log-cap"; mkdir -p "$LOG_STATE"; : > "$T/status-log-signals"
printf '999999 1' > "$LOG_STATE/cloudflared-4449.pid"
printf 'https://one-two.trycloudflare.com' > "$LOG_STATE/cloudflared-4449.url"
printf 'public' > "$LOG_STATE/cloudflared-4449.reach"
truncate -s $((LOG_CAP + 1)) "$LOG_STATE/cloudflared-4449.log"
log_cap_result=$(PORTAL_STATE_DIR="$LOG_STATE" PORTLESS_STATE_DIR="$PORTLESS_STATE_DIR" \
  SIGNAL_LOG="$T/status-log-signals" S="$S" bash -c '
  source "$S/tunnels.sh"
  ss() { return 0; }
  portless_state_load() { return 0; }
  alive_line() { return 0; }
  reconcile_idle() { return 0; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { :; }
  kill() { printf "kill %s\n" "$*" >> "$SIGNAL_LOG"; return 1; }
  proc() { printf "proc %s\n" "$*" >> "$SIGNAL_LOG"; return 1; }
  out=$(cmd_status)
  printf "%s %s %s" "$(jq -r .ok <<<"$out")" \
    "$(stat -c %s "$STATE_DIR/cloudflared-4449.log")" "$(wc -l < "$SIGNAL_LOG")"
')
is "status truncates an oversized provider log without treating it as ownership state" \
  "$log_cap_result" "true 0 0"
DNS_STATE="$T/status-dns-budget"; mkdir -p "$DNS_STATE"; : > "$T/status-dns-calls"; : > "$T/status-dns-effects"
for i in $(seq 1 7); do
  port=$((4100 + i))
  printf 'https://pending-%s.trycloudflare.com' "$i" > "$DNS_STATE/cloudflared-$port.url"
  printf 'public' > "$DNS_STATE/cloudflared-$port.reach"
  printf '999999 1' > "$DNS_STATE/cloudflared-$port.pid"
  : > "$DNS_STATE/cloudflared-$port.dns"
done
dns_budget_result=$(PORTAL_STATE_DIR="$DNS_STATE" PORTLESS_STATE_DIR="$PORTLESS_STATE_DIR" \
  CALLS="$T/status-dns-calls" EFFECTS="$T/status-dns-effects" S="$S" bash -c '
  source "$S/tunnels.sh"
  ss() { return 0; }
  portless_state_load() { return 0; }
  alive_line() { return 0; }
  reconcile_idle() { return 0; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { :; }
  dns_published() {
    local step=${2:-3}
    printf "%s\n" "$step" >> "$CALLS"
    SECONDS=$((SECONDS + step))
    return 1
  }
  dns_resolves_here() { printf "network\n" >> "$EFFECTS"; return 1; }
  kill() { printf "kill\n" >> "$EFFECTS"; return 1; }
  proc() { printf "proc\n" >> "$EFFECTS"; return 1; }
  out=$(cmd_status)
  printf "%s %s %s %s %s" "$(jq -r .ok <<<"$out")" \
    "$(jq -r ".tunnels | length" <<<"$out")" \
    "$(jq -r "[.tunnels[]? | select(.dns == \"pending\")] | length" <<<"$out")" \
    "$(wc -l < "$CALLS")" "$(wc -l < "$EFFECTS")"
')
is "status shares one DNS deadline and still returns every pending row" \
  "$dns_budget_result" "true 7 7 2 0"
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
cp /usr/bin/true "$T/bin/execute-only"; chmod 111 "$T/bin/execute-only"
execute_only=$(state launch "$STATE_DIR" execute-only.log -- "$T/bin/execute-only" 2>/dev/null); execute_only_rc=$?
if (( execute_only_rc == 0 )) && [[ $execute_only =~ ^[1-9][0-9]*\ [1-9][0-9]*$ ]] && (( ${execute_only%% *} > 1 )); then
  ok "launch binds an execute-only ELF"
else
  bad "launch refused an execute-only ELF: rc=$execute_only_rc out=$execute_only"
fi

# launch: a session of its own, a private log, pid bound to start time.
out=$(state launch "$STATE_DIR" launch-test.log -- /usr/bin/sleep 20); lpid=${out%% *}; lstart=${out#* }
owned_pid "$lpid" sleep "$lstart" && ok "launch reports a pid whose start time matches" || bad "launch pid/start mismatch: $out"
[[ $(ps -o sid= -p "$lpid" | tr -d ' ') == "$lpid" ]] && ok "the launched process leads its own session" || bad "launched process is not a session leader"
is "the launch log is private" "$(stat -c %a "$STATE_DIR/launch-test.log")" "600"
kill "$lpid" 2>/dev/null
TRACKED="$T/tracked-launch"; mkdir -p "$TRACKED/blocked.pid"
printf '#!/bin/sh\nprintf ran > "'"$TRACKED"'/ran"\n' > "$TRACKED/provider"; chmod 755 "$TRACKED/provider"
state launch-tracked "$TRACKED" provider.log blocked.pid -- "$TRACKED/provider" >/dev/null 2>&1; rc=$?
sleep 0.1
is "a failed pid record prevents provider execution" "$rc $(test -e "$TRACKED/ran" && echo ran || echo blocked)" "1 blocked"
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
    dns_gate() { return 0; }; listener_identity() { echo "999999 1"; }; target_owns_port() { return 0; }
    portless_state_load; '"$2"
}
real_stub_env() {
  PATH="$T/prov:$PATH" PORTAL_STATE_DIR="$1" bash -c 'source "'"$S"'/tunnels.sh"
    cloudflared_argv() { echo 300; }; cloudflared_url_from_log() { echo https://stub-one-two.trycloudflare.com; }
    dns_gate() { return 0; }; portless_state_load; '"$2"
}
CANCEL="$T/cancel-start"; mkdir -p "$CANCEL"
PORTAL_STATE_DIR="$CANCEL" /usr/bin/python3 -I -S "$PR" run 1000 60 -- bash -c 'source "'"$S"'/tunnels.sh"
  cloudflared_argv() { echo 300; }; cloudflared_url_from_log() { return 1; }
  listener_identity() { echo "999999 1"; }; target_owns_port() { return 0; }
  dns_gate() { return 0; }; cmd_start cloudflared 4488' \
  >/dev/null 2>&1 & start_wrapper=$!
for _ in $(seq 1 100); do [[ -s $CANCEL/cloudflared-4488.pid ]] && break; sleep 0.02; done
cancel_identity=$(cat "$CANCEL/cloudflared-4488.pid" 2>/dev/null)
kill -TERM "$start_wrapper" 2>/dev/null; wait "$start_wrapper" 2>/dev/null; cancel_rc=$?
if [[ -n $cancel_identity ]] && proc check ${cancel_identity%% *} ${cancel_identity#* } >/dev/null 2>&1; then
  cancel_state=alive; proc signal ${cancel_identity%% *} ${cancel_identity#* } KILL >/dev/null 2>&1
else
  cancel_state=gone
fi
is "cancelling a public start ends its detached provider" "$((cancel_rc != 0)) $cancel_state" "1 gone"

PORTLESS_CANCEL="$T/cancel-portless"; mkdir -p "$PORTLESS_CANCEL/bin"
cat > "$PORTLESS_CANCEL/bin/portless" <<'SH'
#!/bin/bash
routes=$PORTLESS_STATE_DIR/routes.json
pause() {
  [[ $PORTLESS_TEST_PAUSE == "$1" && ! -e $PORTLESS_TEST_SYNC.used ]] || return 0
  : > "$PORTLESS_TEST_SYNC.used"
  printf '%s' "$1" > "$PORTLESS_TEST_SYNC"
  trap 'exit 143' TERM INT HUP
  while :; do sleep 1; done
}
[[ ${1:-} == alias ]] || exit 2
if [[ ${2:-} == --remove ]]; then
  pause before-remove
  jq --arg n "$3" 'map(select((.hostname | split(".")[0]) != $n))' "$routes" > "$routes.tmp.$$" || exit 1
  mv "$routes.tmp.$$" "$routes"
  exit 0
fi
name=$2 port=$3
jq --arg n "$name" --argjson p "$port" '
  map(select((.hostname | split(".")[0]) != $n))
  + [{hostname:($n + ".localhost"), port:$p, pid:0}]
' "$routes" > "$routes.tmp.$$" || exit 1
mv "$routes.tmp.$$" "$routes"
pause after-add
SH
chmod 700 "$PORTLESS_CANCEL/bin/portless"
portless_cancel_case() {
  local ownership="$1" pause_at="$2" root="$PORTLESS_CANCEL/$1-$2" wrapper wrapper_start rc route marker=absent state
  mkdir -p "$root/home" "$root/portal" "$root/portless"
  jq -nc '[{hostname:"old.localhost",port:45882,pid:0}]' > "$root/portless/routes.json"
  if [[ $ownership == owned ]]; then
    printf old > "$root/portal/portless-45882.name"
    printf https://old.localhost > "$root/portal/portless-45882.url"
    printf local > "$root/portal/portless-45882.reach"
  fi
  : > "$root/sync"
  HOME="$root/home" PATH="$PORTLESS_CANCEL/bin:/usr/bin:/bin" \
    PORTAL_STATE_DIR="$root/portal" PORTLESS_STATE_DIR="$root/portless" \
    PORTLESS_TEST_SYNC="$root/sync" PORTLESS_TEST_PAUSE="$pause_at" \
    /usr/bin/python3 -I -S "$PR" run 1048576 10 -- \
      /usr/bin/bash "$S/tunnels.sh" start portless 45882 new > "$root/out" 2>&1 &
  wrapper=$!
  wrapper_start=$(proc_start "$wrapper")
  for _ in $(seq 1 400); do [[ -s $root/sync ]] && break; sleep 0.01; done
  if (( wrapper > 1 )) && proc check "$wrapper" "$wrapper_start" >/dev/null 2>&1; then
    kill -TERM "$wrapper" 2>/dev/null
  fi
  wait "$wrapper" 2>/dev/null; rc=$?
  route=$(jq -r 'first(.[] | select(.port == 45882) | .hostname) // "absent"' "$root/portless/routes.json")
  [[ -e $root/portal/portless-45882.name ]] && marker=$(cat "$root/portal/portless-45882.name")
  proc check "$wrapper" "$wrapper_start" >/dev/null 2>&1 && state=alive || state=gone
  printf '%s/%s:%s:%s:%s:%s ' "$ownership" "$pause_at" "$rc" "$route" "$marker" "$state"
}
portless_cancelled=""
for ownership in owned unowned; do
  for pause_at in before-remove after-add; do
    portless_cancelled+=$(portless_cancel_case "$ownership" "$pause_at")
  done
done
is "cancelling a Portless rename restores its route and ownership" "$portless_cancelled" \
  "owned/before-remove:143:old.localhost:old:gone owned/after-add:143:old.localhost:old:gone unowned/before-remove:143:old.localhost:absent:gone unowned/after-add:143:old.localhost:absent:gone "

INCOMPLETE="$T/incomplete-start"; mkdir -p "$INCOMPLETE"
state launch-tracked "$INCOMPLETE" cloudflared-4489.log cloudflared-4489.pid -- "$T/prov/cloudflared" 300 >/dev/null
printf '999999 1' > "$INCOMPLETE/cloudflared-4489.target"
incomplete_identity=$(cat "$INCOMPLETE/cloudflared-4489.pid")
stub_env "$INCOMPLETE" 'cmd_status >/dev/null'
proc check ${incomplete_identity%% *} ${incomplete_identity#* } >/dev/null 2>&1 && incomplete_state=alive || incomplete_state=gone
is "status reconciles an owned provider with no URL" "$incomplete_state $(find "$INCOMPLETE" -maxdepth 1 -type f | wc -l)" "gone 0"

MALFORMED_URL="$T/malformed-url"; mkdir -p "$MALFORMED_URL"
state launch-tracked "$MALFORMED_URL" cloudflared-4490.log cloudflared-4490.pid -- "$T/prov/cloudflared" 300 >/dev/null
printf 'not-a-url' > "$MALFORMED_URL/cloudflared-4490.url"
malformed_status=$(stub_env "$MALFORMED_URL" 'cmd_status')
is "status reports a malformed owned URL" "$(jq -c .ok <<<"$malformed_status") $(test -e "$MALFORMED_URL/cloudflared-4490.pid" && echo kept || echo lost)" "false kept"
malformed_identity=$(cat "$MALFORMED_URL/cloudflared-4490.pid")
proc signal ${malformed_identity%% *} ${malformed_identity#* } KILL >/dev/null 2>&1
# A tunnel whose pidfile cannot be written is stopped again, not left public with no record.
R1="$T/rt1"; mkdir -p "$R1/cloudflared-4449.pid"
is "start refuses an unreadable pidfile before launch" "$(stub_env "$R1" 'cmd_start cloudflared 4449' | jq -r .error)" "cloudflared on port 4449 has a pidfile that cannot be read; its records are kept"
sleep 0.3; pgrep -f "$T/prov/cloudflared" >/dev/null && bad "the unrecorded tunnel is still running" || ok "and the unrecorded tunnel was stopped"
rmdir "$R1/cloudflared-4449.pid"
is "the same start succeeds once the pidfile can be written" "$(stub_env "$R1" 'cmd_start cloudflared 4449' | jq -r .url)" "https://stub-one-two.trycloudflare.com"
# A status snapshot taken before a replacement started does not clear the replacement.
snap=$(state dump "$R1" 8192 4096); old=$(cat "$R1/cloudflared-4449.pid")
stub_env "$R1" 'cmd_stop cloudflared 4449 >/dev/null'
stub_env "$R1" 'cmd_start cloudflared 4449 >/dev/null'
[[ $(cat "$R1/cloudflared-4449.pid") != "$old" ]] && ok "a replacement wrote its own pidfile" || bad "no replacement pidfile"
SNAP="$snap" stub_env "$R1" 'state() { if [[ $1 == dump && $2 == "$STATE_DIR" ]]; then printf "%s" "$SNAP"; else /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; fi; }; cmd_status >/dev/null'
is "status with a stale snapshot leaves the replacement's records" "$(ls "$R1" | grep -c '^cloudflared-4449\.')" "5"
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
# When the Portless directory is over its cap, status keeps the local markers
# and returns independent public rows rather than treating routes as vanished.
PS="$T/pstate"; mkdir -p "$PS"; for i in $(seq 1 520); do : > "$PS/j$i"; done
PD="$T/prt"; mkdir -p "$PD"; printf 'https://acme.localhost' > "$PD/portless-3000.url"; printf 'acme' > "$PD/portless-3000.name"; printf 'local' > "$PD/portless-3000.reach"
printf 'https://one-two.trycloudflare.com' > "$PD/cloudflared-3001.url"; printf '999999 1' > "$PD/cloudflared-3001.pid"; printf 'public' > "$PD/cloudflared-3001.reach"
printf 'https://unit.ngrok.app' > "$PD/ngrok-3002.url"; printf '999999 1' > "$PD/ngrok-3002.pid"; printf 'public' > "$PD/ngrok-3002.reach"
: > "$T/pstate-effects"
portless_status=$(PORTLESS_STATE_DIR="$PS" PORTAL_STATE_DIR="$PD" EFFECTS="$T/pstate-effects" S="$S" bash -c '
  source "$S/tunnels.sh"
  ss() { return 0; }
  alive_line() { return 0; }
  reconcile_idle() { return 0; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { printf "portless-adopt\n" >> "$EFFECTS"; }
  kill() { printf "kill\n" >> "$EFFECTS"; return 1; }
  proc() { printf "proc\n" >> "$EFFECTS"; return 1; }
  cmd_status
')
is "unreadable Portless state keeps public and tracked local status rows" \
  "$(jq -c '[.ok, ([.tunnels[]? | select(.reach == "public") | .provider] | sort), [.tunnels[]? | select(.provider == "portless") | .port]]' <<<"$portless_status") $(wc -l < "$T/pstate-effects")" \
  '[true,["cloudflared","ngrok"],[3000]] 0'
is "status keeps portless markers when the Portless state is unreadable" "$(ls "$PD" | grep -c '^portless-3000\.')" "3"
rm -f "$R1"/crowd-*
is "stop-own stops what it can list" "$(PATH="$T/prov:$PATH" PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" stop-own | jq -c .ok)" "true"
sleep 0.3; pgrep -f "$T/prov/cloudflared" >/dev/null && bad "stop-own left the tunnel running" || ok "and the tunnel is gone"
# An expired idle timer in a stale snapshot stops nothing but the snapshot's own process.
stub_env "$R1" 'cmd_start cloudflared 4449 >/dev/null'; old=$(cat "$R1/cloudflared-4449.pid")
printf '%s' $(( $(printf '%(%s)T' -1) - 700 )) > "$R1/cloudflared-4449.idle"
snap=$(state dump "$R1" 8192 4096)
state launch "$R1" cloudflared-4449.log -- "$T/prov/cloudflared" 300 > "$R1/cloudflared-4449.pid"; rm -f "$R1/cloudflared-4449.idle"
SNAP="$snap" stub_env "$R1" 'state() { if [[ $1 == dump && $2 == "$STATE_DIR" ]]; then printf "%s" "$SNAP"; else /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; fi; }; target_owns_port() { return 1; }; cmd_status >/dev/null'
sleep 0.2; kill -0 "${old%% *}" 2>/dev/null && ok "the snapshot's own process is left to its live status" || bad "the old process was stopped from a stale snapshot"
kill -0 "$(cut -d' ' -f1 "$R1/cloudflared-4449.pid")" 2>/dev/null && ok "and the replacement was not stopped" || bad "the replacement was stopped from a stale snapshot"
kill "${old%% *}" 2>/dev/null
# A stop is a stop only once the process is gone: it fails, keeping the records, when nothing works.
is "cmd_stop fails when the process will not die" "$(stub_env "$R1" 'STOP_TERM_WAIT=2; STOP_KILL_WAIT=2; proc() { :; }; kill() { :; }; cmd_stop cloudflared 4449' | jq -r .error)" "cloudflared on port 4449 did not stop; its records are kept"
is "and keeps its records" "$(ls "$R1" | grep -c -E '^cloudflared-4449\.(pid|url)$')" "2"
# An idle tunnel whose stop failed stays in the status, records and all.
printf '%s' $(( $(printf '%(%s)T' -1) - 700 )) > "$R1/cloudflared-4449.idle"
is "status keeps listing an idle tunnel it could not stop" "$(stub_env "$R1" 'STOP_TERM_WAIT=2; STOP_KILL_WAIT=2; target_owns_port() { return 1; }; proc() { :; }; kill() { :; }; cmd_status' | jq -c '[.tunnels[]|select(.provider=="cloudflared" and .port==4449)|.port]')" "[4449]"
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
is "start rejects a bare --target" "$(timeout 5 bash -c 'source "'"$S"'/tunnels.sh"; portless_state_load; cmd_start cloudflared 3000 --target' | jq -r .error)" "invalid target identity"
# stop-own enumerates a portless name-only partial start (alias written, url not yet).
PN="$T/pn"; mkdir -p "$PN"; printf 'acme' > "$PN/portless-4460.name"
is "stop-own enumerates a portless name-only partial" "$(PORTAL_STATE_DIR="$PN" bash -c 'source "'"$S"'/tunnels.sh"; state dump "$STATE_DIR" 8192 "$STATE_FILES_CAP" 2>/dev/null | jq -r '"'"'.files | keys[] | select(test("^[a-z]+-[0-9]+\\.(url|pid|name)$")) | sub("\\.(url|pid|name)$"; "")'"'"'')" "portless-4460"
python3 -m http.server 4470 --bind 127.0.0.1 >/dev/null 2>&1 & lp=$!; sleep 0.6
lpstart=$(proc_start "$lp")
is "start refuses a stale process start" "$(real_stub_env "$R1" "cmd_start cloudflared 4470 --target $lp $((lpstart + 1))" | jq -r .error)" "port 4470 is no longer served by the approved process"
is "start rejects a malformed target" "$(real_stub_env "$R1" 'cmd_start cloudflared 4470 --target 0x1 2' | jq -r .error)" "invalid target identity"
is "start proceeds for the process that serves the port" "$(real_stub_env "$R1" "cmd_start cloudflared 4470 --target $lp $lpstart" | jq -c .ok)" "true"
is "the public share records the approved process" "$(cat "$R1/cloudflared-4470.target")" "$lp $lpstart"
stub_env "$R1" 'cmd_stop cloudflared 4470 >/dev/null'; kill "$lp" 2>/dev/null

R2="$T/target-idle"; mkdir -p "$R2"
python3 -m http.server 4471 --bind 127.0.0.1 >/dev/null 2>&1 & first_listener=$!; sleep 0.4
first_start=$(proc_start "$first_listener")
real_stub_env "$R2" "cmd_start cloudflared 4471 --target $first_listener $first_start >/dev/null"
tunnel_identity=$(cat "$R2/cloudflared-4471.pid")
kill "$first_listener" 2>/dev/null; wait "$first_listener" 2>/dev/null
python3 -m http.server 4471 --bind 127.0.0.1 >/dev/null 2>&1 & replacement_listener=$!; sleep 0.4
real_stub_env "$R2" 'cmd_status >/dev/null'
proc check ${tunnel_identity%% *} ${tunnel_identity#* } >/dev/null 2>&1 && tunnel_state=alive || tunnel_state=gone
is "a replacement listener cannot inherit a public share" "$tunnel_state" "gone"
kill "$replacement_listener" 2>/dev/null; wait "$replacement_listener" 2>/dev/null

LAN_TARGET="$T/target-lan"; mkdir -p "$LAN_TARGET"; : > "$LAN_TARGET/effects"
printf 'https://stale.trycloudflare.com' > "$LAN_TARGET/cloudflared-4471.url"
printf 'public' > "$LAN_TARGET/cloudflared-4471.reach"
printf '999999 1' > "$LAN_TARGET/cloudflared-4471.pid"
printf '888888 1' > "$LAN_TARGET/cloudflared-4471.target"
lan_status=$(PORTAL_STATE_DIR="$LAN_TARGET" PORTLESS_STATE_DIR="$PORTLESS_STATE_DIR" \
  EFFECTS="$LAN_TARGET/effects" S="$S" bash -c '
  source "$S/tunnels.sh"
  ss() { printf "LISTEN 0 128 192.168.50.8:4471 0.0.0.0:*\n"; }
  portless_state_load() { return 0; }
  alive_line() { return 0; }
  target_owns_port() { return 1; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { :; }
  kill() { printf "kill %s\n" "$*" >> "$EFFECTS"; return 1; }
  proc() { printf "proc %s\n" "$*" >> "$EFFECTS"; return 1; }
  cmd_status
')
is "status marks a tracked tunnel whose localhost target is offline" \
  "$(jq -r '.tunnels[] | select(.provider == "cloudflared" and .port == 4471) | [.targetHealthy, .dns] | @tsv' <<<"$lan_status") $(test -e "$LAN_TARGET/cloudflared-4471.idle" && echo idle || echo no-idle) $(wc -l < "$LAN_TARGET/effects")" \
  $'false\t idle 0'

LEGACY_TARGET="$T/targetless-legacy"; mkdir -p "$LEGACY_TARGET"; : > "$LEGACY_TARGET/effects"
printf 'https://legacy.trycloudflare.com' > "$LEGACY_TARGET/cloudflared-4473.url"
printf 'public' > "$LEGACY_TARGET/cloudflared-4473.reach"
printf '999999 1' > "$LEGACY_TARGET/cloudflared-4473.pid"
legacy_status=$(PORTAL_STATE_DIR="$LEGACY_TARGET" PORTLESS_STATE_DIR="$PORTLESS_STATE_DIR" \
  EFFECTS="$LEGACY_TARGET/effects" S="$S" bash -c '
  source "$S/tunnels.sh"
  ss() { printf "LISTEN 0 128 127.0.0.1:4473 0.0.0.0:*\n"; }
  portless_state_load() { return 0; }
  alive_line() { return 0; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { :; }
  kill() { printf "kill %s\n" "$*" >> "$EFFECTS"; return 1; }
  proc() { printf "proc %s\n" "$*" >> "$EFFECTS"; return 1; }
  cmd_status
')
is "a legacy targetless share gets a fixed reapproval deadline" \
  "$(jq -r '.tunnels[] | select(.provider == "cloudflared" and .port == 4473) | .targetHealthy' <<<"$legacy_status") $(test -e "$LEGACY_TARGET/cloudflared-4473.idle" && echo idle || echo no-idle) $(wc -l < "$LEGACY_TARGET/effects")" \
  "null idle 0"

R3="$T/idle-write"; mkdir -p "$R3"
python3 -m http.server 4472 --bind 127.0.0.1 >/dev/null 2>&1 & idle_listener=$!; sleep 0.4
idle_start=$(proc_start "$idle_listener")
real_stub_env "$R3" "cmd_start cloudflared 4472 --target $idle_listener $idle_start >/dev/null"
idle_tunnel=$(cat "$R3/cloudflared-4472.pid")
kill "$idle_listener" 2>/dev/null; wait "$idle_listener" 2>/dev/null
mkdir "$R3/cloudflared-4472.idle"
real_stub_env "$R3" 'cmd_status >/dev/null'
proc check ${idle_tunnel%% *} ${idle_tunnel#* } >/dev/null 2>&1 && idle_tunnel_state=alive || idle_tunnel_state=gone
is "an unwritable idle deadline closes the public tunnel" "$idle_tunnel_state" "gone"
is "cmd_stop rejects a bad port" "$(cmd_stop cloudflared x | jq -r .error)" "invalid port"
# A pidfile that is present but unreadable is a failure, not an adopt-and-forget.
UB="$T/unread"; mkdir -p "$UB"; : > "$UB/cloudflared-4600.pid"; printf 'https://x-y.trycloudflare.com' > "$UB/cloudflared-4600.url"
is "cmd_stop fails on an empty pidfile rather than clearing state" "$(PORTAL_STATE_DIR="$UB" bash -c 'source "'"$S"'/tunnels.sh"; portless_state_load; cmd_stop cloudflared 4600' | jq -r .error)" "cloudflared on port 4600 has a pidfile that cannot be read; its records are kept"
is "and the records are kept" "$(ls "$UB" | grep -c -E '^cloudflared-4600\.(pid|url)$')" "2"
# owned_pid accepts a process whose executable path shows "(deleted)".
sleep 300 & dpid=$!; dstart=$(cut -d')' -f2- "/proc/$dpid/stat" | awk '{print $20}')
is "owned_pid matches by comm regardless of a deleted exe" "$(bash -c 'source "'"$S"'/tunnels.sh"; owned_pid '"$dpid"' sleep '"$dstart"' && echo yes || echo no')" "yes"
kill "$dpid" 2>/dev/null

PY3=$(readlink -f -- "$(command -v python3)")
wait_listener_pid() {
  local p i
  for i in $(seq 1 50); do
    p=$(ss -tlnpH "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
    [[ -n $p ]] && { printf '%s' "$p"; return 0; }
    sleep 0.05
  done
  return 1
}
REL="$T/rel-launch"; mkdir -p "$REL/target/bin" "$REL/helper/bin"
cp "$PY3" "$REL/target/bin/dev"; cp /usr/bin/true "$REL/helper/bin/dev"
cat > "$REL/srv.py" <<'PYEOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
( cd "$REL/target" && setsid ./bin/dev "$REL/srv.py" 4499 >/dev/null 2>&1 & ) >/dev/null 2>&1
rel_pid=$(wait_listener_pid 4499) || bad "the relative-launcher fixture never listened"
rel_start=$(proc_start "$rel_pid")
rel_argv=$(jq -nc --arg a './bin/dev' --arg s "$REL/srv.py" '[$a,$s,"4499"]')
rel_out=$( cd "$REL/helper" && "$S/lifecycle.sh" restart "$rel_pid" "$rel_start" 4499 "$REL/target" "$rel_argv" )
sleep 0.6
new_pid=$(ss -tlnpH 'sport = :4499' 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
if [[ $(jq -r .ok <<<"$rel_out") == true && -n $new_pid ]]; then
  is "restart resolves a relative launcher from the process's own directory" "$(readlink "/proc/$new_pid/exe")" "$REL/target/bin/dev"
  is "and keeps the original argv[0]" "$(tr '\0' '\n' < "/proc/$new_pid/cmdline" | head -1)" "./bin/dev"
  is "and its output is discarded, not parked on a deleted log" "$(readlink "/proc/$new_pid/fd/1")$(readlink "/proc/$new_pid/fd/2")" "/dev/null/dev/null"
  is "and no restart leaf remains" "$(ls "$STATE_DIR"/.restart-4499.* 2>/dev/null | wc -l)" "0"
  kill "$new_pid" 2>/dev/null
else
  bad "a relative launcher restart failed: $rel_out"
fi
RB2="$T/rel-restart"; mkdir -p "$RB2"
( cd "$RB2" && setsid "$PY3" -m http.server 4499 --bind 127.0.0.1 >/dev/null 2>&1 & ) >/dev/null 2>&1
rb_pid=$(wait_listener_pid 4499) || bad "the non-serving-replacement fixture never listened"
rb_start=$(proc_start "$rb_pid")
rb_out=$( cd "$RB2" && "$S/lifecycle.sh" restart "$rb_pid" "$rb_start" 4499 "$RB2" '["/usr/bin/sleep","4590"]' )
stray=$(pgrep -f "sleep [4]590")
rb_leaves=$(ls "$STATE_DIR"/.restart-4499.* 2>/dev/null | wc -l)
if [[ -n $stray ]]; then s_start=$(proc_start "$stray"); proc signal "$stray" "$s_start" KILL >/dev/null 2>&1; fi
is "a replacement that never serves is ended" "$stray" ""
is "and its identity record cleared" "$rb_leaves" "0"
jq -e '.ok == false' <<<"$rb_out" >/dev/null 2>&1 && ok "and the restart reports failure" || bad "restart reported success for a non-serving replacement: $rb_out"
DIS="$T/discard-launch"; mkdir -p "$DIS"
discard_line=$(state launch-tracked "$DIS" --discard-output discard.pid -- /usr/bin/sleep 4591)
sleep 0.2
dpid=${discard_line%% *}; dstart=${discard_line#* }
is "a discard launch records the identity before execution" "$(cat "$DIS/discard.pid" 2>/dev/null)" "$discard_line"
is "and creates no log leaf" "$(ls "$DIS" | grep -vc '^discard\.pid$')" "0"
is "and its output goes to /dev/null" "$(readlink "/proc/$dpid/fd/1" 2>/dev/null)" "/dev/null"
proc signal "$dpid" "$dstart" KILL >/dev/null 2>&1

# ---- proc.py: capped runs, and signals bound to one process -----------------
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
term_mark="$T/term-child.pid"
/usr/bin/python3 -I -S "$PR" run 1000 60 -- bash -c 'printf "%s" "$BASHPID" > "'"$term_mark"'"; exec sleep 300' >/dev/null 2>&1 & wrapper=$!
for _ in $(seq 1 50); do [[ -s $term_mark ]] && break; sleep 0.02; done
term_child=$(cat "$term_mark" 2>/dev/null); term_start=$(proc_start "$term_child")
kill -TERM "$wrapper" 2>/dev/null; wait "$wrapper" 2>/dev/null; term_rc=$?
if [[ -n $term_child ]] && proc check "$term_child" "$term_start"; then
  term_state=alive; proc signal "$term_child" "$term_start" KILL 2>/dev/null
else
  term_state=gone
fi
is "terminating the wrapper ends its helper session" "$term_rc $term_state" "143 gone"
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

COMP="$T/restart-competitor"; mkdir -p "$COMP"
(cd "$COMP" && exec python3 -m http.server 4496 --bind 127.0.0.1 >/dev/null 2>&1) & old_server=$!; sleep 0.4
old_start=$(proc_start "$old_server")
(cd "$COMP"; while ss -tlnH 'sport = :4496' | grep -q .; do sleep 0.02; done; exec python3 -m http.server 4496 --bind 127.0.0.1 >/dev/null 2>&1) & competitor=$!
competitor_start=$(proc_start "$competitor")
restart_result=$("$S/lifecycle.sh" restart "$old_server" "$old_start" 4496 "$COMP" '["/usr/bin/true"]')
is "restart rejects an unrelated same-directory listener" "$(jq -c '[.ok,.effect]' <<<"$restart_result")" '[false,"stopped"]'
proc signal "$competitor" "$competitor_start" TERM >/dev/null 2>&1 || true
python3 -m http.server 4497 --bind 127.0.0.1 >/dev/null 2>&1 & scan_server=$!; sleep 0.4
scan_start=$(proc_start "$scan_server"); scan=$("$S/scan-ports.sh")
is "the scan carries the owned listener's kernel start time" "$(jq -r '.ports[] | select(.port == 4497) | "\(.pid) \(.start)"' <<<"$scan")" "$scan_server $scan_start"
is "a single-owner scan grants process authority" "$(jq -r '.ports[] | select(.port == 4497) | .exclusiveOwner' <<<"$scan")" "true"
/usr/bin/sleep 300 & scan_peer=$!; scan_peer_start=$(proc_start "$scan_peer")
scan_stub="$T/scan-stub"; mkdir -p "$scan_stub"
cat > "$scan_stub/ss" <<'SH'
#!/bin/bash
case "$*" in
  -tlnpH) printf 'LISTEN 0 5 127.0.0.1:4498 0.0.0.0:* users:(("python3",pid=%s,fd=3),("sleep",pid=%s,fd=4))\n' "$REP_PID" "$OTHER_PID" ;;
  '-tnH state established') ;;
  *) exit 1 ;;
esac
SH
chmod 755 "$scan_stub/ss"
shared_scan=$(REP_PID="$scan_server" OTHER_PID="$scan_peer" PATH="$scan_stub:/usr/bin:/bin" "$S/scan-ports.sh")
is "a shared scan keeps the representative listener identity" "$(jq -r '.ports[] | select(.port == 4498) | "\(.pid) \(.start)"' <<<"$shared_scan")" "$scan_server $scan_start"
is "a shared scan with two attributed owners denies process authority" "$(jq -r '.ports[] | select(.port == 4498) | .exclusiveOwner' <<<"$shared_scan")" "false"
proc signal "$scan_peer" "$scan_peer_start" TERM >/dev/null 2>&1 || true; wait "$scan_peer" 2>/dev/null || true
proc signal "$scan_server" "$scan_start" TERM >/dev/null 2>&1 || true; wait "$scan_server" 2>/dev/null || true

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

DR="$T/digest-race"; mkdir -p "$DR"; printf old > "$DR/cloudflared"
old_sum=$(sha256sum "$DR/cloudflared" | cut -d' ' -f1)
/usr/bin/python3 - "$DR" "$S/lib/statedir.py" "$old_sum" <<'PY'
import importlib.util, os, sys
root, path, expected = sys.argv[1:]
spec = importlib.util.spec_from_file_location("sd", path)
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
real = sd.rename_noreplace
swapped = False
def replace_before_quarantine(dirfd, old, new):
    global swapped
    if old == "cloudflared" and not swapped:
        swapped = True
        os.rename("cloudflared", "old-cloudflared", src_dir_fd=dirfd, dst_dir_fd=dirfd)
        fd = os.open("cloudflared", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dirfd)
        os.write(fd, b"replacement"); os.close(fd)
    return real(dirfd, old, new)
sd.rename_noreplace = replace_before_quarantine
try:
    sd.cmd_remove_digest([root, "cloudflared", expected, "1024"])
except sd.Refused:
    pass
else:
    raise SystemExit("replacement race was accepted")
PY
is "digest removal preserves a replacement inode" "$(cat "$DR/cloudflared")" "replacement"
printf 'existing' > "$DR/no-replace"
printf 'new' | state create "$DR/no-replace" >/dev/null 2>&1; rc=$?
is "atomic create never replaces a concurrent target" "$rc $(cat "$DR/no-replace")" "1 existing"

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
NO_TRUST="$T/untrust-empty"; mkdir -p "$NO_TRUST/home"
no_trust=$(HOME="$NO_TRUST/home" XDG_CONFIG_HOME="$NO_TRUST/home/.config" \
  PORTAL_STATE_DIR="$NO_TRUST/runtime" PORTAL_METRICS_DIR="$NO_TRUST/state" \
  PORTLESS_STATE_DIR="$NO_TRUST/portless" "$S/portless-setup.sh" untrust)
is "untrust treats an absent ledger as already cleared" \
  "$no_trust $(test ! -e "$NO_TRUST/state" && echo state-absent || echo state-created)" \
  '{"ok":true} state-absent'
if command -v certutil >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  U=$(mktemp -d); mkdir -p "$U/nss" "$U/portless"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$U/ca.key" -out "$U/portless/ca.pem" \
    -days 1 -subj "/CN=portless Local CA" >/dev/null 2>&1
  certutil -d "sql:$U/nss" -N --empty-password >/dev/null 2>&1
  # The import itself, through the setup script's own function, and its record.
  PORTAL_METRICS_DIR=$U PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$U"'/nss"' && ok "trust_store imports the CA" || bad "trust_store failed"
  certutil -d "sql:$U/nss" -L -n "portless Local CA" >/dev/null 2>&1 && ok "and the CA is in the store" || bad "the CA is not in the store"
  is "and the store is on record with a fingerprint" "$(cut -f1 "$U/trusted-stores"); $(cut -f2 "$U/trusted-stores" | grep -qE '^[0-9A-F]{64}$' && echo fp-ok)" "$U/nss; fp-ok"
  mkdir -p "$U/fd-import/nss"
  PORTAL_METRICS_DIR=$U/fd-import PORTLESS_STATE_DIR=$U/portless FD_PROOF=$U/fd-proof bash -c '
    set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1
    certutil() {
      local prev="" arg
      for arg in "$@"; do
        if [[ $prev == -i ]]; then
          printf "%s" "$arg" > "$FD_PROOF.path"
          cat "$arg" > "$FD_PROOF.pem"
        fi
        prev=$arg
      done
      return 0
    }
    trust_store "'"$U"'/fd-import/nss"
  ' >/dev/null 2>&1
  [[ $(cat "$U/fd-proof.path") =~ ^/proc/self/fd/[0-9]+$ ]] \
    && ok "browser trust imports through a held descriptor" || bad "browser trust reopened a pathname"
  printf '%s' "$(cat "$U/portless/ca.pem")" > "$U/validated-ca.pem"
  cmp -s "$U/validated-ca.pem" "$U/fd-proof.pem" && ok "and certutil reads the validated CA bytes" || bad "certutil read different CA bytes"
  mkdir -p "$U/rollback/nss" "$U/rollback-bin"
  printf '#!/bin/sh\ncase " $* " in *" -L "*) exit 1;; *) exit 0;; esac\n' > "$U/rollback-bin/certutil"
  chmod 755 "$U/rollback-bin/certutil"
  PATH="$U/rollback-bin:$PATH" PORTAL_METRICS_DIR="$U/rollback" PORTLESS_STATE_DIR="$U/portless" bash -c '
    set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1
    state_remove() { return 1; }
    trust_store "'"$U"'/rollback/nss"
  ' >/dev/null 2>&1
  [[ -e $U/rollback/trusted-stores ]] && ok "a failed trust rollback keeps its ownership record" || bad "a failed trust rollback lost its ownership record"
  cp "$U/trusted-stores" "$U/trusted.before-error"; mkdir -p "$U/failbin"
  printf '#!/bin/sh\nexit 1\n' > "$U/failbin/certutil"; chmod 755 "$U/failbin/certutil"
  out=$(PATH="$U/failbin:$PATH" PORTAL_METRICS_DIR=$U "$S/portless-setup.sh" untrust)
  is "untrust retains a store when verification fails" "$(jq -c .ok <<<"$out") $(test -e "$U/trusted-stores" && echo kept || echo lost)" "false kept"
  cp "$U/trusted.before-error" "$U/trusted-stores"
  # A trust whose record cannot be written is undone: the store ends without the CA.
  mkdir -p "$U/rb/nss"; certutil -d "sql:$U/rb/nss" -N --empty-password >/dev/null 2>&1; mkdir -p "$U/rb/trusted-stores"
  PORTAL_METRICS_DIR=$U/rb PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$U"'/rb/nss"' && bad "trust_store reported success without a record" || ok "trust_store fails when the record cannot be written"
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
  PORTAL_METRICS_DIR=$V PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$V"'/nss"' >/dev/null
  valid_ledger=$(cat "$V/trusted-stores")
  printf '%s\t%s\n' "$V/nss" NOT-A-FINGERPRINT > "$V/trusted-stores"
  out=$(PORTAL_METRICS_DIR=$V "$S/portless-setup.sh" untrust)
  malformed_state=$(certutil -d "sql:$V/nss" -L -n "portless Local CA" >/dev/null 2>&1 && echo cert-kept || echo cert-lost)
  is "untrust refuses a malformed trust fingerprint before changing the store" \
    "$(jq -r .ok <<<"$out") $malformed_state $(test -e "$V/trusted-stores" && echo ledger-kept || echo ledger-lost)" \
    "false cert-kept ledger-kept"
  printf '%s\n' "$valid_ledger" > "$V/trusted-stores"
  # replace the cert under the same nickname with a different self-signed CA
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$V/k.pem" -out "$V/other.pem" -days 1 -subj "/CN=portless Local CA" >/dev/null 2>&1
  certutil -d "sql:$V/nss" -D -n "portless Local CA" >/dev/null 2>&1
  certutil -d "sql:$V/nss" -A -t "C,," -n "portless Local CA" -i "$V/other.pem" >/dev/null 2>&1
  printf '%s\n' "$V/nss" > "$V/trusted-stores"
  out=$(PORTAL_METRICS_DIR=$V "$S/portless-setup.sh" untrust)
  missing_state=$(certutil -d "sql:$V/nss" -L -n "portless Local CA" >/dev/null 2>&1 && echo cert-kept || echo cert-lost)
  is "untrust refuses a missing trust fingerprint before changing the store" \
    "$(jq -r .ok <<<"$out") $missing_state $(test -e "$V/trusted-stores" && echo ledger-kept || echo ledger-lost)" \
    "false cert-kept ledger-kept"
  certutil -d "sql:$V/nss" -D -n "portless Local CA" >/dev/null 2>&1 || true
  certutil -d "sql:$V/nss" -A -t "C,," -n "portless Local CA" -i "$V/other.pem" >/dev/null 2>&1
  printf '%s\n' "$valid_ledger" > "$V/trusted-stores"
  out=$(PORTAL_METRICS_DIR=$V "$S/portless-setup.sh" untrust)
  is "untrust reports success when the recorded cert is gone" "$(jq -c .ok <<<"$out")" "true"
  certutil -d "sql:$V/nss" -L -n "portless Local CA" >/dev/null 2>&1 && ok "and leaves a replacement cert under the same name in place" || bad "untrust deleted a cert Portal did not import"
  rm -rf "$V"
  # A ledger that exists but cannot be read is not an empty one: no import may
  # overwrite it and orphan every earlier record.
  W=$(mktemp -d); mkdir -p "$W/nss" "$W/nss2"
  certutil -d "sql:$W/nss" -N --empty-password >/dev/null 2>&1
  certutil -d "sql:$W/nss2" -N --empty-password >/dev/null 2>&1
  PORTAL_METRICS_DIR=$W PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$W"'/nss"' >/dev/null
  valid_ledger=$(cat "$W/trusted-stores")
  printf '%s\t%s\n' "$W/nss" NOT-A-FINGERPRINT > "$W/trusted-stores"
  PORTAL_METRICS_DIR=$W PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$W"'/nss2"' >/dev/null 2>&1; rc=$?
  certutil -d "sql:$W/nss2" -L -n "portless Local CA" >/dev/null 2>&1 && malformed_import=trusted || malformed_import=clean
  is "trust_store refuses a malformed ledger before importing" "$rc $malformed_import" "1 clean"
  certutil -d "sql:$W/nss2" -D -n "portless Local CA" >/dev/null 2>&1 || true
  printf '%s\n' "$valid_ledger" > "$W/trusted-stores"
  chmod 777 "$W/trusted-stores"
  PORTAL_METRICS_DIR=$W PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$W"'/nss2"' >/dev/null 2>&1 \
    && bad "trust_store imported over an unreadable ledger" || ok "trust_store refuses when the ledger cannot be read"
  is "and the earlier record survives" "$(wc -l < "$W/trusted-stores")" "1"
  chmod 700 "$W/trusted-stores"; rm -rf "$W"
  rm -rf "$U"
else
  ok "untrust checks skipped (no certutil or openssl)"
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
exec 6>"$PORTAL_METRICS_DIR/.metrics.lock"; flock -x 6
locked_append=$(timeout 2 "$M" append-batch '{"6000":{"t":1}}')
exec 6>&-
is "metric append fails fast behind a watched-state update" "$(jq -c .ok <<<"$locked_append") $(test -e "$PORTAL_METRICS_DIR/metrics/6000.jsonl" && echo wrote || echo clean)" "false clean"

RB="$T/review"; mkdir -p "$RB/lock" "$RB/append" "$RB/portless" "$RB/cli" "$RB/bin" "$RB/fake"
printf 'keep' > "$RB/victim"; ln -s "$RB/victim" "$RB/lock/.lifecycle.lock"
state lock "$RB/lock" nowait .lifecycle.lock -- /usr/bin/true >/dev/null 2>&1; rc=$?
is "a lifecycle lock symlink is refused" "$rc $(cat "$RB/victim")" "1 keep"
rm "$RB/lock/.lifecycle.lock"
is "a safe lifecycle lock runs its command" "$(state lock "$RB/lock" nowait .lifecycle.lock -- /usr/bin/printf ran 2>/dev/null)" "ran"
is "an ordinary lock keeps its stable lock file" "$(test -f "$RB/lock/.lifecycle.lock" && echo kept || echo lost)" "kept"

LOCK_CLEAN="$RB/lock-clean"; mkdir -p "$LOCK_CLEAN/foreign"; printf keep > "$LOCK_CLEAN/foreign/keep"
state lock-clean "$LOCK_CLEAN/success" nowait .lock -- /usr/bin/true >/dev/null 2>&1; clean_success_rc=$?
state lock-clean "$LOCK_CLEAN/failure" nowait .lock -- /usr/bin/false >/dev/null 2>&1; clean_failure_rc=$?
state lock-clean "$LOCK_CLEAN/foreign" nowait .lock -- /usr/bin/true >/dev/null 2>&1; clean_foreign_rc=$?
is "lock-clean removes its empty root only after child success" \
  "$clean_success_rc $(test -e "$LOCK_CLEAN/success" && echo present || echo absent)" "0 absent"
is "lock-clean keeps its lock and root after child failure" \
  "$clean_failure_rc $(test -f "$LOCK_CLEAN/failure/.lock" && echo kept || echo lost)" "1 kept"
is "lock-clean removes only its lock from a nonempty root" \
  "$clean_foreign_rc $(test -e "$LOCK_CLEAN/foreign/.lock" && echo lock || echo no-lock) $(cat "$LOCK_CLEAN/foreign/keep")" \
  "0 no-lock keep"
exec 9<"$LOCK_CLEAN"; flock -x 9
timeout 2 /usr/bin/python3 -I -S "$S/lib/statedir.py" lock "$LOCK_CLEAN/namespace" nowait .lock -- \
  /usr/bin/touch "$LOCK_CLEAN/entered" >/dev/null 2>&1; namespace_rc=$?
exec 9>&-
is "a nowait lock fails fast behind root namespace cleanup" \
  "$namespace_rc $(test -e "$LOCK_CLEAN/entered" && echo entered || echo clean)" "75 clean"
state lock-clean "$LOCK_CLEAN/not-ancestor" nowait .lock --prune-to "$LOCK_CLEAN/other" -- \
  /usr/bin/touch "$LOCK_CLEAN/not-ancestor-entered" >/dev/null 2>&1; nonancestor_rc=$?
state lock-clean "$LOCK_CLEAN/equal" nowait .lock --prune-to "$LOCK_CLEAN/equal" -- \
  /usr/bin/touch "$LOCK_CLEAN/equal-entered" >/dev/null 2>&1; equal_rc=$?
state lock-clean "$LOCK_CLEAN/parent" nowait .lock --prune-to "$LOCK_CLEAN/parent/child" -- \
  /usr/bin/touch "$LOCK_CLEAN/descendant-entered" >/dev/null 2>&1; descendant_rc=$?
is "lock-clean rejects invalid prune boundaries before effects" \
  "$nonancestor_rc $equal_rc $descendant_rc $(find "$LOCK_CLEAN" -name '*-entered' -o -name 'not-ancestor' -o -name equal -o -name parent | wc -l)" \
  "1 1 1 0"

/usr/bin/python3 -I -S - "$S/lib/statedir.py" "$RB/lock-race" <<'PY'
import importlib.util
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

module_path, case = sys.argv[1:]
case = Path(case)
case.mkdir()
root = case / "root"
locker_script = case / "locker.py"
owner_entered = case / "owner-entered"
owner_release = case / "owner-release"
cleanup_unlinked = case / "cleanup-unlinked"
cleanup_release = case / "cleanup-release"
replacement_entered = case / "replacement-entered"
replacement_release = case / "replacement-release"
waiter_entered = case / "waiter-entered"
waiter_release = case / "waiter-release"

locker_script.write_text("""import importlib.util, os, pathlib, subprocess, sys, time
module_path, verb, root, entered, release, *cleanup = sys.argv[1:]
spec = importlib.util.spec_from_file_location("statedir", module_path)
sd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sd)
class Result:
    returncode = 0
def run(*args, **kwargs):
    pathlib.Path(entered).touch()
    while not pathlib.Path(release).exists():
        time.sleep(0.01)
    return Result()
subprocess.run = run
if cleanup:
    unlinked, cleanup_release = cleanup
    real_unlink = sd.os.unlink
    def unlink_then_wait(*args, **kwargs):
        real_unlink(*args, **kwargs)
        pathlib.Path(unlinked).touch()
        while not pathlib.Path(cleanup_release).exists():
            time.sleep(0.01)
    sd.os.unlink = unlink_then_wait
raise SystemExit(sd.main([verb, root, "wait", ".lock", "--", "/usr/bin/true"]))
""")

def wait_for(path, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if path.exists():
            return
        time.sleep(0.01)
    raise RuntimeError(f"timed out waiting for {path.name}")

def wait_for_one(first, second, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if first.exists() or second.exists():
            return
        time.sleep(0.01)
    raise RuntimeError(f"timed out waiting for {first.name} or {second.name}")

def wait_for_fd(pid, identity, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        try:
            for entry in Path(f"/proc/{pid}/fd").iterdir():
                try:
                    st = entry.stat()
                except FileNotFoundError:
                    continue
                if (st.st_dev, st.st_ino) == identity:
                    return
        except FileNotFoundError:
            break
        time.sleep(0.01)
    raise RuntimeError(f"pid {pid} never opened lock inode {identity}")

python = "/usr/bin/python3"
processes = []
try:
    owner = subprocess.Popen([python, "-I", "-S", str(locker_script), module_path, "lock-clean", str(root),
                              str(owner_entered), str(owner_release),
                              str(cleanup_unlinked), str(cleanup_release)])
    processes.append(owner)
    wait_for(owner_entered)
    old_root = root.stat()
    old_root_identity = (old_root.st_dev, old_root.st_ino)
    old = root.joinpath(".lock").stat()
    old_identity = (old.st_dev, old.st_ino)

    waiter = subprocess.Popen([python, "-I", "-S", str(locker_script), module_path, "lock", str(root),
                               str(waiter_entered), str(waiter_release)])
    processes.append(waiter)
    wait_for_fd(waiter.pid, old_identity)

    owner_release.touch()
    wait_for(cleanup_unlinked)
    replacement = subprocess.Popen([python, "-I", "-S", str(locker_script), module_path, "lock", str(root),
                                    str(replacement_entered), str(replacement_release)])
    processes.append(replacement)
    wait_for_fd(replacement.pid, old_root_identity)
    if replacement_entered.exists():
        raise RuntimeError("replacement owner bypassed root cleanup")

    cleanup_release.touch()
    if owner.wait(timeout=5) != 0:
        raise RuntimeError("cleanup owner failed")
    wait_for_one(replacement_entered, waiter_entered)
    if replacement_entered.exists() and waiter_entered.exists():
        raise RuntimeError("both rebound owners entered the replacement lock")
    current = root.joinpath(".lock").stat()
    current_identity = (current.st_dev, current.st_ino)
    if current_identity == old_identity:
        raise RuntimeError("replacement reused the retired lock inode")

    wait_for_fd(waiter.pid, current_identity)
    if replacement_entered.exists():
        replacement_release.touch()
        if replacement.wait(timeout=5) != 0:
            raise RuntimeError("replacement owner failed")
        wait_for(waiter_entered)
        waiter_release.touch()
        if waiter.wait(timeout=5) != 0:
            raise RuntimeError("rebound waiter failed")
    else:
        waiter_release.touch()
        if waiter.wait(timeout=5) != 0:
            raise RuntimeError("rebound waiter failed")
        wait_for(replacement_entered)
        replacement_release.touch()
        if replacement.wait(timeout=5) != 0:
            raise RuntimeError("replacement owner failed")

    spec = importlib.util.spec_from_file_location("statedir", module_path)
    statedir = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(statedir)
    directory_root = case / "directory-race"
    directory_root.mkdir()
    dirfd = statedir.open_dir(str(directory_root))
    lockfd = statedir.open_lock(dirfd, ".lock")
    fcntl.flock(lockfd, fcntl.LOCK_EX)
    real_rmdir = statedir.os.rmdir
    actor = []

    def race_rmdir(*args, **kwargs):
        actorfd = os.open(case, os.O_RDONLY | os.O_DIRECTORY)
        try:
            try:
                fcntl.flock(actorfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                actor.append("blocked")
            else:
                actor.append("entered")
                real_rmdir(directory_root)
                directory_root.mkdir()
        finally:
            os.close(actorfd)
        return real_rmdir(*args, **kwargs)

    statedir.os.rmdir = race_rmdir
    try:
        statedir.cleanup_lock(str(directory_root), "wait", ".lock", dirfd, lockfd)
    finally:
        statedir.os.rmdir = real_rmdir
        os.close(dirfd)
        os.close(lockfd)
    if actor != ["blocked"]:
        raise RuntimeError(f"directory replacement actor was not serialized: {actor}")

    contended_root = case / "cleanup-contention"
    contended_root.mkdir()
    dirfd = statedir.open_dir(str(contended_root))
    lockfd = statedir.open_lock(dirfd, ".lock")
    fcntl.flock(lockfd, fcntl.LOCK_EX)
    actorfd = os.open(case, os.O_RDONLY | os.O_DIRECTORY)
    fcntl.flock(actorfd, fcntl.LOCK_EX)

    def release_namespace():
        time.sleep(0.1)
        fcntl.flock(actorfd, fcntl.LOCK_UN)

    release_thread = threading.Thread(target=release_namespace)
    release_thread.start()
    started = time.monotonic()
    try:
        statedir.cleanup_lock(str(contended_root), "nowait", ".lock", dirfd, lockfd)
    finally:
        release_thread.join()
        os.close(actorfd)
        os.close(dirfd)
        os.close(lockfd)
    elapsed = time.monotonic() - started
    if elapsed < 0.08 or elapsed > 2 or contended_root.exists():
        raise RuntimeError(f"cleanup did not survive brief namespace contention: {elapsed:.3f}s")
finally:
    owner_release.touch()
    cleanup_release.touch()
    replacement_release.touch()
    waiter_release.touch()
    timed_out = []
    for process in processes:
        if process.poll() is None:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                timed_out.append(process)
    for process in timed_out:
        process.terminate()
    for process in timed_out:
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
PY
race_rc=$?
is "a stale waiter reopens the replacement lock before entering" "$race_rc" "0"

exec 5>"$RB/lock/.lifecycle.lock"; flock -x 5
PORTAL_STATE_DIR="$RB/lock" timeout 2 "$S/tunnels.sh" stop cloudflared 6000 >/dev/null 2>&1; rc=$?
exec 5>&-
is "tunnel mutations fail fast behind the lifecycle lock" "$rc" "75"

mkdir -p "$RB/uninstall-state" "$RB/uninstall-runtime" "$RB/uninstall-bin"
printf '#!/bin/sh\nprintf called >> "'"$RB"'/uninstall-called"\nexit 0\n' > "$RB/uninstall-bin/omarchy"
chmod 755 "$RB/uninstall-bin/omarchy"
exec 5>"$RB/uninstall-state/.metrics.lock"; flock -x 5
PATH="$RB/uninstall-bin:$PATH" PORTAL_METRICS_DIR="$RB/uninstall-state" PORTAL_STATE_DIR="$RB/uninstall-runtime" \
  timeout 2 "$S/uninstall.sh" >/dev/null 2>&1; rc=$?
exec 5>&-
is "uninstall fails before effects when metrics are being updated" "$rc $(test -e "$RB/uninstall-called" && echo called || echo clean)" "75 clean"

CLEAN_UNINSTALL="$RB/uninstall-clean"; mkdir -p "$CLEAN_UNINSTALL/home" "$CLEAN_UNINSTALL/bin"
printf '#!/bin/sh\n[ "$*" = "plugin list --json" ] && { printf "[]\\n"; exit 0; }\nexit 99\n' > "$CLEAN_UNINSTALL/bin/omarchy"
chmod 700 "$CLEAN_UNINSTALL/bin/omarchy"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$CLEAN_UNINSTALL/home" \
  PORTAL_STATE_DIR="$CLEAN_UNINSTALL/runtime" PORTAL_METRICS_DIR="$CLEAN_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$CLEAN_UNINSTALL/portless" "$S/uninstall.sh" > "$CLEAN_UNINSTALL/out" 2>&1; clean_uninstall_rc=$?
is "successful uninstall restores initially absent state roots" \
  "$clean_uninstall_rc $(test -e "$CLEAN_UNINSTALL/runtime" && echo present || echo absent) $(test -e "$CLEAN_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$CLEAN_UNINSTALL/out" || true)" \
  "0 absent absent 0"

SHARED_UNINSTALL="$RB/uninstall-shared"; mkdir -p "$SHARED_UNINSTALL/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$SHARED_UNINSTALL/home" \
  PORTAL_STATE_DIR="$SHARED_UNINSTALL/state" PORTAL_METRICS_DIR="$SHARED_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$SHARED_UNINSTALL/portless" "$S/uninstall.sh" > "$SHARED_UNINSTALL/out" 2>&1; shared_uninstall_rc=$?
is "successful uninstall removes a shared lock-only state root" \
  "$shared_uninstall_rc $(test -e "$SHARED_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$SHARED_UNINSTALL/out" || true)" \
  "0 absent 0"

NESTED_UNINSTALL="$RB/uninstall-nested"; mkdir -p "$NESTED_UNINSTALL/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$NESTED_UNINSTALL/home" \
  PORTAL_STATE_DIR="$NESTED_UNINSTALL/state/runtime" PORTAL_METRICS_DIR="$NESTED_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$NESTED_UNINSTALL/portless" "$S/uninstall.sh" > "$NESTED_UNINSTALL/out" 2>&1; nested_uninstall_rc=$?
is "successful uninstall removes a runtime root nested directly under state" \
  "$nested_uninstall_rc $(test -e "$NESTED_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$NESTED_UNINSTALL/out" || true)" \
  "0 absent 0"

REVERSE_UNINSTALL="$RB/uninstall-reverse-nested"; mkdir -p "$REVERSE_UNINSTALL/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$REVERSE_UNINSTALL/home" \
  PORTAL_STATE_DIR="$REVERSE_UNINSTALL/state" PORTAL_METRICS_DIR="$REVERSE_UNINSTALL/state/metrics-state" \
  PORTLESS_STATE_DIR="$REVERSE_UNINSTALL/portless" "$S/uninstall.sh" > "$REVERSE_UNINSTALL/out" 2>&1; reverse_uninstall_rc=$?
is "successful uninstall removes state nested directly under runtime" \
  "$reverse_uninstall_rc $(test -e "$REVERSE_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$REVERSE_UNINSTALL/out" || true)" \
  "0 absent 0"

DEEP_UNINSTALL="$RB/uninstall-deep"; mkdir -p "$DEEP_UNINSTALL/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$DEEP_UNINSTALL/home" \
  PORTAL_STATE_DIR="$DEEP_UNINSTALL/state/a/runtime" PORTAL_METRICS_DIR="$DEEP_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$DEEP_UNINSTALL/portless" "$S/uninstall.sh" > "$DEEP_UNINSTALL/out" 2>&1; deep_uninstall_rc=$?
is "successful uninstall removes a deeply nested runtime root" \
  "$deep_uninstall_rc $(test -e "$DEEP_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$DEEP_UNINSTALL/out" || true)" \
  "0 absent 0"

REVERSE_DEEP="$RB/uninstall-reverse-deep"; mkdir -p "$REVERSE_DEEP/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$REVERSE_DEEP/home" \
  PORTAL_STATE_DIR="$REVERSE_DEEP/state" PORTAL_METRICS_DIR="$REVERSE_DEEP/state/a/metrics-state" \
  PORTLESS_STATE_DIR="$REVERSE_DEEP/portless" "$S/uninstall.sh" > "$REVERSE_DEEP/out" 2>&1; reverse_deep_rc=$?
is "successful uninstall removes deeply nested metrics state" \
  "$reverse_deep_rc $(test -e "$REVERSE_DEEP/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$REVERSE_DEEP/out" || true)" \
  "0 absent 0"

FOREIGN_DEEP="$RB/uninstall-foreign-deep"; mkdir -p "$FOREIGN_DEEP/home" "$FOREIGN_DEEP/state/a"
printf keep > "$FOREIGN_DEEP/state/a/foreign"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$FOREIGN_DEEP/home" \
  PORTAL_STATE_DIR="$FOREIGN_DEEP/state/a/runtime" PORTAL_METRICS_DIR="$FOREIGN_DEEP/state" \
  PORTLESS_STATE_DIR="$FOREIGN_DEEP/portless" "$S/uninstall.sh" > "$FOREIGN_DEEP/out" 2>&1; foreign_deep_rc=$?
is "uninstall preserves and reports a foreign nested runtime parent" \
  "$foreign_deep_rc $(cat "$FOREIGN_DEEP/state/a/foreign") $(grep -c 'holds files that are not Portal' "$FOREIGN_DEEP/out" || true)" \
  "0 keep 1"

REVERSE_FOREIGN="$RB/uninstall-reverse-foreign"; mkdir -p "$REVERSE_FOREIGN/home" "$REVERSE_FOREIGN/state/a"
printf keep > "$REVERSE_FOREIGN/state/a/foreign"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$REVERSE_FOREIGN/home" \
  PORTAL_STATE_DIR="$REVERSE_FOREIGN/state" PORTAL_METRICS_DIR="$REVERSE_FOREIGN/state/a/metrics-state" \
  PORTLESS_STATE_DIR="$REVERSE_FOREIGN/portless" "$S/uninstall.sh" > "$REVERSE_FOREIGN/out" 2>&1; reverse_foreign_rc=$?
is "uninstall preserves and reports a foreign nested metrics parent" \
  "$reverse_foreign_rc $(cat "$REVERSE_FOREIGN/state/a/foreign") $(grep -c 'holds files that are not Portal' "$REVERSE_FOREIGN/out" || true)" \
  "0 keep 1"

exec 7<"$RB/append"; flock -x 7
printf 'x\n' | timeout 2 /usr/bin/python3 -I -S "$S/lib/statedir.py" append "$RB/append/sample" 10 1024 >/dev/null 2>&1; rc=$?
exec 7>&-
is "append refuses a held directory lock without blocking" "$rc" "1"

p1start=$(cut -d')' -f2- /proc/1/stat 2>/dev/null | awk '{print $20}')
/usr/bin/python3 -I -S "$PR" check 1 "${p1start:-1}" >/dev/null 2>&1; rc=$?
is "process identity rejects pid 1" "$rc" "1"

printf '[]' > "$RB/route-target"; ln -s "$RB/route-target" "$RB/portless/routes.json"
PORTLESS_STATE_DIR="$RB/portless" PORTAL_STATE_DIR="$RB/runtime" bash -c 'source "'"$S"'/lib/portless.sh"; portless_state_load' >/dev/null 2>&1; rc=$?
is "a refused Portless route makes the state load fail" "$rc" "1"
refused_providers=$(PORTLESS_STATE_DIR="$RB/portless" PORTAL_STATE_DIR="$RB/runtime" bash -c '
  source "'"$S"'/tunnels.sh"
  cloudflared_status() { printf "ready|Cloudflare ready|"; }
  ngrok_status() { printf "ready|ngrok ready|"; }
  cmd_providers
')
is "refused Portless state keeps independent public providers available" \
  "$(jq -c '[.ok, [.providers[]? | select(.reach == "public") | .id], (.providers[]? | select(.id == "portless") | [.status, .detail])]' <<<"$refused_providers")" \
  '[true,["cloudflared","ngrok"],["unavailable","State could not be read safely"]]'

mkdir -p "$RB/portless-stop" "$RB/portless-stop-state" "$RB/fake-portless"
printf '[{"port":45882,"hostname":"acme.test","pid":0}]' > "$RB/portless-stop/routes.json"
printf 'acme' > "$RB/portless-stop-state/portless-45882.name"
printf 'https://acme.test' > "$RB/portless-stop-state/portless-45882.url"
printf '#!/bin/sh\nexit 0\n' > "$RB/fake-portless/portless"; chmod 755 "$RB/fake-portless/portless"
stubborn=$(PATH="$RB/fake-portless:$PATH" PORTLESS_STATE_DIR="$RB/portless-stop" PORTAL_STATE_DIR="$RB/portless-stop-state" \
  bash -c 'source "'"$S"'/tunnels.sh"; PROVIDER_BIN[portless]="'"$RB"'/fake-portless/portless"; cmd_stop portless 45882')
is "Portless removal keeps ownership when the route remains" "$(jq -c .ok <<<"$stubborn") $(test -e "$RB/portless-stop-state/portless-45882.name" && echo kept || echo lost)" "false kept"

printf '#!/bin/bash\necho '\''{"ok":false,"error":"setup engine failed"}'\''\n' > "$RB/fake/portless-setup.sh"; chmod 755 "$RB/fake/portless-setup.sh"
OLD_SD="$SCRIPT_DIR"; SCRIPT_DIR="$RB/fake"
is "Portless setup propagates an engine failure" "$(cmd_setup portless | jq -c .)" '{"ok":false,"error":"setup engine failed"}'
SCRIPT_DIR="$OLD_SD"

cp "$S/portal" "$RB/cli/portal"; printf '#!/bin/bash\necho '\''{"ok":false,"error":"sentinel"}'\''\n' > "$RB/cli/tunnels.sh"; chmod 755 "$RB/cli/portal" "$RB/cli/tunnels.sh"
printf '#!/bin/sh\nexit 1\n' > "$RB/fake/omarchy-shell"; chmod 755 "$RB/fake/omarchy-shell"
"$RB/cli/portal" expose cloudflared 3000 >/dev/null 2>&1; rc=$?
is "portal expose returns failure for an action error" "$rc" "1"
shared_error=$(PATH="$RB/fake:$PATH" "$RB/cli/portal" shared 2>&1); rc=$?
is "portal shared preserves an offline status failure" "$rc $(grep -c sentinel <<<"$shared_error")" "1 1"

printf 'mine' > "$RB/bin/cloudflared"
printf '#!/bin/bash\nprintf called > "'"$RB"'/curl-called"; exit 1\n' > "$RB/fake/curl"; chmod 755 "$RB/fake/curl"
PORTAL_BIN_DIR="$RB/bin" PORTAL_METRICS_DIR="$RB/provider-state" PATH="$RB/fake:/usr/bin:/bin" "$S/provider-install.sh" cloudflared >/dev/null 2>&1
[[ -e $RB/curl-called ]] && bad "provider install tried to overwrite an existing target" || ok "provider install refuses an existing target before download"

mkdir -p "$RB/home/.local/share/mise/installs/node/1/bin" "$RB/home/.local/share/mise/shims"
printf '#!/bin/sh\nexit 0\n' > "$RB/home/.local/share/mise/installs/node/1/bin/portless"
chmod 755 "$RB/home/.local/share/mise/installs/node/1/bin/portless"
ln -s /usr/bin/true "$RB/home/.local/share/mise/shims/portless"
resolved_portless=$(HOME="$RB/home" PATH="$RB/home/.local/share/mise/shims:/usr/bin:/bin" bash -c 'source "'"$S"'/tunnels.sh"; provider_bin portless')
is "provider resolution prefers a concrete version-manager binary over its shim" "$resolved_portless" "$RB/home/.local/share/mise/installs/node/1/bin/portless"

printf '#!/bin/bash\nexit 1\n' > "$RB/fake/ss"; chmod 755 "$RB/fake/ss"
scan_fail=$(PATH="$RB/fake:/usr/bin:/bin" "$S/scan-ports.sh")
is "a failed socket listing is an explicit scan error" "$(jq -r '.error // empty' <<<"$scan_fail")" "could not query listening sockets"
printf '#!/bin/sh\nprintf "%%s\\n" '\''{"version":1,"error":"more than 512 listening ports","ports":[]}'\''\n' > "$RB/scan-error"
chmod 700 "$RB/scan-error"
qmljs_scan_error=$(node "$S/lib/qmljs.mjs" decorate "$RB/scan-error" 2>&1); qmljs_scan_rc=$?
is "offline decoration propagates a scan error" \
  "$qmljs_scan_rc $(grep -c 'more than 512 listening ports' <<<"$qmljs_scan_error")" "1 1"

mkdir -p "$RB/shared/metrics" "$RB/shared-runtime"
: > "$RB/shared-runtime/server-3000.log"; : > "$RB/shared-runtime/.foreign.tmp"; : > "$RB/shared-runtime/ngrok.ok"
: > "$RB/shared/ca-import.pem"; : > "$RB/shared/watched.json"
plan=$(PORTAL_METRICS_DIR="$RB/shared" PORTAL_STATE_DIR="$RB/shared-runtime" "$S/uninstall.sh" --dry 2>/dev/null)
grep -qE 'server-3000|foreign' <<<"$plan" && bad "uninstall selected unrelated shared files" || ok "uninstall ignores unrelated shared files"
is "uninstall includes its exact transient files" "$(grep -Ec 'ngrok.ok|ca-import.pem' <<<"$plan")" "2"

echo; echo "$pass passed, $fail failed"
exit $((fail > 0))
