#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/tunnels.sh"
mapfile -t cloudflare_args < <(cloudflared_argv 39417)
[[ ${cloudflare_args[*]} == 'tunnel --config /dev/null --no-autoupdate --url http://localhost:39417' ]] || {
  echo 'FAIL Cloudflare arguments must isolate config and name the approved local origin' >&2
  exit 1
}
cloudflare_scratch=$(mktemp -d)
trap 'rm -rf -- "$cloudflare_scratch"' EXIT
(
  export TUNNEL_NAME=portal-env-probe TUNNEL_HELLO_WORLD=true TUNNEL_BASTION=true
  export TUNNEL_URL=http://localhost:39418 TUNNEL_LOGLEVEL=warn
  STATE_DIR="$cloudflare_scratch/state"
  kill() { echo 'unexpected signal in launch fixture' >&2; exit 78; }
  proc() { echo 'unexpected process operation in launch fixture' >&2; exit 79; }
  target_owns_port() { return 0; }
  provider_bin() { printf '%s' /usr/bin/false; }
  clear_share() { return 0; }
  write_own() { return 0; }
  state() {
    [[ $1 == launch-tracked ]] || return 1
    python3 - "$cloudflare_scratch/launch.json" "${@:6}" <<'CAPTURE'
import json, os, sys
keys = ("TUNNEL_NAME", "TUNNEL_HELLO_WORLD", "TUNNEL_BASTION", "TUNNEL_URL", "TUNNEL_LOGLEVEL")
with open(sys.argv[1], "w") as output:
    json.dump({"command": sys.argv[2:], "environment": {k: os.environ[k] for k in keys if k in os.environ}}, output)
CAPTURE
    return 1
  }
  cmd_start cloudflared 39417 --target 999999 1 >/dev/null
)
python3 - "$cloudflare_scratch/launch.json" <<'CHECK'
import json, sys
with open(sys.argv[1]) as source:
    captured = json.load(source)
for key in ("TUNNEL_NAME", "TUNNEL_HELLO_WORLD", "TUNNEL_BASTION"):
    assert key not in captured["environment"], f"launch must not inherit {key}"
assert captured["environment"]["TUNNEL_URL"] == "http://localhost:39418"
assert captured["environment"]["TUNNEL_LOGLEVEL"] == "warn"
print("ok real launch removes only origin and mode overrides")
CHECK
cloudflare_binary=$(command -v cloudflared || true)
if [[ -z $cloudflare_binary ]] || ! command -v unshare >/dev/null || ! command -v ip >/dev/null \
    || ! unshare --user --map-root-user --net --mount true 2>/dev/null; then
  echo 'skip Cloudflare binary proof requires cloudflared, ip, and user/network/mount namespaces'
  exit 0
fi
cp -- "$cloudflare_binary" "$cloudflare_scratch/cloudflared"
mkdir -p "$cloudflare_scratch/home/.cloudflared"
unshare --user --map-root-user --net --mount python3 - "$cloudflare_scratch" "${cloudflare_args[@]}" <<'PY'
import base64
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

scratch = Path(sys.argv[1])
args = sys.argv[2:]
binary = str(scratch / "cloudflared")
subprocess.run(["mount", "--bind", str(scratch / "home"), str(Path.home())], check=True)
subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
config = scratch / "home/.cloudflared/config.yaml"
clean_env = {key: value for key, value in os.environ.items() if not key.startswith("TUNNEL_")}
clean_env.pop("NO_TLS_VERIFY", None)

class Allocation(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.dumps({"success": True, "result": {
            "id": "12345678-1234-1234-1234-123456789abc", "account_tag": "offline-test",
            "secret": base64.b64encode(b"x" * 32).decode(),
            "hostname": "offline-test.trycloudflare.com",
        }}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

api = http.server.HTTPServer(("127.0.0.1", 0), Allocation)
threading.Thread(target=api.serve_forever, daemon=True).start()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def run(label, command, expected=None, environment=None, error=None):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        metrics_port = listener.getsockname()[1]
    command = [binary, *command, "--quick-service", f"http://127.0.0.1:{api.server_port}",
               "--metrics", f"127.0.0.1:{metrics_port}", "--edge", "127.0.0.1:1",
               "--no-prechecks", "--grace-period", "0s"]
    with tempfile.TemporaryFile() as logs:
        child = subprocess.Popen(command, env=clean_env | (environment or {}), stdout=logs, stderr=logs)
        actual = None
        try:
            for _ in range(50):
                try:
                    with opener.open(f"http://127.0.0.1:{metrics_port}/config", timeout=0.1) as response:
                        actual = json.load(response)["config"]["ingress"][0]["service"]
                    break
                except (OSError, ValueError, KeyError):
                    if child.poll() is not None:
                        break
                    time.sleep(0.05)
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        logs.seek(0)
        text = logs.read().decode(errors="replace")
    if error:
        assert error in text and actual is None, f"{label}: expected {error!r}, got {actual!r}"
    else:
        assert actual == expected, f"{label}: expected {expected!r}, got {actual!r}; {text[-1000:]}"
    print(f"ok {label}")
    return text

unisolated = [part for index, part in enumerate(args) if index not in (1, 2)]
config.write_text("ingress: [\n")
run("malformed default config fails without isolation", unisolated, error="error parsing YAML")
text = run("empty explicit config bypasses malformed default", args, "http://localhost:39417")
assert "Configuration file /dev/null was empty" in text
config.write_text("ingress:\n  - service: http://localhost:39418\n")
run("default ingress overrides CLI origin without isolation", unisolated, "http://localhost:39418")
run("explicit empty config preserves approved origin", args, "http://localhost:39417")
run("explicit URL overrides TUNNEL_URL", args, "http://localhost:39417",
    {"TUNNEL_URL": "http://localhost:39418"})
run("hello-world environment changes the origin without launch filtering", args, "hello_world",
    {"TUNNEL_HELLO_WORLD": "true"})
run("bastion environment changes the origin without launch filtering", args, "bastion",
    {"TUNNEL_BASTION": "true"})
run("name environment switches away from quick mode without filtering", args,
    environment={"TUNNEL_NAME": "offline-probe"}, error="cert.pem")
with (scratch / "launch.json").open() as source:
    captured = json.load(source)
run("real launch arguments and environment preserve the approved origin",
    captured["command"][1:], "http://localhost:39417", captured["environment"])
run("unix socket env does not replace explicit HTTP URL", args, "http://localhost:39417",
    {"TUNNEL_UNIX_SOCKET": "/tmp/portal-unused.sock"})
run("hostname env does not replace explicit HTTP URL", args, "http://localhost:39417",
    {"TUNNEL_HOSTNAME": "other.example.com"})
api.shutdown()
print(subprocess.check_output([binary, "--version"], text=True).strip())
PY
