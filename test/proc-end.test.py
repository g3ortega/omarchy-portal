import errno
import importlib.util
from pathlib import Path
import signal
import types
import unittest
from unittest.mock import Mock


class BoundGroup(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "portal_proc", Path(__file__).resolve().parents[1] / "scripts/lib/proc.py")
        self.proc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.proc)
        self.pid, self.fd = 424242, 71
        self.start = "12345"
        self.events = []
        self.clock = 0

        def opened(pid):
            self.assertEqual(pid, self.pid)
            self.events.append("open")
            return self.fd

        def identity(pid):
            self.assertEqual(self.events[:1], ["open"], "identity checked before binding a pidfd")
            self.assertEqual(pid, self.pid)
            return self.start

        def sleep(seconds):
            self.clock += seconds

        self.proc.os = types.SimpleNamespace(
            pidfd_open=Mock(side_effect=opened), close=Mock(),
            getpgid=Mock(return_value=self.pid), getsid=Mock(return_value=self.pid),
            killpg=Mock(side_effect=AssertionError("unbound group signal")),
            kill=Mock(side_effect=AssertionError("unbound leader signal")))
        self.proc.starttime = identity
        self.proc.time = types.SimpleNamespace(monotonic=lambda: self.clock, sleep=sleep)
        self.proc.signal = types.SimpleNamespace(
            SIGTERM=signal.SIGTERM, SIGKILL=signal.SIGKILL,
            pidfd_send_signal=Mock())

    def run_end(self):
        return self.proc.cmd_end([str(self.pid), "12345"])

    def test_escalation_stays_bound_after_leader_exit_and_numeric_reuse(self):
        def send(fd, sig, info, flags):
            self.assertEqual((fd, info, flags), (self.fd, None, 4))
            self.events.append(sig)
            if sig == signal.SIGTERM:
                self.start = "67890"
            if signal.SIGKILL in self.events and sig == 0:
                raise ProcessLookupError()

        self.proc.signal.pidfd_send_signal.side_effect = send
        self.assertEqual(self.run_end(), 0)
        self.assertIn(signal.SIGTERM, self.events)
        self.assertIn(signal.SIGKILL, self.events)
        self.proc.os.pidfd_open.assert_called_once_with(self.pid)
        self.proc.os.close.assert_called_once_with(self.fd)

    def test_absent_group_succeeds_without_escalation(self):
        self.proc.signal.pidfd_send_signal.side_effect = ProcessLookupError()
        self.assertEqual(self.run_end(), 0)
        self.proc.os.close.assert_called_once_with(self.fd)

    def test_failed_probe_or_surviving_group_never_reports_success(self):
        for error in (None, PermissionError(errno.EPERM, "denied"),
                      OSError(errno.EINVAL, "unsupported flags"), OSError(errno.ENOSYS, "unsupported")):
            with self.subTest(error=error):
                self.setUp()
                self.proc.signal.pidfd_send_signal.side_effect = error
                self.assertEqual(self.run_end(), 1)
                self.assertLessEqual(self.clock, self.proc.GRACE + 0.55)

    def test_identity_and_session_mismatch_never_signal(self):
        for field in ("start", "pgid", "sid"):
            with self.subTest(field=field):
                self.setUp()
                if field == "start":
                    self.start = "67890"
                else:
                    getattr(self.proc.os, "get" + field).return_value = self.pid + 1
                self.assertEqual(self.run_end(), 1)
                self.proc.signal.pidfd_send_signal.assert_not_called()
                self.proc.os.close.assert_called_once_with(self.fd)

    def test_acquisition_failure_never_signals(self):
        self.proc.os.pidfd_open.side_effect = ProcessLookupError()
        self.assertEqual(self.run_end(), 1)
        self.proc.signal.pidfd_send_signal.assert_not_called()
        self.proc.os.close.assert_not_called()

    def test_dangerous_identities_never_open_or_signal(self):
        for pid, start in (("1", "1"), ("0", "0"), ("-1", "1"), ("", ""),
                           ("999999999999999999999", "1"), ("424242", "nope")):
            self.assertEqual(self.proc.cmd_end([pid, start]), 1)
        self.proc.os.pidfd_open.assert_not_called()
        self.proc.signal.pidfd_send_signal.assert_not_called()


if __name__ == "__main__":
    unittest.main()
