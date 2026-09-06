#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT="$ROOT" bash -c '
  source "$ROOT/scripts/tunnels.sh"
  proc() { printf "unexpected proc %s\n" "$*"; return 1; }
  kill() { printf "unexpected kill %s\n" "$*"; return 1; }
  alive_line() { return 0; }
  group_alive() { return 0; }
  STOP_TERM_WAIT=0; STOP_KILL_WAIT=0
  for line in "1 1" "0 0" "-1 1" "" "999999999999999999999 1" "2 nope"; do
    output=$(stop_line "$line" cloudflared) && exit 1
    if grep -Eq -- "(^| )-(0|1)( |$)" <<<"$output"; then exit 1; fi
  done
'

for cancel_signal in SIGTERM SIGINT SIGHUP; do
/usr/bin/python3 -I -S - "$ROOT" "$cancel_signal" <<'PYTHON'
import ctypes
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(sys.argv[1])
cancel_signal = getattr(signal, sys.argv[2])
# Reap the detached provider so cleanup can verify its process group vanished.
assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0

def identity(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
    except FileNotFoundError:
        return None

with tempfile.TemporaryDirectory() as directory:
    tmp = Path(directory)
    provider = tmp / 'cloudflared'
    shutil.copyfile('/usr/bin/python3', provider)
    provider.chmod(0o700)
    action = tmp / 'action.sh'
    action.write_text('''source "$SOURCE/scripts/tunnels.sh"
lifecycle_mutation nowait /usr/bin/bash "$ACTION"
provider_bin() { printf '%s' "$PROVIDER"; }
cloudflared_argv() { printf '%s\\n' -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)'; }
cloudflared_url_from_log() { : > "$POLLING"; return 1; }
listener_identity() { printf '999999 1'; }
target_owns_port() { return 0; }
cmd_start cloudflared 4488
''')
    env = dict(os.environ, SOURCE=str(ROOT), ACTION=str(action), PROVIDER=str(provider),
               POLLING=str(tmp / 'polling'), PORTAL_STATE_DIR=str(tmp / 'state'))
    wrapper = subprocess.Popen(['/usr/bin/python3', '-I', '-S', str(ROOT / 'scripts/lib/proc.py'),
                                'run', '1000', '60', '--', '/usr/bin/bash', str(action)],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    wrapper_start = identity(wrapper.pid)
    pid = start = None
    try:
        limit = time.monotonic() + 10
        while not (tmp / 'polling').exists():
            if time.monotonic() > limit:
                raise RuntimeError('start did not reach URL polling')
            time.sleep(.02)
        pid_text, start = (tmp / 'state/cloudflared-4488.pid').read_text().split()
        pid = int(pid_text)
        def reap():
            os.waitpid(pid, 0)
        reaper = threading.Thread(target=reap, daemon=True)
        reaper.start()
        handle = os.pidfd_open(wrapper.pid)
        assert identity(wrapper.pid) == wrapper_start
        signal.pidfd_send_signal(handle, cancel_signal)
        os.close(handle)
        before = time.monotonic()
        out, err = wrapper.communicate(timeout=20)
        alive = identity(pid) == start
        leaves = sorted(p.name for p in (tmp / 'state').glob('cloudflared-*'))
        print(f'{cancel_signal.name} rc={wrapper.returncode} provider_alive={alive} leaves={leaves} elapsed={time.monotonic()-before:.2f}')
        assert wrapper.returncode == 128 + cancel_signal and not alive and not leaves, err.decode()
    finally:
        for target, expected in ((pid, start), (wrapper.pid, wrapper_start)):
            if target and identity(target) == expected:
                handle = os.pidfd_open(target)
                if identity(target) == expected:
                    signal.pidfd_send_signal(handle, signal.SIGKILL)
                os.close(handle)
        wrapper.wait()
        if pid:
            reaper.join(timeout=2)
        while True:
            try:
                if os.waitpid(-1, os.WNOHANG)[0] == 0:
                    break
            except ChildProcessError:
                break
PYTHON
done
