#!/usr/bin/env python3
"""Descriptor-relative state files for Portal's shell helpers.

Every state path Portal touches is predictable, so nothing here trusts a
pathname twice. A directory is reached by walking every component from `/`
with O_DIRECTORY|O_NOFOLLOW, and the final directory must be a real directory
the current user owns that nobody else can write to. A leaf is opened
relative to that directory with O_NOFOLLOW|O_NONBLOCK (a planted FIFO cannot
block, a link is refused), then fstat decides: regular, ours, writable by nobody
else, one link, under the byte cap. Writes create a random adjacent temporary with O_CREAT|O_EXCL
mode 0600, fsync it, renameat it into place and fsync the directory. Appends
and truncation go through the validated descriptor, never the path again.

  ensure   <dir>...                       create (0700) and verify directories
  dump     <dir> [maxbytes] [maxfiles] [name...]  JSON {"files":{name:text}} of every leaf, or only the named ones
  read     <path> [maxbytes]              raw bytes to stdout
  write    <path> [mode]                  stdin -> atomic replace
  create   <path> [mode]                  stdin -> atomic no-replace create
  append   <path> <maxlines> [maxbytes]   stdin lines -> descriptor append, trimmed
  append-many <dir> <maxlines> <maxbytes> stdin rows "<name>\t<line>" -> one append each
  remove   <dir> <name>...                unlink leaves (never directories)
  remove-digest <dir> <name> <sha256> <maxbytes>  remove only the bound matching file
  truncate <path> <maxbytes>              empty the file once it is past the cap
  lock     <dir> <nowait|wait> <name> -- <argv...>  run argv under a stable lock
  lock-clean <dir> <nowait|wait> <name> [--prune-to <dir>] -- <argv...> run argv; remove empty lock roots after success
  launch   <dir> <logname> -- <argv...>   daemonize argv with the log as stdio;
                                           prints "pid starttime". The executable
                                           is walked to by descriptor (every
                                           directory root's or ours, swappable by
                                           nobody else) and executed by descriptor.
  launch-tracked <dir> <logname> <pidname> -- <argv...>
                                           launch only after the pid record is durable.
                                           The log name may instead be
                                           --discard-output: stdio then goes to
                                           /dev/null and no log leaf is created

Most commands exit 0 on success, 1 when refused, and 2 on top-level usage.
Lock commands return 75 on nowait contention and otherwise return their child's status.
Every refusal fails closed. Runs under the caller's timeout.
"""
import errno
import fcntl
import hashlib
import os
import stat
import sys
import time

UID = os.getuid()
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
LEAF_FLAGS = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
MAX_FILES = 512
MAX_BYTES = 1 << 20
WRITE_CAP = 128 << 20   # the largest thing ever written: a provider binary


class Refused(Exception):
    pass


def swappable(st):
    """A directory whose entries another user could rename: not root's or ours,
    or group/other-writable without the sticky bit."""
    return st.st_uid not in (0, UID) or ((st.st_mode & 0o022) and not (st.st_mode & stat.S_ISVTX))


def open_dir(path, create=False):
    """Walk from / component by component; return an fd for the final directory.
    Every ancestor must be root's or ours and not renamable by another user, so
    no component of the path can be swapped between two helper calls; the final
    directory must be private to us."""
    path = os.path.abspath(path)
    comps = [c for c in path.split("/") if c]
    fd = os.open("/", DIR_FLAGS)
    try:
        for i, comp in enumerate(comps):
            try:
                nfd = os.open(comp, DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise Refused(f"missing: {path}")
                try:
                    os.mkdir(comp, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass          # another helper created it first; open what is there
                nfd = os.open(comp, DIR_FLAGS, dir_fd=fd)
            except OSError as e:
                raise Refused(f"refused {path}: {e.strerror} at {comp}")
            os.close(fd)
            fd = nfd
            if i < len(comps) - 1 and swappable(os.fstat(fd)):
                raise Refused(f"refused {path}: an ancestor is writable by others: /{'/'.join(comps[:i + 1])}")
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


def check_name(name, kind="name"):
    if not name or "/" in name or name in (".", ".."):
        raise Refused(f"refused {kind}: {name}")
    return name


def open_leaf(dirfd, name, flags, cap):
    """Open a leaf relative to a verified directory and bind it: regular, ours, writable by nobody else, single link, capped."""
    try:
        fd = os.open(name, flags | LEAF_FLAGS, dir_fd=dirfd)
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Refused(f"refused {name}: {e.strerror}")
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != UID or (st.st_mode & 0o022) or st.st_nlink != 1 or st.st_size > cap:
        os.close(fd)
        raise Refused(f"refused {name}: not a plain owned file, writable by nobody else, under the cap")
    return fd


def open_lock(dirfd, name):
    check_name(name, "lock name")
    try:
        fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dirfd)
    except OSError as e:
        raise Refused(f"refused {name}: {e.strerror}")
    st = os.fstat(fd)
    try:
        current = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    except OSError as e:
        os.close(fd)
        raise Refused(f"refused {name}: {e.strerror}")
    if (not stat.S_ISREG(st.st_mode) or st.st_uid != UID or (st.st_mode & 0o022)
            or st.st_nlink != 1 or (st.st_dev, st.st_ino) != (current.st_dev, current.st_ino)):
        os.close(fd)
        raise Refused(f"refused {name}: not a stable plain owned lock file")
    return fd


def lock_entry_current(dirfd, name, lockfd):
    held = os.fstat(lockfd)
    if held.st_nlink == 0:
        return False
    if (not stat.S_ISREG(held.st_mode) or held.st_uid != UID
            or (held.st_mode & 0o022) or held.st_nlink != 1):
        raise Refused(f"refused {name}: not a stable plain owned lock file")
    try:
        current = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError as e:
        raise Refused(f"refused {name}: {e.strerror}")
    if (not stat.S_ISREG(current.st_mode) or current.st_uid != UID
            or (current.st_mode & 0o022) or current.st_nlink != 1):
        raise Refused(f"refused {name}: not a stable plain owned lock file")
    return (held.st_dev, held.st_ino) == (current.st_dev, current.st_ino)


def open_lock_parent(path, dirfd):
    dirname = os.path.basename(os.path.abspath(path))
    if not dirname:
        raise Refused("refused lock at filesystem root")
    try:
        parentfd = os.open("..", DIR_FLAGS, dir_fd=dirfd)
    except OSError as e:
        raise Refused(f"could not bind the lock directory parent: {e.strerror}")
    if swappable(os.fstat(parentfd)):
        os.close(parentfd)
        raise Refused("refused lock through a swappable parent")
    return parentfd, dirname


def lock_root_current(parentfd, dirname, dirfd):
    bound = os.fstat(dirfd)
    if bound.st_nlink == 0:
        return False
    if (not stat.S_ISDIR(bound.st_mode) or bound.st_uid != UID
            or (bound.st_mode & 0o022)):
        raise Refused("refused lock for a non-private directory")
    try:
        current = os.stat(dirname, dir_fd=parentfd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError as e:
        raise Refused(f"could not verify the lock directory: {e.strerror}")
    if (not stat.S_ISDIR(current.st_mode) or current.st_uid != UID
            or (current.st_mode & 0o022)):
        raise Refused("refused lock for a non-private directory")
    return (bound.st_dev, bound.st_ino) == (current.st_dev, current.st_ino)


def lock_namespace(dirfd, mode, cleanup=False):
    if mode == "wait":
        fcntl.flock(dirfd, fcntl.LOCK_EX)
        return True
    attempts = 100 if cleanup else 1
    for attempt in range(attempts):
        try:
            fcntl.flock(dirfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if attempt + 1 < attempts:
                time.sleep(0.01)
    return False


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


def write_all(fd, data):
    """Every byte, however many calls it takes: a short write is not a write."""
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


def hash_fd(fd, cap):
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = os.read(fd, min(65536, cap + 1 - total))
        if not chunk:
            return digest.hexdigest()
        total += len(chunk)
        if total > cap:
            raise Refused("refused: grew past the cap while hashing")
        digest.update(chunk)


def atomic_write(dirfd, name, data, mode=0o600, replace=True):
    """data is bytes, or a callable that writes to the descriptor and returns the byte count."""
    tmp = f".{name}.{os.urandom(8).hex()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dirfd)
    try:
        if callable(data):
            data(fd)
        else:
            write_all(fd, data)
        os.fsync(fd)
        os.fchmod(fd, mode)
        os.close(fd)
        if replace:
            os.rename(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        else:
            try:
                rename_noreplace(dirfd, tmp, name)
            except FileExistsError:
                raise Refused(f"refused {name}: already exists")
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


def open_exe(path):
    """Walk to an executable and bind it: every directory on the way is root's
    or ours and nobody else can rename its entries (not group/other writable,
    or sticky); the file is regular, root's or ours, not writable by others,
    executable. The descriptor is what gets executed."""
    path = os.path.abspath(path)
    parts = [c for c in path.split("/") if c]
    if not parts:
        raise Refused("not an executable path")

    fd = os.open("/", DIR_FLAGS)
    try:
        for comp in parts[:-1]:
            if swappable(os.fstat(fd)):
                raise Refused(f"refused {path}: a directory on the way is not root's or yours alone")
            try:
                nfd = os.open(comp, DIR_FLAGS, dir_fd=fd)
            except OSError as e:
                raise Refused(f"refused {path}: {e.strerror} at {comp}")
            os.close(fd)
            fd = nfd
        if swappable(os.fstat(fd)):
            raise Refused(f"refused {path}: its directory is not root's or yours alone")
        try:
            efd = os.open(parts[-1], os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
        except OSError as e:
            raise Refused(f"refused {path}: {e.strerror}")
    finally:
        os.close(fd)
    st = os.fstat(efd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid not in (0, UID) or (st.st_mode & 0o022) or not (st.st_mode & 0o111):
        os.close(efd)
        raise Refused(f"refused {path}: not a plain executable of root's or yours")
    return efd


def process_starttime(pid):
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            fields = f.read().rsplit(b")", 1)[1].split()
    except (OSError, IndexError):
        raise Refused("launched process disappeared before it could be recorded")
    if len(fields) <= 19 or not fields[19].isdigit():
        raise Refused("launched process has no valid start time")
    return fields[19].decode()


def close_unrelated(keep):
    for name in os.listdir("/proc/self/fd"):
        if name.isdigit() and int(name) not in keep:
            try:
                os.close(int(name))
            except OSError:
                pass


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
        refused = []
        for name in names:
            try:
                data = read_leaf(dirfd, name, cap)
            except Refused:
                refused.append(name)
                continue          # a directory, link, FIFO or oversized file is simply not state
            if data is not None:
                files[name] = data.decode("utf-8", "replace")
        sys.stdout.write(json.dumps({"files": files, "refused": refused}))
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


def copy_stdin(fd):
    total = 0
    while True:
        chunk = sys.stdin.buffer.read(1 << 20)
        if not chunk:
            return total
        total += len(chunk)
        if total > WRITE_CAP:
            raise Refused("refused: content past the cap")
        write_all(fd, chunk)


def cmd_write(a):
    mode = int(a[1], 8) if len(a) > 1 else 0o600
    d, name = split(a[0])
    dirfd = open_dir(d, create=True)
    try:
        atomic_write(dirfd, name, copy_stdin, mode)
    finally:
        os.close(dirfd)


def cmd_create(a):
    mode = int(a[1], 8) if len(a) > 1 else 0o600
    d, name = split(a[0])
    dirfd = open_dir(d, create=True)
    try:
        atomic_write(dirfd, name, copy_stdin, mode, replace=False)
    finally:
        os.close(dirfd)


def acquire_lock(path, mode, name):
    flags = fcntl.LOCK_EX | (fcntl.LOCK_NB if mode == "nowait" else 0)
    # A cleanup owner can retire a lock while a waiter still has that inode
    # open. Only the current root and lock entries serialize new callers.
    for _ in range(16):
        dirfd = open_dir(path, create=True)
        lockfd = None
        keep = False
        try:
            parentfd, dirname = open_lock_parent(path, dirfd)
            try:
                if not lock_namespace(parentfd, mode):
                    return None
                if not lock_root_current(parentfd, dirname, dirfd):
                    continue
                lockfd = open_lock(dirfd, name)
            finally:
                os.close(parentfd)
            try:
                fcntl.flock(lockfd, flags)
            except BlockingIOError:
                return None
            parentfd, dirname = open_lock_parent(path, dirfd)
            try:
                if not lock_namespace(parentfd, mode):
                    return None
                current = (lock_root_current(parentfd, dirname, dirfd)
                           and lock_entry_current(dirfd, name, lockfd))
            finally:
                os.close(parentfd)
            if current:
                keep = True
                return dirfd, lockfd
        finally:
            if not keep:
                if lockfd is not None:
                    os.close(lockfd)
                os.close(dirfd)
    raise Refused(f"refused {name}: lock namespace did not stabilize")


def lock_prune_intermediates(path, prune_to):
    path = os.path.abspath(path)
    prune_to = os.path.abspath(prune_to)
    if path == prune_to or not path.startswith(prune_to.rstrip(os.sep) + os.sep):
        raise Refused("lock cleanup boundary is not an ancestor")
    return os.path.relpath(path, prune_to).split(os.sep)[:-1]


def prune_lock_parents(intermediates, parentfd, mode):
    currentfd = os.dup(parentfd)
    grandfd = None
    try:
        for dirname in reversed(intermediates):
            try:
                grandfd = os.open("..", DIR_FLAGS, dir_fd=currentfd)
            except OSError as e:
                raise Refused(f"could not bind a nested state parent: {e.strerror}")
            locked = False
            try:
                if swappable(os.fstat(grandfd)):
                    raise Refused("refused nested state cleanup through a swappable parent")
                if not lock_namespace(grandfd, mode, cleanup=True):
                    raise Refused("nested state directory namespace is busy")
                locked = True
                if not lock_root_current(grandfd, dirname, currentfd):
                    raise Refused("nested state directory changed before cleanup")
                try:
                    os.rmdir(dirname, dir_fd=grandfd)
                except OSError as e:
                    if e.errno == errno.ENOENT and os.fstat(currentfd).st_nlink == 0:
                        pass
                    elif e.errno in (errno.ENOTEMPTY, errno.EEXIST):
                        return
                    else:
                        raise Refused(f"could not remove empty nested state directory {dirname}: {e.strerror}")
                if os.fstat(currentfd).st_nlink != 0:
                    raise Refused(f"could not verify removal of nested state directory {dirname}")
                try:
                    os.fsync(grandfd)
                except OSError as e:
                    raise Refused(f"could not sync nested state cleanup: {e.strerror}")
            finally:
                if locked:
                    fcntl.flock(grandfd, fcntl.LOCK_UN)
            os.close(currentfd)
            currentfd = grandfd
            grandfd = None
    finally:
        if grandfd is not None:
            os.close(grandfd)
        os.close(currentfd)


def cleanup_lock(path, mode, name, dirfd, lockfd, intermediates=None):
    parentfd, dirname = open_lock_parent(path, dirfd)
    try:
        if not lock_namespace(parentfd, mode, cleanup=True):
            raise Refused("lock directory namespace is busy")
        if not lock_root_current(parentfd, dirname, dirfd):
            raise Refused("lock directory changed before cleanup")
        if not lock_entry_current(dirfd, name, lockfd):
            raise Refused(f"refused {name}: lock changed before cleanup")
        try:
            os.unlink(name, dir_fd=dirfd)
        except OSError as e:
            raise Refused(f"could not remove {name}: {e.strerror}")
        if os.fstat(lockfd).st_nlink != 0:
            raise Refused(f"could not verify removal of {name}")
        try:
            os.fsync(dirfd)
        except OSError as e:
            raise Refused(f"could not sync lock removal: {e.strerror}")
        if not lock_root_current(parentfd, dirname, dirfd):
            raise Refused("lock directory changed during cleanup")
        try:
            os.rmdir(dirname, dir_fd=parentfd)
        except OSError as e:
            if e.errno in (errno.ENOTEMPTY, errno.EEXIST):
                return
            raise Refused(f"could not remove the empty lock directory: {e.strerror}")
        if os.fstat(dirfd).st_nlink != 0:
            raise Refused("could not verify removal of the lock directory")
        try:
            os.fsync(parentfd)
        except OSError as e:
            raise Refused(f"could not sync lock directory removal: {e.strerror}")
        if intermediates is not None:
            fcntl.flock(parentfd, fcntl.LOCK_UN)
            prune_lock_parents(intermediates, parentfd, mode)
    finally:
        os.close(parentfd)


def run_locked(a, clean):
    prune_to = None
    if len(a) >= 5 and a[1] in ("nowait", "wait") and a[3] == "--":
        argv = a[4:]
    elif clean and len(a) >= 7 and a[1] in ("nowait", "wait") and a[3] == "--prune-to" and a[5] == "--":
        prune_to = a[4]
        argv = a[6:]
    else:
        verb = "lock-clean <dir> <nowait|wait> <name> [--prune-to <dir>]" if clean else "lock <dir> <nowait|wait> <name>"
        raise Refused(f"usage: {verb} -- <argv...>")
    if not os.path.isabs(argv[0]):
        raise Refused("lock needs an absolute command path")
    intermediates = lock_prune_intermediates(a[0], prune_to) if prune_to is not None else None
    held = acquire_lock(a[0], a[1], a[2])
    if held is None:
        return 75
    dirfd, lockfd = held
    try:
        import subprocess
        try:
            result = subprocess.run(argv, close_fds=True)
        except OSError as e:
            raise Refused(f"could not run {argv[0]}: {e.strerror}")
        code = result.returncode if result.returncode >= 0 else 128 - result.returncode
        if clean and code == 0:
            cleanup_lock(a[0], a[1], a[2], dirfd, lockfd, intermediates)
        return code
    finally:
        os.close(dirfd)
        os.close(lockfd)


def cmd_lock(a):
    return run_locked(a, False)


def cmd_lock_clean(a):
    return run_locked(a, True)


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
            write_all(fd, data)
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
        try:
            fcntl.flock(dirfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused("append directory is busy")
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
        try:
            fcntl.flock(dirfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused("append directory is busy")
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


def rename_noreplace(dirfd, old, new):
    import ctypes
    try:
        call = ctypes.CDLL(None, use_errno=True).renameat2
    except AttributeError:
        raise OSError(errno.ENOSYS, "renameat2 is unavailable")
    call.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    call.restype = ctypes.c_int
    if call(dirfd, os.fsencode(old), dirfd, os.fsencode(new), 1) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def refuse_quarantine(dirfd, quarantine, name, reason):
    try:
        rename_noreplace(dirfd, quarantine, name)
    except OSError as e:
        raise Refused(f"{reason}; could not restore {quarantine}: {e.strerror}")
    try:
        os.fsync(dirfd)
    except OSError as e:
        raise Refused(f"{reason}; restored {name} but could not sync its directory: {e.strerror}")
    raise Refused(reason)


def cmd_remove_digest(a):
    if len(a) != 4:
        raise Refused("usage: remove-digest <dir> <name> <sha256> <maxbytes>")
    name = check_name(a[1])
    expected = a[2].lower()
    if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        raise Refused("invalid sha256 digest")
    try:
        cap = int(a[3])
    except ValueError:
        raise Refused("invalid byte cap")
    if cap < 0 or cap > WRITE_CAP:
        raise Refused("invalid byte cap")

    dirfd = open_dir(a[0])
    fd = None
    try:
        fd = open_leaf(dirfd, name, os.O_RDONLY, cap)
        if fd is None:
            raise Refused(f"missing: {name}")
        opened = os.fstat(fd)
        if hash_fd(fd, cap) != expected:
            raise Refused(f"digest mismatch: {name}")

        quarantine = None
        for _ in range(16):
            candidate = f".remove-{os.urandom(16).hex()}"
            try:
                rename_noreplace(dirfd, name, candidate)
                quarantine = candidate
                break
            except FileExistsError:
                continue
            except OSError as e:
                raise Refused(f"could not quarantine {name}: {e.strerror}")
        if quarantine is None:
            raise Refused(f"could not quarantine {name}")

        try:
            moved = os.stat(quarantine, dir_fd=dirfd, follow_symlinks=False)
        except OSError as e:
            refuse_quarantine(dirfd, quarantine, name, f"could not bind quarantined {name}: {e.strerror}")
        if (moved.st_dev, moved.st_ino) != (opened.st_dev, opened.st_ino):
            refuse_quarantine(dirfd, quarantine, name, f"candidate changed while removing {name}")
        try:
            same_digest = hash_fd(fd, cap) == expected
        except Refused as e:
            refuse_quarantine(dirfd, quarantine, name, str(e))
        if not same_digest or os.fstat(fd).st_nlink != 1:
            refuse_quarantine(dirfd, quarantine, name, f"candidate changed while removing {name}")
        try:
            final = os.stat(quarantine, dir_fd=dirfd, follow_symlinks=False)
        except OSError as e:
            refuse_quarantine(dirfd, quarantine, name, f"could not recheck quarantined {name}: {e.strerror}")
        if (final.st_dev, final.st_ino) != (opened.st_dev, opened.st_ino):
            refuse_quarantine(dirfd, quarantine, name, f"quarantine changed while removing {name}")
        try:
            os.unlink(quarantine, dir_fd=dirfd)
        except OSError as e:
            refuse_quarantine(dirfd, quarantine, name, f"could not remove {name}: {e.strerror}")
        if os.fstat(fd).st_nlink != 0:
            raise Refused(f"removed name but inode is still linked: {name}")
        os.fsync(dirfd)
    finally:
        if fd is not None:
            os.close(fd)
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


def launch_process(d, logname, pidname, argv, executable=None):
    discard = logname is None
    if not discard:
        check_name(logname, "log name")
    if pidname is not None:
        check_name(pidname, "pid name")
        if not discard and pidname == logname:
            raise Refused("log and pid names must differ")
    executable = executable or (argv[0] if argv else "")
    if not argv or not os.path.isabs(executable):
        raise Refused("launch needs an absolute executable path")

    exefd = open_exe(executable)
    dirfd = None
    logfd = None
    ready_r = ready_w = release_r = release_w = None
    pid = None
    released = False
    try:
        dirfd = open_dir(d, create=True)
        if discard:
            logfd = os.open(os.devnull, os.O_WRONLY | os.O_CLOEXEC)
        else:
            try:
                os.unlink(logname, dir_fd=dirfd)
            except FileNotFoundError:
                pass
            except OSError as e:
                raise Refused(f"could not replace log {logname}: {e.strerror}")
            try:
                logfd = os.open(logname, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_APPEND | os.O_CLOEXEC, 0o600, dir_fd=dirfd)
            except OSError as e:
                raise Refused(f"could not create log {logname}: {e.strerror}")
        ready_r, ready_w = os.pipe()
        release_r, release_w = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(ready_r)
                os.close(release_w)
                os.setsid()
                devnull = os.open(os.devnull, os.O_RDONLY | os.O_CLOEXEC)
                os.dup2(devnull, 0)
                os.dup2(logfd, 1)
                os.dup2(logfd, 2)
                close_unrelated({0, 1, 2, exefd, ready_w, release_r})
                write_all(ready_w, b"1")
                os.close(ready_w)
                if os.read(release_r, 1) != b"1":
                    os._exit(126)
                os.close(release_r)
                os.set_inheritable(exefd, True)
                os.execve(exefd, argv, os.environ)
            finally:
                os._exit(127)

        os.close(ready_w)
        ready_w = None
        os.close(release_r)
        release_r = None
        if os.read(ready_r, 1) != b"1":
            raise Refused("launched process failed before it could be recorded")
        os.close(ready_r)
        ready_r = None
        start = process_starttime(pid)
        if pidname is not None:
            atomic_write(dirfd, pidname, f"{pid} {start}".encode())
        try:
            write_all(release_w, b"1")
        except OSError as e:
            raise Refused(f"launched process exited before release: {e.strerror}")
        released = True
        os.close(release_w)
        release_w = None
        sys.stdout.write(f"{pid} {start}")
    finally:
        for fd in (ready_r, ready_w, release_r, release_w, logfd, dirfd, exefd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        if pid is not None and pid > 0 and not released:
            while True:
                try:
                    os.waitpid(pid, 0)
                    break
                except InterruptedError:
                    continue
                except ChildProcessError:
                    break


def cmd_launch(a):
    if len(a) < 4 or a[2] != "--":
        raise Refused("usage: launch <dir> <logname> -- <argv...>")
    return launch_process(a[0], a[1], None, a[3:])


def cmd_launch_tracked(a):
    logname = None if a[1] == "--discard-output" else a[1]
    if len(a) < 5 or a[3] != "--":
        if len(a) < 7 or a[3] != "--exec" or a[5] != "--":
            raise Refused("usage: launch-tracked <dir> <logname|--discard-output> <pidname> [--exec <path>] -- <argv...>")
        return launch_process(a[0], logname, a[2], a[6:], a[4])
    return launch_process(a[0], logname, a[2], a[4:])


COMMANDS = {
    "ensure": (cmd_ensure, 1), "dump": (cmd_dump, 1), "read": (cmd_read, 1), "write": (cmd_write, 1),
    "create": (cmd_create, 1),
    "append": (cmd_append, 2), "append-many": (cmd_append_many, 3), "remove": (cmd_remove, 2),
    "remove-digest": (cmd_remove_digest, 4), "truncate": (cmd_truncate, 2), "lock": (cmd_lock, 5),
    "lock-clean": (cmd_lock_clean, 5),
    "launch": (cmd_launch, 4), "launch-tracked": (cmd_launch_tracked, 5),
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
