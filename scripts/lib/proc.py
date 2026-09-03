#!/usr/bin/env python3
"""Process handling for Portal's shell helpers.

  run <stdout-cap> <deadline> -- <argv...>
      Run argv in a session of its own. Its stdout is held up to the cap and
      its stderr up to 4096 bytes; past the cap, or past the deadline
      (seconds), the whole process group is ended (TERM, then KILL five
      seconds later) and nothing is passed on: exit 125 for overflow, 124 for
      the deadline, so a reader never parses a document that was cut short.
      TERM, INT, or HUP sent to this wrapper ends and reaps the group before
      returning 128 plus that signal. Otherwise the child's output and its
      own exit status are returned.
  signal <pid> <starttime> <SIG>
      Signal the process that is <pid> and started at <starttime> (kernel
      ticks, field 22 of /proc/<pid>/stat) through a pidfd, so a pid reused
      since the process was listed is never signaled. Exit 1 when refused.
  check <pid> <starttime>
      Exit 0 while that process exists, 1 otherwise.
  end <pid> <starttime>
      End and reap the process's session after validating its identity.

Runs as python3 -I -S: no environment or working directory redirects it.
"""
import os
import re
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
    if not re.fullmatch(r"[1-9][0-9]*", a) or not re.fullmatch(r"[0-9]+", b):
        return None, None
    pid = int(a)
    return (pid, b) if pid > 1 else (None, None)


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


def cmd_end(a):
    pid, start = parse_pid(a[0], a[1])
    if not pid or starttime(pid) != start:
        return 1
    end_group(pid)
    return 0 if starttime(pid) != start else 1


def end_group(pid):
    """TERM the whole group, and if anything is still in it after the grace
    period, KILL the group. The leader exiting does not end this: a descendant
    that inherited the pipes and ignores TERM is still a group member."""
    reaped = False

    def reap():
        nonlocal reaped
        if reaped:
            return
        try:
            if os.waitpid(pid, os.WNOHANG)[0]:
                reaped = True
        except ChildProcessError:
            reaped = True

    def group_gone():
        try:
            os.killpg(pid, 0)   # signal 0 sends nothing; it asks whether the group still has members
            return False
        except OSError:
            return True

    try:
        os.killpg(pid, signal.SIGTERM)
    except OSError:
        pass
    limit = time.monotonic() + GRACE
    while time.monotonic() < limit:
        reap()
        if group_gone():
            break
        time.sleep(0.05)
    else:
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass
    if not reaped:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


def cmd_run(a):
    if len(a) < 3 or a[2] != "--" or not a[0].isdigit():
        sys.stderr.write(__doc__)
        return 2
    cap, deadline, argv = int(a[0]), float(a[1]), a[3:]
    if not argv:
        return 2
    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    watched = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, watched)
    forwarded = [None]

    class ForwardedSignal(Exception):
        pass

    def forward(signum, _frame):
        if forwarded[0] is None:
            forwarded[0] = signum
            raise ForwardedSignal

    old_handlers = {}
    try:
        for sig in watched:
            old_handlers[sig] = signal.signal(sig, forward)
        pid = os.fork()
    except BaseException:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        for fd in (out_r, out_w, err_r, err_w):
            os.close(fd)
        raise
    if pid == 0:
        try:
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
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
    open_reads = {out_r, err_r}
    limit = time.monotonic() + deadline
    status = None
    reaped = False

    def close_reads():
        for fd in tuple(open_reads):
            try:
                sel.unregister(fd)
            except (KeyError, ValueError):
                pass
            try:
                os.close(fd)
            except OSError:
                pass
            open_reads.discard(fd)
        sel.close()

    try:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
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
                    open_reads.discard(key.fd)
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
            close_reads()
            end_group(pid)
            reaped = True
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
                reaped = True
                break
            if time.monotonic() > limit:
                close_reads()
                end_group(pid)
                reaped = True
                code = 124 << 8
                break
            time.sleep(0.02)
        sys.stdout.buffer.write(out)
        sys.stdout.buffer.flush()
        sys.stderr.buffer.write(err[:STDERR_CAP])
        if os.WIFSIGNALED(code):
            return 128 + os.WTERMSIG(code)
        return os.WEXITSTATUS(code)
    except ForwardedSignal:
        close_reads()
        if not reaped:
            end_group(pid)
            reaped = True
        return 128 + forwarded[0]
    except BaseException:
        close_reads()
        if not reaped:
            end_group(pid)
        raise
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, watched)
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


COMMANDS = {"run": (cmd_run, 3), "signal": (cmd_signal, 3), "check": (cmd_check, 2), "end": (cmd_end, 2)}


def main(argv):
    if not argv or argv[0] not in COMMANDS or len(argv) - 1 < COMMANDS[argv[0]][1]:
        sys.stderr.write(__doc__)
        return 2
    return COMMANDS[argv[0]][0](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
