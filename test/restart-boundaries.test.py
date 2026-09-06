import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
FAILURES = []


def identity(pid):
    assert pid > 1
    return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]


def check(name, condition, actual):
    if not condition:
        FAILURES.append((name, actual))
    print(('ok ' if condition else 'FAIL ') + name + ' ' + str(actual), flush=True)


with tempfile.TemporaryDirectory(prefix='portal-restart-boundaries-') as temporary:
    case = Path(temporary)
    app = case/'app'
    (app/'lib').mkdir(parents=True)
    (app/'lifecycle.sh').write_bytes((ROOT/'scripts/lifecycle.sh').read_bytes())
    (app/'lib/files.sh').write_text('''source "$REAL_FILES"
lifecycle_mutation() { :; }
kill() { printf '%s\\n' "$*" >> "$CASE/group-probes"; return 1; }
state() {
  if [[ $1 == launch-tracked ]]; then
    cat >/dev/null
    printf launched > "$CASE/launched"
    [[ $MODE == shutdown ]] && return 1
    own_dir "$PORTAL_RUNTIME_DIR" && write_own "$PORTAL_RUNTIME_DIR/.restart-35001.pid" '999999 1'
    return
  fi
  /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"
}
ss() {
  if [[ $MODE == shutdown ]]; then
    [[ ${QUERY_FAIL:-0} != 1 || ! -e $CASE/signaled ]] || return 1
    /usr/bin/ss "$@"; return
  fi
  if [[ -e $CASE/launched ]]; then
    [[ ${QUERY_FAIL:-0} != 1 || $1 != -tlnpH ]] || return 1
    printf '%s\\n' "$SOCKETS"; return
  fi
  if [[ ! -e $CASE/signaled ]]; then
    printf 'LISTEN 0 10 127.0.0.1:35001 0.0.0.0:* users:(("fixture",pid=%s,fd=4))\\n' "$TARGET_PID"
  fi
}
proc() {
  if [[ $2 == 999999 ]]; then return 1; fi
  /usr/bin/python3 -I -S "$PROC_PY" "$@"
  local rc=$?
  [[ $1 != signal ]] || touch "$CASE/signaled"
  return "$rc"
}
ps() {
  case ${@: -1} in 999999|999998) printf '999999\\n' ;; *) printf '999997\\n' ;; esac
}
''')
    base_env = {**os.environ, 'REAL_FILES': str(ROOT/'scripts/lib/files.sh'),
                'CASE': str(case), 'PORTAL_STATE_DIR': str(case/'state')}
    server_code = '''import signal,socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen()
def stop(signum, frame):
    s.close()
    if sys.argv[1] == "delay": time.sleep(0.4); sys.exit(0)
    if sys.argv[1] == "exit": sys.exit(0)
signal.signal(signal.SIGTERM,stop)
print(s.getsockname()[1],flush=True)
sys.stdin.read()
'''
    for behavior in ('stay', 'delay', 'query-fail'):
        (case/'launched').unlink(missing_ok=True)
        (case/'signaled').unlink(missing_ok=True)
        server = subprocess.Popen(['/usr/bin/python3', '-I', '-S', '-c', server_code, behavior],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        port = int(server.stdout.readline())
        start = identity(server.pid)
        waiter = threading.Thread(target=server.wait)
        waiter.start()
        try:
            began = time.monotonic()
            output = subprocess.run(['/usr/bin/bash', str(app/'lifecycle.sh'), 'restart',
                str(server.pid), start, str(port), str(case), '["/usr/bin/true"]'],
                env={**base_env, 'MODE': 'shutdown', 'QUERY_FAIL': str(int(behavior == 'query-fail'))}, capture_output=True, text=True, timeout=12)
            elapsed = time.monotonic()-began
            result = json.loads(output.stdout)
            if behavior == 'query-fail':
                check('shutdown socket-query failure aborts immediately',
                      not (case/'launched').exists() and result.get('effect') == 'none'
                      and 'could not query' in result.get('error', '') and elapsed < 2,
                      (result, round(elapsed, 3)))
            elif behavior == 'stay':
                check('closed socket with live original does not launch',
                      not (case/'launched').exists() and result.get('effect') == 'none'
                      and result.get('ok') is False and server.poll() is None,
                      (result, round(elapsed, 3)))
            else:
                check('delayed shutdown finishes before launch',
                      (case/'launched').exists() and elapsed >= 0.4 and server.poll() == 0,
                      (result, round(elapsed, 3)))
        finally:
            server.communicate(timeout=5)
            waiter.join(timeout=5)
    local = 'LISTEN 0 10 127.0.0.1:35001 0.0.0.0:* users:(("new",pid=999999,fd=4))'
    child = local.replace('999999', '999998')
    foreign = local.replace('999999', '999997')
    unknown = 'LISTEN 0 10 [::1]:35001 [::]:*'
    shared = local[:-1]+',("other",pid=999997,fd=5))'
    for name, rows, expected in (
        ('replacement leader', local, True), ('replacement workers', local+'\n'+child, True),
        ('foreign then local', foreign+'\n'+local, False),
        ('local then foreign', local+'\n'+foreign, False),
        ('query failure', local, False), ('shared row', shared, False),
        ('shared row with local last', shared.replace('pid=999999', 'pid=999996').replace('pid=999997', 'pid=999999'), False), ('unattributed row', local+'\n'+unknown, False),
    ):
        (case/'launched').unlink(missing_ok=True)
        (case/'signaled').unlink(missing_ok=True)
        server = subprocess.Popen(['/usr/bin/python3', '-I', '-S', '-c', server_code, 'exit'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        server.stdout.readline()
        start = identity(server.pid)
        waiter = threading.Thread(target=server.wait)
        waiter.start()
        try:
            output = subprocess.run(['/usr/bin/bash', str(app/'lifecycle.sh'), 'restart',
                str(server.pid), start, '35001', str(case), '["/usr/bin/true"]'],
                env={**base_env, 'MODE': 'ownership', 'SOCKETS': rows, 'TARGET_PID': str(server.pid),
                     'QUERY_FAIL': str(int(name == 'query failure'))},
                capture_output=True, text=True, timeout=12)
            result = json.loads(output.stdout)
            check(name, result.get('ok') is expected, result)
            assert not (case/'state/.restart-35001.pid').exists()
        finally:
            server.communicate(timeout=5)
            waiter.join(timeout=5)
    if (case/'group-probes').exists():
        assert all(line == '-0 -- -999999' for line in (case/'group-probes').read_text().splitlines())

for argument, unusable in ((b'invalid-\xff', True), ('valid-\ufffd'.encode(), False),
                            ('valid-\u65e5\u672c'.encode(), False)):
    server = subprocess.Popen([b'/usr/bin/python3', b'-I', b'-S', b'-c',
        b'import socket,sys;s=socket.socket();s.bind(("127.0.0.1",0));s.listen();'
        b'print(s.getsockname()[1],flush=True);sys.stdin.read()', argument],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        port = int(server.stdout.readline())
        scan = subprocess.run(['/usr/bin/bash', str(ROOT/'scripts/scan-ports.sh')],
                              capture_output=True, text=True, timeout=30)
        entry = next(row for row in json.loads(scan.stdout)['ports'] if row['port'] == port)
        check('argv restart eligibility ' + repr(argument), entry['argvTruncated'] is unusable,
              entry['argvTruncated'])
        if not unusable:
            assert entry['argv'][-1].encode() == argument
    finally:
        server.communicate(timeout=5)
assert not FAILURES, FAILURES
