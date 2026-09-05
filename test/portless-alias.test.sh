#!/bin/bash
set -eo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
export FIXTURE PORTLESS_STATE_DIR="$FIXTURE/portless" PORTAL_STATE_DIR="$FIXTURE/portal"
export PORTAL_PORTLESS_TLD=localhost
mkdir -p "$PORTLESS_STATE_DIR" "$PORTAL_STATE_DIR" "$FIXTURE/bin"
printf '["localhost","test","dev.test"]' > "$PORTLESS_STATE_DIR/proxy.tlds"

cat > "$FIXTURE/bin/portless" <<'PY'
#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["FIXTURE"])
args = sys.argv[1:]
with (root / "calls").open("a") as log:
    log.write(" ".join(args) + "\n")
if args[0] != "alias" or "--force" in args:
    raise SystemExit(99)
state = root / "portless"
routes = json.loads((state / "routes.json").read_text())
tlds = json.loads((state / "proxy.tlds").read_text())
remove = args[1] == "--remove"
name = args[2] if remove else args[1]
hosts = {name.lower() + "." + tld for tld in tlds}
if not remove and name == os.environ.get("FAIL_ALIAS_NAME"):
    taken = os.environ.get("TAKE_OLD_ON_FAIL")
    if taken:
        routes += [{"hostname": taken + ".localhost", "port": 4000, "pid": 0}]
        (state / "routes.json").write_text(json.dumps(routes))
    raise SystemExit(1)
routes = [r for r in routes if r["hostname"] not in hosts]
if not remove:
    routes += [{"hostname": h, "port": int(args[2]), "pid": 0} for h in sorted(hosts)]
(state / "routes.json").write_text(json.dumps(routes))
PY
chmod +x "$FIXTURE/bin/portless"

source "$ROOT/scripts/tunnels.sh"
provider_bin() { printf '%s' "$FIXTURE/bin/portless"; }
portless_probe() { PROBE_PORT=1355; PROBE_SCHEME=https; }
portless_listener_scope() { echo local; }
portless_serving_routes() { return 0; }
getent() { return 0; }
kill() { echo kill >> "$FIXTURE/signals"; return 99; }
proc() { echo proc >> "$FIXTURE/signals"; return 99; }

reset_routes() {
  rm -f -- "$STATE_DIR"/portless-*
  printf '%s' "$1" > "$PORTLESS_STATE_DIR/routes.json"
  : > "$FIXTURE/calls"
  portless_state_load
}

for identity in 0 999999; do
  reset_routes "[{\"hostname\":\"taken.test\",\"port\":4000,\"pid\":$identity},{\"hostname\":\"old.localhost\",\"port\":3000,\"pid\":0}]"
  before=$(cat "$PORTLESS_STATE_DIR/routes.json")
  result=$(cmd_start_portless 3000 taken)
  jq -e '.ok == false and (.error | contains("choose another name"))' <<<"$result" >/dev/null
  [[ ! -s $FIXTURE/calls && ! -e $STATE_DIR/portless-3000.name ]]
  [[ $(cat "$PORTLESS_STATE_DIR/routes.json") == "$before" ]]
done
echo 'PASS static and managed collisions in another TLD cause no effects'

reset_routes '[{"hostname":"app.localhost","port":3000,"pid":999999}]'
for action in start stop; do
  if [[ $action == start ]]; then result=$(cmd_start_portless 3000 renamed)
  else result=$(cmd_stop portless 3000); fi
  jq -e '.ok == false and (.error | contains("managed by portless run"))' <<<"$result" >/dev/null
  [[ ! -s $FIXTURE/calls ]]
done
echo 'PASS managed routes reject alias rename and removal without signals'

reset_routes '[{"hostname":"native.localhost","port":3000,"pid":999999},{"hostname":"owned.localhost","port":3000,"pid":0}]'
write_own "$(namefile portless 3000)" owned
result=$(cmd_stop portless 3000)
jq -e '.ok == true' <<<"$result" >/dev/null
jq -e 'length == 1 and .[0].hostname == "native.localhost" and .[0].pid == 999999' "$PORTLESS_STATE_DIR/routes.json" >/dev/null
[[ ! -e $(namefile portless 3000) && ! -e $FIXTURE/signals ]]
echo 'PASS owned static alias removal preserves a managed route on the same port'

reset_routes '[{"hostname":"owned.localhost","port":3000,"pid":999999}]'
write_own "$(namefile portless 3000)" owned
result=$(cmd_stop portless 3000)
jq -e '.ok == false' <<<"$result" >/dev/null
[[ ! -s $FIXTURE/calls && -e $(namefile portless 3000) && ! -e $FIXTURE/signals ]]
echo 'PASS stale ownership marker cannot remove a managed matching alias'

for outcome in renamed broken; do
  reset_routes '[{"hostname":"native.localhost","port":3000,"pid":999999},{"hostname":"owned.localhost","port":3000,"pid":0}]'
  write_own "$(namefile portless 3000)" owned
  if [[ $outcome == broken ]]; then result=$(FAIL_ALIAS_NAME=broken cmd_start_portless 3000 broken)
  else result=$(cmd_start_portless 3000 renamed); fi
  if [[ $outcome == broken ]]; then
    jq -e '.ok == false and (.error | contains("alias failed"))' <<<"$result" >/dev/null
    expected=owned
  else
    jq -e '.ok == true' <<<"$result" >/dev/null
    expected=renamed
  fi
  jq -e --arg name "$expected.localhost" 'any(.[]; .hostname == "native.localhost" and .pid == 999999)
    and any(.[]; .hostname == $name and .port == 3000 and .pid == 0)' "$PORTLESS_STATE_DIR/routes.json" >/dev/null
  [[ $(cat "$(namefile portless 3000)") == "$expected" && ! -e $FIXTURE/signals ]]
done
echo 'PASS exact owned aliases rename and roll back beside managed siblings'

reset_routes '[{"hostname":"api.acme.dev.test","port":3000,"pid":0}]'
[[ $(portless_route_name 3000) == api.acme ]]
echo 'PASS adopted alias names use the longest matching domain suffix'

reset_routes '[{"hostname":"api.acme.localhost","port":3000,"pid":0},{"hostname":"api.acme.test","port":3000,"pid":0},{"hostname":"api.other.localhost","port":4000,"pid":0}]'
result=$(cmd_stop portless 3000)
jq -e '.ok' <<<"$result" >/dev/null
[[ $(cat "$FIXTURE/calls") == 'alias --remove api.acme' ]]
jq -e 'length == 1 and .[0].hostname == "api.other.localhost"' "$PORTLESS_STATE_DIR/routes.json" >/dev/null
echo 'PASS removing a dotted static alias preserves unrelated nested names'

reset_routes '[{"hostname":"old.localhost","port":3000,"pid":0}]'
printf old > "$STATE_DIR/portless-3000.name"
result=$(cmd_start_portless 3000 renamed)
jq -e '.ok and .url == "https://renamed.localhost:1355"' <<<"$result" >/dev/null
[[ $(cat "$STATE_DIR/portless-3000.name") == renamed ]]
[[ $(cat "$FIXTURE/calls") == $'alias --remove old\nalias renamed 3000' ]]
echo 'PASS owned static aliases rename without forced takeover'

for owned in 0 1; do
  reset_routes '[{"hostname":"api.old.localhost","port":3000,"pid":0}]'
  if (( owned )); then
    reset_routes '[{"hostname":"old.localhost","port":3000,"pid":0}]'
    printf old > "$STATE_DIR/portless-3000.name"
    old=old
  else old=api.old; fi
  result=$(FAIL_ALIAS_NAME=broken cmd_start_portless 3000 broken)
  jq -e '.ok == false and (.error | contains("alias failed"))' <<<"$result" >/dev/null
  portless_state_load
  [[ $(portless_route_name 3000) == "$old" ]]
  if (( owned )); then [[ $(cat "$STATE_DIR/portless-3000.name") == old ]]
  else [[ ! -e $STATE_DIR/portless-3000.name ]]; fi
  [[ $(tail -1 "$FIXTURE/calls") == "alias $old 3000" ]]
done
[[ ! -e $FIXTURE/signals ]]
echo 'PASS failed renames restore owned and adopted static aliases without force'

reset_routes '[{"hostname":"old.localhost","port":3000,"pid":0}]'
printf old > "$STATE_DIR/portless-3000.name"
result=$(FAIL_ALIAS_NAME=broken TAKE_OLD_ON_FAIL=old cmd_start_portless 3000 broken)
jq -e '.ok == false and (.error | contains("rollback could not be verified"))' <<<"$result" >/dev/null
jq -e 'length == 1 and .[0].hostname == "old.localhost" and .[0].port == 4000' "$PORTLESS_STATE_DIR/routes.json" >/dev/null
[[ $(cat "$FIXTURE/calls") == $'alias --remove old\nalias broken 3000' ]]
[[ $(cat "$STATE_DIR/portless-3000.name") == broken ]]
echo 'PASS rollback preserves a name claimed by another port during failure'

reset_routes '[{"hostname":"api.acme.dev.test","port":3000,"pid":0},{"hostname":"static.localhost","port":4000,"pid":0},{"hostname":"native.test","port":4000,"pid":999999},{"hostname":"branch.app.localhost","port":6000,"pid":999999}]'
ss() {
  local port
  for port in 3000 4000 5000 6000; do
    printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' "$port"
  done
}
cloudflared_adopt() { printf '5000\thttps://example.trycloudflare.com\n'; }
ngrok_adopt() { :; }
result=$(cmd_status)
jq -e '[.tunnels[] | select(.provider == "portless") | [.port, .aliasName, .managed]] == [[3000,"api.acme",false],[4000,"static",false],[6000,"branch.app",true]]' <<<"$result" >/dev/null \
  || { echo "FAIL displayed alias classification: $result"; exit 1; }
jq -e '[.tunnels[] | select(.provider == "cloudflared")] == [{provider:"cloudflared",port:5000,url:"https://example.trycloudflare.com",reach:"public",dns:"",targetHealthy:null}]' <<<"$result" >/dev/null
echo 'PASS local metadata classifies the displayed alias without changing public rows'

printf static > "$STATE_DIR/portless-4000.name"
printf https://static.localhost:1355 > "$STATE_DIR/portless-4000.url"
printf local > "$STATE_DIR/portless-4000.reach"
result=$(cmd_status)
jq -e '.ok and any(.tunnels[]; .port == 4000 and .aliasName == "static" and .managed == false)' <<<"$result" >/dev/null
echo 'PASS owned static alias remains editable beside a managed sibling'

python3 - <<'PY'
import json
import os
from pathlib import Path
path = Path(os.environ["PORTLESS_STATE_DIR"]) / "routes.json"
routes = json.loads(path.read_text())
routes[0]["padding"] = "x" * 200000
path.write_text(json.dumps(routes))
PY
result=$(cmd_status)
jq -e '.ok and any(.tunnels[]; .aliasName == "api.acme")' <<<"$result" >/dev/null
echo 'PASS metadata reads a large validated snapshot without an oversized command argument'

printf https://api.acme.dev.test:1355 > "$STATE_DIR/portless-3000.url"
printf local > "$STATE_DIR/portless-3000.reach"
portless_state_load() { PORTLESS_STATE=""; return 1; }
result=$(cmd_status)
jq -e '.ok and any(.tunnels[]; .provider == "portless" and .aliasName == "" and .managed == null)' <<<"$result" >/dev/null
echo 'PASS refused Portless state leaves local ownership explicitly unknown'
