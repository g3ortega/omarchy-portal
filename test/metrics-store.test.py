#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
NOW = int(time.time())


def call(home, *args):
    result = subprocess.run(['bash', str(ROOT / 'scripts/metrics.sh'), *map(str, args)], env={**os.environ, 'PORTAL_METRICS_DIR': str(home)}, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert not result.stderr, result.stderr
    return json.loads(result.stdout)


with tempfile.TemporaryDirectory(prefix='portal-metrics-store-') as temporary:
    home = Path(temporary) / 'state'
    legacy = home / 'metrics' / '3307.jsonl'
    legacy.parent.mkdir(parents=True)
    rows = [{'t': NOW-3600, 'rssKb': 10}, {'t': NOW, 'rssKb': 90}, {'t': NOW, 'rssKb': None}, {'t': NOW-172801, 'rssKb': 1}]
    original = ('\n'.join(map(json.dumps, rows)) + '\n{torn\n').encode()
    legacy.write_bytes(original)
    result = call(home, 'query', 3307, 3600, NOW)
    assert result['ok'] and result['view']['count'] == 3 and result['warning'], result
    assert result['view']['stats']['rssKb'] == {'lo': 10, 'hi': 90}
    assert result['view']['buckets'][-1]['rssKb']['count'] == 1
    assert call(home, 'query', 3307, 3600, NOW)['view'] == result['view']
    batch = json.dumps({'3307': {'t': NOW, 'rssKb': 100}})
    assert call(home, 'append-batch', batch, 'session_1')['ok']
    assert call(home, 'append-batch', batch, 'session_1')['ok']
    assert call(home, 'query', 3307, 172800, NOW)['view']['count'] == 4
    assert call(home, 'stats')['storage']['count'] == 4
    assert call(home, 'unwatch', 3307)['ok'] and legacy.read_bytes() == original
    assert call(home, 'query', 3307, 172800, NOW)['view']['count'] == 4
    assert not call(home, 'query', 3307, 604800, NOW)['ok']
    assert not call(home, 'append-batch', '{"3307":{"t":1,"rssKb":-1}}')['ok']
    print('ok migration preserves duplicates/originals/torn lines; retries, retention, unwatch and null extrema')
    for name in ('metrics.db', 'metrics.db-journal', 'metrics.db-wal', 'metrics.db-shm'):
        for kind in ('symlink', 'fifo', 'hardlink', 'directory', 'mode'):
            isolated = Path(temporary) / (name + '-' + kind)
            store = isolated / 'metrics' / 'store'
            store.mkdir(parents=True, mode=0o700)
            target = store / name
            sentinel = isolated / 'secret'
            sentinel.write_text('PRIVATE_SENTINEL')
            if kind == 'symlink': target.symlink_to(sentinel)
            elif kind == 'fifo': os.mkfifo(target)
            elif kind == 'hardlink': os.link(sentinel, target)
            elif kind == 'directory': target.mkdir()
            else: target.write_bytes(b''); target.chmod(0o644)
            result = call(isolated, 'query', 3307, 3600, NOW)
            assert result['ok'] is False and 'PRIVATE_SENTINEL' not in json.dumps(result), (name, kind, result)
            assert sentinel.read_text() == 'PRIVATE_SENTINEL'
    print('ok database and all sidecars reject symlinks, FIFOs, hardlinks, directories and unsafe modes')

with tempfile.TemporaryDirectory(prefix='portal-metrics-identity-') as temporary:
    home = Path(temporary) / 'state'
    store = home / 'metrics' / 'store'
    store.mkdir(parents=True, mode=0o700)
    db = store / 'metrics.db'
    subprocess.run(['/usr/bin/sqlite3', str(db), 'CREATE TABLE unrelated(value); INSERT INTO unrelated VALUES(7);'], check=True)
    db.chmod(0o600)
    before = db.read_bytes()
    assert not call(home, 'query', 3307, 1800, NOW)['ok']
    assert db.read_bytes() == before
    cleanup = ['/usr/bin/python3', '-I', '-S', str(ROOT / 'scripts/lib/statedir.py'), 'metrics', str(home / 'metrics'), 'remove-store']
    assert subprocess.run(cleanup, capture_output=True).returncode == 1
    assert db.read_bytes() == before
    db.unlink()
    assert call(home, 'query', 3307, 1800, NOW)['ok']
    subprocess.run(cleanup + ['--dry-run'], check=True, capture_output=True)
    assert db.exists()
    subprocess.run(cleanup, check=True, capture_output=True)
    assert not store.exists()
    subprocess.run(cleanup, check=True, capture_output=True)
    assert not store.exists()
    print('ok unrelated databases remain untouched; cleanup validates ownership, supports dry run and stays absent')

with tempfile.TemporaryDirectory(prefix='portal-metrics-lock-') as temporary:
    import fcntl
    home = Path(temporary) / 'state'
    home.mkdir(mode=0o700)
    with (home / '.metrics.lock').open('w') as locked:
        fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for args in [('query', 3307, 1800, NOW), ('stats',), ('append-batch', json.dumps({'3307': {'t': NOW}})), ('watch', 3307), ('unwatch', 3307)]:
            assert call(home, *args)['ok'] is False, args
        assert not (home / 'metrics').exists()
    code = '''import runpy,sys
state=runpy.run_path(sys.argv[1])
from types import SimpleNamespace
state=SimpleNamespace(**state)
metrics=runpy.run_path(sys.argv[2])
def held(args, state):
    print("held",flush=True)
    sys.stdin.readline()
metrics["run"].__globals__["execute"]=held
metrics["run"]([sys.argv[3],"stats"],state)
'''
    holder = subprocess.Popen(['/usr/bin/python3', '-I', '-S', '-c', code, str(ROOT / 'scripts/lib/statedir.py'), str(ROOT / 'scripts/lib/metrics.py'), str(home / 'metrics')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert holder.stdout.readline().strip() == 'held'
        for args in [('query', 3307, 1800, NOW), ('append-batch', json.dumps({'3307': {'t': NOW}})), ('watch', 3307), ('unwatch', 3307)]:
            assert call(home, *args)['ok'] is False, args
    finally:
        output, error = holder.communicate('\n', timeout=5)
        assert holder.returncode == 0, error
    assert call(home, 'query', 3307, 1800, NOW)['ok']
    assert call(home, 'watch', 3307)['ok']
    print('ok shell and Python readers/writers share the stable fail-fast lock and release it')
