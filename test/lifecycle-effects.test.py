import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def identity(pid):
    assert pid > 1
    return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]


with tempfile.TemporaryDirectory(prefix='portal-stop-effect-') as temporary:
    server = subprocess.Popen(['/usr/bin/python3', '-I', '-S', '-c',
        'import signal,socket,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
        's=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); '
        'print(s.getsockname()[1],flush=True); sys.stdin.read()'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    start = identity(server.pid)
    try:
        port = int(server.stdout.readline())
        result = subprocess.run(['/usr/bin/bash', str(ROOT/'scripts/lifecycle.sh'), 'stop',
            str(server.pid), start, str(port)], env={**os.environ, 'PORTAL_STATE_DIR': temporary+'/state'},
            capture_output=True, text=True, timeout=15)
        output = json.loads(result.stdout)
        assert server.poll() is None
        with socket.create_connection(('127.0.0.1',port), timeout=1):
            pass
        assert output == {'ok': True, 'effect': 'none'}, output
    finally:
        server.communicate(timeout=5)
    print('ok delivered TERM does not claim an ignored stop completed')

with tempfile.TemporaryDirectory(prefix='portal-restart-path-') as temporary:
    case = Path(temporary)
    app = case/'app'
    (app/'lib').mkdir(parents=True)
    (app/'lifecycle.sh').write_bytes((ROOT/'scripts/lifecycle.sh').read_bytes())
    (app/'lib/files.sh').write_text('''source "$REAL_FILES"
lifecycle_mutation() { :; }
proc() {
  if [[ $1 == signal ]]; then printf '%s\\n' "$*" >> "$CASE/signals"; return 0; fi
  /usr/bin/python3 -I -S "$PROC_PY" "$@"
}
kill() { printf '%s\\n' "$*" >> "$CASE/forbidden"; return 99; }
ss() {
  if [[ $1 == -tlnpH ]]; then
    printf 'LISTEN 0 10 127.0.0.1:35001 0.0.0.0:* users:(("fixture",pid=%s,fd=4))\\n' "$TARGET_PID"
  fi
}
state() {
  if [[ $1 == launch-tracked ]]; then
    printf '%s\\0' "$@" > "$CASE/launch"; /usr/bin/cat >/dev/null; return 1
  fi
  /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"
}
''')
    helperbin = case/'helperbin'
    helperbin.mkdir()
    decoy = helperbin/'portal-path-fixture'
    decoy.write_text('#!/bin/sh\nexit 99\n')
    decoy.chmod(0o700)
    cwd = case/'cwd'
    cwd.mkdir()
    local_binary = cwd/'portal-path-fixture'
    cases = [({}, False, None), ({'PATH': ''}, False, None),
             ({}, True, None), ({'PATH': ''}, True, local_binary),
             ({'PATH': str(helperbin)}, False, decoy)]
    for target_env, local_exists, selected_path in cases:
        local_binary.unlink(missing_ok=True)
        if local_exists:
            local_binary.write_bytes(decoy.read_bytes())
            local_binary.chmod(0o700)
        server = subprocess.Popen(['portal-path-fixture', '-I', '-S', '-c',
            'import sys;print("ready",flush=True);sys.stdin.read()'], executable='/usr/bin/python3',
            cwd=cwd, env=target_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            assert server.stdout.readline().strip() == 'ready'
            expected = str(selected_path) if selected_path else os.readlink(f'/proc/{server.pid}/exe')
            env = {**os.environ, 'REAL_FILES': str(ROOT/'scripts/lib/files.sh'), 'CASE': str(case),
                   'TARGET_PID': str(server.pid), 'PORTAL_STATE_DIR': str(case/'state'),
                   'PATH': str(helperbin)+':/usr/bin:/bin'}
            result = subprocess.run(['/usr/bin/bash', str(app/'lifecycle.sh'), 'restart', str(server.pid),
                identity(server.pid), '35001', str(cwd), '["portal-path-fixture"]'],
                env=env, text=True, capture_output=True, timeout=10)
            assert result.returncode == 0, result.stderr
            args = (case/'launch').read_bytes().decode().split('\0')
            selected = args[args.index('--exec')+1]
            assert selected == expected, (target_env, selected, expected, result.stdout)
            assert not (case/'forbidden').exists()
            assert server.poll() is None
        finally:
            server.communicate(timeout=5)
    print('ok absent PATH uses the target executable; empty and explicit PATH retain their own lookup semantics')
