#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

source = (Path(sys.argv[1]) / 'test/e2e-live.sh').read_text()
functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n[\s\S]*?^\}', source, re.M)[0]
                      for name in ['process_start', 'record_pid'])
with tempfile.TemporaryDirectory(prefix='portal-farm-ownership-') as directory:
    ledger = Path(directory) / 'pids'
    run = os.urandom(16).hex()
    environment = dict(os.environ, PORTAL_E2E_RUN=run, PIDS=str(ledger))
    child = subprocess.Popen([sys.executable, '-c', 'import sys; sys.stdin.read()'],
                             stdin=subprocess.PIPE, env=environment)
    try:
        command = functions + '\nrecord_pid "$1"\n'
        unrelated = subprocess.run(['bash', '-c', command, 'proof', str(os.getpid())],
                                   env=environment, timeout=5)
        assert unrelated.returncode != 0 and not ledger.exists()
        owned = subprocess.run(['bash', '-c', command, 'proof', str(child.pid)],
                               env=environment, timeout=5)
        assert owned.returncode == 0
        assert ledger.read_text().split()[0] == str(child.pid)
        print('ok unrelated live process cannot enter teardown ledger; marked fixture can')
    finally:
        child.stdin.close()
        child.wait(timeout=5)
PY
