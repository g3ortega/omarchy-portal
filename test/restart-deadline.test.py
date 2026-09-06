import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
APP = '''import os,signal,socket,sys,time
from pathlib import Path
root=Path(sys.argv[1])
port_file=root/'port'
replacement=port_file.exists()
with (root/'identities').open('a') as output:
    start=Path(f'/proc/{os.getpid()}/stat').read_text().rsplit(')',1)[1].split()[19]
    output.write(f'{os.getpid()} {start}\\n')
if replacement:
    if float(sys.argv[2]) == 60: signal.signal(signal.SIGTERM,signal.SIG_IGN)
    deadline=time.monotonic()+float(sys.argv[2])
    while time.monotonic()<deadline:
        if (root/'stop').exists(): sys.exit(0)
        time.sleep(.05)
s=socket.socket()
s.bind(('127.0.0.1',int(port_file.read_text()) if replacement else 0))
s.listen()
port_file.write_text(str(s.getsockname()[1]))
while not (root/'stop').exists(): time.sleep(.05)
'''


def alive(pid, start):
    assert pid > 1
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return fields[19] == start and fields[0] != 'Z'
    except FileNotFoundError:
        return False


def wait_for(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('condition did not complete')


failures = []
for delay in (6.5, 60):
    with tempfile.TemporaryDirectory(prefix='portal-restart-deadline-') as directory:
        root = Path(directory)
        app = root/'app.py'
        app.write_text(APP)
        argv = ['/usr/bin/python3', '-I', '-S', str(app), str(root), str(delay)]
        original = subprocess.Popen(argv, start_new_session=True)
        reaper = threading.Thread(target=original.wait)
        reaper.start()
        try:
            wait_for(lambda: (root/'port').exists() and (root/'port').stat().st_size > 0, 3)
            port = (root/'port').read_text()
            pid, start = (root/'identities').read_text().split()
            assert int(pid) == original.pid and int(pid) > 1
            began = time.monotonic()
            result = subprocess.run([
                '/usr/bin/python3', '-I', '-S', str(ROOT/'scripts/lib/proc.py'),
                'run', '1048576', '20', '--', '/usr/bin/bash',
                str(ROOT/'scripts/lifecycle.sh'), 'restart', pid, start, port,
                str(root), json.dumps(argv),
            ], env={**os.environ, 'PORTAL_STATE_DIR': str(root/'state')},
                capture_output=True, text=True, timeout=35)
            elapsed = time.monotonic() - began
            value = json.loads(result.stdout)
            new_pid, new_start = (root/'identities').read_text().splitlines()[-1].split()
            record = root/f'state/.restart-{port}.pid'
            if delay == 6.5:
                passed = (result.returncode == 0 and value == {'ok': True, 'effect': 'restarted'}
                          and 6.5 <= elapsed < 20 and alive(int(new_pid), new_start)
                          and not record.exists())
                name = 'startup beyond five seconds keeps its replacement'
            else:
                wait_for(lambda: not alive(int(new_pid), new_start), 2)
                record_safe = not record.exists() or (
                    record.read_text() == f'{new_pid} {new_start}'
                    and 'identity record was kept' in value.get('error', ''))
                passed = (result.returncode == 0 and value.get('ok') is False
                          and value.get('effect') == 'stopped'
                          and 18 <= elapsed < 20 and record_safe)
                name = 'exhausted restart budget rolls back within the action deadline'
            print(('ok ' if passed else 'FAIL ') + name + f' ({elapsed:.2f}s) {value}', flush=True)
            if not passed:
                failures.append(name)
        finally:
            (root/'stop').touch()
            original.wait(timeout=5)
            reaper.join(timeout=5)
            identities = [line.split() for line in (root/'identities').read_text().splitlines()]
            wait_for(lambda: all(not alive(int(pid), start) for pid, start in identities), 5)
assert not failures, failures
