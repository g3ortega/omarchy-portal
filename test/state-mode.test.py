import importlib.util
import os
from pathlib import Path
import stat
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('statedir', ROOT / 'scripts/lib/statedir.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)
fsync = os.fsync

with tempfile.TemporaryDirectory() as directory:
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for mode in (0o600, 0o755):
            synced = []

            def record_sync(target):
                info = os.fstat(target)
                synced.append(('dir' if stat.S_ISDIR(info.st_mode) else 'file', stat.S_IMODE(info.st_mode)))
                fsync(target)

            with patch.object(os, 'fsync', record_sync):
                state.atomic_write(fd, 'provider', b'content', mode)
            assert synced == [('file', mode), ('dir', 0o700)], synced
            assert (Path(directory) / 'provider').read_bytes() == b'content'
            assert stat.S_IMODE(os.stat('provider', dir_fd=fd).st_mode) == mode
    finally:
        os.close(fd)
print('ok state file data and final mode are synced before publication')
