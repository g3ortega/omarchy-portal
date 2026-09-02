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

  ensure   <dir>                          create (0700) and verify a directory
  dump     <dir> [maxbytes] [maxfiles]    JSON {"files":{name:text}} of every leaf
  read     <path> [maxbytes]              raw bytes to stdout
  write    <path> [mode]                  stdin -> atomic replace
  append   <path> <maxlines> [maxbytes]   stdin lines -> descriptor append, trimmed
  remove   <dir> <name>...                unlink leaves (never directories)
  truncate <path> <maxbytes>              empty the file once it is past the cap
  launch   <dir> <logname> -- <argv...>   daemonize argv with the log as stdio;
                                          prints "pid starttime"

Exit status 0 on success, 1 when a path is refused, 2 on usage; every refusal
fails closed with nothing read or written. Runs under the caller's timeout.
"""
import json
import os
import secrets
import stat
import sys

UID = os.getuid()
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
LEAF_FLAGS = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
MAX_FILES = 512
MAX_BYTES = 1 << 20


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
    tmp = f".{name}.{secrets.token_hex(8)}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dirfd)
    try:
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fsync(fd)
        if mode != 0o600:
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
    os.close(open_dir(a[0], create=True))


def cmd_dump(a):
    cap = int(a[1]) if len(a) > 1 else MAX_BYTES
    maxfiles = int(a[2]) if len(a) > 2 else MAX_FILES
    dirfd = open_dir(a[0])
    try:
        names = sorted(os.listdir(dirfd))
        if len(names) > maxfiles:
            raise Refused(f"refused: more than {maxfiles} entries in {a[0]}")
        files = {}
        for name in names:
            try:
                fd = open_leaf(dirfd, name, os.O_RDONLY, cap)
            except Refused:
                continue          # a directory, link, FIFO or oversized file is simply not state
            if fd is None:
                continue
            try:
                files[name] = read_fd(fd, cap).decode("utf-8", "replace")
            finally:
                os.close(fd)
        sys.stdout.write(json.dumps({"files": files}))
    finally:
        os.close(dirfd)


def cmd_read(a):
    cap = int(a[1]) if len(a) > 1 else MAX_BYTES
    d, name = split(a[0])
    dirfd = open_dir(d)
    try:
        fd = open_leaf(dirfd, name, os.O_RDONLY, cap)
        if fd is None:
            return 1
        try:
            sys.stdout.buffer.write(read_fd(fd, cap))
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)


def cmd_write(a):
    mode = int(a[1], 8) if len(a) > 1 else 0o600
    d, name = split(a[0])
    data = sys.stdin.buffer.read(MAX_BYTES * 128 + 1)
    if len(data) > MAX_BYTES * 128:
        raise Refused("refused: content past the cap")
    dirfd = open_dir(d, create=True)
    try:
        atomic_write(dirfd, name, data, mode)
    finally:
        os.close(dirfd)


def cmd_append(a):
    maxlines = int(a[1])
    cap = int(a[2]) if len(a) > 2 else 8 * MAX_BYTES
    d, name = split(a[0])
    data = sys.stdin.buffer.read(cap + 1)
    if len(data) > cap:
        raise Refused("refused: content past the cap")
    dirfd = open_dir(d, create=True)
    try:
        try:
            fd = open_leaf(dirfd, name, os.O_WRONLY | os.O_APPEND, cap * 2)
        except Refused:
            # Whatever is there is not a sample file of ours (or is far past the
            # cap): it is replaced by the new samples, never appended to.
            atomic_write(dirfd, name, data)
            return
        if fd is None:
            atomic_write(dirfd, name, data)
            return
        try:
            os.write(fd, data)
            size = os.fstat(fd).st_size
        finally:
            os.close(fd)
        if size <= cap:
            return
        # Past the cap: keep the newest lines, through a fresh bound read and an atomic replace.
        fd = open_leaf(dirfd, name, os.O_RDONLY, cap * 2)
        if fd is None:
            return
        try:
            lines = read_fd(fd, cap * 2).splitlines(keepends=True)
        finally:
            os.close(fd)
        atomic_write(dirfd, name, b"".join(lines[-maxlines:]))
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
    if "--" not in a:
        raise Refused("usage: launch <dir> <logname> -- <argv...>")
    sep = a.index("--")
    d, logname, argv = a[0], a[1], a[sep + 1:]
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
    "append": (cmd_append, 2), "remove": (cmd_remove, 2), "truncate": (cmd_truncate, 2), "launch": (cmd_launch, 4),
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        sys.stderr.write(__doc__)
        return 2
    fn, arity = COMMANDS[argv[0]]
    if len(argv) - 1 < arity:
        sys.stderr.write(__doc__)
        return 2
    try:
        return fn(argv[1:]) or 0
    except Refused as e:
        sys.stderr.write(f"statedir: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
