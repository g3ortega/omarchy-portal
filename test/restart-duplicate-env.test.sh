#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

root=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='portal-duplicate-env-') as temporary:
    case=Path(temporary)
    app=case/'app'; (app/'lib').mkdir(parents=True)
    shutil.copy2(root/'scripts/lifecycle.sh',app/'lifecycle.sh')
    (app/'lib/files.sh').write_text('''source "$REAL_FILES"
lifecycle_mutation() { :; }
ss() {
  printf 'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:* users:(("cat",pid=%s,fd=3))\\n' "$TARGET_PID"
  if [[ ${JOIN_PEER:-0} == 1 && -e $CASE_ROOT/queried ]]; then
    printf 'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:* users:(("peer",pid=999998,fd=3))\\n'
  fi
  echo queried > "$CASE_ROOT/queried"
}
proc() { if [[ $1 == signal ]]; then echo signal >> "$CASE_ROOT/signals"; return 1; fi; }
kill() { echo kill >> "$CASE_ROOT/signals"; return 99; }
''')
    source=case/'duplicate.c'; executable=case/'duplicate'
    source.write_text('''#include <unistd.h>
int main(void) {
 char *argv[]={"/usr/bin/cat",0};
 char *env[]={"PORTAL_DUPLICATE=first","PORTAL_DUPLICATE=last",0};
 execve(argv[0],argv,env); return 99;
}
''')
    subprocess.run(['cc',str(source),'-o',str(executable)],check=True)
    child=subprocess.Popen([str(executable)],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            raw=Path(f'/proc/{child.pid}/environ').read_bytes()
            if raw==b'PORTAL_DUPLICATE=first\0PORTAL_DUPLICATE=last\0':break
            time.sleep(.01)
        else:raise AssertionError('fixture did not expose duplicate kernel environment entries')
        start=Path(f'/proc/{child.pid}/stat').read_text().rsplit(')',1)[1].split()[19]
        env=dict(os.environ,REAL_FILES=str(root/'scripts/lib/files.sh'),CASE_ROOT=str(case),TARGET_PID=str(child.pid),PORTAL_STATE_DIR=str(case/'state'))
        result=subprocess.run(['bash',str(app/'lifecycle.sh'),'restart',str(child.pid),start,'3000',str(case),'["/usr/bin/cat"]'],env=env,text=True,capture_output=True,timeout=10)
        assert not (case/'signals').exists(), 'duplicate environment reached original-process signal'
        assert json.loads(result.stdout)['ok'] is False
        assert 'environment' in json.loads(result.stdout)['error']
        assert child.poll() is None
        print('ok actual duplicate /proc environment is rejected before signaling the original process')
    finally:
        child.stdin.close()
        child.wait(timeout=5)
    (case/'queried').unlink()
    child=subprocess.Popen(['/usr/bin/cat'],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        start=Path(f'/proc/{child.pid}/stat').read_text().rsplit(')',1)[1].split()[19]
        env.update(TARGET_PID=str(child.pid),JOIN_PEER='1')
        result=subprocess.run(['bash',str(app/'lifecycle.sh'),'restart',str(child.pid),start,'3000',str(case),'["/usr/bin/cat"]'],env=env,text=True,capture_output=True,timeout=10)
        assert not (case/'signals').exists(), 'new peer did not prevent original-process signal'
        assert json.loads(result.stdout)['ok'] is False
        assert 'exclusively' in json.loads(result.stdout)['error']
        assert child.poll() is None
        print('ok a peer joining during restart preparation is rechecked before TERM')
    finally:
        child.stdin.close()
        child.wait(timeout=5)
PY
