#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/test/lifecycle-owner.test.sh" >/dev/null
/usr/bin/python3 -I -S - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temporary:
    server = subprocess.Popen(['/usr/bin/python3', '-I', '-S', '-c',
        'import signal,socket,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
        's=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); '
        'print(s.getsockname()[1],flush=True); time.sleep(300)'], stdout=subprocess.PIPE, text=True)
    pid = server.pid
    start = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
    handle = os.pidfd_open(pid)
    try:
        port = int(server.stdout.readline())
        result = subprocess.run(['/usr/bin/bash', str(root/'scripts/lifecycle.sh'), 'restart',
            str(pid), start, str(port), temporary, '["/usr/bin/false"]'],
            env=dict(os.environ, PORTAL_STATE_DIR=temporary+'/state'), capture_output=True, text=True, timeout=15)
        output = json.loads(result.stdout)
        assert server.poll() is None
        with socket.create_connection(('127.0.0.1',port), timeout=1):
            pass
        print(json.dumps(output))
        assert output['ok'] is False and output['effect'] == 'none'
    finally:
        if server.poll() is None:
            assert Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19] == start
            signal.pidfd_send_signal(handle, signal.SIGKILL)
        os.close(handle)
        server.wait(timeout=5)
PY
