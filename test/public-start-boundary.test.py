import itertools
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def identity(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
    except FileNotFoundError:
        return None

with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    for stage, sig in itertools.product(("before", "after"), (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)):
        case = base / (stage + sig.name)
        case.mkdir()
        (case / "state").mkdir(mode=0o700)
        provider = case / 'cloudflared'
        shutil.copyfile('/usr/bin/python3', provider)
        provider.chmod(0o700)
        gate = case / 'gate'
        os.mkfifo(gate)
        action = case / 'action'
        action.write_text('''source "$SOURCE/scripts/tunnels.sh" >/dev/null
provider_bin() { printf '%s' "$CASE/cloudflared"; }
cloudflared_argv() { printf '%s\\n' -c 'import time; time.sleep(300)'; }
listener_identity() { printf '999999 1'; }
target_owns_port() { return 0; }
stop_line() { printf '%s\\n' "$1" >> "$CASE/stops"; return 1; }
state() {
  if [[ $1 == launch-tracked ]]; then
    local result subshell_pid=$BASHPID
    if [[ $BARRIER == before ]]; then
      : > "$CASE/ready"
      read -r release < "$CASE/gate"
    fi
    result=$(/usr/bin/python3 -I -S "$SOURCE/scripts/lib/statedir.py" "$@") || return
    if [[ $BARRIER == after ]]; then
      printf '%s %s' "$subshell_pid" "$(proc_start "$subshell_pid")" > "$CASE/subshell"
      : > "$CASE/ready"
      read -r release < "$CASE/gate"
    fi
    printf '%s' "$result"
  else
    /usr/bin/python3 -I -S "$SOURCE/scripts/lib/statedir.py" "$@"
  fi
}
cmd_start cloudflared 4488
''')
        env = dict(os.environ, SOURCE=str(ROOT), CASE=str(case), HOME=str(case), BARRIER=stage,
                   PORTAL_STATE_DIR=str(case / 'state'), PORTAL_METRICS_DIR=str(case / 'metrics'))
        process = subprocess.Popen(['/usr/bin/bash', str(action)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        start = identity(process.pid)
        child = child_start = None
        try:
            deadline = time.monotonic() + 8
            while not (case / 'ready').exists():
                assert process.poll() is None, process.communicate()
                assert time.monotonic() < deadline, 'launch barrier timed out'
                time.sleep(.01)
            record = case / 'state/cloudflared-4488.pid'
            handle = os.pidfd_open(process.pid)
            assert process.pid > 1 and identity(process.pid) == start
            signal.pidfd_send_signal(handle, sig)
            os.close(handle)
            if stage == "before":
                with gate.open('w') as stream:
                    stream.write('release\n')
            else:
                subshell_text, subshell_start = (case / 'subshell').read_text().split()
                subshell = int(subshell_text)
                assert subshell > 1
                handle = os.pidfd_open(subshell)
                assert identity(subshell) == subshell_start
                signal.pidfd_send_signal(handle, signal.SIGTERM)
                os.close(handle)
            out, err = process.communicate(timeout=8)
            durable = record.read_text()
            child_text, child_start = durable.split()
            child = int(child_text)
            assert process.returncode == 128 + sig, (out, err, process.returncode)
            assert (case / 'stops').exists(), f'{sig.name}: cancellation never read durable PID'
            assert (case / 'stops').read_text().strip() == durable, 'cancellation used another identity'
            assert record.read_text() == durable, 'failed stop discarded durable ownership'
            print(f'PASS {stage} publication {sig.name} launch-boundary cancellation recovers durable identity and preserves failed cleanup')
        finally:
            if child is None:
                try:
                    child_text, child_start = (case / 'state/cloudflared-4488.pid').read_text().split()
                    child = int(child_text)
                except FileNotFoundError:
                    pass
            for pid, expected in ((child, child_start), (process.pid, start)):
                if pid and pid > 1 and identity(pid) == expected:
                    handle = os.pidfd_open(pid)
                    if identity(pid) == expected:
                        signal.pidfd_send_signal(handle, signal.SIGKILL)
                    os.close(handle)
            process.wait()
