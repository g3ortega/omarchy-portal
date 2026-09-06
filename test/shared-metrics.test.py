import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def scan(port):
    result = subprocess.run(['bash', str(ROOT / 'scripts/scan-ports.sh')], capture_output=True, text=True, timeout=15, check=True)
    return next(row for row in json.loads(result.stdout)['ports'] if row['port'] == port)


with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    port = listener.getsockname()[1]
    single = scan(port)
    assert single['exclusiveOwner'] and single['cpuTicks'] is not None and single['rssKb'] > 0
    child = subprocess.Popen([sys.executable, '-I', '-S', '-c', 'import sys; print("ready", flush=True); sys.stdin.read()'],
                             pass_fds=(listener.fileno(),), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        assert child.stdout.readline().strip() == 'ready'
        shared = scan(port)
        assert not shared['exclusiveOwner'], shared
        assert shared['cpuTicks'] is None and shared['rssKb'] is None, shared
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, 'PORTAL_METRICS_DIR': directory}
            sample = {'t': int(time.time()), 'conns': shared['conns'], 'cpuPct': None, 'rssKb': shared['rssKb']}
            result = subprocess.run(['bash', str(ROOT / 'scripts/metrics.sh'), 'append-batch', json.dumps({str(port): sample})],
                                    env=env, capture_output=True, text=True, timeout=15, check=True)
            assert json.loads(result.stdout)['ok'], result.stdout
            with sqlite3.connect(Path(directory) / 'metrics/store/metrics.db') as db:
                assert db.execute('SELECT cpuPct,rssKb FROM samples WHERE port=?', (port,)).fetchone() == (None, None)
    finally:
        child.stdin.close()
        child.wait(timeout=5)
        child.stdout.close()
    recovered = scan(port)
    assert recovered['exclusiveOwner'] and recovered['cpuTicks'] is not None and recovered['rssKb'] > 0
print('ok shared listener usage is unavailable, stays null in storage, and returns after exclusive ownership')
