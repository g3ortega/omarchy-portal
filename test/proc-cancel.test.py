#!/usr/bin/env python3
import json
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

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


class GroupOwnership(unittest.TestCase):
    def test_child_is_not_reaped_before_last_group_signal(self):
        for exited_before_term in (True, False):
            with self.subTest(exited_before_term=exited_before_term), tempfile.TemporaryDirectory() as tmp:
                spec = importlib.util.spec_from_file_location("portal_proc", PROC)
                proc = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(proc)
                pid = 424242
                events = []
                waits = 0
                real_scandir = os.scandir
                member = Path(tmp) / "424243"
                member.mkdir()
                (member / "stat").write_text(f"424243 (descendant) S {pid} {pid} 0\n")

                def waitpid(target, flags):
                    nonlocal waits
                    self.assertEqual(target, pid)
                    waits += 1
                    if flags and not exited_before_term and waits == 1:
                        return 0, 0
                    events.append("reap")
                    return pid, 0

                def killpg(target, sig):
                    self.assertEqual(target, pid)
                    self.assertNotIn("reap", events, "group ID may belong to a successor after reaping")
                    events.append(sig)
                    if exited_before_term and sig == 0:
                        raise ProcessLookupError

                exited = SimpleNamespace(si_pid=pid)
                statuses = iter([exited, exited] if exited_before_term else [None, exited])

                def waitid(kind, target, flags):
                    self.assertEqual((kind, target), (os.P_PID, pid))
                    self.assertEqual(flags, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                    return next(statuses)

                with patch.object(proc.os, "waitpid", waitpid), \
                        patch.object(proc.os, "waitid", waitid), \
                        patch.object(proc.os, "killpg", killpg), \
                        patch.object(proc.os, "kill", side_effect=AssertionError("unexpected leader signal")), \
                        patch.object(proc.os, "scandir", side_effect=lambda _: real_scandir(tmp)), \
                        patch.object(proc.time, "monotonic", side_effect=[0, 0, 2]), \
                        patch.object(proc.time, "sleep"):
                    proc.end_group(pid, grace=1)
                self.assertEqual(events[-1], "reap")
                if not exited_before_term:
                    self.assertIn(signal.SIGKILL, events)


if __name__ == "__main__":
    unittest.main()
