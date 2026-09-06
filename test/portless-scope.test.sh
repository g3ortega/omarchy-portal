#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export PORTLESS_STATE_DIR="$T/portless" PORTAL_STATE_DIR="$T/runtime" PORTAL_METRICS_DIR="$T/state"
export PORTAL_PORTLESS_TLD=localhost
mkdir "$PORTLESS_STATE_DIR" "$PORTAL_STATE_DIR" "$PORTAL_METRICS_DIR"
printf '%s' '[{"hostname":"app.localhost","port":3000,"pid":0}]' > "$PORTLESS_STATE_DIR/routes.json"
set -- noop
source "$ROOT/scripts/tunnels.sh" >/dev/null || true
ss() {
  [[ ${SS_FAIL:-0} == 0 ]] || return 1
  [[ $BIND == off ]] || printf 'LISTEN 0 128 %s:1355 0.0.0.0:*\n' "$BIND"
  printf 'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*\n'
}
for BIND in 127.0.0.1 127.1.2.3 '[::1]' '[0:0:0:0:0:0:0:1]' '[::ffff:127.0.0.1]'; do
  [[ $(portless_listener_scope 1355) == local ]]
done
for BIND in 0.0.0.0 '*' '[::]' 192.0.2.1 '[2001:db8::1]'; do
  [[ $(portless_listener_scope 1355) == lan ]]
done
[[ $(portless_listener_scope 1355 '') == unknown ]]
[[ $(portless_listener_scope 1355 'broken') == unknown ]]
[[ $(portless_listener_scope invalid) == unknown ]]
[[ $(SS_FAIL=1 portless_listener_scope 1355) == unknown ]]
[[ $(portless_listener_scope 1355 $'LISTEN 0 128 127.0.0.1:1355 *:*\nLISTEN 0 128 [::]:1355 *:*') == lan ]]
echo 'ok actual socket scope recognizes loopback, wildcard, LAN and unknown'

portless_probe() { [[ ${OFFLINE:-0} == 0 ]] || return 1; PROBE_PORT=1355; PROBE_SCHEME=https; }
portless_serving_routes() { return 0; }
portless_serves_tld() { return 0; }
tld_resolves() { return 0; }
provider_bin() { echo /stub/portless; }
cloudflared_adopt() { :; }
ngrok_adopt() { :; }
proc() { echo proc >> "$T/forbidden"; return 99; }
kill() { echo kill >> "$T/forbidden"; return 99; }
portless_state_load
for BIND in 127.0.0.1 0.0.0.0; do
  expected=local; [[ $BIND == 127.0.0.1 ]] || expected=lan
  out=$(cmd_status)
  jq -e --arg scope "$expected" '.ok and (.tunnels | length == 1) and .tunnels[0].reach == $scope and .tunnels[0].aliasName == "app" and .tunnels[0].managed == false' <<<"$out" >/dev/null
done
SS_FAIL=0 BIND=broken
out=$(cmd_status)
jq -e '.ok and (.tunnels | length == 0)' <<<"$out" >/dev/null
echo 'ok runtime LAN routes remain visible with alias metadata; unknown routes omitted'

for BIND in 0.0.0.0 broken; do
  out=$(cmd_start_portless 3000 renamed)
  jq -e '.ok == false and (.error | contains("not verified as local-only"))' <<<"$out" >/dev/null
done
OFFLINE=1 BIND=0.0.0.0
write_own "$STATE_DIR/portless-3000.name" app
write_own "$STATE_DIR/portless-3000.url" https://app.localhost:1355
write_own "$STATE_DIR/portless-3000.reach" local
out=$(cmd_status)
jq -e '.ok and (.tunnels | length == 0)' <<<"$out" >/dev/null
out=$(cmd_status internal)
jq -e '.ok and (.tunnels | length == 1) and .tunnels[0].reach == "unknown" and .tunnels[0].managed == null and .tunnels[0].aliasName == ""' <<<"$out" >/dev/null
out=$(cmd_start_portless 3000 renamed)
jq -e '.ok == false and (.error | contains("not verified as local-only"))' <<<"$out" >/dev/null
[[ $(portless_status) == unavailable\|* ]]
(
  cmd_stop() { printf '%s %s\n' "$1" "$2" > "$T/stopped"; echo '{"ok":true}'; }
  cmd_stop_all > "$T/stop-result"
)
[[ $(cat "$T/stopped") == 'portless 3000' ]]
jq -e '.ok' "$T/stop-result" >/dev/null
BIND=off
out=$(cmd_status)
jq -e '.ok and .tunnels[0].reach == "local"' <<<"$out" >/dev/null
state_remove "$STATE_DIR" portless-3000.name portless-3000.url portless-3000.reach
[[ $(portless_status) == 'setup|Local names are off|' ]]
cat > "$T/offline-provider" <<'SH'
#!/bin/bash
echo attempted > "$PORTAL_STATE_DIR/offline-attempt"
exit 1
SH
chmod +x "$T/offline-provider"
provider_bin() { echo "$T/offline-provider"; }
out=$(cmd_start_portless 3000 renamed)
[[ -e $PORTAL_STATE_DIR/offline-attempt ]]
jq -e '.ok == false and (.error | contains("not verified as local-only") | not)' <<<"$out" >/dev/null
OFFLINE=0 BIND=0.0.0.0
[[ $(portless_status) == setup\|Proxy\ listens\ beyond* ]]
[[ $(portless_fix_cmd '' 1355) == *'PORTLESS_LAN=0 PORTLESS_LAN_IP='* ]]
[[ $(portless_fix_cmd '' 1355) == *'-p 1355 --skip-trust'* ]]
[[ ! -e $T/forbidden ]]
echo 'ok failed HTTP probe cannot claim local or bypass naming; internal stop retains unknown aliases'
echo 'ok naming blocked on LAN/unknown and explicit repair preserves unprivileged port'

finish_start portless 3000 https://app.localhost:1355 > "$T/start"
jq -e '.reach == "lan"' "$T/start" >/dev/null
echo 'ok finish rechecks scope instead of promising local-only exposure'

mkdir -p "$T/setup/lib"
cp "$ROOT/scripts/portless-setup.sh" "$T/setup/portless-setup.sh"
export REAL_PORTLESS_LIB="$ROOT/scripts/lib/portless.sh" SCOPE_FIXTURE="$T"
cat > "$T/setup/lib/portless.sh" <<'SH'
source "$REAL_PORTLESS_LIB"
lifecycle_mutation() { :; }
portless_probe() { [[ ${SCOPE_OFFLINE:-0} == 0 ]] || return 1; PROBE_PORT=1355; PROBE_SCHEME=https; }
ss() { printf 'LISTEN 0 128 %s:1355 *:*\n' "$SCOPE_BIND"; }
resolve_bin() { echo provider >> "$SCOPE_FIXTURE/forbidden"; return 99; }
SH
for bind in 0.0.0.0 broken; do
  out=$(SCOPE_BIND="$bind" bash "$T/setup/portless-setup.sh" run)
  jq -e '.ok == false and (.error | contains("before setup"))' <<<"$out" >/dev/null
done
[[ ! -e $T/forbidden ]]
echo 'ok setup refuses LAN/unknown before provider or trust changes'

out=$(SCOPE_OFFLINE=1 SCOPE_BIND=0.0.0.0 bash "$T/setup/portless-setup.sh" run)
jq -e '.ok == false and (.error | contains("before setup"))' <<<"$out" >/dev/null
[[ ! -e $T/forbidden ]]
echo 'ok failed HTTP probe cannot bypass setup listener checks'
