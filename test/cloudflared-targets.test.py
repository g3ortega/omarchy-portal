#!/usr/bin/python3
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    (['--url', 'http://localhost:3000'], '3000'),
    (['--url', 'http://192.0.2.10:3000'], None),
    (['--url=https://127.0.0.1:03000/'], '3000'),
    (['--url', 'http://[::1]:3000'], '3000'),
    (['--url', 'http://example.com:3000'], None),
    (['--url', 'http://localhost.example.com:3000'], None),
    (['--url', 'http://localhost:3000', '--url', 'http://192.0.2.10:3000'], None),
    (['--url', 'http://localhost:3000', '--url=http://localhost:3000'], None),
    (['--url', 'http://localhost:65536'], None),
    (['--url', 'http://user@localhost:3000'], None),
    (['--url', 'http://localhost:3000/api:4000'], '3000'),
    (['--url', 'http://localhost'], '80'),
    (['--url=https://localhost/path'], '443'),
    (['--', '--url', 'http://localhost:3000'], None),
    (['--note', '--url http://localhost:3000'], None),
    (['--url'], None),
]

with tempfile.TemporaryDirectory(prefix='portal-cf-targets-') as directory:
    env = dict(os.environ, CASE_ROOT=directory)
    for argv, expected in CASES:
        child = subprocess.Popen(['/usr/bin/python3', '-c', 'import time; time.sleep(30)', *argv])
        try:
            script = r'''
source scripts/tunnels.sh
cloudflared_targets "$1"
pgrep() { printf '%s\n' "$FIXTURE_PID"; }
proc() {
  if [[ $1 == signal ]]; then printf '%s\n' "$*" >> "$CASE_ROOT/signals"; return 0; fi
  return 1
}
kill() { printf 'forbidden\n' >> "$CASE_ROOT/signals"; return 1; }
cloudflared_stop_adopted 3000
'''
            result = subprocess.run(['/usr/bin/bash', '-c', script, 'probe', str(child.pid)], cwd=ROOT,
                                    env=dict(env, FIXTURE_PID=str(child.pid)), capture_output=True, text=True, check=True)
            rows = result.stdout.splitlines()
            signal_file = Path(directory, 'signals')
            if expected is None:
                assert not rows, (argv, rows)
                assert not signal_file.exists(), (argv, signal_file.read_text())
            else:
                assert len(rows) == 1 and rows[0].split('\t')[2] == expected, (argv, rows)
                if expected == '3000':
                    assert signal_file.read_text().startswith(f'signal {child.pid} ')
                    signal_file.unlink()
                else:
                    assert not signal_file.exists()
        finally:
            child.terminate()
            child.wait(timeout=5)
print('PASS Cloudflare adoption and stopping accept only unambiguous loopback origins from actual argv')
