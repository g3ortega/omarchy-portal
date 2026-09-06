#!/usr/bin/env python3
import collections
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NOW = int(time.time())
SAMPLE_COLUMNS = 'id,port,t,latMs,conns,cpuPct,rssKb,httpCode,tcpRttMs,tcpRttCount'


def call(home, *args):
    result = subprocess.run(['bash', str(ROOT/'scripts/metrics.sh'), *map(str, args)],
                            env={**os.environ, 'PORTAL_METRICS_DIR': str(home)},
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def cleanup(home, dry=False):
    return subprocess.run(['/usr/bin/python3', '-I', '-S', str(ROOT/'scripts/lib/statedir.py'),
                           'metrics', str(home/'metrics'), 'remove-store', *(['--dry-run'] if dry else [])],
                          capture_output=True, text=True, timeout=20)


def populated_store(home):
    assert call(home, 'stats')['ok']
    db = home/'metrics/store/metrics.db'
    with sqlite3.connect(db) as connection:
        rows = [(7, 3307, NOW-200000, 21, 2, 3, 4, 200),
                (13, 3307, NOW-100, 0, None, 0, 0, None),
                (19, 3307, NOW-100, 0, None, 0, 0, None)]
        connection.executemany('INSERT INTO samples(id,port,t,latMs,conns,cpuPct,rssKb,httpCode) VALUES(?,?,?,?,?,?,?,?)', rows)
        connection.execute("INSERT INTO batches VALUES('session-1',?)", (NOW,))
    db.chmod(0o600)
    return db


def snapshot(db):
    with sqlite3.connect(db) as connection:
        return (collections.Counter(connection.execute('SELECT '+SAMPLE_COLUMNS+' FROM samples')),
                list(connection.execute('SELECT * FROM batches')))


with tempfile.TemporaryDirectory(prefix='portal-metrics-transport-') as temporary:
    home = Path(temporary)/'state'
    db = populated_store(home)
    before = snapshot(db)
    original_bytes = db.read_bytes()
    assert cleanup(home, dry=True).returncode == 0
    assert db.read_bytes() == original_bytes, 'dry cleanup must leave storage unchanged'
    assert call(home, 'stats')['ok'] and snapshot(db) == before
    assert call(home, 'query', 3307, 1800, NOW)['ok'] and snapshot(db) == before
    print('ok reads preserve IDs, every sample value, duplicate and expired rows, and retry records')

    samples = [dict(t=NOW-40, latMs=12), dict(t=NOW-30, tcpRttMs=0, tcpRttCount=2),
               dict(t=NOW-20, latMs=20, tcpRttMs=4, tcpRttCount=1), dict(t=NOW-10),
               dict(t=NOW-10, latMs=0, tcpRttMs=8, tcpRttCount=3)]
    for i, sample in enumerate(samples):
        batch = json.dumps({'3307': sample})
        assert call(home, 'append-batch', batch, 'transport-'+str(i))['ok']
        assert call(home, 'append-batch', batch, 'transport-'+str(i))['ok']
    result = call(home, 'query', 3307, 1800, NOW, 1)
    assert result['ok'], result
    bucket = result['view']['buckets'][0]
    assert bucket['tcpRttMs'] == {'lo': 0, 'hi': 8, 'avg': 4, 'count': 3}
    assert bucket['latMs'] == {'lo': 0, 'hi': 20, 'avg': 6.4, 'count': 5}
    assert 'tcpRttCount' not in bucket
    with sqlite3.connect(db) as connection:
        assert connection.execute('SELECT count(*) FROM samples').fetchone()[0] == 7
        assert list(connection.execute('SELECT tcpRttCount FROM samples WHERE tcpRttCount IS NOT NULL ORDER BY t,id')) == [(2,), (1,), (3,)]
    for value in [-1, True, '4']:
        assert not call(home, 'append-batch', json.dumps({'3307': dict(t=NOW,tcpRttMs=value)}))['ok']
        assert not call(home, 'append-batch', json.dumps({'3307': dict(t=NOW,tcpRttCount=value)}))['ok']
    print('ok mixed HTTP/TCP samples preserve nulls, true zero, duplicate timestamps and stable retry IDs')

    with sqlite3.connect(db) as connection:
        for i in range(400):
            for value in (1.2345678901234567e100, 9.876543210987654e100):
                connection.execute('INSERT INTO samples(port,t,latMs,conns,cpuPct,rssKb,tcpRttMs) VALUES(?,?,?,?,?,?,?)',
                                   (8080, NOW-3600+i*9, *([value]*5)))
    bounded = call(home, 'query', 8080, 3600, NOW, 400)
    assert bounded['ok'], bounded
    assert len(bounded['view']['buckets']) == 400
    assert all(len([key for key in bucket if isinstance(bucket[key],dict)]) == 5 for bucket in bounded['view']['buckets'])
    print('ok 400 buckets carry all five metrics; final response bytes', len(json.dumps(bounded,separators=(',',':')).encode()))
    assert cleanup(home, dry=True).returncode == 0
    assert cleanup(home).returncode == 0 and not db.exists()

    for version in (1, 3):
        isolated = Path(temporary)/('version-'+str(version))
        db = populated_store(isolated)
        with sqlite3.connect(db) as connection:
            connection.execute(f'PRAGMA user_version={version}')
        before_bytes = db.read_bytes()
        assert not call(isolated, 'stats')['ok']
        assert cleanup(isolated).returncode == 1
        assert db.read_bytes() == before_bytes
    print('ok unsupported schema versions are refused unchanged')

    fresh = Path(temporary)/'fresh'
    assert call(fresh, 'stats')['ok']
    with sqlite3.connect(fresh/'metrics/store/metrics.db') as connection:
        assert connection.execute('PRAGMA user_version').fetchone()[0] == 2
        assert {'tcpRttMs', 'tcpRttCount'} <= {row[1] for row in connection.execute('PRAGMA table_info(samples)')}
        assert {row[0] for row in connection.execute("SELECT name FROM sqlite_schema WHERE type='table'")} == {'samples', 'batches'}
    print('ok fresh stores start at version 2')

with tempfile.TemporaryDirectory(prefix='portal-metrics-output-') as temporary:
    state = runpy.run_path(str(ROOT/'scripts/lib/statedir.py'))
    metrics = runpy.run_path(str(ROOT/'scripts/lib/metrics.py'))
    store = state['open_dir'](temporary)
    executable = state['open_exe']('/usr/bin/sqlite3')
    try:
        size = 512 * 1024
        keys = ['bin', 'count'] + [field + suffix for field in metrics['FIELDS'] for suffix in ('Lo', 'Hi', 'Avg', 'Count')]
        number = '1.' + '2' * 33 + 'e+100'
        assert len(number) == 40
        row = '{' + ','.join(json.dumps(key) + ':' + number for key in keys) + '}'
        projection = 'load_extension off\n[' + ',\n'.join([row] * 400) + ']\n'
        assert 256 * 1024 < len(projection) < size
        completed = subprocess.CompletedProcess([], 0, stdout=projection)
        with patch.object(subprocess, 'run', return_value=completed):
            result = metrics['sql'](store, executable, 'fixture projection')
        assert len(result) == 400 and all(len(row) == 22 for row in result)
        assert result[0]['tcpRttMsAvg'] == float(number)
        result = metrics['sql'](store, executable, f"SELECT printf('%.*c',{size - 64},'x') AS payload;")
        assert result == [{'payload': 'x' * (size - 64)}]
        try:
            metrics['sql'](store, executable, f"SELECT printf('%.*c',{size},'x') AS payload;")
        except ValueError as error:
            assert str(error) == 'metrics response exceeds limit'
        else:
            raise AssertionError('SQL output above 512 KiB must be refused')
    finally:
        os.close(executable)
        os.close(store)
    print('ok real SQLite output below 512 KiB is accepted and output above the cap is refused')
