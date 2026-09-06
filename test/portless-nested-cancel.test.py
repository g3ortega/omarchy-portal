import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PROVIDER = '''#!/usr/bin/python3
import os,signal,sys,time
from pathlib import Path
root=Path(os.environ['FIXTURE'])
phase='remove' if '--remove' in sys.argv else 'restore'
mode=os.environ['CASE_MODE']
if mode!='inherited': signal.signal(signal.SIGTERM,signal.SIG_IGN)
with (root/'identities').open('a') as output:
    start=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19]
    output.write(f'{os.getpid()} {start} {phase}\\n')
if mode=='slow-success':
    time.sleep(1.3)
elif phase==('restore' if mode=='restore' else 'remove'):
    while not (root/'stop').exists(): time.sleep(.02)
    sys.exit(0)
(root/('removed' if phase=='remove' else 'restored')).touch()
'''
ACTION = '''source "$ROOT/scripts/tunnels.sh"
namefile() { echo unused; }
cat_own() { echo new; }
portless_state_load() { return 0; }
portless_alias_safe() { return 0; }
portless_alias_present() {
  case $1 in
    new) [[ ! -e $FIXTURE/removed ]] ;;
    old) [[ -e $FIXTURE/restored ]] ;;
  esac
}
write_own() { printf '%s' "$2" > "$FIXTURE/marker"; }
trap 'cancel_portless_start 35001 new old 1 "$FIXTURE/portless" 143' TERM
sleep 2
'''


def identities(root):
    path = root/'identities'
    return [line.split() for line in path.read_text().splitlines()] if path.exists() else []


def alive(pid, start):
    assert pid > 1
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return fields[19] == start and fields[0] not in ('Z', 'X')
    except FileNotFoundError:
        return False


failures = []
for mode in ('inherited', 'remove', 'restore', 'slow-success'):
    with tempfile.TemporaryDirectory(prefix='portal-nested-cancel-') as directory:
        root = Path(directory)
        provider = root/'portless'
        provider.write_text(PROVIDER)
        provider.chmod(0o700)
        action = root/'action.sh'
        action.write_text(ACTION)
        try:
            began = time.monotonic()
            result = subprocess.run([
                '/usr/bin/python3', '-I', '-S', str(ROOT/'scripts/lib/proc.py'),
                'run', '4096', '.3', '--', '/usr/bin/bash', str(action),
            ], env={**os.environ, 'ROOT': str(ROOT), 'FIXTURE': directory,
                    'CASE_MODE': mode, 'PORTAL_STATE_DIR': str(root/'state')},
                capture_output=True, text=True, timeout=15)
            elapsed = time.monotonic() - began
            records = identities(root)
            live = [pid for pid, start, _ in records if alive(int(pid), start)]
            phases = [phase for _, _, phase in records]
            wanted = ['remove', 'restore'] if mode in ('restore', 'slow-success') else ['remove']
            passed = result.returncode == 124 and elapsed < 8 and not live and phases == wanted
            if mode == 'slow-success':
                passed = passed and (root/'marker').read_text() == 'old'
            else:
                passed = passed and not (root/'marker').exists()
            print(('ok ' if passed else 'FAIL ') + f'{mode} nested rollback '
                  + json.dumps({'elapsed': round(elapsed, 2), 'rc': result.returncode,
                                'live': live, 'phases': phases}), flush=True)
            if not passed:
                failures.append(mode)
        finally:
            (root/'stop').touch()
            deadline = time.monotonic() + 5
            while any(alive(int(pid), start) for pid, start, _ in identities(root)):
                assert time.monotonic() < deadline, 'fixture did not exit through its stop file'
                time.sleep(.02)
for grace, expected in (('0', 0), ('1', 0), ('10', 0), ('-1', 2), ('11', 2),
                        ('nan', 2), ('inf', 2), ('invalid', 2)):
    result = subprocess.run([
        '/usr/bin/python3', '-I', '-S', str(ROOT/'scripts/lib/proc.py'),
        'run', '4096', '2', '--cleanup-grace', grace, '--', '/usr/bin/true',
    ], capture_output=True, timeout=3)
    assert result.returncode == expected, (grace, result.returncode)
for arguments in (['--cleanup-grace'], ['--cleanup-grace', '1'],
                  ['--cleanup-grace', '1', '--']):
    result = subprocess.run([
        '/usr/bin/python3', '-I', '-S', str(ROOT/'scripts/lib/proc.py'),
        'run', '4096', '2', *arguments,
    ], capture_output=True, timeout=3)
    assert result.returncode == 2, (arguments, result.returncode)
print('ok cleanup grace accepts bounded values and rejects malformed runs')
assert not failures, failures
