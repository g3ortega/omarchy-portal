"""Raw metric retention and bounded chart queries through statedir."""
import json
import math
import os
import re
import stat
import subprocess
import sys
import time

FIELDS = ('latMs', 'conns', 'cpuPct', 'rssKb', 'tcpRttMs')
RETENTION = 172800
APPLICATION_ID = 1347701809
MAX_SQL_OUTPUT = 512 * 1024
SCHEMA = '''CREATE TABLE IF NOT EXISTS samples(id INTEGER PRIMARY KEY,port INTEGER NOT NULL,t INTEGER NOT NULL,latMs REAL,conns REAL,cpuPct REAL,rssKb REAL,httpCode REAL,tcpRttMs REAL,tcpRttCount REAL);
CREATE INDEX IF NOT EXISTS samples_port_t ON samples(port,t);
CREATE INDEX IF NOT EXISTS samples_t ON samples(t);
CREATE TABLE IF NOT EXISTS batches(id TEXT PRIMARY KEY,t INTEGER NOT NULL);
'''


def integer(value, low, high):
    text = str(value)
    if not re.fullmatch(r'[0-9]{1,16}', text) or not low <= int(text) <= high:
        raise ValueError('invalid numeric argument')
    return int(text)


def sample_sql(port, sample, condition='1'):
    if not isinstance(sample, dict):
        raise ValueError('invalid metric sample')
    values = [str(port), str(integer(sample.get('t'), 0, 253402300799))]
    for field in (*FIELDS, 'httpCode', 'tcpRttCount'):
        value = sample.get(field)
        if value is None:
            values.append('NULL')
        elif isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError('invalid metric value')
        else:
            values.append(str(value))
    return 'INSERT INTO samples(port,t,latMs,conns,cpuPct,rssKb,tcpRttMs,httpCode,tcpRttCount) SELECT ' + ','.join(values) + ' WHERE ' + condition + ';'


def sql(store, executable, statement, readonly=False):
    script = '.bail on\n.open --nofollow ' + ('--readonly ' if readonly else '') + 'metrics.db\n.timeout 0\n.dbconfig load_extension off\nPRAGMA trusted_schema=OFF;\nPRAGMA temp_store=MEMORY;\nPRAGMA synchronous=FULL;\n' + statement
    result = subprocess.run(['/usr/bin/sqlite3', '-batch', '-bail', '-json'],
                            executable=f'/proc/self/fd/{executable}',
                            cwd=f'/proc/self/fd/{store}', pass_fds=(store, executable),
                            input=script, text=True, capture_output=True, timeout=15,
                            env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent'})
    if result.returncode:
        raise ValueError('SQLite operation failed')
    if len(result.stdout) > MAX_SQL_OUTPUT:
        raise ValueError('metrics response exceeds limit')
    lines = result.stdout.splitlines()
    if not lines or lines.pop(0).strip() != 'load_extension off':
        raise ValueError('SQLite extension guard failed')
    output = '\n'.join(lines)
    return json.loads(output) if output.strip() else []


def run(args, state):
    held = None
    previous_umask = os.umask(0o077)
    try:
        if len(args) > 1 and args[1] != 'remove-store':
            held = state.acquire_lock(os.path.dirname(os.path.abspath(args[0])), 'nowait', '.metrics.lock')
            if held is None:
                raise ValueError('another watched-port update is in progress')
        execute(args, state)
    except (ValueError, TypeError, IndexError, OverflowError, OSError, subprocess.SubprocessError, state.Refused) as error:
        print(json.dumps({'ok': False, 'error': 'metrics storage refused: ' + str(error)}))
        return 1 if len(args) > 1 and args[1] == 'remove-store' else 0
    finally:
        os.umask(previous_umask)
        if held is not None:
            dirfd, lockfd, created = held
            os.close(lockfd)
            os.close(dirfd)
            state.close_creation_ledger(created)
    return 0


def validate_store(store, state):
    if stat.S_IMODE(os.fstat(store).st_mode) != 0o700:
        raise ValueError('metrics store must have mode 0700')
    names = os.listdir(store)
    for name in names:
        if name not in ('metrics.db', 'metrics.db-journal', 'metrics.db-wal', 'metrics.db-shm'):
            raise ValueError('unexpected metrics store entry')
        fd = state.open_leaf(store, name, os.O_RDONLY, 1 << 30)
        try:
            if fd is None or stat.S_IMODE(os.fstat(fd).st_mode) != 0o600:
                raise ValueError('metrics database files must have mode 0600')
        finally:
            if fd is not None:
                os.close(fd)
    return names


def remove_store(directory, params, state):
    if params not in ([], ['--dry-run']):
        raise ValueError('invalid store cleanup arguments')
    parent = store = executable = None
    try:
        try:
            parent = state.open_dir(directory)
            store = state.open_dir(os.path.join(directory, 'store'))
        except state.MissingDirectory:
            print('{"ok":true,"files":[]}')
            return
        names = validate_store(store, state)
        if names:
            if 'metrics.db' not in names:
                raise ValueError('metrics sidecars have no owned database')
            executable = state.open_exe('/usr/bin/sqlite3')
            identity = sql(store, executable, 'SELECT (SELECT application_id FROM pragma_application_id) AS id, (SELECT user_version FROM pragma_user_version) AS version;', readonly=True)[0]
            if identity['id'] != APPLICATION_ID or identity['version'] != 2:
                raise ValueError('not a supported Portal metrics database')
        if not params:
            for name in names:
                os.unlink(name, dir_fd=store)
            current = os.stat('store', dir_fd=parent, follow_symlinks=False)
            if state.directory_identity(store) != (current.st_dev, current.st_ino):
                raise ValueError('metrics store changed during cleanup')
            os.rmdir('store', dir_fd=parent)
            os.fsync(parent)
        print(json.dumps({'ok': True, 'files': names}))
    finally:
        for fd in (executable, store, parent):
            if fd is not None:
                os.close(fd)


def execute(args, state):
    directory, action, *params = args
    if action == 'remove-store':
        return remove_store(directory, params, state)
    if action not in ('append', 'query', 'stats'):
        raise ValueError('invalid metrics action')
    parent = state.open_dir(directory, create=True)
    store = executable = None
    try:
        store = state.open_dir(os.path.join(directory, 'store'), create=True)
        validate_store(store, state)
        executable = state.open_exe('/usr/bin/sqlite3')

        metadata = sql(store, executable, 'SELECT (SELECT application_id FROM pragma_application_id) AS application_id, (SELECT user_version FROM pragma_user_version) AS version, (SELECT journal_mode FROM pragma_journal_mode) AS journal_mode, (SELECT count(*) FROM sqlite_schema) AS tables;')[0]
        if metadata['journal_mode'] != 'delete':
            raise ValueError('metrics database requires DELETE journaling')
        if metadata['application_id'] == 0 and metadata['version'] == 0 and metadata['tables'] == 0:
            sql(store, executable, 'BEGIN IMMEDIATE;\n' + SCHEMA + f'PRAGMA application_id={APPLICATION_ID}; PRAGMA user_version=2; COMMIT;')
        elif metadata['application_id'] != APPLICATION_ID or metadata['version'] != 2:
            raise ValueError('not a supported Portal metrics database')
        if action == 'append':
            raw = sys.stdin.buffer.read(1048577)
            if len(raw) > 1048576:
                raise ValueError('metric batch exceeds limit')
            batch = json.loads(raw)
            if not isinstance(batch, dict) or len(batch) > 512:
                raise ValueError('invalid metric batch')
            batch_id = params[0] if params else ''
            if batch_id and not re.fullmatch(r'[a-zA-Z0-9_-]{1,128}', batch_id):
                raise ValueError('invalid batch identity')
            condition = f"NOT EXISTS(SELECT 1 FROM batches WHERE id='{batch_id}')" if batch_id else '1'
            statements = [sample_sql(integer(port, 1, 65535), sample, condition) for port, sample in batch.items()]
        elif action == 'query':
            port = integer(params[0], 1, 65535)
            seconds = integer(params[1], 1, RETENTION)
            if seconds not in (1800, 3600, 10800, 21600, 86400, RETENTION):
                raise ValueError('invalid time range')
            end = integer(params[2], 0, 253402300799)
            maximum = integer(params[3] if len(params) > 3 else 400, 1, 400)
        if action == 'append':
            now = int(time.time())
            cutoff = now - RETENTION
            ledger = f"INSERT OR IGNORE INTO batches VALUES('{batch_id}',{now});" if batch_id else ''
            sql(store, executable, 'BEGIN IMMEDIATE;\n' + '\n'.join(statements) + ledger + f'\nDELETE FROM samples WHERE t < {cutoff};\nDELETE FROM batches WHERE t < {cutoff};\nCOMMIT;')
            result = {'ok': True}
        elif action == 'stats':
            result = {'ok': True, 'storage': sql(store, executable, 'SELECT count(*) AS count,min(t) AS first,max(t) AS last FROM samples;')[0]}
        else:
            start = end - seconds
            width = seconds / maximum
            where = f'port={port} AND t>={start} AND t<={end}'
            summary = sql(store, executable, f'SELECT count(*) AS count,min(t) AS first,max(t) AS last,' + ','.join(f'min({f}) AS {f}Lo,max({f}) AS {f}Hi' for f in FIELDS) + f' FROM samples WHERE {where};')[0]
            rows = sql(store, executable, f'SELECT min(CAST((t-({start}))/{width} AS INTEGER),{maximum - 1}) AS bin,count(*) AS count,' + ','.join(f'min({f}) AS {f}Lo,max({f}) AS {f}Hi,avg({f}) AS {f}Avg,count({f}) AS {f}Count' for f in FIELDS) + f' FROM samples WHERE {where} GROUP BY bin ORDER BY bin;')
            buckets = []
            for row in rows:
                bucket = {'t': start + row['bin'] * width, 'end': min(end, start + (row['bin'] + 1) * width), 'count': row['count']}
                for field in FIELDS:
                    bucket[field] = {key: row[field + suffix] for key, suffix in [('lo', 'Lo'), ('hi', 'Hi'), ('avg', 'Avg'), ('count', 'Count')]}
                buckets.append(bucket)
            result = {'ok': True, 'view': {'start': start, 'end': end, 'bucketSeconds': width, 'count': summary['count'], 'first': summary['first'], 'last': summary['last'], 'buckets': buckets, 'stats': {f: {'lo': summary[f + 'Lo'], 'hi': summary[f + 'Hi']} for f in FIELDS}}}
        print(json.dumps(result, separators=(',', ':'), allow_nan=False))
    finally:
        for fd in (executable, store, parent):
            if fd is not None:
                os.close(fd)
