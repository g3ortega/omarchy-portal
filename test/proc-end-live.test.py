#!/usr/bin/env python3
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import unittest


PROC = Path(__file__).resolve().parents[1] / "scripts/lib/proc.py"


def load_proc():
    spec = importlib.util.spec_from_file_location("portal_proc_live", PROC)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def reap(pid):
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def deadline(_sig, _frame):
    raise TimeoutError("live group cleanup exceeded its deadline")


def supervisor():
    # Keep an orphaned group member our child so teardown can reap everything.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    proc = load_proc()
    proc.GRACE = 0.15

    ready_r, ready_w = os.pipe()
    leader = os.fork()
    if leader == 0:
        os.close(ready_r)
        os.setsid()
        signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.write(ready_w, f"{os.getpid()}\n".encode())
            os.close(ready_w)
            while True:
                signal.pause()
        os.close(ready_w)
        while True:
            signal.pause()
    os.close(ready_w)

    control = os.fork()
    if control == 0:
        os.close(ready_r)
        while True:
            signal.pause()

    owned = []
    calls = []
    leader_reaped = threading.Event()
    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(5)
    try:
        descendant = int(os.read(ready_r, 64))
        os.close(ready_r)
        for pid in (leader, descendant, control):
            start = proc.starttime(pid)
            if pid <= 1 or start is None:
                raise AssertionError(f"unsafe or missing owned process: {pid}")
            fd = os.pidfd_open(pid)
            if proc.starttime(pid) != start:
                os.close(fd)
                raise AssertionError(f"identity changed while opening pidfd: {pid}")
            owned.append((pid, start, fd))

        original_send = proc.signal.pidfd_send_signal

        def recording_send(fd, sig, *args, **kwargs):
            os.fstat(fd)
            flags = kwargs.get("flags", args[1] if len(args) > 1 else 0)
            calls.append((fd, int(sig), flags))
            if flags == 4 and sig == signal.SIGKILL:
                assert leader_reaped.is_set(), "leader was not reaped before escalation"
            return original_send(fd, sig, *args, **kwargs)

        proc.signal.pidfd_send_signal = recording_send

        def reap_leader():
            reap(leader)
            leader_reaped.set()
            reap(descendant)

        thread = threading.Thread(target=reap_leader)
        thread.start()
        rc = proc.cmd_end([str(leader), proc.starttime(leader)])
        thread.join(2)

        group_members = []
        for entry in os.scandir("/proc"):
            if entry.name.isdigit():
                try:
                    if os.getpgid(int(entry.name)) == leader:
                        group_members.append(int(entry.name))
                except (ProcessLookupError, PermissionError):
                    pass
        control_ok = proc.starttime(control) == owned[2][1]
        original_send(owned[2][2], 0)
        group_calls = [call for call in calls if call[2] == 4 and call[1] != 0]
        if rc != 0 or not leader_reaped.is_set() or group_members or not control_ok:
            raise AssertionError(
                f"rc={rc} reaped={leader_reaped.is_set()} group={group_members} control={control_ok}"
            )
        if [sig for _, sig, _ in group_calls] != [signal.SIGTERM, signal.SIGKILL]:
            raise AssertionError(f"expected group pidfd TERM/KILL, got {calls}")
        if len({fd for fd, _, _ in group_calls}) != 1:
            raise AssertionError(f"group signals did not use one pidfd: {group_calls}")
        print(json.dumps({"leader_reaped": True, "group_absent": True,
                          "control_untouched": True, "group_signals": [15, 9]}))
    finally:
        signal.alarm(0)
        for pid, start, fd in owned:
            try:
                if proc.starttime(pid) == start:
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
            except OSError:
                pass
            os.close(fd)
        for _ in range(100):
            try:
                waited, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if waited == 0:
                time.sleep(0.01)


class ProcEndLiveTest(unittest.TestCase):
    def test_reaped_leader_still_ends_group(self):
        result = subprocess.run(
            [sys.executable, "-I", "-S", __file__, "--supervisor"],
            text=True, capture_output=True, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "leader_reaped": True,
            "group_absent": True,
            "control_untouched": True,
            "group_signals": [15, 9],
        })


if __name__ == "__main__":
    if sys.argv[-1:] == ["--supervisor"]:
        supervisor()
    else:
        unittest.main()
