#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export PORTAL_STATE_DIR="$T/runtime" PORTAL_METRICS_DIR="$T/state"
mkdir "$PORTAL_STATE_DIR" "$PORTAL_METRICS_DIR"
set -- noop
source "$ROOT/scripts/tunnels.sh" >/dev/null

provider_bin() { printf '%s' "$T/ngrok"; }
ss() { printf 'LISTEN 0 128 127.0.0.1:4040 0.0.0.0:* users:(("ngrok",pid=999999,fd=3))\n'; }
proc_start() { echo 1; }
proc() { [[ $1 == check && $2 == 999999 && $3 == 1 ]]; }
stat() { printf '%s' "${TEST_UID:-$UID}"; }
readlink() {
  [[ ${UNTRUSTED:-0} == 0 ]] || { echo /other/program; return; }
  if [[ ${REPLACED:-0} == 1 && $(cat "$T/gets") -ge 2 ]]; then echo /other/program; else echo "$T/ngrok"; fi
}
kill() { echo signal >> "$T/forbidden"; return 99; }
curl() {
  local method url
  [[ $* == *"--noproxy *"* ]] || return 99
  while (( $# )); do
    case $1 in -X) method=$2; shift ;; http://*) url=$1 ;; esac
    shift
  done
  [[ $url == http://127.0.0.1:4040/api/* ]] || return 99
  if [[ $method == GET ]]; then
    local count; count=$(cat "$T/gets")
    echo $((count + 1)) > "$T/gets"
    if [[ ${CHANGED:-0} == 1 && $count -ge 1 ]]; then
      jq '.tunnels |= map(if .name == "local/name" then .public_url = "https://changed.ngrok.app" else . end)' "$T/api"
    else cat "$T/api"; fi
  elif [[ $method == DELETE ]]; then
    printf '%s\n' "$url" >> "$T/deletes"
    [[ $url == http://127.0.0.1:4040/api/tunnels/local%2Fname ]] || return 99
    jq '.tunnels |= map(select(.name != "local/name"))' "$T/api" > "$T/next"
    mv "$T/next" "$T/api"
  else return 99; fi
}
reset_api() {
  echo 0 > "$T/gets"
  rm -f "$T/deletes"
  UNTRUSTED=0 REPLACED=0 CHANGED=0 TEST_UID=$UID
  cat > "$T/api" <<'JSON'
{"tunnels":[{"name":"remote","config":{"addr":"http://192.0.2.10:3000"},"public_url":"https://remote.ngrok.app"},{"name":"local/name","config":{"addr":"http://localhost:3000"},"public_url":"https://local.ngrok.app"}]}
JSON
}

reset_api
old=$(jq -r 'first(.tunnels[] | select(.config.addr | endswith(":3000")) | .name)' "$T/api")
[[ $old == remote ]]
LIVE_PORTS=' 4040 '
[[ $(ngrok_adopt) == $'3000\thttps://local.ngrok.app' ]]
ngrok_stop_adopted 3000
[[ $(jq -r '.tunnels[].name' "$T/api") == remote ]]
[[ $(wc -l < "$T/deletes") == 1 ]]
echo 'ok remote same-port tunnel preserved and local name URI-encoded'

reset_api
jq '.tunnels += [{name:"second",config:{addr:"http://127.0.0.1:3000"},public_url:"https://second.ngrok.app"}]' "$T/api" > "$T/next"
mv "$T/next" "$T/api"
if ngrok_stop_adopted 3000; then echo 'FAIL ambiguous stop succeeded'; exit 1; fi
[[ ! -e $T/deletes ]]
echo 'ok ambiguous local tunnels refused before deletion'

for mode in untrusted changed replaced foreign_uid; do
  reset_api
  case $mode in untrusted) UNTRUSTED=1 ;; changed) CHANGED=1 ;; replaced) REPLACED=1 ;; foreign_uid) TEST_UID=$((UID + 1)) ;; esac
  if ngrok_stop_adopted 3000; then echo "FAIL $mode stop succeeded"; exit 1; fi
  [[ ! -e $T/deletes ]]
done
echo 'ok untrusted agent, foreign owner, changed tunnel and replaced agent refused'

reset_api
for addr in localhost:1 http://127.0.0.1:3000 'https://[::1]:65535/'; do
  result=$(jq --arg addr "$addr" '.tunnels = [.tunnels[1] | .config.addr = $addr]' "$T/api" | ngrok_local_tunnels)
  [[ $(jq length <<<"$result") == 1 ]]
done
for addr in localhost:0 localhost:65536 localhost:999999 'http://localhost.evil:3000' 'http://localhost:3000@remote' 'http://192.0.2.10:3000' 'http://[2001:db8::1]:3000'; do
  result=$(jq --arg addr "$addr" '.tunnels = [.tunnels[1] | .config.addr = $addr]' "$T/api" | ngrok_local_tunnels)
  [[ $(jq length <<<"$result") == 0 ]]
done
if ngrok_local_tunnels <<< '{}' 2>/dev/null; then echo 'FAIL malformed response accepted'; exit 1; fi
echo 'ok explicit IPv4/IPv6 loopback port bounds and malformed response checks'

cat > "$T/ngrok" <<'SH'
#!/bin/bash
[[ $* == 'config check' ]] || exit 99
exit "${CONFIG_RC:-0}"
SH
chmod +x "$T/ngrok"
[[ $(ngrok_status) == 'ready|Configuration valid; account required|' ]]
[[ $(CONFIG_RC=1 ngrok_status) == 'setup|Configuration needs attention|ngrok config check' ]]
[[ ! -e $T/forbidden ]]
echo 'ok status describes configuration without asserting authentication'
