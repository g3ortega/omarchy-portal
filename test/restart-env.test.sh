#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='portal-restart-env-') as temporary:
    fixture = Path(temporary)
    preload = fixture / 'preload.so'
    source = fixture / 'preload.c'
    source.write_text('''#include <unistd.h>
#include <string.h>
__attribute__((constructor)) static void check(void) {
 char p[4096]; ssize_t n=readlink("/proc/self/exe",p,sizeof(p)-1);
 if(n>0){p[n]=0;if(strstr(p,"python"))_exit(79);}
}
''')
    subprocess.run(['cc','-shared','-fPIC',str(source),'-o',str(preload)],check=True)
    source.write_text('''#include <stdio.h>
#include <string.h>
#include <fcntl.h>
extern char **environ;
int main(int argc,char **argv) {
 FILE *out=fopen(argv[1],"wb"); if(!out)return 2;
 for(int i=0;i<argc;i++)fwrite(argv[i],1,strlen(argv[i])+1,out);
 fputc(0,out);
 for(char **e=environ;*e;e++)fwrite(*e,1,strlen(*e)+1,out);
 fputc(0,out);
 for(int i=3;i<128;i++)if(i!=fileno(out)&&fcntl(i,F_GETFD)!=-1)fprintf(out,"%d\\n",i);
 return fclose(out);
}
''')
    executable = fixture/'reporter'
    subprocess.run(['cc',str(source),'-o',str(executable)],check=True)
    helper = ['/usr/bin/python3','-I','-S',str(root/'scripts/lib/statedir.py')]
    clean = dict(os.environ, PORTAL_HELPER_ONLY='must-not-leak')
    clean.pop('LD_PRELOAD',None)
    clean.pop('LD_LIBRARY_PATH',None)
    old = subprocess.run(helper+['ensure',str(fixture/'old')],env=dict(clean,LD_PRELOAD=str(preload)))
    assert old.returncode == 79
    print('ok exporting target preload poisons Python helper startup')

    def read_output(path):
        for _ in range(100):
            if path.exists() and path.stat().st_size:
                data=path.read_bytes()
                if data.endswith(b'\n'):return data
            time.sleep(.01)
        raise AssertionError('replacement did not write its environment')

    output=fixture/'lifecycle-output'
    entries=[b'LD_PRELOAD='+os.fsencode(preload),b'LD_LIBRARY_PATH='+os.fsencode(fixture),
             b'PORTAL_VALUE=spaces\nand=equals',b'PATH=/deliberately/not/a/helper/path']
    args=['custom-argv-zero',str(output),'space\nargument','','utf8-é']
    lifecycle=(root/'scripts/lifecycle.sh').read_text()
    start=lifecycle.index('    (\n',lifecycle.index('    restart_pid='))
    block=lifecycle[start:lifecycle.index('    launch_rc=$?',start)]
    script='source '+shlex.quote(str(root/'scripts/lib/files.sh'))+'\n'
    script+='envs=('+ ' '.join(shlex.quote(os.fsdecode(e)) for e in entries)+')\n'
    script+='argv=('+ ' '.join(shlex.quote(a) for a in args)+')\n'
    for key,value in [('cwd',str(fixture)),('exec_path',str(executable)),('PORTAL_RUNTIME_DIR',str(fixture/'runtime')),('restart_pid','.restart-39419.pid')]:
        script+=key+'='+shlex.quote(value)+'\n'
    result=subprocess.run(['bash','-eo','pipefail'],input=script+block,text=True,env=clean,capture_output=True,timeout=10)
    assert result.returncode==0,(result.stdout,result.stderr)
    raw=read_output(output)
    expected_args=b''.join(os.fsencode(a)+b'\0' for a in args)+b'\0'
    assert raw.startswith(expected_args)
    rest=raw[len(expected_args):]
    env_bytes,fd_bytes=rest.split(b'\0\0',1)
    assert env_bytes.split(b'\0')==entries
    assert len(fd_bytes.splitlines())==1,fd_bytes
    assert (fixture/'runtime/.restart-39419.pid').read_text().split()[0].isdigit()
    print('ok actual lifecycle launch keeps helpers clean and applies exact argv/environment only to replacement')
    print('ok replacement inherits only stdio and its executable descriptor')

    output=fixture/'empty-output'
    command=helper+['launch-tracked',str(fixture/'empty'),'--discard-output','.restart-39420.pid','--env-stdin','--exec',str(executable),'--','custom-zero',str(output)]
    result=subprocess.run(command,input=b'',env=clean,capture_output=True,timeout=10)
    assert result.returncode==0,result.stderr
    data=read_output(output)
    expected=b'custom-zero\0'+os.fsencode(output)+b'\0\0\0'
    assert data.startswith(expected),data
    print('ok empty captured environment does not inherit Portal helper variables')
    for number,raw in enumerate([b'KEY=value',b'NO_EQUALS\0',b'=empty-key\0',b'K=first\0K=last\0',b'K='+b'x'*8388608+b'\0']):
        state=fixture/('invalid-'+str(number))
        result=subprocess.run(helper+['launch-tracked',str(state),'--discard-output','record','--env-stdin','--exec',str(executable),'--','report',str(fixture/'invalid-output')],input=raw,env=clean,capture_output=True,timeout=10)
        assert result.returncode!=0 and not state.exists(),result.stderr
    print('ok malformed and oversized environments fail before creating launch state')
PY
