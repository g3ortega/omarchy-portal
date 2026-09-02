#!/usr/bin/env python3
"""Descriptor-relative state files for Portal's shell helpers.

Every state path Portal touches is predictable, so nothing here trusts a
pathname twice. A directory is reached by walking every component from `/`
with O_DIRECTORY|O_NOFOLLOW, and the final directory must be a real directory
the current user owns that nobody else can write to. A leaf is opened
relative to that directory with O_NOFOLLOW|O_NONBLOCK (a planted FIFO cannot
block, a link is refused), then fstat decides: regular, ours, one link, under
the byte cap. Writes create a random adjacent temporary with O_CREAT|O_EXCL
mode 0600, fsync it, renameat it into place and fsync the directory. Appends
and truncation go through the validated descriptor, never the path again.

  ensure   <dir>...                       create (0700) and verify directories
  dump     <dir> [maxbytes] [maxfiles] [name...]  JSON {"files":{name:text}} of every leaf, or only the named ones
  read     <path> [maxbytes]              raw bytes to stdout
  write    <path> [mode]                  stdin -> atomic replace
  append   <path> <maxlines> [maxbytes]   stdin lines -> descriptor append, trimmed
  append-many <dir> <maxlines> <maxbytes> stdin rows "<name>\t<line>" -> one append each
  remove   <dir> <name>...                unlink leaves (never directories)
  truncate <path> <maxbytes>              empty the file once it is past the cap
  launch   <dir> <logname> -- <argv...>   daemonize argv with the log as stdio;
                                          prints "pid starttime"

Exit status 0 on success, 1 when a path is refused, 2 on usage; every refusal
fails closed with nothing read or written. Runs under the caller's timeout.
"""
import fcntl
import os
import stat
import sys

UID = os.getuid()
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
LEAF_FLAGS = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
MAX_FILES = 512
MAX_BYTES = 1 << 20
WRITE_CAP = 128 << 20   # the largest thing ever written: a provider binary


class Refused(Exception):
    pass


def open_dir(path, create=False):
    """Walk from / component by component; return an fd for the final directory."""
    path = os.path.abspath(path)
    fd = os.open("/", DIR_FLAGS)
    try:
        for comp in [c for c in path.split("/") if c]:
            try:
                nfd = os.open(comp, DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise Refused(f"missing: {path}")
                os.mkdir(comp, 0o700, dir_fd=fd)
                nfd = os.open(comp, DIR_FLAGS, dir_fd=fd)
            except OSError as e:
                raise Refused(f"refused {path}: {e.strerror} at {comp}")
            os.close(fd)
            fd = nfd
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != UID or (st.st_mode & 0o022):
            raise Refused(f"not a private directory of yours: {path}")
        return fd
    except BaseException:
        os.close(fd)
        raise


def split(path):
    path = os.path.abspath(path)
    d, name = os.path.split(path)
    if not name or name in (".", ".."):
        raise Refused(f"not a file path: {path}")
    return d, name


def open_leaf(dirfd, name, flags, cap):
    """Open a leaf relative to a verified directory and bind it: regular, ours, single link, capped."""
    try:
        fd = os.open(name, flags | LEAF_FLAGS, dir_fd=dirfd)
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Refused(f"refused {name}: {e.strerror}")
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != UID or st.st_nlink != 1 or st.st_size > cap:
        os.close(fd)
        raise Refused(f"refused {name}: not a plain owned file under the cap")
    return fd


def read_leaf(dirfd, name, cap):
    """The bytes of a bound leaf, or None when there is no such file."""
    fd = open_leaf(dirfd, name, os.O_RDONLY, cap)
    if fd is None:
        return None
    try:
        return read_fd(fd, cap)
    finally:
        os.close(fd)


def read_fd(fd, cap):
    out = bytearray()
    while len(out) <= cap:
        chunk = os.read(fd, min(65536, cap + 1 - len(out)))
        if not chunk:
            break
        out += chunk
    if len(out) > cap:
        raise Refused("refused: grew past the cap while reading")
    return bytes(out)


def atomic_write(dirfd, name, data, mode=0o600):
    """data is bytes, or a callable that writes to the descriptor and returns the byte count."""
    tmp = f".{name}.{os.urandom(8).hex()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dirfd)
    try:
        if callable(data):
            data(fd)
        else:
            view = memoryview(data)
            while view:
                n = os.write(fd, view)
                view = view[n:]
        os.fsync(fd)
        os.fchmod(fd, mode)
        os.close(fd)
        os.rename(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        os.fsync(dirfd)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(tmp, dir_fd=dirfd)
        except OSError:
            pass
        raise


def cmd_ensure(a):
    for d in a:
        os.close(open_dir(d, create=True))


def cmd_dump(a):
    import json
    cap = int(a[1]) if len(a) > 1 else MAX_BYTES
    maxfiles = int(a[2]) if len(a) > 2 else MAX_FILES
    dirfd = open_dir(a[0], create=True)
    try:
        names = sorted(os.listdir(dirfd))
        if len(names) > maxfiles:
            raise Refused(f"refused: more than {maxfiles} entries in {a[0]}")
        if len(a) > 3:
            names = [n for n in names if n in a[3:]]
        files = {}
        for name in names:
            try:
                data = read_leaf(dirfd, name, cap)
            except Refused:
                continue          # a directory, link, FIFO or oversized file is simply not state
            if data is not None:
                files[name] = data.decode("utf-8", "replace")
        sys.stdout.write(json.dumps({"files": files}))
    finally:
        os.close(dirfd)


def cmd_read(a):
    cap = int(a[1]) if len(a) > 1 else MAX_BYTES
    d, name = split(a[0])
    dirfd = open_dir(d)
    try:
        data = read_leaf(dirfd, name, cap)
        if data is None:
            return 1
        sys.stdout.buffer.write(data)
    finally:
        os.close(dirfd)


def cmd_write(a):
    mode = int(a[1], 8) if len(a) > 1 else 0o600
    d, name = split(a[0])

    def copy_stdin(fd):
        total = 0
        while True:
            chunk = sys.stdin.buffer.read(1 << 20)
            if not chunk:
                return total
            total += len(chunk)
            if total > WRITE_CAP:
                raise Refused("refused: content past the cap")
            view = memoryview(chunk)
            while view:
                view = view[os.write(fd, view):]

    dirfd = open_dir(d, create=True)
    try:
        atomic_write(dirfd, name, copy_stdin, mode)
    finally:
        os.close(dirfd)


def append_one(dirfd, name, data, maxlines, cap):
    try:
        fd = open_leaf(dirfd, name, os.O_WRONLY | os.O_APPEND, cap * 2)
    except Refused:
        fd = None   # not a sample file of ours: replaced, never appended to
    if fd is None:
        atomic_write(dirfd, name, data)
        size = len(data)
    else:
        try:
            os.write(fd, data)
            size = os.fstat(fd).st_size
        finally:
            os.close(fd)
    # A file too small to hold maxlines lines (three bytes is the shortest)
    # needs no count; past that the count is read. Past the byte cap or the
    # line cap, keep the newest lines that fit, so the file is never past
    # either after a call and a reader needs no margin.
    if size <= cap and size < maxlines * 3:
        return
    body = read_leaf(dirfd, name, cap * 2 + len(data)) or b""
    if size <= cap and body.count(b"\n") <= maxlines:
        return
    lines = body.splitlines(keepends=True)
    lines = lines[-maxlines:]
    while lines and sum(map(len, lines)) > cap:
        lines.pop(0)
    atomic_write(dirfd, name, b"".join(lines))


def cmd_append(a):
    maxlines = int(a[1])
    cap = int(a[2]) if len(a) > 2 else 8 * MAX_BYTES
    d, name = split(a[0])
    data = sys.stdin.buffer.read(cap + 1)
    if len(data) > cap:
        raise Refused("refused: content past the cap")
    dirfd = open_dir(d, create=True)
    try:
        fcntl.flock(dirfd, fcntl.LOCK_EX)   # appends in one directory take turns; a trim replaces the file
        append_one(dirfd, name, data, maxlines, cap)
    finally:
        os.close(dirfd)


def cmd_append_many(a):
    maxlines, cap = int(a[1]), int(a[2])
    batch = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(batch) > MAX_BYTES:
        raise Refused("refused: batch past the cap")
    dirfd = open_dir(a[0], create=True)
    try:
        fcntl.flock(dirfd, fcntl.LOCK_EX)   # see cmd_append
        for row in batch.splitlines():
            name, _, line = row.partition(b"\t")
            if not name or b"/" in name or name in (b".", b"..") or not line:
                raise Refused(f"refused row: {row[:64]!r}")
            append_one(dirfd, name.decode(), line + b"\n", maxlines, cap)
    finally:
        os.close(dirfd)


def cmd_remove(a):
    dirfd = open_dir(a[0])
    try:
        for name in a[1:]:
            if "/" in name or name in (".", ".."):
                raise Refused(f"refused name: {name}")
            try:
                st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if stat.S_ISDIR(st.st_mode):
                continue
            os.unlink(name, dir_fd=dirfd)
    finally:
        os.close(dirfd)


def cmd_truncate(a):
    cap = int(a[1])
    d, name = split(a[0])
    dirfd = open_dir(d)
    try:
        fd = open_leaf(dirfd, name, os.O_WRONLY, 1 << 40)
        if fd is None:
            return
        try:
            if os.fstat(fd).st_size > cap:
                os.ftruncate(fd, 0)
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)


def cmd_launch(a):
    if len(a) < 4 or a[2] != "--":
        raise Refused("usage: launch <dir> <logname> -- <argv...>")
    d, logname, argv = a[0], a[1], a[3:]
    if not argv or not os.path.isabs(argv[0]):
        raise Refused("launch needs an absolute executable path")
    dirfd = open_dir(d, create=True)
    try:
        # A fresh, exclusive, private log; then a session of its own with that log as stdio.
        try:
            os.unlink(logname, dir_fd=dirfd)
        except FileNotFoundError:
            pass
        logfd = os.open(logname, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_APPEND, 0o600, dir_fd=dirfd)
        os.set_inheritable(logfd, True)
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(r)
                os.setsid()
                devnull = os.open(os.devnull, os.O_RDONLY)
                os.dup2(devnull, 0)
                os.dup2(logfd, 1)
                os.dup2(logfd, 2)
                os.write(w, b"1")
                os.close(w)
                os.execv(argv[0], argv)
            finally:
                os._exit(127)
        os.close(w)
        os.read(r, 1)     # the child has its session before we report it
        os.close(r)
        os.close(logfd)
        with open(f"/proc/{pid}/stat", "rb") as f:
            fields = f.read().rsplit(b")", 1)[1].split()
        sys.stdout.write(f"{pid} {fields[19].decode()}")
    finally:
        os.close(dirfd)


COMMANDS = {
    "ensure": (cmd_ensure, 1), "dump": (cmd_dump, 1), "read": (cmd_read, 1), "write": (cmd_write, 1),
    "append": (cmd_append, 2), "append-many": (cmd_append_many, 3), "remove": (cmd_remove, 2),
    "truncate": (cmd_truncate, 2), "launch": (cmd_launch, 4),
}


def main(argv):
    if not argv or argv[0] not in COMMANDS or len(argv) - 1 < COMMANDS[argv[0]][1]:
        sys.stderr.write(__doc__)
        return 2
    try:
        return COMMANDS[argv[0]][0](argv[1:]) or 0
    except Refused as e:
        sys.stderr.write(f"statedir: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
