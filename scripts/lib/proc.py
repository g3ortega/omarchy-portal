#!/usr/bin/env python3
"""Process handling for Portal's shell helpers.

  run <stdout-cap> <deadline> -- <argv...>
      Run argv in a session of its own. Its stdout is held up to the cap and
      its stderr up to 4096 bytes; past the cap, or past the deadline
      (seconds), the whole process group is ended (TERM, then KILL five
      seconds later) and nothing is passed on: exit 125 for overflow, 124 for
      the deadline, so a reader never parses a document that was cut short.
      Otherwise the child's output and its own exit status are returned.
  signal <pid> <starttime> <SIG>
      Signal the process that is <pid> and started at <starttime> (kernel
      ticks, field 22 of /proc/<pid>/stat) through a pidfd, so a pid reused
      since the process was listed is never signaled. Exit 1 when refused.
  check <pid> <starttime>
      Exit 0 while that process exists, 1 otherwise.

Runs as python3 -I -S: no environment or working directory redirects it.
"""
import os
import selectors
import signal
import sys
import time

STDERR_CAP = 4096
GRACE = 5.0


def starttime(pid):
    """Field 22 of /proc/<pid>/stat, parsed after the last ')' so a comm with spaces cannot shift it."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            fields = f.read().rsplit(b")", 1)[1].split()
    except OSError:
        return None
    return fields[19].decode() if len(fields) > 19 else None


def parse_pid(a, b):
    if not (a.isdigit() and b.isdigit()) or a.startswith("0"):
        return None, None
    return int(a), b


def cmd_check(a):
    pid, start = parse_pid(a[0], a[1])
    return 0 if pid and starttime(pid) == start else 1


def cmd_signal(a):
    pid, start = parse_pid(a[0], a[1])
    if not pid:
        return 1
    name = a[2].upper()
    name = name if name.startswith("SIG") else "SIG" + name
    sig = getattr(signal, name, None)
    if not isinstance(sig, signal.Signals):
        return 1
    try:
        pidfd = os.pidfd_open(pid)
    except OSError:
        return 1
    try:
        # The handle is bound to whatever holds this pid right now; the start
        # time says whether that is the process that was listed. A process
        # that exits after the check makes the send fail rather than hit a
        # successor.
        if starttime(pid) != start:
            return 1
        try:
            signal.pidfd_send_signal(pidfd, sig)
        except OSError:
            return 1
        return 0
    finally:
        os.close(pidfd)


def end_group(pid):
    """TERM the group, then KILL what is left after the grace period; reap the leader."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except OSError:
            pass
        limit = time.monotonic() + GRACE
        while time.monotonic() < limit:
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return
            if done:
                return
            time.sleep(0.05)


def cmd_run(a):
    if len(a) < 3 or a[2] != "--" or not a[0].isdigit():
        sys.stderr.write(__doc__)
        return 2
    cap, deadline, argv = int(a[0]), float(a[1]), a[3:]
    if not argv:
        return 2
    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.setsid()
            os.dup2(out_w, 1)
            os.dup2(err_w, 2)
            for fd in (out_r, out_w, err_r, err_w):
                os.close(fd)
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)
    os.close(out_w)
    os.close(err_w)
    out, err = bytearray(), bytearray()
    sel = selectors.DefaultSelector()
    sel.register(out_r, selectors.EVENT_READ, out)
    sel.register(err_r, selectors.EVENT_READ, err)
    limit = time.monotonic() + deadline
    status = None
    while sel.get_map():
        left = limit - time.monotonic()
        if left <= 0:
            status = 124
            break
        for key, _ in sel.select(timeout=left):
            chunk = os.read(key.fd, 65536)
            if not chunk:
                sel.unregister(key.fd)
                os.close(key.fd)
                continue
            key.data.extend(chunk)
            if key.data is out and len(out) > cap:
                status = 125
                break
            if key.data is err and len(err) > STDERR_CAP:
                del err[STDERR_CAP:]
        if status is not None:
            break
    if status is not None:
        end_group(pid)
        sys.stderr.buffer.write(err[:STDERR_CAP])
        sys.stderr.buffer.write(b"\nproc: output past the cap\n" if status == 125 else b"\nproc: past the deadline\n")
        return status
    # Both pipes reached EOF: the helper is done or has handed its descriptors
    # on. Wait for it, but not past the deadline: a lingering grandchild does
    # not hold the caller.
    while True:
        try:
            done, code = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            done, code = pid, 0
        if done:
            break
        if time.monotonic() > limit:
            end_group(pid)
            code = 124 << 8
            break
        time.sleep(0.02)
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(err[:STDERR_CAP])
    if os.WIFSIGNALED(code):
        return 128 + os.WTERMSIG(code)
    return os.WEXITSTATUS(code)


COMMANDS = {"run": (cmd_run, 3), "signal": (cmd_signal, 3), "check": (cmd_check, 2)}


def main(argv):
    if not argv or argv[0] not in COMMANDS or len(argv) - 1 < COMMANDS[argv[0]][1]:
        sys.stderr.write(__doc__)
        return 2
    return COMMANDS[argv[0]][0](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
