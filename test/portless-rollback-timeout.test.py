import os
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory() as d:
    p = Path(d)
    helper = p / 'portless'
    helper.write_text('#!/usr/bin/python3\nimport os,time\nfrom pathlib import Path\np=Path(os.environ["FIXTURE"])\n(p/"child").write_text(str(os.getpid()))\nwhile not (p/"stop").exists(): time.sleep(.05)\n')
    helper.chmod(0o700)
    code = '''source "$ROOT/scripts/tunnels.sh"
exec 8>"$FIXTURE/lock"
flock -n 8 || exit 90
namefile() { echo unused; }
cat_own() { echo new; }
portless_state_load() { return 0; }
portless_alias_safe() { return 0; }
portless_alias_present() { return 0; }
cancel_portless_start 35001 new old 1 "$FIXTURE/portless" 143
'''
    child = subprocess.Popen(['bash','-c',code],env={**os.environ,'ROOT':str(ROOT),'FIXTURE':d,'PORTAL_STATE_DIR':d+'/state'},stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    started = time.monotonic()
    try:
        try:
            child.communicate(timeout=15)
            assert child.returncode == 143
            print('ok cancelled Portless rollback ends its blocked helper in', round(time.monotonic()-started,2), 'seconds')
        except subprocess.TimeoutExpired:
            print('FAIL cancellation rollback still holds lifecycle lock after 15s')
            raise
        assert subprocess.run(['flock','-n',str(p/'lock'),'true']).returncode == 0
        pid = int((p / 'child').read_text())
        assert pid > 1
        statfile = Path(f'/proc/{pid}/stat')
        assert not statfile.exists() or statfile.read_text().rsplit(')',1)[1].split()[0] == 'Z'
    finally:
        (p/'stop').touch()
        child.communicate(timeout=5)
