#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
payload = b'\x7fELFprivate-installer-fixture'
digest = hashlib.sha256(payload).hexdigest()
harness = r'''
set -- noop
source "$ROOT/scripts/provider-install.sh" >/dev/null
CLOUDFLARED_SHA256[amd64]="$DIGEST"
uname() { echo x86_64; }
curl() {
  while (( $# )); do
    if [[ $1 == -o ]]; then cp "$CASE/download" "$2"; return; fi
    shift
  done
  return 99
}
installer_pid=$BASHPID
installer_start=$(python3 -c 'import pathlib,sys; print(pathlib.Path("/proc/"+sys.argv[1]+"/stat").read_text().rsplit(")",1)[1].split()[19])' "$installer_pid")
interrupt_installer() {
  python3 - "$installer_pid" "$installer_start" "$SIGNAL" <<'SIGNAL'
import os,pathlib,signal,sys
pid=int(sys.argv[1]); assert pid>1
fd=os.pidfd_open(pid)
assert pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19] == sys.argv[2]
signal.pidfd_send_signal(fd,getattr(signal,'SIG'+sys.argv[3]))
os.close(fd)
SIGNAL
}
real_state() { /usr/bin/python3 -I -S "$ROOT/scripts/lib/statedir.py" "$@"; }
state() {
  if [[ $1 == create && $2 == "$BIN_DIR/cloudflared" ]]; then
    case $MODE in
      failure) return 1 ;;
      swapped_marker) printf 'foreign-marker' | real_state write "$MARK"; return 1 ;;
      foreign_binary) printf 'foreign-binary' | real_state create "$2"; return 1 ;;
      symlink_binary) printf 'foreign-binary' > "$CASE/foreign"; ln -s "$CASE/foreign" "$2"; return 1 ;;
    esac
  fi
  real_state "$@" || return $?
  if [[ $1 == create && $2 == "$BIN_DIR/cloudflared" && $MODE == after_binary ]]; then interrupt_installer; fi
  if [[ $1 == create && $2 == "$MARK" && $MODE == after_marker ]]; then interrupt_installer; fi
}
install_cloudflared
'''

with tempfile.TemporaryDirectory(prefix='portal-install-') as temporary:
    root = Path(temporary)
    app = root/'app'
    shutil.copytree(source/'scripts', app, ignore=shutil.ignore_patterns('__pycache__'))
    for helper in ('tunnels.sh','portless-setup.sh'):
        (app/helper).write_text('#!/bin/bash\necho \'{"ok":true}\'\n')
        (app/helper).chmod(0o755)
    fakebin = root/'fakebin'
    fakebin.mkdir()
    (fakebin/'omarchy').write_text('#!/bin/bash\n[[ $* == "plugin list --json" ]] || exit 99\necho "[]"\n')
    (fakebin/'omarchy').chmod(0o755)
    def environment(case):
        return dict(os.environ,ROOT=str(source),CASE=str(case),DIGEST=digest,
                    HOME=str(case/'home'),PORTAL_BIN_DIR=str(case/'bin'),
                    TMPDIR=str(case/'tmp'),
                    PORTAL_METRICS_DIR=str(case/'state'),PORTAL_STATE_DIR=str(case/'runtime'),
                    PORTLESS_STATE_DIR=str(case/'portless'),PATH=str(fakebin)+os.pathsep+os.environ['PATH'])
    def execute(mode, sig='TERM'):
        case = root / (mode + '-' + sig)
        case.mkdir()
        for child in ('bin','state','runtime','home','tmp'):
            (case / child).mkdir()
        (case / 'download').write_bytes(payload)
        env = dict(environment(case),MODE=mode,SIGNAL=sig)
        result = subprocess.run(['bash'], input=harness, text=True, env=env, capture_output=True, timeout=15)
        return case, result
    def cleanup_install(case):
        marker = case/'state/installed-cloudflared'
        data = json.loads(marker.read_text())
        assert data == {'path': str(case/'bin/cloudflared'), 'sha256': digest}
        subprocess.run(['bash',str(app/'uninstall.sh')],env=environment(case),check=True,capture_output=True,timeout=15)
        assert not marker.exists() and not (case/'bin/cloudflared').exists()
    if os.environ.get('PORTAL_INSTALL_EXPECT_OLD') == '1':
        case,result=execute('after_binary')
        assert result.returncode != 0 and (case/'bin/cloudflared').exists() and not (case/'state/installed-cloudflared').exists()
        print('reproduced interrupted installer leaves executable without ownership marker')
        sys.exit(0)
    for sig in ('TERM','INT','HUP','KILL'):
        for mode in ('after_marker','after_binary'):
            case,result=execute(mode,sig)
            assert result.returncode != 0, (mode,sig,result.stdout,result.stderr)
            assert (case/'bin/cloudflared').exists() == (mode == 'after_binary')
            cleanup_install(case)
    print('ok TERM/INT/HUP/KILL leave removable marker-only or complete owned installs')
    case,result=execute('failure')
    assert json.loads(result.stdout)['ok'] is False
    assert not (case/'state/installed-cloudflared').exists() and not (case/'bin/cloudflared').exists()
    print('ok failed binary publication removes its exact marker')
    case,result=execute('swapped_marker')
    assert json.loads(result.stdout)['ok'] is False
    assert (case/'state/installed-cloudflared').read_text() == 'foreign-marker'
    print('ok failed publication preserves a replaced marker')
    case,result=execute('foreign_binary')
    assert json.loads(result.stdout)['ok'] is False
    assert (case/'bin/cloudflared').read_text() == 'foreign-binary'
    assert (case/'state/installed-cloudflared').exists()
    refused=subprocess.run(['bash',str(app/'uninstall.sh')],env=environment(case),capture_output=True,timeout=15)
    assert refused.returncode != 0 and (case/'bin/cloudflared').read_text() == 'foreign-binary'
    print('ok uncertain failed publication preserves the foreign binary and ownership evidence')
    case,result=execute('symlink_binary')
    assert json.loads(result.stdout)['ok'] is False
    refused=subprocess.run(['bash',str(app/'uninstall.sh')],env=environment(case),capture_output=True,timeout=15)
    assert refused.returncode != 0 and (case/'bin/cloudflared').is_symlink()
    assert (case/'foreign').read_text() == 'foreign-binary' and (case/'state/installed-cloudflared').exists()
    print('ok refused symlink cannot masquerade as absent during rollback or uninstall')
    case=root/'dry'
    case.mkdir()
    for child in ('state','runtime','home','tmp'):
        (case/child).mkdir()
    (case/'state/installed-cloudflared').write_text(json.dumps({'path':str(case/'bin/cloudflared'),'sha256':digest}))
    subprocess.run(['bash',str(app/'uninstall.sh'),'--dry'],env=environment(case),check=True,capture_output=True,timeout=15)
    assert not (case/'bin').exists() and (case/'state/installed-cloudflared').exists()
    print('ok dry uninstall does not create a missing binary directory')
    subprocess.run(['bash',str(app/'uninstall.sh')],env=environment(case),check=True,capture_output=True,timeout=15)
    assert not (case/'bin').exists() and not (case/'state/installed-cloudflared').exists()
    print('ok actual uninstall does not create a missing binary directory')
    case=root/'legacy'
    case.mkdir()
    for child in ('state','runtime','home','tmp'):
        (case/child).mkdir()
    for name in ('portless-3000.log','portless-00080.log','portless-0.log','foreign.log'):
        (case/'runtime'/name).write_text('preserved unless Portal owns this name')
    (case/'secret').write_text('unrelated')
    (case/'runtime/portless-3001.log').symlink_to(case/'secret')
    subprocess.run(['bash',str(app/'uninstall.sh')],env=environment(case),check=True,capture_output=True,timeout=15)
    assert sorted(p.name for p in (case/'runtime').iterdir()) == ['foreign.log','portless-0.log']
    assert (case/'secret').read_text() == 'unrelated'
    print('ok legacy Portless logs are removed while invalid ports and unrelated files remain')

    for obstruction in ('none', 'foreign-file', 'foreign-db', 'symlink'):
        case=root/('sqlite-'+obstruction)
        case.mkdir()
        for child in ('state','runtime','home','tmp'):
            (case/child).mkdir()
        metrics=case/'state/metrics'
        created=subprocess.run(['/usr/bin/python3','-I','-S',str(app/'lib/statedir.py'),
                                'metrics',str(metrics),'stats'],
                               env=environment(case),text=True,capture_output=True,check=True,timeout=15,
                               preexec_fn=lambda: os.umask(0o077))
        assert json.loads(created.stdout)['ok'], created.stdout
        store=metrics/'store'
        database=store/'metrics.db'
        if obstruction == 'foreign-file':
            (store/'foreign.txt').write_text('unrelated')
        elif obstruction == 'foreign-db':
            with sqlite3.connect(database) as connection:
                connection.execute('PRAGMA application_id=123')
        elif obstruction == 'symlink':
            (case/'secret').write_text('unrelated')
            (store/'metrics.db-journal').symlink_to(case/'secret')
        before=database.read_bytes()
        dry=subprocess.run(['bash',str(app/'uninstall.sh'),'--dry'],env=environment(case),capture_output=True,timeout=15)
        assert (dry.returncode == 0) == (obstruction == 'none'), (obstruction,dry.stderr)
        assert database.read_bytes() == before
        result=subprocess.run(['bash',str(app/'uninstall.sh')],env=environment(case),capture_output=True,timeout=15)
        assert (result.returncode == 0) == (obstruction == 'none'), (obstruction,result.stderr)
        if obstruction == 'none':
            assert not store.exists()
        else:
            assert database.read_bytes() == before
        if obstruction == 'foreign-file':
            assert (store/'foreign.txt').read_text() == 'unrelated'
        if obstruction == 'symlink':
            assert (store/'metrics.db-journal').is_symlink()
            assert (case/'secret').read_text() == 'unrelated'
    print('ok uninstall removes owned SQLite storage and refuses foreign files, databases, and symlinks')


PY
