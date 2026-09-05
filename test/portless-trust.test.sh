#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="portal-trust-") as temporary:
    root = Path(temporary)
    def run(*args):
        subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for name in ("home", "runtime", "state", "portless", "db", "missing"):
        (root / name).mkdir()
    for name in ("current", "stale"):
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(root / (name + ".key")), "-out", str(root / (name + ".pem")),
            "-subj", "/CN=Portless Local CA", "-days", "1")
    run("certutil", "-N", "-d", "sql:" + str(root / "db"), "--empty-password")
    env = dict(os.environ, FIXTURE=str(root), ROOT=sys.argv[1], HOME=str(root / "home"),
               PORTAL_STATE_DIR=str(root / "runtime"), PORTAL_METRICS_DIR=str(root / "state"),
               PORTLESS_STATE_DIR=str(root / "portless"))
    subprocess.run(["bash", "-eo", "pipefail"], env=env, check=True, input=r'''
set -- noop
source "$ROOT/scripts/portless-setup.sh" >/dev/null || true
CA_PEM=$(cat "$FIXTURE/current.pem")
NSSDB="$FIXTURE/db"
NICK='Portless Local CA'
firefox_profiles() { printf '%s\n' "$NSSDB"; }
fp=$(ca_fingerprint <<<"$CA_PEM")

certutil -A -d "sql:$NSSDB" -n "$NICK" -t ',,' -i "$FIXTURE/current.pem"
if nss_trusted; then echo 'FAIL current certificate without SSL CA trust accepted'; exit 1; fi
[[ $(firefox_untrusted) == "$NSSDB" ]]
if trust_store "$NSSDB"; then echo 'FAIL pre-existing trust flags overwritten'; exit 1; fi
[[ ! -e $TRUSTED ]]
echo 'ok current certificate without SSL CA trust is unmet'

certutil -M -d "sql:$NSSDB" -n "$NICK" -t 'C,,'
nss_trusted
[[ -z $(firefox_untrusted) ]]
trust_store "$NSSDB"
[[ ! -e $TRUSTED ]]
echo 'ok current SSL CA trust recognized without claiming existing ownership'

certutil -D -d "sql:$NSSDB" -n "$NICK"
certutil -A -d "sql:$NSSDB" -n "$NICK" -t 'C,,' -i "$FIXTURE/stale.pem"
certutil -L -d "sql:$NSSDB" | grep -q "$NICK"
if nss_trusted; then echo 'FAIL stale same-nickname certificate accepted'; exit 1; fi
[[ $(firefox_untrusted) == "$NSSDB" ]]
if trust_store "$NSSDB"; then echo 'FAIL stale certificate overwritten'; exit 1; fi
[[ $(store_cert_state "$NSSDB" "$fp") == different && ! -e $TRUSTED ]]
echo 'ok stale nickname is unmet and preserved without ownership record'

certutil -D -d "sql:$NSSDB" -n "$NICK"
[[ $(store_cert_state "$NSSDB" "$fp") == absent ]]
trust_store "$NSSDB"
nss_trusted
[[ -s $TRUSTED ]]
echo 'ok absent current CA imported and ownership recorded'

NSSDB="$FIXTURE/missing"
if nss_trusted; then echo 'FAIL unreadable store accepted'; exit 1; fi
[[ $(firefox_untrusted) == "$NSSDB" ]]
if trust_store "$NSSDB"; then echo 'FAIL unreadable store mutated'; exit 1; fi
[[ $(store_cert_state "$NSSDB" "$fp") == unreadable ]]
echo 'ok unreadable database remains unmet'
''', text=True)
PY
