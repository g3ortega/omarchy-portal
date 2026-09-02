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
me=$(< /proc/$$/comm)
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

# The pidfile binds pid and kernel start time; a matching comm is not enough.
me=$(< /proc/$$/comm); mystart=$(proc_start "$$")
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
rm -f "$STATE_DIR/cloudflared-4446".*
crowd=$(mktemp -d); for i in $(seq 1 600); do : > "$crowd/f$i"; done
is "a state directory with too many entries dumps nothing" "$(state_dump "$crowd" | jq -c '.files|length')" "0"
rm -rf "$crowd"
# State is read only from plain files we own; a planted link is not a file.
ln -s /etc/hostname "$STATE_DIR/cloudflared-4445.url"; ln -s /proc/self/stat "$STATE_DIR/cloudflared-4445.pid"
own_file "$STATE_DIR/cloudflared-4445.url" && bad "own_file accepted a symlink" || ok "own_file rejects a symlink"
is "read_own returns nothing for a symlink" "$(read_own "$STATE_DIR/cloudflared-4445.url")" ""
write_own "$STATE_DIR/cloudflared-4445.url" "replaced"
[[ -L $STATE_DIR/cloudflared-4445.url ]] && bad "write_own followed a link" || ok "write_own replaces a link with a file"
is "and the target was never touched" "$(cat /etc/hostname | wc -c | tr -d ' ')" "$(cat /etc/hostname | wc -c | tr -d ' ')"
rm -f "$STATE_DIR"/cloudflared-4445.*
mkdir -p "$T/notmine"; chmod 700 "$T/notmine"; ln -s "$T/notmine" "$T/link-dir"
own_dir "$T/link-dir" && bad "own_dir accepted a symlinked directory" || ok "own_dir rejects a symlinked directory"
printf 'x' > "$T/notmine/leaf"; is "a leaf under a symlinked parent is refused" "$(cat_own "$T/link-dir/leaf")" ""
chmod 770 "$T/notmine"; is "a leaf under a group-writable directory is refused" "$(cat_own "$T/notmine/leaf")" ""; chmod 700 "$T/notmine"
is "write_own creates 0600" "$(write_own "$T/notmine/w" v; stat -c %a "$T/notmine/w")" "600"

# Provider binaries run by absolute, validated path only.
mkdir -p "$T/bin"; printf '#!/bin/sh\n' > "$T/bin/fakeprov"; chmod 777 "$T/bin/fakeprov"
PATH="$T/bin:$PATH" resolve_bin fakeprov >/dev/null && bad "resolve_bin accepted a world-writable executable" || ok "resolve_bin rejects a world-writable executable"
chmod 755 "$T/bin/fakeprov"; is "resolve_bin returns the absolute path of a safe one" "$(PATH="$T/bin:$PATH" resolve_bin fakeprov)" "$T/bin/fakeprov"
resolve_bin definitely-not-a-command-xyz >/dev/null && bad "resolve_bin found a ghost" || ok "resolve_bin fails for a missing command"

# launch: a session of its own, a private log, pid bound to start time.
out=$(state launch "$STATE_DIR" launch-test.log -- /usr/bin/sleep 20); lpid=${out%% *}; lstart=${out#* }
owned_pid "$lpid" sleep "$lstart" && ok "launch reports a pid whose start time matches" || bad "launch pid/start mismatch: $out"
[[ $(ps -o sid= -p "$lpid" | tr -d ' ') == "$lpid" ]] && ok "the launched process leads its own session" || bad "launched process is not a session leader"
is "the launch log is private" "$(stat -c %a "$STATE_DIR/launch-test.log")" "600"
kill "$lpid" 2>/dev/null
is "cmd_stop rejects an unknown provider" "$(cmd_stop nope 1 | jq -r .error)" "unknown provider"
is "cmd_stop rejects a bad port" "$(cmd_stop cloudflared x | jq -r .error)" "invalid port"

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
[[ ! -L $PORTAL_METRICS_DIR/metrics/5000.jsonl && -f $PORTAL_METRICS_DIR/metrics/5000.jsonl && $(wc -c < /etc/hostname) -lt 64 ]] && ok "append replaces a planted link with a fresh file and never follows it" || bad "append followed or kept a symlinked path"
mkfifo "$PORTAL_METRICS_DIR/metrics/5001.jsonl"
is "read of a planted FIFO returns at once, empty" "$(timeout 5 "$M" read 5001 | jq -c '.samples|length')" "0"
"$M" append-batch '{"5001":{"t":1}}' >/dev/null; [[ -f $PORTAL_METRICS_DIR/metrics/5001.jsonl && ! -p $PORTAL_METRICS_DIR/metrics/5001.jsonl ]] && ok "append replaces a planted FIFO with a fresh file" || bad "append left or blocked on a FIFO"
big=$(mktemp -p "$PORTAL_METRICS_DIR/metrics"); head -c 9000000 /dev/zero > "$big"; mv "$big" "$PORTAL_METRICS_DIR/metrics/5002.jsonl"
is "read refuses a file past the cap" "$(timeout 5 "$M" read 5002 | jq -c '.samples|length')" "0"
yes '{"t":1756700000,"conns":0,"cpuPct":0,"rssKb":73000,"latMs":12,"httpCode":200,"pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' | head -n 19300 > "$PORTAL_METRICS_DIR/metrics/4000.jsonl"
"$M" append-batch '{"4000":{"t":2}}' >/dev/null
is "append-batch trims past the hard bound" "$(wc -l < "$PORTAL_METRICS_DIR/metrics/4000.jsonl")" "17280"
"$M" unwatch 3000 >/dev/null
[[ -e $PORTAL_METRICS_DIR/metrics/3000.jsonl ]] && bad "unwatch left the metric file" || ok "unwatch deletes the metric file"
is "state files are private" "$(stat -c %a "$PORTAL_METRICS_DIR/metrics/4000.jsonl")" "600"

echo; echo "$pass passed, $fail failed"
exit $((fail > 0))
