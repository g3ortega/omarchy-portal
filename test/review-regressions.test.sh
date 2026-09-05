#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export PORTAL_STATE_DIR="$T/runtime" PORTAL_METRICS_DIR="$T/state" PORTLESS_STATE_DIR="$T/portless"
export PORTAL_PORTLESS_TLD=localhost
mkdir "$PORTAL_STATE_DIR" "$PORTAL_METRICS_DIR" "$PORTLESS_STATE_DIR"
set -- noop
source "$ROOT/scripts/tunnels.sh" >/dev/null || true
ss() { echo 'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:* users:(("node",pid=999999,fd=3))'; }
proc_start() { echo 1; }
proc() { [[ $1 == check && $2 == 999999 && $3 == 1 ]] || { echo unexpected-proc >> "$T/signals"; return 99; }; }
kill() { echo kill >> "$T/signals"; return 99; }
alive_line() { [[ $1 == '999999 1' ]]; }
stop_line() { echo refused-stop >> "$T/stops"; return 1; }
provider_bin() { echo "$T/provider"; }
printf '999999 1' > "$STATE_DIR/cloudflared-3000.pid"
printf 'https://unit.trycloudflare.com' > "$STATE_DIR/cloudflared-3000.url"
failures=0
out=$(cmd_start cloudflared 03000)
if jq -e '.ok and .url == "https://unit.trycloudflare.com"' <<<"$out" >/dev/null \
    && [[ -e $STATE_DIR/cloudflared-3000.target && ! -e $STATE_DIR/cloudflared-03000.target ]]; then
  echo 'ok padded CLI port uses canonical socket and state identity'
else echo 'FAIL padded CLI port rejected or noncanonical state written'; failures=$((failures + 1)); fi

for suffix in multiline newline nul; do
  python3 - "$STATE_DIR/cloudflared-3000.url" "$suffix" <<'PY'
from pathlib import Path
import sys
suffix = {'multiline':b'\nextra', 'newline':b'\n', 'nul':b'\0'}[sys.argv[2]]
Path(sys.argv[1]).write_bytes(b'https://unit.trycloudflare.com' + suffix)
PY
  out=$(cmd_start cloudflared 3000)
  if jq -e '.ok == false' <<<"$out" >/dev/null; then
    echo "ok complete URL record rejects $suffix suffix"
  else echo "FAIL existing URL accepted $suffix suffix"; failures=$((failures + 1)); fi
done

for leaf in "$STATE_DIR"/cloudflared-3000.*; do
  mv -- "$leaf" "${leaf/-3000./-03000.}"
done
[[ $(tracked_state_port cloudflared 3000 3000) == 03000 ]]
out=$(cmd_stop cloudflared 3000)
jq -e '.ok == false and (.error | contains("did not stop"))' <<<"$out" >/dev/null
[[ -e $STATE_DIR/cloudflared-03000.pid ]]
echo 'ok stopping retains the existing lexical state key and guarded identity path'

printf '[]' > "$PORTLESS_STATE_DIR/routes.json"
printf '["localhost"]' > "$PORTLESS_STATE_DIR/proxy.tlds"
cat > "$T/provider" <<'PY'
#!/usr/bin/python3
import json,os
from pathlib import Path
import sys
path=Path(os.environ['PORTLESS_STATE_DIR'])/'routes.json'
rows=json.loads(path.read_text())
args=sys.argv[1:]
assert args[0]=='alias' and '--force' not in args
remove=args[1]=='--remove'
name=(args[2] if remove else args[1]).lower()
if not remove and name == os.environ.get('FAIL_NAME'):
    sys.exit(1)
rows=[r for r in rows if r['hostname'] != name+'.localhost']
if not remove:
    rows.append({'hostname':name+'.localhost','port':int(args[2]),'pid':0})
path.write_text(json.dumps(rows))
PY
chmod +x "$T/provider"
portless_probe() { PROBE_PORT=1355; PROBE_SCHEME=https; }
portless_proxy_scope() { echo local; }
portless_listener_scope() { echo local; }
portless_serving_routes() { return 0; }
getent() { return 0; }
out=$(cmd_start portless 03000 MyApp)
if jq -e '.ok and (.url | contains("myapp.localhost"))' <<<"$out" >/dev/null \
    && [[ $(cat "$STATE_DIR/portless-3000.name" 2>/dev/null) == myapp ]]; then
  echo 'ok uppercase Portless name normalized before publication'
else echo 'FAIL uppercase Portless name failed or left noncanonical marker'; failures=$((failures + 1)); fi
if (( failures == 0 )); then
  out=$(FAIL_NAME=anotherapp cmd_start portless 3000 AnotherApp)
  jq -e '.ok == false' <<<"$out" >/dev/null
  [[ $(cat "$STATE_DIR/portless-3000.name") == myapp ]]
  jq -e 'length == 1 and .[0].hostname == "myapp.localhost"' "$PORTLESS_STATE_DIR/routes.json" >/dev/null
  echo 'ok uppercase failed rename rolls back to canonical prior alias'
fi
[[ ! -e $T/signals ]]
(( failures == 0 ))
