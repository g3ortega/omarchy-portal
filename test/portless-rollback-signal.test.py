import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    script = root / 'cancel.sh'
    script.write_text('''source "$ROOT/scripts/tunnels.sh"
namefile() { echo unused; }
cat_own() { echo new; }
rollback_portless() {
  touch "$FIXTURE/entered"
  sleep 0.3
  echo old > "$FIXTURE/restored"
}
cancel_portless_start 35001 new old 1 unused 143
''')
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        for name in ('entered', 'restored'):
            (root / name).unlink(missing_ok=True)
        child = subprocess.Popen(['bash', str(script)], env={**os.environ, 'ROOT': str(ROOT), 'FIXTURE': directory, 'PORTAL_STATE_DIR': str(root / 'state')})
        try:
            deadline = time.monotonic() + 5
            while not (root / 'entered').exists() and time.monotonic() < deadline:
                assert child.poll() is None
                time.sleep(0.01)
            assert (root / 'entered').exists()
            assert child.pid > 1
            child.send_signal(sig)
            rc = child.wait(timeout=5)
            assert rc == 143 and (root / 'restored').read_text() == 'old\n', (sig, rc)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
print('ok repeated TERM, INT and HUP cannot interrupt Portless rollback')
