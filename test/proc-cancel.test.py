#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROC = Path(__file__).resolve().parents[1] / "scripts/lib/proc.py"

HARNESS = r'''
import importlib.util
import json
import os
import signal
import sys
import time

spec = importlib.util.spec_from_file_location("portal_proc", sys.argv[1])
proc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proc)
real_fork, real_setsid = os.fork, os.setsid
if sys.argv[4] == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    proc.RUN_GRACE = 0.1

def fork_and_cancel():
    pid = real_fork()
    if pid:
        assert os.getpid() > 1 and pid > 1
        os.kill(os.getpid(), int(sys.argv[3]))
    return pid

def delayed_setsid():
    time.sleep(0.5)
    return real_setsid()

proc.os.fork = fork_and_cancel
proc.os.setsid = delayed_setsid
started = time.monotonic()
result = proc.cmd_run(["1024", "2", "--", sys.executable, "-I", "-S", "-c",
                      "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", sys.argv[2]])
try:
    os.waitpid(-1, os.WNOHANG)
    reaped = False
except ChildProcessError:
    reaped = True
print(json.dumps({"status": result, "elapsed": time.monotonic() - started, "reaped": reaped}))
'''


class EarlyCancellation(unittest.TestCase):
    def test_cancel_before_child_creates_session(self):
        import signal

        cases = [(sig, "default") for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)]
        cases.append((signal.SIGTERM, "ignore-term"))
        for sig, mode in cases:
            with self.subTest(signal=sig, mode=mode), tempfile.TemporaryDirectory() as tmp:
                marker = Path(tmp) / "executed"
                result = subprocess.run(
                    [sys.executable, "-I", "-S", "-c", HARNESS, str(PROC), str(marker), str(int(sig)), mode],
                    capture_output=True, text=True, timeout=5, check=True,
                )
                report = json.loads(result.stdout)
                self.assertEqual(report["status"], 128 + sig)
                self.assertTrue(report["reaped"])
                self.assertFalse(marker.exists(), "cancelled child executed after group cleanup missed setsid")


if __name__ == "__main__":
    unittest.main()
