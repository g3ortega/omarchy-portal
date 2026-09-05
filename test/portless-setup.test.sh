#!/bin/bash
set -eo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
export FIXTURE REAL_SCRIPTS="$ROOT/scripts"
export HOME="$FIXTURE/home" PORTAL_STATE_DIR="$FIXTURE/runtime" PORTAL_METRICS_DIR="$FIXTURE/state"
export PORTLESS_STATE_DIR="$FIXTURE/portless" PORTAL_PORTLESS_TLD=localhost
mkdir -p "$FIXTURE/app/lib" "$FIXTURE/bin" "$HOME"
cp "$REAL_SCRIPTS/portless-setup.sh" "$FIXTURE/app/portless-setup.sh"

cat > "$FIXTURE/app/lib/portless.sh" <<'SH'
source "$REAL_SCRIPTS/lib/portless.sh"
lifecycle_mutation() { :; }
resolve_bin() { printf '%s' "$FIXTURE/bin/portless"; }
provider_bin() { resolve_bin "$@"; }
portless_state_load() { PORTLESS_STATE='{"files":{}}'; }
portless_probe() {
  if [[ ${PROXY_MODE:-off} == off && ! -e $FIXTURE/started ]]; then return 1; fi
  PROBE_PORT=${TEST_PROXY_PORT:-1355}
  PROBE_SCHEME=https
}
portless_serving_routes() { [[ ${PROXY_MODE:-off} != foreign ]]; }
portless_listener_scope() { echo local; }
ss() { :; }
portless_running_tlds() { echo localhost; }
tld_resolves() { return 0; }
sleep() { :; }
sudo() { echo sudo >> "$FIXTURE/forbidden"; return 99; }
resolvectl() { echo "resolvectl $*" >> "$FIXTURE/forbidden"; return 99; }
SH

cat > "$FIXTURE/bin/portless" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE/provider-calls"
printf '%s|%s\n' "${PORTLESS_LAN:-unset}" "${PORTLESS_LAN_IP:-}" > "$FIXTURE/provider-lan"
[[ $1 == proxy && $2 == start && $* == *--skip-trust* ]] || exit 99
touch "$FIXTURE/started"
SH
chmod +x "$FIXTURE/bin/portless"

run_setup() { bash "$FIXTURE/app/portless-setup.sh" "$1"; }

for port in 443 80 0 1 1023 -1 abc 65536 999999999999999999999999; do
  result=$(PORTAL_PORTLESS_PORT="$port" run_setup run)
  jq -e '.ok == false' <<<"$result" >/dev/null
  [[ ! -e $FIXTURE/provider-calls ]]
done
echo 'PASS invalid and privileged ports never start a provider'

result=$(PORTLESS_LAN=1 PORTLESS_LAN_IP=192.0.2.10 run_setup run)
jq -e '.ok and .checks.proxy == "ok" and all(.remaining[]; contains("sudo") | not)' <<<"$result" >/dev/null
[[ $(cat "$FIXTURE/provider-calls") == 'proxy start -p 1355 --skip-trust --tld localhost' ]]
[[ $(cat "$FIXTURE/provider-lan") == '0|' ]]
echo 'PASS default startup uses port 1355 and skips system trust'
echo 'PASS automatic startup overrides inherited LAN mode and LAN IP'

for port in 01024 65535; do
  rm -- "$FIXTURE/started" "$FIXTURE/provider-calls"
  result=$(PORTAL_PORTLESS_PORT="$port" run_setup run)
  jq -e '.ok and .checks.proxy == "ok"' <<<"$result" >/dev/null
  [[ $(cat "$FIXTURE/provider-calls") == "proxy start -p $((10#$port)) --skip-trust --tld localhost" ]]
done
echo 'PASS unprivileged port boundaries use canonical decimal arguments'

rm -- "$FIXTURE/started" "$FIXTURE/provider-calls"
result=$(PROXY_MODE=running PORTAL_PORTLESS_TLD=test run_setup run)
jq -e '.ok and .checks.proxy == "wrong-tld" and (.remaining | length > 0)' <<<"$result" >/dev/null
jq -e 'any(.remaining[]; contains("-p 1355 --skip-trust"))' <<<"$result" >/dev/null
[[ ! -e $FIXTURE/provider-calls ]]
echo 'PASS a wrong-domain proxy stays running for explicit repair'

result=$(
  set -- status
  source "$FIXTURE/app/portless-setup.sh" >/dev/null
  have() { [[ $1 != certutil ]] && command -v "$1" >/dev/null 2>&1; }
  report
)
jq -e '.checks.chromeTrust == false and any(.remaining[]; contains("Install certutil"))' <<<"$result" >/dev/null
echo 'PASS missing browser trust tooling stays visible in setup guidance'

source "$REAL_SCRIPTS/tunnels.sh"
source "$FIXTURE/app/lib/portless.sh"
PROXY_MODE=running
for TEST_PROXY_PORT in 1355 443; do
  [[ $(portless_status) == "ready|Proxy on port $TEST_PROXY_PORT|" ]]
done
PORTAL_PORTLESS_TLD=test
[[ $(portless_status) == 'setup|Proxy does not serve .test yet'* ]]
PORTAL_PORTLESS_TLD=localhost
echo 'PASS readiness accepts high and standard ports and catches domain mismatch'

(
  getent() { echo local >> "$FIXTURE/dns-order"; return 0; }
  dns_published() { echo published >> "$FIXTURE/dns-order"; return 0; }
  dns_gate fresh.trycloudflare.com
  [[ $(cat "$FIXTURE/dns-order") == $'published\nlocal' ]]
)
echo 'PASS new names are published before querying the local resolver'

getent() { [[ ${DNS_READY:-0} == 1 ]]; }
dns_published() { return 0; }
DNS_READY=0
if dns_gate example.trycloudflare.com; then exit 1; fi
[[ ! -e $FIXTURE/forbidden ]]

cat > "$FIXTURE/dump" <<'JSON'
{"files":{"cloudflared-3000.url":"https://example.trycloudflare.com","cloudflared-3000.reach":"public","cloudflared-3000.pid":"999999 1","cloudflared-3000.dns":"pending"},"refused":[]}
JSON
reconcile_portless_status() { cat "$FIXTURE/dump"; }
ss() { echo 'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*'; }
alive_line() { return 0; }
snapshot_current() { return 0; }
reconcile_idle() { return 0; }
cloudflared_adopt() { :; }
ngrok_adopt() { :; }
portless_adopt() { :; }
state_remove() { printf '%s\n' "$*" >> "$FIXTURE/removed"; }
kill() { echo kill >> "$FIXTURE/forbidden"; return 99; }
proc() { echo proc >> "$FIXTURE/forbidden"; return 99; }

result=$(cmd_status)
jq -e '.ok and .tunnels[0].dns == "pending"' <<<"$result" >/dev/null
[[ ! -e $FIXTURE/removed ]]
DNS_READY=1
result=$(cmd_status)
jq -e '.ok and .tunnels[0].dns == ""' <<<"$result" >/dev/null
[[ $(cat "$FIXTURE/removed") == "$STATE_DIR cloudflared-3000.dns" ]]
[[ ! -e $FIXTURE/forbidden ]]
echo 'PASS DNS becomes ready on a later poll without privileged cache flushes'
