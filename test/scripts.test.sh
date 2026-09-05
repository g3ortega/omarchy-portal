#!/bin/bash
# Unit tests for the shell side: the portless library, the tunnels.sh
# validators, and metrics.sh's file handling. Everything runs against
# throwaway state directories; nothing here touches the live system.
set -o pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
S="$(cd "$HERE/../scripts" && pwd)"
PR="$S/lib/proc.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
is()  { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }

if [[ -z ${PORTAL_TEST_ONLY:-} || ${PORTAL_TEST_ONLY:-} == proc-end ]]; then
if /usr/bin/python3 -I -S - "$PR" <<'PY'
import errno
import importlib.util
import sys
import types

pid = 424242
start = "12345"
spec = importlib.util.spec_from_file_location("portal_proc_end", sys.argv[1])
proc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proc)


def end_case(group):
    state = [start]
    probes = []

    def killpg(value, sig):
        probes.append((value, sig))
        if group is not None:
            raise group

    proc.starttime = lambda value: state[0] if value == pid else None
    proc.end_group = lambda value: state.__setitem__(0, None)
    proc.os = types.SimpleNamespace(killpg=killpg)
    return proc.cmd_end([str(pid), start]), state[0], probes


groups = {
    "present": None,
    "absent": ProcessLookupError(),
    "eperm": PermissionError(errno.EPERM, "operation not permitted"),
}
results = {name: end_case(error) for name, error in groups.items()}

dangerous = (("1", "1"), ("0", "0"), ("-1", "1"), ("", ""),
             ("999999999999999999999", "1"), (str(pid), "not-a-number"))
dangerous_probes = []
proc.starttime = lambda value: None
proc.os = types.SimpleNamespace(killpg=lambda value, sig: dangerous_probes.append((value, sig)))
dangerous_results = [proc.cmd_end(list(identity)) for identity in dangerous]

expected = {
    "present": (1, None, [(pid, 0)]),
    "absent": (0, None, [(pid, 0)]),
    "eperm": (1, None, [(pid, 0)]),
}
if (results != expected or dangerous_results != [1] * len(dangerous)
        or dangerous_probes):
    raise SystemExit(
        f"expected {expected}, got {results}; "
        f"dangerous returns {dangerous_results}, probes {dangerous_probes}"
    )
print("present=1 absent=0 eperm=1 dangerous-probes=0")
PY
then
  ok "proc end requires the exact leader and process group to be gone"
else
  bad "proc end accepted a surviving or unprobeable process group"
fi
if [[ ${PORTAL_TEST_ONLY:-} == proc-end ]]; then
  echo; echo "$pass passed, $fail failed"
  exit $((fail > 0))
fi
fi

if [[ -z ${PORTAL_TEST_ONLY:-} || ${PORTAL_TEST_ONLY:-} == restart-cancel ]]; then
RESTART_CANCEL="$T/restart-cancel"
mkdir -p "$RESTART_CANCEL/state"
PORTAL_STATE_DIR="$RESTART_CANCEL/state" EFFECTS="$RESTART_CANCEL/effects" S="$S" bash -c '
  set -- noop
  source "$S/lifecycle.sh" >/dev/null
  : > "$EFFECTS"
  rollback_replacement() {
    printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$EFFECTS"
    state remove "$PORTAL_RUNTIME_DIR" "$3"
  }
  read_case() {
    local label=$1 record=$2 identity rc
    identity=$(read_restart_identity "$record"); rc=$?
    printf "%s\t%s\t%s\n" "$label" "$rc" "$identity"
  }

  printf "999999 1" | state write "$PORTAL_RUNTIME_DIR/valid"
  read_case valid valid
  ( cancel_restart valid 143 ); printf "cancel-valid\t%s\n" "$?"

  printf "999999 1\n" | state write "$PORTAL_RUNTIME_DIR/newline"
  printf "999999 1\000tail" | state write "$PORTAL_RUNTIME_DIR/nul"
  printf "2147483648 1" | state write "$PORTAL_RUNTIME_DIR/huge"
  printf "1 1" | state write "$PORTAL_RUNTIME_DIR/one"
  printf "999999 nope" | state write "$PORTAL_RUNTIME_DIR/nonnumeric"
  printf "999999 1 extra" | state write "$PORTAL_RUNTIME_DIR/extra"
  for record in newline nul huge one nonnumeric extra; do
    read_case "$record" "$record"
    ( cancel_restart "$record" 130 ); printf "cancel-%s\t%s\n" "$record" "$?"
  done
  read_case absent absent

  state() { return 129; }
  read_case helper-signal ignored
' > "$RESTART_CANCEL/result" 2> "$RESTART_CANCEL/err"
restart_cancel_rc=$?
restart_trap_line=$(grep -nF "trap 'cancel_restart \"\$restart_pid\" 143' TERM" "$S/lifecycle.sh" | head -1 | cut -d: -f1)
restart_launch_line=$(grep -n 'state launch-tracked .*restart_pid' "$S/lifecycle.sh" | head -1 | cut -d: -f1)
is "restart cancellation reads only bounded durable identities" \
  "$restart_cancel_rc|$(cat "$RESTART_CANCEL/result")|$(cat "$RESTART_CANCEL/effects")" \
  $'0|valid\t0\t999999 1\ncancel-valid\t143\nnewline\t2\t\ncancel-newline\t130\nnul\t2\t\ncancel-nul\t130\nhuge\t2\t\ncancel-huge\t130\none\t2\t\ncancel-one\t130\nnonnumeric\t2\t\ncancel-nonnumeric\t130\nextra\t2\t\ncancel-extra\t130\nabsent\t1\t\nhelper-signal\t129\t|999999\t1\tvalid'
if [[ $restart_trap_line =~ ^[0-9]+$ && $restart_launch_line =~ ^[0-9]+$ \
    && $restart_trap_line -lt $restart_launch_line ]]; then
  ok "restart arms durable-record cancellation before launch"
else
  bad "restart launches before durable-record cancellation is armed"
fi
if [[ ${PORTAL_TEST_ONLY:-} == restart-cancel ]]; then
  echo; echo "$pass passed, $fail failed"
  exit $((fail > 0))
fi
fi

if [[ -z ${PORTAL_TEST_ONLY:-} || ${PORTAL_TEST_ONLY:-} == stage-ignored ]]; then
STAGE_IGNORED="$T/stage-ignored"
STAGE_SOURCE="$STAGE_IGNORED/source"
STAGE_HOME="$STAGE_IGNORED/home"
STAGE_INSTALL="$STAGE_HOME/.config/omarchy/plugins/g3ortega.portal"
STAGE_TMP="$STAGE_IGNORED/tmp"
mkdir -p "$STAGE_SOURCE/dev" "$STAGE_SOURCE/pkg" "$STAGE_HOME/.config/omarchy/plugins" "$STAGE_TMP"
cp "$HERE/../.gitignore" "$STAGE_SOURCE/.gitignore"
cp "$HERE/../dev/portal.sh" "$STAGE_SOURCE/dev/portal.sh"
chmod 700 "$STAGE_SOURCE/dev/portal.sh"
printf base > "$STAGE_SOURCE/tracked.txt"
printf base > "$STAGE_SOURCE/pkg/base"
git init -q "$STAGE_SOURCE"
git -C "$STAGE_SOURCE" add -A
git -C "$STAGE_SOURCE" -c user.name=Portal -c user.email=portal@example.invalid \
  commit -qm fixture
git clone -q "$STAGE_SOURCE" "$STAGE_INSTALL"
printf staged > "$STAGE_SOURCE/tracked.txt"
git -C "$STAGE_SOURCE" add tracked.txt

stage_unsupported=(
  normal.log
  .venv/cache/value
  nested/dev/unsafe.log
  nested/tmp/unsafe
  repo-only.ignore
  global-only.ignore
  $'literal\nnewline.log'
)
stage_allowed=(
  dev/allowed.log
  tmp
  __pycache__
  pkg/__pycache__/allowed
  .venv/__pycache__/allowed
)
stage_success_allowed=(
  dev/allowed.log
  tmp
  __pycache__
  pkg/__pycache__/allowed
)
stage_scale_paths=(
  node_modules/pkg/leaf
  pkg/ignored-1.log
  pkg/ignored-2.log
  pkg/ignored-3.log
)
for i in "${!stage_unsupported[@]}"; do
  mkdir -p "$(dirname -- "$STAGE_INSTALL/${stage_unsupported[$i]}")"
  printf 'unsupported-%s' "$i" > "$STAGE_INSTALL/${stage_unsupported[$i]}"
done
for i in "${!stage_allowed[@]}"; do
  mkdir -p "$(dirname -- "$STAGE_INSTALL/${stage_allowed[$i]}")"
  printf 'allowed-%s' "$i" > "$STAGE_INSTALL/${stage_allowed[$i]}"
done
for i in "${!stage_scale_paths[@]}"; do
  mkdir -p "$(dirname -- "$STAGE_INSTALL/${stage_scale_paths[$i]}")"
  printf 'scale-%s' "$i" > "$STAGE_INSTALL/${stage_scale_paths[$i]}"
done
printf '/repo-only.ignore\n/tmp\n/__pycache__\n' >> "$STAGE_INSTALL/.git/info/exclude"
printf '/global-only.ignore\n' > "$STAGE_IGNORED/global-excludes"
HOME="$STAGE_HOME" git config --global core.excludesFile "$STAGE_IGNORED/global-excludes"

cat > "$STAGE_IGNORED/digest.py" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
for name in sorted(sys.argv[2:], key=os.fsencode):
    encoded = os.fsencode(name)
    digest.update(len(encoded).to_bytes(8, "big"))
    digest.update(encoded)
    try:
        content = (root / name).read_bytes()
    except FileNotFoundError:
        digest.update(b"missing")
    else:
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
print(digest.hexdigest())
PY

mkdir "$STAGE_IGNORED/bin"
cat > "$STAGE_IGNORED/bin/mktemp" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$MKTEMP_LOG"
exec /usr/bin/mktemp "$@"
SH
cat > "$STAGE_IGNORED/bin/git" <<'SH'
#!/bin/bash
inventory=0
if [[ ${1:-} == -C && ${2:-} == "$STAGE_INSTALL" && ${3:-} == ls-files ]]; then
  for arg in "$@"; do
    [[ $arg == --ignored ]] && inventory=1
  done
fi
if (( inventory )); then
  out=$(/usr/bin/mktemp) || exit 1
  trap 'rm -f -- "$out"' EXIT
  /usr/bin/git "$@" > "$out"
  rc=$?
  cp -- "$out" "${GIT_INVENTORY_OUT:-/dev/null}" || exit 1
  cat -- "$out" || exit 1
  printf drained > "${GIT_INVENTORY_DRAINED:-/dev/null}" || exit 1
  [[ ${GIT_INVENTORY_FAIL:-0} == 1 ]] && exit 71
  exit "$rc"
fi
exec /usr/bin/git "$@"
SH
cat > "$STAGE_IGNORED/bin/sed" <<'SH'
#!/bin/bash
if [[ ${1:-} == -n && ${2:-} == 1p && $# == 2 && -n ${SED_REDUCER_OUT:-} ]]; then
  out=$(/usr/bin/sed "$@")
  rc=$?
  printf '%s' "$out" > "$SED_REDUCER_OUT" || exit 1
  printf '%s' "$out" || exit 1
  exit "$rc"
fi
exec /usr/bin/sed "$@"
SH
chmod 700 "$STAGE_IGNORED/bin/mktemp" "$STAGE_IGNORED/bin/git" "$STAGE_IGNORED/bin/sed"
: > "$STAGE_IGNORED/mktemp.log"
: > "$STAGE_IGNORED/fail.drained"
: > "$STAGE_IGNORED/fail.reducer"
stage_fixture_before=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  "${stage_unsupported[@]}" "${stage_allowed[@]}" "${stage_scale_paths[@]}")
stage_success_allowed_before=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  "${stage_success_allowed[@]}")
stage_tracked_before=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  .gitignore dev/portal.sh pkg/base tracked.txt)
stage_index_before=$(sha256sum "$STAGE_INSTALL/.git/index" | cut -d' ' -f1)
HOME="$STAGE_HOME" TMPDIR="$STAGE_TMP" MKTEMP_LOG="$STAGE_IGNORED/mktemp.log" STAGE_INSTALL="$STAGE_INSTALL" \
  GIT_INVENTORY_OUT="$STAGE_IGNORED/fail.inventory" GIT_INVENTORY_DRAINED="$STAGE_IGNORED/fail.drained" \
  GIT_INVENTORY_FAIL=1 SED_REDUCER_OUT="$STAGE_IGNORED/fail.reducer" \
  PATH="$STAGE_IGNORED/bin:/usr/bin:/bin" "$STAGE_SOURCE/dev/portal.sh" stage \
  > "$STAGE_IGNORED/inventory-fail.out" 2>&1
stage_inventory_fail_rc=$?
stage_fixture_after=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  "${stage_unsupported[@]}" "${stage_allowed[@]}" "${stage_scale_paths[@]}")
stage_tracked_after=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  .gitignore dev/portal.sh pkg/base tracked.txt)
stage_index_after=$(sha256sum "$STAGE_INSTALL/.git/index" | cut -d' ' -f1)
is "an ignored inventory failure rejects before snapshot and preserves bytes and index" \
  "$stage_inventory_fail_rc|$(cat "$STAGE_IGNORED/inventory-fail.out")|$(wc -l < "$STAGE_IGNORED/mktemp.log")|$stage_fixture_after|$stage_tracked_after|$stage_index_after" \
  "1|portal.sh: cannot inspect ignored paths in install|0|$stage_fixture_before|$stage_tracked_before|$stage_index_before"
stage_fail_first=$(/usr/bin/sed -n '1p' "$STAGE_IGNORED/fail.inventory")
is "a failed ignored inventory is fully drained and reduced before status 71 propagates" \
  "$(cat "$STAGE_IGNORED/fail.drained")|$(cat "$STAGE_IGNORED/fail.reducer")" \
  "drained|$stage_fail_first"

: > "$STAGE_IGNORED/mktemp.log"
: > "$STAGE_IGNORED/first.drained"
: > "$STAGE_IGNORED/first.reducer"
HOME="$STAGE_HOME" TMPDIR="$STAGE_TMP" MKTEMP_LOG="$STAGE_IGNORED/mktemp.log" STAGE_INSTALL="$STAGE_INSTALL" \
  GIT_INVENTORY_OUT="$STAGE_IGNORED/first.inventory" GIT_INVENTORY_DRAINED="$STAGE_IGNORED/first.drained" \
  SED_REDUCER_OUT="$STAGE_IGNORED/first.reducer" \
  PATH="$STAGE_IGNORED/bin:/usr/bin:/bin" "$STAGE_SOURCE/dev/portal.sh" stage \
  > "$STAGE_IGNORED/first.out" 2>&1
stage_first_rc=$?
stage_fixture_after=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  "${stage_unsupported[@]}" "${stage_allowed[@]}" "${stage_scale_paths[@]}")
stage_tracked_after=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  .gitignore dev/portal.sh pkg/base tracked.txt)
stage_index_after=$(sha256sum "$STAGE_INSTALL/.git/index" | cut -d' ' -f1)
is "stage rejects unsupported ignored paths before creating a snapshot" \
  "$stage_first_rc|$(cat "$STAGE_IGNORED/first.out")|$(wc -l < "$STAGE_IGNORED/mktemp.log")" \
  '1|portal.sh: install has ignored paths outside stage exclusions; remove them first|0'
is "rejected ignored paths preserve every fixture byte, tracked byte, and exact index byte" \
  "$stage_fixture_after|$stage_tracked_after|$stage_index_after" \
  "$stage_fixture_before|$stage_tracked_before|$stage_index_before"
stage_inventory_shape=$(/usr/bin/python3 -I -S - "$STAGE_IGNORED/first.inventory" "$STAGE_IGNORED/first.reducer" <<'PY'
from pathlib import Path
import sys

raw = Path(sys.argv[1]).read_bytes()
lines = raw.decode().splitlines()
reduced = Path(sys.argv[2]).read_bytes()
first = raw.splitlines()[0]
pkg_leaves = {f"pkg/ignored-{index}.log" for index in range(1, 4)}
print(
    f"{lines.count('.venv/')}:{lines.count('node_modules/')}:"
    f"{len(pkg_leaves.intersection(lines))}:{int(len(lines) > 1)}:"
    f"{int(reduced == first)}"
)
PY
)
is "stage keeps tracked-parent leaves raw while retaining only the first drained record" \
  "$stage_inventory_shape|$(cat "$STAGE_IGNORED/first.drained")" '1:1:3:1:1|drained'

rm -rf -- "$STAGE_INSTALL/.venv/cache" "$STAGE_INSTALL/node_modules"
rm -f -- "$STAGE_INSTALL"/pkg/ignored-*.log

stage_isolated_actual=""
stage_isolated_expected=""
for i in "${!stage_unsupported[@]}"; do
  for path in "${stage_unsupported[@]}"; do rm -f -- "$STAGE_INSTALL/$path"; done
  mkdir -p "$(dirname -- "$STAGE_INSTALL/${stage_unsupported[$i]}")"
  printf 'unsupported-%s' "$i" > "$STAGE_INSTALL/${stage_unsupported[$i]}"
  : > "$STAGE_IGNORED/mktemp.log"
  HOME="$STAGE_HOME" TMPDIR="$STAGE_TMP" MKTEMP_LOG="$STAGE_IGNORED/mktemp.log" STAGE_INSTALL="$STAGE_INSTALL" \
    GIT_INVENTORY_OUT="$STAGE_IGNORED/isolated-$i.inventory" \
    PATH="$STAGE_IGNORED/bin:/usr/bin:/bin" "$STAGE_SOURCE/dev/portal.sh" stage \
    > "$STAGE_IGNORED/isolated-$i.out" 2>&1
  stage_isolated_rc=$?
  if [[ -f $STAGE_INSTALL/${stage_unsupported[$i]} ]]; then
    stage_isolated_bytes=$(cat "$STAGE_INSTALL/${stage_unsupported[$i]}")
  else
    stage_isolated_bytes=missing
  fi
  stage_isolated_actual+="$i:$stage_isolated_rc:$(wc -l < "$STAGE_IGNORED/mktemp.log"):$stage_isolated_bytes "
  stage_isolated_expected+="$i:1:0:unsupported-$i "
done
is "each unsupported ignored path independently rejects before snapshot and preserves its bytes" \
  "$stage_isolated_actual" "$stage_isolated_expected"
is "an excluded pycache leaf does not retain its ignored parent" \
  "$(cat "$STAGE_IGNORED/isolated-0.inventory")" "normal.log"

for path in "${stage_unsupported[@]}"; do rm -f -- "$STAGE_INSTALL/$path"; done
rm -rf -- "$STAGE_INSTALL/.venv"
: > "$STAGE_IGNORED/mktemp.log"
HOME="$STAGE_HOME" TMPDIR="$STAGE_TMP" MKTEMP_LOG="$STAGE_IGNORED/mktemp.log" \
  STAGE_INSTALL="$STAGE_INSTALL" \
  PATH="$STAGE_IGNORED/bin:/usr/bin:/bin" "$STAGE_SOURCE/dev/portal.sh" stage \
  > "$STAGE_IGNORED/second.out" 2>&1
stage_second_rc=$?
stage_allowed_after=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  "${stage_success_allowed[@]}")
stage_staged_names=$(git -C "$STAGE_INSTALL" diff --cached --name-only)
HOME="$STAGE_HOME" TMPDIR="$STAGE_TMP" PATH="$STAGE_IGNORED/bin:/usr/bin:/bin" \
  "$STAGE_SOURCE/dev/portal.sh" parity > "$STAGE_IGNORED/parity.out" 2>&1
stage_parity_rc=$?
is "stage succeeds after removing only unsupported ignored paths and stages the source change" \
  "$stage_second_rc|$(tail -1 "$STAGE_IGNORED/second.out")|$(wc -l < "$STAGE_IGNORED/mktemp.log")|$(cat "$STAGE_INSTALL/tracked.txt")|$stage_staged_names" \
  '0|stage: IDENTICAL; install changes are staged|1|staged|tracked.txt'
is "successful stage preserves every remaining allowed ignored byte and passes parity" \
  "$stage_allowed_after|$stage_parity_rc|$(cat "$STAGE_IGNORED/parity.out")" \
  "$stage_success_allowed_before|0|parity: IDENTICAL"

printf ordinary > "$STAGE_INSTALL/ordinary-only"
: > "$STAGE_IGNORED/mktemp.log"
stage_tracked_before=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  .gitignore dev/portal.sh pkg/base tracked.txt)
stage_index_before=$(sha256sum "$STAGE_INSTALL/.git/index" | cut -d' ' -f1)
HOME="$STAGE_HOME" TMPDIR="$STAGE_TMP" MKTEMP_LOG="$STAGE_IGNORED/mktemp.log" STAGE_INSTALL="$STAGE_INSTALL" \
  PATH="$STAGE_IGNORED/bin:/usr/bin:/bin" "$STAGE_SOURCE/dev/portal.sh" stage \
  > "$STAGE_IGNORED/ordinary.out" 2>&1
stage_ordinary_rc=$?
stage_tracked_after=$(/usr/bin/python3 -I -S "$STAGE_IGNORED/digest.py" "$STAGE_INSTALL" \
  .gitignore dev/portal.sh pkg/base tracked.txt)
stage_index_after=$(sha256sum "$STAGE_INSTALL/.git/index" | cut -d' ' -f1)
is "ordinary installed-only files still reject before snapshot or mutation" \
  "$stage_ordinary_rc|$(cat "$STAGE_IGNORED/ordinary.out")|$(wc -l < "$STAGE_IGNORED/mktemp.log")|$(cat "$STAGE_INSTALL/ordinary-only")|$stage_tracked_after|$stage_index_after" \
  "1|portal.sh: install has untracked files; remove installed-only probes first|0|ordinary|$stage_tracked_before|$stage_index_before"

if [[ ${PORTAL_TEST_ONLY:-} == stage-ignored ]]; then
  echo; echo "$pass passed, $fail failed"
  exit $((fail > 0))
fi
fi

if [[ -z ${PORTAL_TEST_ONLY:-} || ${PORTAL_TEST_ONLY:-} == scan-argv ]]; then
ARGV_SCAN="$T/scan-argv"; mkdir -p "$ARGV_SCAN/bin" "$ARGV_SCAN/spool"
cat > "$ARGV_SCAN/holder.py" <<'PY'
import os
import signal
import sys

size = int(sys.argv[1])
identities = sys.argv[2]
alarm_seconds = int(sys.argv[3])

signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.alarm(alarm_seconds)

with open("/proc/self/stat", "rb") as stream:
    stat = stream.read()
start = stat.rsplit(b") ", 1)[1].split()[19]
line = f"{os.getpid()} {int(start)}\n".encode()
fd = os.open(identities, os.O_WRONLY | os.O_APPEND | os.O_CLOEXEC)
try:
    if os.write(fd, line) != len(line):
        raise OSError("short identity write")
finally:
    os.close(fd)

argv0 = "x" * (size - 10) + "sleep"
os.execve("/usr/bin/sleep", [argv0, "300"], {"PATH": "/usr/bin:/bin"})
PY
cat > "$ARGV_SCAN/bin/ss" <<'SH'
#!/bin/bash
case "$*" in
  -tlnpH)
    if [[ $SCAN_ARGV_CASE == exact ]]; then
      printf 'LISTEN 0 128 127.0.0.1:45191 0.0.0.0:* users:(("sleep",pid=%s,fd=3))\n' "$PID_8191"
      printf 'LISTEN 0 128 127.0.0.1:45192 0.0.0.0:* users:(("sleep",pid=%s,fd=3))\n' "$PID_8192"
      printf 'LISTEN 0 128 127.0.0.1:45193 0.0.0.0:* users:(("sleep",pid=%s,fd=3))\n' "$PID_8193"
    elif [[ $SCAN_ARGV_CASE == boundary ]]; then
      printf 'LISTEN 0 128 127.0.0.1:45201 0.0.0.0:* users:(("sleep",pid=%s,fd=3))\n' "$PID_SHARED"
      printf 'LISTEN 0 128 127.0.0.1:45202 0.0.0.0:* users:(("sleep",pid=%s,fd=3))\n' "$PID_SHARED"
    else
      for ((i = 0; i < 512; i++)); do
        printf 'LISTEN 0 128 127.0.0.1:%d 0.0.0.0:* users:(("sleep",pid=%s,fd=3))\n' "$((10000 + i))" "$PID_SHARED"
      done
    fi
    ;;
  '-tnH state established') ;;
  *) exit 1 ;;
esac
SH
cat > "$ARGV_SCAN/bin/head" <<'SH'
#!/bin/bash
last=${!#}
if [[ -n ${ARGV_TARGET_PID:-} && $last == "/proc/$ARGV_TARGET_PID/cmdline" ]]; then
  case ${ARGV_HEAD_MODE:-normal} in
    partial) printf 'partial\0sample'; exit 23 ;;
    empty) exit 0 ;;
  esac
fi
exec /usr/bin/head "$@"
SH
cat > "$ARGV_SCAN/bin/base64" <<'SH'
#!/bin/bash
spool=$(mktemp -p "$BASE64_SPOOL_DIR" base64.XXXXXX) || exit 1
trap 'rm -f -- "$spool"' EXIT
cat > "$spool" || exit 1
bytes=$(wc -c < "$spool") || exit 1
printf '%s\n' "$bytes" >> "$BASE64_LOG" || exit 1
if [[ ${ARGV_BASE64_MODE:-normal} == partial ]]; then
  printf 'cGFydGlhbA=='
  exit 29
fi
/usr/bin/base64 "$@" < "$spool"
SH
chmod 700 "$ARGV_SCAN/bin/ss" "$ARGV_SCAN/bin/head" "$ARGV_SCAN/bin/base64"

scan_argv_start() {
  local pid=$1 stat fields start
  [[ $pid =~ ^[1-9][0-9]*$ ]] && (( pid > 1 )) || return 1
  IFS= read -r stat 2>/dev/null < "/proc/$pid/stat" || return 1
  read -ra fields <<<"${stat##*) }"
  start=${fields[19]:-}
  [[ $start =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$start"
}

scan_argv_reapable() {
  local pid=$1 expected_start=$2 stat fields
  [[ $pid =~ ^[1-9][0-9]*$ && $expected_start =~ ^[0-9]+$ ]] && (( pid > 1 )) || return 1
  [[ -e /proc/$pid/stat ]] || return 0
  IFS= read -r stat 2>/dev/null < "/proc/$pid/stat" || return 1
  [[ $stat == *") "* ]] || return 1
  read -ra fields <<<"${stat##*) }"
  [[ ${fields[0]:-} == Z && ${fields[19]:-} == "$expected_start" ]]
}

cleanup_scan_argv() {
  local identities=$1 pid start extra current i
  while read -r pid start extra; do
    [[ -z $extra && $pid =~ ^[1-9][0-9]*$ && $start =~ ^[0-9]+$ ]] || continue
    (( pid > 1 )) || continue
    current=$(scan_argv_start "$pid" 2>/dev/null || true)
    if [[ $current == "$start" ]]; then
      /usr/bin/python3 -I -S "$PR" signal "$pid" "$start" TERM >/dev/null 2>&1 || true
    fi
    for ((i = 0; i < 20; i++)); do
      scan_argv_reapable "$pid" "$start" && break
      sleep 0.01
    done
    if ! scan_argv_reapable "$pid" "$start"; then
      current=$(scan_argv_start "$pid" 2>/dev/null || true)
      if [[ $current == "$start" ]]; then
        /usr/bin/python3 -I -S "$PR" signal "$pid" "$start" KILL >/dev/null 2>&1 || true
      fi
      for ((i = 0; i < 20; i++)); do
        scan_argv_reapable "$pid" "$start" && break
        sleep 0.01
      done
    fi
    if scan_argv_reapable "$pid" "$start"; then
      wait "$pid" 2>/dev/null || true
    fi
  done < "$identities"
}

launch_scan_argv_holder() {
  local size=$1 identities=$2 pid identity_pid start extra actual current i
  local matches=()
  /usr/bin/python3 -I -S "$ARGV_SCAN/holder.py" "$size" "$identities" 30 >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 200); do
    mapfile -t matches < <(awk -v pid="$pid" '$1 == pid { print }' "$identities")
    if (( ${#matches[@]} == 1 )); then
      read -r identity_pid start extra <<<"${matches[0]}"
      [[ -z $extra && $identity_pid == "$pid" && $start =~ ^[0-9]+$ ]] || return 1
      current=$(scan_argv_start "$pid" 2>/dev/null || true)
      [[ $current == "$start" ]] || return 1
      break
    fi
    sleep 0.01
  done
  (( ${#matches[@]} == 1 )) || return 1
  for i in $(seq 1 200); do
    actual=$(wc -c < "/proc/$pid/cmdline" 2>/dev/null || true)
    [[ $actual == "$size" ]] && break
    sleep 0.01
  done
  [[ $actual == "$size" ]] || return 1
  HOLDER_PID=$pid
}

scan_argv_alarm_probe() (
  set -u
  local identities="$ARGV_SCAN/fallback-identities"
  local pid recorded start current wait_rc i
  local records=()

  : > "$identities"
  trap 'cleanup_scan_argv "$identities"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  /usr/bin/python3 -I -S "$ARGV_SCAN/holder.py" 8191 "$identities" 1 >/dev/null 2>&1 &
  pid=$!
  for ((i = 0; i < 200; i++)); do
    mapfile -t records < "$identities"
    (( ${#records[@]} <= 1 )) || return 1
    (( ${#records[@]} == 1 )) && break
    sleep 0.01
  done
  (( ${#records[@]} == 1 )) || return 1
  [[ ${records[0]} =~ ^([1-9][0-9]*)\ ([0-9]+)$ ]] || return 1
  recorded=${BASH_REMATCH[1]}
  start=${BASH_REMATCH[2]}
  (( recorded > 1 )) || return 1
  [[ $recorded == "$pid" ]] || return 1
  current=$(scan_argv_start "$pid" 2>/dev/null || true)
  [[ $current == "$start" ]] || return 1

  for ((i = 0; i < 300; i++)); do
    scan_argv_reapable "$pid" "$start" && break
    sleep 0.01
  done
  scan_argv_reapable "$pid" "$start" || return 1
  if wait "$pid"; then
    wait_rc=0
  else
    wait_rc=$?
  fi
  trap - EXIT
  [[ $wait_rc == 142 ]]
)
if scan_argv_alarm_probe 2>/dev/null; then
  scan_argv_alarm_rc=0
else
  scan_argv_alarm_rc=$?
fi
is "the argv holder records its exact identity before its one-second alarm ends it" \
  "$scan_argv_alarm_rc" "0"

scan_argv_boundary_case() {
  local name=$1 head_mode=$2 base64_mode=$3
  : > "$ARGV_SCAN/$name-base64.log"
  SCAN_ARGV_CASE=boundary ARGV_TARGET_PID="$PID_SHARED" \
    ARGV_HEAD_MODE="$head_mode" ARGV_BASE64_MODE="$base64_mode" \
    BASE64_LOG="$ARGV_SCAN/$name-base64.log" BASE64_SPOOL_DIR="$ARGV_SCAN/spool" \
    PATH="$ARGV_SCAN/bin:/usr/bin:/bin" "$S/scan-ports.sh" > "$ARGV_SCAN/$name.json"
}

scan_argv_probe() (
  set -euo pipefail
  local identities="$ARGV_SCAN/identities" HOLDER_PID
  : > "$identities"

  trap 'cleanup_scan_argv "$identities"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  launch_scan_argv_holder 8191 "$identities"; PID_8191=$HOLDER_PID
  launch_scan_argv_holder 8192 "$identities"; PID_8192=$HOLDER_PID
  launch_scan_argv_holder 8193 "$identities"; PID_8193=$HOLDER_PID
  export PID_8191 PID_8192 PID_8193
  : > "$ARGV_SCAN/base64.log"
  SCAN_ARGV_CASE=exact BASE64_LOG="$ARGV_SCAN/base64.log" BASE64_SPOOL_DIR="$ARGV_SCAN/spool" \
    PATH="$ARGV_SCAN/bin:/usr/bin:/bin" "$S/scan-ports.sh" > "$ARGV_SCAN/exact.json"
  cp "$ARGV_SCAN/base64.log" "$ARGV_SCAN/exact-base64.log"

  launch_scan_argv_holder 65536 "$identities"; PID_SHARED=$HOLDER_PID
  export PID_SHARED
  : > "$ARGV_SCAN/base64.log"
  SCAN_ARGV_CASE=shared BASE64_LOG="$ARGV_SCAN/base64.log" BASE64_SPOOL_DIR="$ARGV_SCAN/spool" \
    PATH="$ARGV_SCAN/bin:/usr/bin:/bin" "$S/scan-ports.sh" > "$ARGV_SCAN/shared.json"

  scan_argv_boundary_case partial-producer partial normal
  scan_argv_boundary_case partial-base64 normal partial
  scan_argv_boundary_case successful-empty empty normal
)
scan_argv_probe; scan_argv_probe_rc=$?
is "the scanner argv probe completes against real processes" "$scan_argv_probe_rc" "0"
is "exact 8,191, 8,192, and 8,193-byte command lines keep the truncation boundary" \
  "$(jq -c '[.ports[] | .argvTruncated]' "$ARGV_SCAN/exact.json" 2>/dev/null)" '[false,false,true]'
is "exact 8,191 and 8,192-byte command lines keep both NUL-delimited arguments" \
  "$(jq -c '[.ports[0:2][] | [(.argv | length), (.argv[0] | length), .argv[1]]]' "$ARGV_SCAN/exact.json" 2>/dev/null)" \
  '[[2,8186,"300"],[2,8187,"300"]]'
is "exact argv samples feed Base64 once at each raw byte length" \
  "$(sort -n "$ARGV_SCAN/exact-base64.log" 2>/dev/null | paste -sd, -)" '8191,8192,8193'
is "one PID projected onto 512 ports feeds Base64 one bounded sample" \
  "$(awk '{ calls++; total += $1; if ($1 > max) max = $1 } END { print calls + 0, total + 0, max + 0 }' "$ARGV_SCAN/base64.log" 2>/dev/null)" \
  '1 8193 8193'
is "all 512 shared-PID rows return with equal truncated argv" \
  "$(jq -r '[(.ports | length), ([.ports[].argv] | unique | length), ([.ports[].argvTruncated] | all)] | @tsv' "$ARGV_SCAN/shared.json" 2>/dev/null)" \
  $'512\t1\ttrue'
is "the shared-PID scan keeps the public row key set" \
  "$(jq -c '[.ports[] | keys] | unique' "$ARGV_SCAN/shared.json" 2>/dev/null)" \
  '[["addresses","argv","argvTruncated","cmdline","comm","conns","cpuTicks","cwd","deps","exclusiveOwner","httpCode","latMs","markers","pid","port","procState","projectName","projectRoot","rssKb","scope","start","upSec"]]'

for scan_argv_boundary_name in partial-producer partial-base64 successful-empty; do
  is "$scan_argv_boundary_name caches empty argv after one scoped producer and encoder attempt" \
    "$(jq -c '[(.ports | length), [.ports[].argv], [.ports[].argvTruncated]]' "$ARGV_SCAN/$scan_argv_boundary_name.json" 2>/dev/null)|$(wc -l < "$ARGV_SCAN/$scan_argv_boundary_name-base64.log")" \
    '[2,[[],[]],[false,false]]|1'
done
if pgrep -f "sleep [3]00" >/dev/null; then bad "the scanner argv probe left a sleep 300 process"; else ok "the scanner argv probe leaves no sleep 300 process"; fi

if [[ ${PORTAL_TEST_ONLY:-} == scan-argv ]]; then
  echo; echo "$pass passed, $fail failed"
  exit $((fail > 0))
fi
fi

# ---- scripts/lib/portless.sh ----------------------------------------------
export PORTLESS_STATE_DIR="$T/portless"; mkdir -p "$PORTLESS_STATE_DIR"
export PORTAL_STATE_DIR="$T/runtime"
export PORTAL_PORTLESS_TLD=test
# shellcheck source=tunnels.sh
source "$S/tunnels.sh"    # sources lib/portless.sh; returns before dispatch

if [[ -z ${PORTAL_TEST_ONLY:-} || ${PORTAL_TEST_ONLY:-} == tunnel-targets ]]; then
LOOPBACK="$T/loopback-endpoints"; mkdir -p "$LOOPBACK/state" "$LOOPBACK/portless"; : > "$LOOPBACK/effects"
CASE_ROOT="$LOOPBACK" PORTAL_STATE_DIR="$LOOPBACK/state" PORTLESS_STATE_DIR="$LOOPBACK/portless" S="$S" bash -c '
  source "$S/tunnels.sh"
  kill() { printf "kill %s\n" "$*" >> "$CASE_ROOT/effects"; return 1; }
  proc() {
    if [[ ${1:-} == check ]]; then
      PROC_CHECK_COUNT=$((PROC_CHECK_COUNT + 1))
      case ${PROC_MODE:-pass} in
        pass) return 0 ;;
        fail) return 1 ;;
        second-fail) (( PROC_CHECK_COUNT == 1 )) && return 0 || return 1 ;;
      esac
    fi
    printf "proc-effect %s\n" "$*" >> "$CASE_ROOT/effects"
    return 1
  }
  proc_start() { printf 1; }
  stop_line() { printf "stop-line %s\n" "$*" >> "$CASE_ROOT/effects"; return 1; }
  group_alive() { printf "group-alive %s\n" "$*" >> "$CASE_ROOT/effects"; return 1; }
  provider_bin() { printf "provider-bin %s\n" "$*" >> "$CASE_ROOT/effects"; return 1; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { :; }
  cloudflared_stop_adopted() { printf "cloudflared-stop %s\n" "$*" >> "$CASE_ROOT/effects"; return 1; }
  ngrok_stop_adopted() { printf "ngrok-stop %s\n" "$*" >> "$CASE_ROOT/effects"; return 1; }
  cmd_stop() { printf "partial-stop %s\n" "$*" >> "$CASE_ROOT/effects"; printf "{\"ok\":true}"; }
  stop_reconciled_share() {
    printf "reconciled-stop %s\n" "$*" >> "$CASE_ROOT/effects"
    printf "%s\t%s\t%s\t%s\n" "$@" >> "$CASE_ROOT/stops"
    return 0
  }
  portless_state_load() { return 0; }
  alive_line() { return 0; }
  ss() {
    if [[ ${1:-} == -tlnH ]]; then
      printf "%b" "${RAW_SOCKETS:-}"
      return 0
    fi
    if [[ ${1:-} == -tlnpH && $# == 1 ]]; then
      printf "full\n" >> "$CASE_ROOT/socket-queries"
      if [[ ${ATTRIBUTED_FAIL:-0} == 1 ]]; then
        printf "LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"partial\",pid=999998,fd=3))\n"
        return 1
      fi
      printf "%b" "${ATTRIBUTED_SOCKETS:-}"
      return 0
    fi
    if [[ ${1:-} == -tlnpH ]]; then
      printf "targeted\n" >> "$CASE_ROOT/socket-queries"
      (( ${IDENTITY_FAIL:-0} == 0 )) || return 1
      printf "%b" "${IDENTITY_SOCKETS:-}"
      return 0
    fi
    return 1
  }

  for endpoint in \
    127.0.0.1:4471 127.0.0.1%lo:4471 "*:4471" 0.0.0.0:4471 \
    "[::]:4471" "[::1]:4471" "[::ffff:127.0.0.1]:4471" \
    "[::ffff:127.0.0.1%lo]:4471" :::4471 ::1:4471; do
    localhost_reachable_endpoint "$endpoint" && printf "%s\n" "$endpoint"
  done > "$CASE_ROOT/accepted"
  for endpoint in \
    192.168.50.8:4471 0.0.0.0%lo:4471 "[::ffff:192.168.50.8]:4471" \
    "[::1%lo]:4471" ::1%lo:4471 "[::%lo]:4471" ::%lo:4471 "[fe80::1]:4471"; do
    localhost_reachable_endpoint "$endpoint" && printf "%s\n" "$endpoint"
  done > "$CASE_ROOT/rejected-accepted"

  eval "$(declare -f localhost_reachable_endpoint | sed "1s/localhost_reachable_endpoint/localhost_reachable_endpoint_real/")"
  localhost_reachable_endpoint() {
    printf "%s\n" "$1" >> "$CASE_ROOT/predicate-calls"
    localhost_reachable_endpoint_real "$1"
  }

  target_case() {
    local rows=$1 mode=$2 rc
    SOCKS=$(printf "%b" "$rows")
    SOCKS_READY=1
    PROC_MODE=$mode
    PROC_CHECK_COUNT=0
    if target_owns_port "999999 1" 4471; then rc=0; else rc=$?; fi
    printf "%s:%s\n" "$rc" "$PROC_CHECK_COUNT"
  }
  {
    target_case "" pass
    target_case "LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"server\",pid=999999,fd=3))" pass
    target_case "LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"other\",pid=999998,fd=3))" pass
    target_case "LISTEN 0 128 127.0.0.1:4471 0.0.0.0:*" pass
    target_case "LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"server\",pid=999999,fd=3),(\"other\",pid=999998,fd=4))" pass
    target_case "LISTEN 0 128 192.168.50.8:4471 0.0.0.0:* users:((\"other\",pid=999998,fd=3))" pass
    target_case "LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"server\",pid=999999,fd=3))" second-fail
  } > "$CASE_ROOT/target-matrix"

  : > "$CASE_ROOT/socket-queries"
  ATTRIBUTED_FAIL=1 SOCKS="partial" SOCKS_READY=0 PROC_MODE=pass PROC_CHECK_COUNT=0
  if target_owns_port "999999 1" 4471; then target_query_rc=0; else target_query_rc=$?; fi
  printf "%s:%s:%s\n" "$target_query_rc" "$SOCKS_READY" "$(wc -l < "$CASE_ROOT/socket-queries")" > "$CASE_ROOT/target-query-failure"

  : > "$CASE_ROOT/socket-queries"
  ATTRIBUTED_FAIL=0 ATTRIBUTED_SOCKETS="" SOCKS="" SOCKS_READY=0 PROC_MODE=fail PROC_CHECK_COUNT=0
  if target_owns_port "999999 1" 4471; then dead_absent_rc=0; else dead_absent_rc=$?; fi
  printf "%s:%s:%s\n" "$dead_absent_rc" "$PROC_CHECK_COUNT" "$(wc -l < "$CASE_ROOT/socket-queries")" > "$CASE_ROOT/dead-absent"

  : > "$CASE_ROOT/socket-queries"
  ATTRIBUTED_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"server\",pid=999999,fd=3))\n" SOCKS="" SOCKS_READY=0 PROC_MODE=fail PROC_CHECK_COUNT=0
  if target_owns_port "999999 1" 4471; then dead_present_rc=0; else dead_present_rc=$?; fi
  printf "%s:%s:%s\n" "$dead_present_rc" "$PROC_CHECK_COUNT" "$(wc -l < "$CASE_ROOT/socket-queries")" > "$CASE_ROOT/dead-present"

  : > "$CASE_ROOT/socket-queries"
  ATTRIBUTED_SOCKETS="" SOCKS="" SOCKS_READY=0 PROC_MODE=pass PROC_CHECK_COUNT=0
  if target_owns_port "999999 1" 4471; then empty_first=0; else empty_first=$?; fi
  if target_owns_port "999999 1" 4472; then empty_second=0; else empty_second=$?; fi
  printf "%s:%s:%s\n" "$empty_first" "$empty_second" "$(wc -l < "$CASE_ROOT/socket-queries")" > "$CASE_ROOT/empty-cache"

  : > "$CASE_ROOT/predicate-calls"
  IDENTITY_FAIL=0
  IDENTITY_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"server\",pid=999999,fd=3))\nLISTEN 0 128 192.168.50.8:4471 0.0.0.0:* users:((\"other\",pid=999998,fd=3))\n"
  PROC_MODE=pass PROC_CHECK_COUNT=0
  if identity=$(listener_identity 4471); then identity_rc=0; else identity_rc=$?; fi
  printf "%s:%s\n" "$identity_rc" "$identity" > "$CASE_ROOT/mixed-identity"
  cp "$CASE_ROOT/predicate-calls" "$CASE_ROOT/identity-predicate-calls"
  IDENTITY_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:*\n"
  if identity=$(listener_identity 4471); then identity_unattributed=0; else identity_unattributed=$?; fi
  IDENTITY_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"one\",pid=999999,fd=3))\nLISTEN 0 128 127.0.0.2:4471 0.0.0.0:* users:((\"two\",pid=999998,fd=3))\n"
  if identity=$(listener_identity 4471); then identity_multiple=0; else identity_multiple=$?; fi
  IDENTITY_FAIL=1
  if identity=$(listener_identity 4471); then identity_query=0; else identity_query=$?; fi
  printf "%s:%s:%s\n" "$identity_unattributed" "$identity_multiple" "$identity_query" > "$CASE_ROOT/identity-refusals"

  : > "$CASE_ROOT/effects"
  IDENTITY_FAIL=1
  ( set -e; cmd_start cloudflared 4471 ) > "$CASE_ROOT/start-implicit-query.json"
  printf "%s\n" "$?" > "$CASE_ROOT/start-implicit-query.rc"
  IDENTITY_FAIL=0 ATTRIBUTED_FAIL=1
  ( set -e; cmd_start cloudflared 4471 --target 999999 1 ) > "$CASE_ROOT/start-explicit-query.json"
  printf "%s\n" "$?" > "$CASE_ROOT/start-explicit-query.rc"
  ATTRIBUTED_FAIL=0 ATTRIBUTED_SOCKETS=""
  ( set -e; cmd_start cloudflared 4471 --target 999999 1 ) > "$CASE_ROOT/start-absent.json"
  printf "%s\n" "$?" > "$CASE_ROOT/start-absent.rc"
  ATTRIBUTED_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"other\",pid=999998,fd=3))\n"
  ( cmd_start cloudflared 4471 --target 999999 1 ) > "$CASE_ROOT/start-unapproved.json"
  printf "%s\n" "$?" > "$CASE_ROOT/start-unapproved.rc"
  cp "$CASE_ROOT/effects" "$CASE_ROOT/start-effects"

  reset_status_share() {
    rm -f -- "$STATE_DIR"/*
    printf "https://loopback.trycloudflare.com" > "$STATE_DIR/cloudflared-4471.url"
    printf public > "$STATE_DIR/cloudflared-4471.reach"
    printf "999997 1" > "$STATE_DIR/cloudflared-4471.pid"
    printf "999999 1" > "$STATE_DIR/cloudflared-4471.target"
    : > "$CASE_ROOT/stops"
    : > "$CASE_ROOT/predicate-calls"
    : > "$CASE_ROOT/socket-queries"
    ATTRIBUTED_FAIL=0
    PROC_MODE=pass
    PROC_CHECK_COUNT=0
  }

  reset_status_share
  rm -f -- "$STATE_DIR"/*
  printf "999999 1" > "$STATE_DIR/cloudflared-4399.pid"
  printf "999999 1" > "$STATE_DIR/cloudflared-4399.target"
  printf "https://expired.trycloudflare.com" > "$STATE_DIR/cloudflared-4400.url"
  printf "999999 1" > "$STATE_DIR/cloudflared-4400.pid"
  printf 1 > "$STATE_DIR/cloudflared-4400.idle"
  printf "https://fresh.trycloudflare.com" > "$STATE_DIR/cloudflared-4401.url"
  printf "999999 1" > "$STATE_DIR/cloudflared-4401.pid"
  printf "https://tracked.trycloudflare.com" > "$STATE_DIR/cloudflared-4471.url"
  printf "999997 1" > "$STATE_DIR/cloudflared-4471.pid"
  printf "999999 1" > "$STATE_DIR/cloudflared-4471.target"
  state dump "$STATE_DIR" 8192 "$STATE_FILES_CAP" > "$CASE_ROOT/pre-effect-query-before.json"
  pre_effect_lines=$(wc -l < "$CASE_ROOT/effects")
  RAW_SOCKETS=""
  ATTRIBUTED_FAIL=1
  ( cmd_status ) > "$CASE_ROOT/pre-effect-query.json"
  state dump "$STATE_DIR" 8192 "$STATE_FILES_CAP" > "$CASE_ROOT/pre-effect-query-after.json"
  tail -n "+$((pre_effect_lines + 1))" "$CASE_ROOT/effects" > "$CASE_ROOT/pre-effect-query-effects"
  cp "$CASE_ROOT/socket-queries" "$CASE_ROOT/pre-effect-query-socket-queries"
  test -e "$STATE_DIR/cloudflared-4401.idle" && printf idle > "$CASE_ROOT/pre-effect-query-idle" || printf no-idle > "$CASE_ROOT/pre-effect-query-idle"

  reset_status_share
  rm -f -- "$STATE_DIR"/*
  printf "999999 1" > "$STATE_DIR/ngrok-4399.pid"
  printf "999999 1" > "$STATE_DIR/ngrok-4399.target"
  printf "https://legacy.trycloudflare.com" > "$STATE_DIR/cloudflared-4401.url"
  printf public > "$STATE_DIR/cloudflared-4401.reach"
  printf "999999 1" > "$STATE_DIR/cloudflared-4401.pid"
  pre_effect_lines=$(wc -l < "$CASE_ROOT/effects")
  RAW_SOCKETS="LISTEN 0 128 192.168.50.8:4401 0.0.0.0:*\n"
  ATTRIBUTED_FAIL=1
  cmd_status > "$CASE_ROOT/partial-targetless.json"
  tail -n "+$((pre_effect_lines + 1))" "$CASE_ROOT/effects" > "$CASE_ROOT/partial-targetless-effects"
  cp "$CASE_ROOT/socket-queries" "$CASE_ROOT/partial-targetless-socket-queries"
  printf "%s:%s\n" "$(cat "$STATE_DIR/cloudflared-4401.idle")" "$IDLE_CAP" > "$CASE_ROOT/partial-targetless-idle"

  reset_status_share
  RAW_SOCKETS=""
  ATTRIBUTED_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"other\",pid=999998,fd=3))\n"
  cmd_status > "$CASE_ROOT/replacement.json"
  find "$STATE_DIR" -maxdepth 1 -name "*.idle" -type f -printf "%f\n" > "$CASE_ROOT/replacement-idles"
  cp "$CASE_ROOT/stops" "$CASE_ROOT/replacement-stops"

  reset_status_share
  RAW_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:*\n"
  ATTRIBUTED_SOCKETS=""
  cmd_status > "$CASE_ROOT/disappeared.json"
  find "$STATE_DIR" -maxdepth 1 -name "*.idle" -type f -printf "%f\n" > "$CASE_ROOT/disappeared-idles"
  cp "$CASE_ROOT/stops" "$CASE_ROOT/disappeared-stops"

  reset_status_share
  RAW_SOCKETS=""
  ATTRIBUTED_FAIL=1
  ( cmd_status ) > "$CASE_ROOT/status-query.json"
  printf "%s\n" "$?" > "$CASE_ROOT/status-query.rc"
  find "$STATE_DIR" -maxdepth 1 -name "*.idle" -type f -printf "%f\n" > "$CASE_ROOT/status-query-idles"
  cp "$CASE_ROOT/stops" "$CASE_ROOT/status-query-stops"

  reset_status_share
  printf 1 > "$STATE_DIR/cloudflared-4471.idle"
  RAW_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:*\n"
  ATTRIBUTED_SOCKETS="LISTEN 0 128 127.0.0.1:4471 0.0.0.0:* users:((\"server\",pid=999999,fd=3))\n"
  cmd_status > "$CASE_ROOT/approved.json"
  find "$STATE_DIR" -maxdepth 1 -name "*.idle" -type f -printf "%f\n" > "$CASE_ROOT/approved-idles"
  cp "$CASE_ROOT/stops" "$CASE_ROOT/approved-stops"

  reset_status_share
  RAW_SOCKETS="LISTEN 0 128 192.168.50.8:4471 0.0.0.0:*\n"
  ATTRIBUTED_SOCKETS="LISTEN 0 128 192.168.50.8:4471 0.0.0.0:* users:((\"server\",pid=999999,fd=3))\n"
  cmd_status > "$CASE_ROOT/lan-only.json"
  find "$STATE_DIR" -maxdepth 1 -name "*.idle" -type f -printf "%f\n" > "$CASE_ROOT/lan-only-idles"
  cp "$CASE_ROOT/predicate-calls" "$CASE_ROOT/lan-only-predicate-calls"
  cp "$CASE_ROOT/stops" "$CASE_ROOT/lan-only-stops"

  reset_status_share
  RAW_SOCKETS=""
  ATTRIBUTED_SOCKETS=""
  ( set -e; cmd_status ) > "$CASE_ROOT/status-errexit.json"
  printf "%s\n" "$?" > "$CASE_ROOT/status-errexit.rc"
'
is "localhost reachability keeps the exact accepted endpoint policy" \
  "$(paste -sd, "$LOOPBACK/accepted")" \
  '127.0.0.1:4471,127.0.0.1%lo:4471,*:4471,0.0.0.0:4471,[::]:4471,[::1]:4471,[::ffff:127.0.0.1]:4471,[::ffff:127.0.0.1%lo]:4471,:::4471,::1:4471'
is "localhost reachability rejects LAN and scoped IPv6 endpoint forms" \
  "$(wc -l < "$LOOPBACK/rejected-accepted")" "0"
is "target ownership returns approved, absent, unapproved, and post-check states" \
  "$(paste -sd, "$LOOPBACK/target-matrix")" \
  '1:1,0:2,3:1,3:1,3:1,1:1,3:2'
is "target ownership reports query failure without consuming partial output" \
  "$(cat "$LOOPBACK/target-query-failure")" '2:0:1'
is "a failed target precheck still queries and distinguishes absence from replacement" \
  "$(cat "$LOOPBACK/dead-absent")|$(cat "$LOOPBACK/dead-present")" '1:1:1|3:1:1'
is "a successful empty attributed snapshot is reused" \
  "$(cat "$LOOPBACK/empty-cache")" '1:1:1'
is "implicit identity ignores an unrelated LAN-only owner" \
  "$(cat "$LOOPBACK/mixed-identity")" '0:999999 1'
is "implicit identity rejects unsafe eligible ownership and distinguishes query failure" \
  "$(cat "$LOOPBACK/identity-refusals")" '1:1:2'
is "listener identity calls the shared endpoint predicate on complete rows" \
  "$(sort "$LOOPBACK/identity-predicate-calls" | paste -sd,)" '127.0.0.1:4471,192.168.50.8:4471'
is "start preserves query and consent errors under sourced errexit" \
  "$(cat "$LOOPBACK/start-implicit-query.rc"):$(jq -r .error "$LOOPBACK/start-implicit-query.json" 2>/dev/null)|$(cat "$LOOPBACK/start-explicit-query.rc"):$(jq -r .error "$LOOPBACK/start-explicit-query.json" 2>/dev/null)|$(cat "$LOOPBACK/start-absent.rc"):$(jq -r .error "$LOOPBACK/start-absent.json" 2>/dev/null)|$(cat "$LOOPBACK/start-unapproved.rc"):$(jq -r .error "$LOOPBACK/start-unapproved.json" 2>/dev/null)" \
  '0:could not query attributed listening sockets|0:could not query attributed listening sockets|0:port 4471 is no longer served by the approved process|0:port 4471 is no longer served by the approved process'
is "rejected starts have no provider or signal effect" "$(wc -l < "$LOOPBACK/start-effects")" '0'
is "an attributed query failure precedes every partial, idle, and stop effect" \
  "$(jq -r .error "$LOOPBACK/pre-effect-query.json" 2>/dev/null)|$(wc -l < "$LOOPBACK/pre-effect-query-socket-queries")|$(wc -l < "$LOOPBACK/pre-effect-query-effects")|$(cmp -s "$LOOPBACK/pre-effect-query-before.json" "$LOOPBACK/pre-effect-query-after.json"; echo $?)|$(cat "$LOOPBACK/pre-effect-query-idle")" \
  'could not query attributed listening sockets|1|0|0|no-idle'
partial_targetless_idle=$(cut -d: -f1 "$LOOPBACK/partial-targetless-idle")
is "partial and targetless state skips attribution and keeps the fixed reapproval deadline" \
  "$(wc -l < "$LOOPBACK/partial-targetless-socket-queries")|$(grep -c '^partial-stop ' "$LOOPBACK/partial-targetless-effects")|$(cut -d: -f2 "$LOOPBACK/partial-targetless-idle")|$(jq -r '(.tunnels[0].targetHealthy | tostring) + "\t" + .tunnels[0].dns' "$LOOPBACK/partial-targetless.json" 2>/dev/null)|$([[ $partial_targetless_idle =~ ^[0-9]+$ ]] && echo timestamp)" \
  $'0|1|600|null\t|timestamp'
is "a raw-empty attributed replacement stops immediately without idle or output row" \
  "$(wc -l < "$LOOPBACK/replacement-stops")|$(wc -l < "$LOOPBACK/replacement-idles")|$(jq -c '[.ok, (.tunnels | length)]' "$LOOPBACK/replacement.json" 2>/dev/null)" \
  '1|0|[true,0]'
is "a raw-present attributed absence gets the fixed idle path without a stop" \
  "$(wc -l < "$LOOPBACK/disappeared-stops")|$(cat "$LOOPBACK/disappeared-idles")|$(jq -c '[.ok, (.tunnels | length), .tunnels[0].targetHealthy]' "$LOOPBACK/disappeared.json" 2>/dev/null)" \
  '0|cloudflared-4471.idle|[true,1,false]'
is "an attributed query failure makes no idle or stop mutation" \
  "$(cat "$LOOPBACK/status-query.rc"):$(jq -r .error "$LOOPBACK/status-query.json" 2>/dev/null)|$(wc -l < "$LOOPBACK/status-query-stops")|$(wc -l < "$LOOPBACK/status-query-idles")" \
  '0:could not query attributed listening sockets|0|0'
is "approved status clears idle and reports healthy" \
  "$(wc -l < "$LOOPBACK/approved-stops")|$(wc -l < "$LOOPBACK/approved-idles")|$(jq -c '.tunnels[0].targetHealthy' "$LOOPBACK/approved.json" 2>/dev/null)" \
  '0|0|true'
is "fresh LAN-only status uses the shared predicate twice and starts one idle deadline" \
  "$(wc -l < "$LOOPBACK/lan-only-stops")|$(cat "$LOOPBACK/lan-only-idles")|$(sort "$LOOPBACK/lan-only-predicate-calls" | paste -sd,)|$(jq -r '[.tunnels[0].targetHealthy, .tunnels[0].dns] | @tsv' "$LOOPBACK/lan-only.json" 2>/dev/null)" \
  $'0|cloudflared-4471.idle|192.168.50.8:4471,192.168.50.8:4471|false\t'
is "status classifies an absent target under sourced errexit" \
  "$(cat "$LOOPBACK/status-errexit.rc"):$(jq -c '[.ok, .tunnels[0].targetHealthy]' "$LOOPBACK/status-errexit.json" 2>/dev/null)" \
  '0:[true,false]'
is "the tunnel target regressions invoke no provider or signal effect" \
  "$(grep -Ec '^(kill|proc-effect|stop-line|group-alive|provider-bin|cloudflared-stop|ngrok-stop) ' "$LOOPBACK/effects" || true)" '0'

if [[ ${PORTAL_TEST_ONLY:-} == tunnel-targets ]]; then
  echo; echo "$pass passed, $fail failed"
  exit $((fail > 0))
fi
fi

portal_status_fixture_file() {
  local root=$1 port=$2 suffix=$3 spec=$4 kind value target
  kind=${spec%%:*}
  value=${spec#*:}
  case $kind in
    missing) ;;
    file) printf '%s' "$value" > "$root/portal/portless-$port.$suffix" ;;
    raw-nul) printf 'https://ac\0me.test' > "$root/portal/portless-$port.$suffix" ;;
    raw-lf) printf 'https://acme.test\n' > "$root/portal/portless-$port.$suffix" ;;
    raw-us) printf 'https://acme.test/\037tail' > "$root/portal/portless-$port.$suffix" ;;
    raw-tab) printf 'https://acme.test/\ttail' > "$root/portal/portless-$port.$suffix" ;;
    raw-reach) printf 'local\0public' > "$root/portal/portless-$port.$suffix" ;;
    raw-invalid) printf '\200' > "$root/portal/portless-$port.$suffix" ;;
    refused)
      target="$root/refused-$suffix"
      printf '%s' "$value" > "$target"
      ln -s "$target" "$root/portal/portless-$port.$suffix"
      ;;
  esac
}

run_portal_status_case() {
  local id=$1 port=$2 routes=$3 marker=$4 url=$5 reach=$6
  local hook=${7:-none} url_mode=${8:-live} live_port=${9:-none} action=${10:-status} repeats=${11:-1}
  local root="$T/portal-status-$id" i
  rm -rf "$root"
  mkdir -p "$root/portal" "$root/portless"
  printf '["test"]' > "$root/portless/proxy.tlds"
  if [[ $routes == refused:* ]]; then
    printf '%s' "${routes#*:}" > "$root/refused-routes"
    ln -s "$root/refused-routes" "$root/portless/routes.json"
  elif [[ $routes != missing ]]; then
    printf '%s' "$routes" > "$root/portless/routes.json"
  fi
  portal_status_fixture_file "$root" "$port" name "$marker"
  portal_status_fixture_file "$root" "$port" url "$url"
  portal_status_fixture_file "$root" "$port" reach "$reach"
  if [[ $hook == initial-other-refused ]]; then
    printf 'https://cache.test/refused' > "$root/portal/portless-4102.url"
    printf refused > "$root/refused-other"
    ln -s "$root/refused-other" "$root/portal/portless-4102.name"
  elif [[ $hook == fresh-other-refused ]]; then
    printf 'https://cache.test/fresh' > "$root/portal/portless-4102.url"
    printf refused > "$root/refused-other"
  fi
  if [[ -e $root/portless/routes.json || -L $root/portless/routes.json ]]; then
    cp -L "$root/portless/routes.json" "$root/routes.expected"
  else
    : > "$root/routes.absent"
  fi
  : > "$root/effects"
  : > "$root/mutations"
  : > "$root/adoptions"
  : > "$root/stops"
  CASE_ROOT="$root" CASE_PORT="$port" CASE_HOOK="$hook" CASE_URL_MODE="$url_mode" \
    CASE_LIVE_PORT="$live_port" CASE_ACTION="$action" CASE_REPEATS="$repeats" \
    PORTAL_STATE_DIR="$root/portal" PORTLESS_STATE_DIR="$root/portless" PORTAL_PORTLESS_TLD=test \
    S="$S" bash -c '
      source "$S/tunnels.sh"
      route_matches_expected() {
        if [[ -e $CASE_ROOT/routes.absent ]]; then
          [[ ! -e $PORTLESS_DIR/routes.json && ! -L $PORTLESS_DIR/routes.json ]]
        else
          [[ -e $PORTLESS_DIR/routes.json || -L $PORTLESS_DIR/routes.json ]] \
            && cmp -s "$PORTLESS_DIR/routes.json" "$CASE_ROOT/routes.expected"
        fi
      }
      provider_bin() { printf "provider:%s\n" "$1" >> "$CASE_ROOT/effects"; return 1; }
      proc() { printf "proc:%s\n" "$*" >> "$CASE_ROOT/effects"; return 1; }
      kill() { printf "kill:%s\n" "$*" >> "$CASE_ROOT/effects"; return 1; }
      cloudflared_adopt() { :; }
      ngrok_adopt() { :; }
      eval "$(declare -f portless_adopt | sed "1s/portless_adopt/portal_status_real_portless_adopt/")"
      portless_adopt() {
        printf "portless\n" >> "$CASE_ROOT/adoptions"
        portal_status_real_portless_adopt
      }
      portless_probe() { PROBE_PORT=1355; PROBE_SCHEME=https; return 0; }
      portless_listener_scope() { echo local; }
      portless_host_url() {
        [[ $CASE_URL_MODE == fallback ]] && return 0
        printf "https://%s:1355" "$1"
      }
      ss() {
        [[ $CASE_LIVE_PORT == none ]] && return 0
        printf "LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n" "$CASE_LIVE_PORT"
      }
      state() {
        local counter next expected_host marker
        if [[ $1 == dump && $2 == "$PORTLESS_DIR" ]]; then
          counter="$CASE_ROOT/provider-dumps"
          next=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
          printf "%s" "$next" > "$counter"
          if (( next >= 2 )) && [[ ! -e $CASE_ROOT/hook.done ]]; then
            case $CASE_HOOK in
              route-appears)
                marker=$(cat "$STATE_DIR/portless-$CASE_PORT.name")
                expected_host="${marker,,}.test"
                printf "[{\"hostname\":\"%s\",\"port\":%s,\"pid\":0}]" "$expected_host" "$((10#$CASE_PORT))" > "$PORTLESS_DIR/routes.json"
                cp "$PORTLESS_DIR/routes.json" "$CASE_ROOT/routes.expected"
                : > "$CASE_ROOT/hook.done"
                ;;
              route-disappears)
                printf "[{\"hostname\":\"other.test\",\"port\":%s,\"pid\":0}]" "$((10#$CASE_PORT))" > "$PORTLESS_DIR/routes.json"
                cp "$PORTLESS_DIR/routes.json" "$CASE_ROOT/routes.expected"
                : > "$CASE_ROOT/hook.done"
                ;;
            esac
          fi
        elif [[ $1 == dump && $2 == "$STATE_DIR" ]]; then
          counter="$CASE_ROOT/portal-dumps"
          next=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
          printf "%s" "$next" > "$counter"
          if (( next >= 2 )) && [[ ! -e $CASE_ROOT/hook.done ]]; then
            case $CASE_HOOK in
              marker-changes) printf Changed > "$STATE_DIR/portless-$CASE_PORT.name"; : > "$CASE_ROOT/hook.done" ;;
              url-published)
                marker=$(cat "$STATE_DIR/portless-$CASE_PORT.name")
                printf "https://%s.test" "${marker,,}" > "$STATE_DIR/portless-$CASE_PORT.url"
                : > "$CASE_ROOT/hook.done"
                ;;
              reach-changes) printf raced > "$STATE_DIR/portless-$CASE_PORT.reach"; : > "$CASE_ROOT/hook.done" ;;
              reach-invalid-change) printf "\201" > "$STATE_DIR/portless-$CASE_PORT.reach"; : > "$CASE_ROOT/hook.done" ;;
              fresh-other-refused) ln -s "$CASE_ROOT/refused-other" "$STATE_DIR/portless-4102.name"; : > "$CASE_ROOT/hook.done" ;;
            esac
          fi
        fi
        /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"
      }
      write_own() {
        route_matches_expected || printf "routes-changed-before-write\n" >> "$CASE_ROOT/effects"
        printf "write:%s=%s\n" "${1##*/}" "$2" >> "$CASE_ROOT/mutations"
        printf "%s" "$2" | /usr/bin/python3 -I -S "$STATEDIR_PY" write "$1" 2>/dev/null
        route_matches_expected || printf "routes-changed-after-write\n" >> "$CASE_ROOT/effects"
      }
      state_remove() {
        local directory=$1 leaf
        shift
        route_matches_expected || printf "routes-changed-before-remove\n" >> "$CASE_ROOT/effects"
        for leaf in "$@"; do printf "remove:%s\n" "$leaf" >> "$CASE_ROOT/mutations"; done
        /usr/bin/python3 -I -S "$STATEDIR_PY" remove "$directory" "$@" 2>/dev/null
        route_matches_expected || printf "routes-changed-after-remove\n" >> "$CASE_ROOT/effects"
      }
      if [[ $CASE_ACTION == stop-all ]]; then
        cmd_stop() { printf "%s:%s:%s\n" "$1" "$2" "${3:-}" >> "$CASE_ROOT/stops"; echo "{\"ok\":true}"; }
        cmd_stop_all > "$CASE_ROOT/out.1"
        route_matches_expected || printf "routes-changed-after-status\n" >> "$CASE_ROOT/effects"
      else
        for ((i = 1; i <= CASE_REPEATS; i++)); do
          cmd_status > "$CASE_ROOT/out.$i"
          route_matches_expected || printf "routes-changed-after-status\n" >> "$CASE_ROOT/effects"
        done
      fi
    ' 2> "$root/stderr"
  PORTAL_STATUS_ROOT=$root
  if [[ -s $root/effects ]]; then
    bad "status $id invokes no provider or signal effect: $(tr '\n' ' ' < "$root/effects")"
  else
    ok "status $id invokes no provider or signal effect"
  fi
  if [[ -e $root/routes.absent ]]; then
    [[ ! -e $root/portless/routes.json && ! -L $root/portless/routes.json ]] \
      && ok "status $id preserves provider routes" || bad "status $id created provider routes"
  elif cmp -s "$root/portless/routes.json" "$root/routes.expected"; then
    ok "status $id preserves provider routes"
  else
    bad "status $id changed provider routes"
  fi
}

status_row() { jq -c '[.tunnels[]? | [.provider,.port,.url,.reach]]' "$1"; }

DIGEST_DUMP="$T/portal-status-digest"; mkdir -p "$DIGEST_DUMP"
printf 'nul\0bytes' > "$DIGEST_DUMP/nul"
printf 'bad\377bytes' > "$DIGEST_DUMP/invalid-utf8"
printf refused > "$T/portal-status-digest-target"
ln -s "$T/portal-status-digest-target" "$DIGEST_DUMP/refused"
digest_dump=$(state dump "$DIGEST_DUMP" 8192 32)
digest_nul=$(sha256sum "$DIGEST_DUMP/nul" | cut -d' ' -f1)
digest_invalid=$(sha256sum "$DIGEST_DUMP/invalid-utf8" | cut -d' ' -f1)
is "state dump hashes exact NUL and invalid UTF-8 bytes from the bound read" \
  "$(jq -r --arg n "$digest_nul" --arg i "$digest_invalid" '[.sha256.nul == $n, .sha256["invalid-utf8"] == $i] | @tsv' <<< "$digest_dump")" \
  $'true\ttrue'
is "state dump gives refused leaves no digest" \
  "$(jq -c '[keys, .refused, ((.sha256 // {}) | has("refused"))]' <<< "$digest_dump")" \
  '[["files","refused","sha256"],["refused"],false]'
evidence_digest=$(printf raw | sha256sum | cut -d' ' -f1)
evidence_dump=$(jq -nc --arg d "$evidence_digest" \
  '{files:{"portless-3037.name":"raw"},refused:[],sha256:{"portless-3037.name":$d}}')
evidence_shape=$(portal_portless_evidence "$evidence_dump" portless-3037 pending)
is "Portal evidence contains only exact presence refusal and digest facts" \
  "$(jq -c '[map(keys), .[0].sha256]' <<< "$evidence_shape")" \
  "[[[\"present\",\"refused\",\"sha256\"],[\"present\",\"refused\",\"sha256\"]],\"$evidence_digest\"]"
missing_digest_dump='{"files":{"portless-3037.name":"raw"},"refused":[],"sha256":{}}'
portal_portless_evidence "$missing_digest_dump" portless-3037 pending >/dev/null \
  && missing_digest_result=authorized || missing_digest_result=blocked
is "present Portal evidence without a valid digest cannot authorize mutation" "$missing_digest_result" blocked

marker_40=$(printf 'A%.0s' {1..40})
marker_41=${marker_40}A
is "Portal markers accept and lowercase one 40-byte ASCII DNS label" "$(portal_marker_lower "$marker_40")" "${marker_40,,}"
portal_marker_lower "$marker_41" >/dev/null && marker_41_result=accepted || marker_41_result=rejected
is "Portal markers reject 41 bytes" "$marker_41_result" rejected
url_label_63=$(printf 'a%.0s' {1..63})
url_label_64=${url_label_63}a
is "canonical URL hostnames lowercase a 63-byte label" \
  "$(canonical_url_hostname "https://UPPER.$url_label_63")" "upper.$url_label_63"
canonical_url_hostname "https://$url_label_64.test" >/dev/null && url_label_64_result=accepted || url_label_64_result=rejected
is "canonical URL hostnames reject a 64-byte label" "$url_label_64_result" rejected

exact_routes='[{"hostname":"other.test","port":3000,"pid":0},{"hostname":"acme.test","port":3e3,"pid":0}]'
run_portal_status_case exact-pending 03000 "$exact_routes" file:AcMe missing: missing: none live none status 2
is "status completes an exact pending alias from a duplicate leading-zero port" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-03000.url")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-03000.reach")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-03000.name")" \
  '[["portless",3000,"https://acme.test:1355","local"]]|https://acme.test:1355|local|AcMe'
is "a second status is idempotent after pending completion" \
  "$(cmp -s "$PORTAL_STATUS_ROOT/out.1" "$PORTAL_STATUS_ROOT/out.2" && echo same)|$(cat "$PORTAL_STATUS_ROOT/mutations")" \
  $'same|write:portless-03000.reach=local\nwrite:portless-03000.url=https://acme.test:1355'

run_portal_status_case pending-fallback 3001 '[{"hostname":"beta.test","port":3001,"pid":0}]' file:BeTa missing: file:bogus none fallback none status
is "pending completion replaces malformed reach before the fallback URL" \
  "$(cat "$PORTAL_STATUS_ROOT/mutations")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  $'write:portless-3001.reach=local\nwrite:portless-3001.url=https://beta.test|[["portless",3001,"https://beta.test","local"]]'

run_portal_status_case pending-mismatch 3002 '[{"hostname":"other.test","port":3002,"pid":0}]' file:gone missing: file:local none live none status 2
is "a confirmed pending mismatch clears URL reach and name in order once" \
  "$(cat "$PORTAL_STATUS_ROOT/mutations")|$(find "$PORTAL_STATUS_ROOT/portal" -maxdepth 1 -type f -o -type l | wc -l)|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  $'remove:portless-3002.url\nremove:portless-3002.reach\nremove:portless-3002.name|0|[]'

run_portal_status_case pending-route-race 3003 '[{"hostname":"other.test","port":3003,"pid":0}]' file:race missing: file:local route-appears live none status
is "a pending route that appears on confirmation completes from fresh state" \
  "$(cat "$PORTAL_STATUS_ROOT/mutations")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  $'write:portless-3003.reach=local\nwrite:portless-3003.url=https://race.test:1355|[["portless",3003,"https://race.test:1355","local"]]'

run_portal_status_case pending-route-disappears 3030 '[{"hostname":"vanish.test","port":3030,"pid":0}]' file:Vanish missing: file:local route-disappears live none status
is "a pending route that disappears on confirmation clears from fresh state" \
  "$(cat "$PORTAL_STATUS_ROOT/mutations")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  $'remove:portless-3030.url\nremove:portless-3030.reach\nremove:portless-3030.name|[]'

run_portal_status_case pending-reach-completes 3031 '[{"hostname":"reach-race.test","port":3031,"pid":0}]' file:Reach-Race missing: file:local reach-changes live none status
is "a pending reach race does not cancel fresh exact completion" \
  "$(cat "$PORTAL_STATUS_ROOT/mutations")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  $'write:portless-3031.reach=local\nwrite:portless-3031.url=https://reach-race.test:1355|[["portless",3031,"https://reach-race.test:1355","local"]]'

run_portal_status_case pending-reach-clears 3032 '[{"hostname":"other.test","port":3032,"pid":0}]' file:Gone missing: file:local reach-changes live none status
is "a pending reach race does not cancel fresh mismatch cleanup" \
  "$(cat "$PORTAL_STATUS_ROOT/mutations")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  $'remove:portless-3032.url\nremove:portless-3032.reach\nremove:portless-3032.name|[]'

run_portal_status_case pending-marker-race 3004 '[{"hostname":"before.test","port":3004,"pid":0}]' file:Before missing: file:local marker-changes live none status
is "a changed pending marker cancels the stale completion" \
  "$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-3004.name")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  '0|Changed|[]'

run_portal_status_case pending-url-race 3005 '[{"hostname":"publish.test","port":3005,"pid":0}]' file:Publish missing: missing: url-published live none status
is "a concurrently published URL is not overwritten and appears from the refreshed dump" \
  "$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-3005.url")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  '0|https://publish.test|[["portless",3005,"https://publish.test","local"]]'

run_portal_status_case pending-stop-all 03000 '[{"hostname":"stop.test","port":3000,"pid":0}]' file:Stop missing: missing: none live none stop-all
is "stop-all passes the numeric and lexical ports from its private status call" \
  "$(cat "$PORTAL_STATUS_ROOT/stops")|$(jq -c . "$PORTAL_STATUS_ROOT/out.1")" \
  $'portless:3000:03000|{"ok":true}'

run_portal_status_case complete-missing-reach 3007 '[{"hostname":"mixed.test","port":3007,"pid":0}]' file:MiXeD file:https://mixed.test/path missing: none live none status
is "an exact mixed-case complete record keeps marker bytes and falls back to local reach" \
  "$(cat "$PORTAL_STATUS_ROOT/portal/portless-3007.name")|$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")" \
  'MiXeD|[["portless",3007,"https://mixed.test/path","local"]]|0'

run_portal_status_case complete-malformed-reach 3008 '[{"hostname":"reach.test","port":3008,"pid":0}]' file:Reach file:https://REACH.test file:bogus none live none status
is "observed proxy scope replaces malformed reach without rewriting its record" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-3008.reach")" \
  '[["portless",3008,"https://REACH.test","local"]]|bogus'

run_portal_status_case complete-unrelated-port 3009 '[{"hostname":"unrelated.test","port":3009,"pid":0}]' file:owned file:https://owned.test file:local none live none status
is "an unrelated same-port route cannot prove complete ownership" \
  "$(cat "$PORTAL_STATUS_ROOT/mutations")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  $'remove:portless-3009.url\nremove:portless-3009.reach\nremove:portless-3009.name|[]'

run_portal_status_case complete-positive-pid 3010 '[{"hostname":"owned.test","port":3010,"pid":999999}]' file:Owned file:https://owned.test file:local none live none status
is "a positive-PID route mismatch clears complete metadata in URL reach name order" \
  "$(cat "$PORTAL_STATUS_ROOT/mutations")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  $'remove:portless-3010.url\nremove:portless-3010.reach\nremove:portless-3010.name|[]'

run_portal_status_case complete-route-race 3011 '[{"hostname":"other.test","port":3011,"pid":0}]' file:late file:https://late.test file:local route-appears live none status
is "a complete exact route appearing on confirmation prevents stale cleanup" \
  "$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-3011.url")|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  '0|https://late.test|[["portless",3011,"https://late.test","local"]]'

run_portal_status_case complete-local-race 3012 '[{"hostname":"owned.test","port":3012,"pid":999999}]' file:Owned file:https://owned.test file:local reach-changes live none status
is "changed complete local evidence prevents stale cleanup" \
  "$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-3012.reach")|$(test -e "$PORTAL_STATUS_ROOT/portal/portless-3012.url" && echo kept || echo lost)" \
  '0|raced|kept'

run_portal_status_case complete-invalid-reach-race 3033 '[{"hostname":"owned.test","port":3033,"pid":999999}]' file:Owned file:https://owned.test raw-invalid: reach-invalid-change live none status
is "distinct invalid reach bytes with the same decoded text block complete cleanup" \
  "$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(test -e "$PORTAL_STATUS_ROOT/portal/portless-3033.url" && echo kept || echo lost)|$(od -An -t x1 "$PORTAL_STATUS_ROOT/portal/portless-3033.reach" | tr -d ' \n')" \
  '0|kept|81'

run_portal_status_case initial-global-refused 4101 '[{"hostname":"other.test","port":4101,"pid":0}]' file:Clean file:https://clean.test file:local initial-other-refused live none status
is "an initially refused Portless leaf preserves every other mismatching record" \
  "$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(test -e "$PORTAL_STATUS_ROOT/portal/portless-4101.url" && echo clean-kept || echo clean-lost)|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  '0|clean-kept|[["portless",4101,"https://clean.test","local"],["portless",4102,"https://cache.test/refused","local"]]'

run_portal_status_case fresh-global-refused 4101 '[{"hostname":"other.test","port":4101,"pid":0}]' file:Clean file:https://clean.test file:local fresh-other-refused live none status
is "a newly refused Portless leaf cancels all cleanup from the fresh dump" \
  "$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(test -e "$PORTAL_STATUS_ROOT/portal/portless-4101.url" && echo clean-kept || echo clean-lost)|$(status_row "$PORTAL_STATUS_ROOT/out.1")" \
  '0|clean-kept|[["portless",4101,"https://clean.test","local"],["portless",4102,"https://cache.test/fresh","local"]]'

run_portal_status_case known-url-only 3013 '[{"hostname":"adopted.test","port":3013,"pid":0}]' missing: file:https://cache.test/cached missing: none live 3013 status
is "known URL-only state is adopted from the fixed route rather than tracked from cache" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(test -e "$PORTAL_STATUS_ROOT/portal/portless-3013.url" && echo kept || echo lost)|$(wc -l < "$PORTAL_STATUS_ROOT/adoptions")" \
  '[["portless",3013,"https://adopted.test:1355","local"]]|kept|1'

run_portal_status_case leading-zero-dedup 03000 '[{"hostname":"tracked.test","port":3000,"pid":0},{"hostname":"adopted.test","port":3000,"pid":0}]' file:Tracked file:https://tracked.test file:local none live 3000 status
is "a leading-zero tracked row suppresses numeric adopted duplicates" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(jq -c '.tunnels[0] | keys' "$PORTAL_STATUS_ROOT/out.1")" \
  '[["portless",3000,"https://tracked.test","local"]]|["aliasName","dns","managed","port","provider","reach","targetHealthy","url"]'

run_portal_status_case malformed-marker 3014 '[{"hostname":"bad.name.test","port":3014,"pid":0}]' file:bad.name file:https://bad.name.test file:local none live none status
is "a malformed marker stays untracked under known provider state" "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")" '[]|0'

run_portal_status_case unrelated-marker 3015 '[{"hostname":"url.test","port":3015,"pid":0}]' file:other file:https://url.test file:local none live none status
is "a marker unrelated to its URL stays untracked under known provider state" "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")" '[]|0'

run_portal_status_case malformed-url-host 3016 '[{"hostname":"bad.test","port":3016,"pid":0}]' file:bad file:https://bad..test file:local none live none status
is "a noncanonical URL hostname stays untracked under known provider state" "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")" '[]|0'

run_portal_status_case known-url-only-no-route 3017 missing missing: file:https://cache.test missing: none live none status
is "known URL-only state without a provider route emits no row" "$(status_row "$PORTAL_STATUS_ROOT/out.1")" '[]'

run_portal_status_case outage-url-only 3018 '{' missing: file:https://cache.test/outage missing: none live none status
is "malformed provider state renders readable URL-only cache without adoption" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/adoptions")" \
  '[["portless",3018,"https://cache.test/outage","local"]]|0'

run_portal_status_case outage-pending 3026 '{' file:Pending missing: file:local none live none status
is "provider outage keeps pending evidence without publishing a row" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-3026.name")" \
  '[]|0|Pending'

run_portal_status_case outage-malformed-host 3027 '{' file:bad file:https://bad..test file:local none live none status
is "provider outage renders a valid URL shape with a noncanonical hostname" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")" \
  '[["portless",3027,"https://bad..test","local"]]|0'

run_portal_status_case outage-complete-mismatch 3028 '{' file:Owned file:https://owned.test file:local none live none status
is "provider outage keeps related complete evidence instead of cleaning it" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$(test -e "$PORTAL_STATUS_ROOT/portal/portless-3028.name" && echo kept || echo lost)" \
  '[["portless",3028,"https://owned.test","local"]]|0|kept'

run_portal_status_case outage-malformed-name 3019 '{' file:bad.name file:https://cache.test/name file:local none live none status
is "provider outage renders cache with a malformed marker" "$(status_row "$PORTAL_STATUS_ROOT/out.1")" '[["portless",3019,"https://cache.test/name","local"]]'

run_portal_status_case outage-refused-routes 3020 'refused:[{"hostname":"cache.test","port":3020,"pid":0}]' missing: file:https://cache.test/refused-routes missing: none live none status
is "refused provider routes render readable URL cache without adoption" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/adoptions")" \
  '[["portless",3020,"https://cache.test/refused-routes","local"]]|0'

run_portal_status_case outage-refused-name 3021 '[{"hostname":"cache.test","port":3021,"pid":0}]' refused:Cache file:https://cache.test/refused-name missing: none live none status
is "a refused name leaf renders readable URL cache without adoption" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/adoptions")" \
  '[["portless",3021,"https://cache.test/refused-name","local"]]|0'

run_portal_status_case outage-refused-reach 3022 '[{"hostname":"cache.test","port":3022,"pid":0}]' file:Cache file:https://cache.test/refused-reach refused:public none live none status
is "a refused reach leaf renders readable URL cache with fallback and no adoption" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -l < "$PORTAL_STATUS_ROOT/adoptions")" \
  '[["portless",3022,"https://cache.test/refused-reach","local"]]|0'

run_portal_status_case refused-url 3023 '[{"hostname":"cache.test","port":3023,"pid":0}]' file:Cache refused:https://cache.test file:local none live none status
is "a refused URL leaf emits no row and stays on disk" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(test -L "$PORTAL_STATUS_ROOT/portal/portless-3023.url" && echo kept || echo lost)" '[]|kept'

run_portal_status_case malformed-readable-url 3024 '{' file:Cache file:not-a-url file:local none live none status
is "a readable malformed URL remains a hard status error" \
  "$(jq -c .ok "$PORTAL_STATUS_ROOT/out.1")|$(test -e "$PORTAL_STATUS_ROOT/portal/portless-3024.url" && echo kept || echo lost)" 'false|kept'

for unsafe_url_kind in nul lf us tab; do
  run_portal_status_case "unsafe-url-$unsafe_url_kind" 3034 '[{"hostname":"acme.test","port":3034,"pid":0}]' file:Acme "raw-$unsafe_url_kind:" file:local none live none status
  unsafe_url_hash=$(sha256sum "$PORTAL_STATUS_ROOT/portal/portless-3034.url" | cut -d' ' -f1)
  is "a raw $unsafe_url_kind URL hard-errors without warning or mutation" \
    "$(jq -c .ok "$PORTAL_STATUS_ROOT/out.1")|$(wc -c < "$PORTAL_STATUS_ROOT/stderr")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$unsafe_url_hash" \
    "false|0|0|$(case $unsafe_url_kind in nul) printf 'https://ac\0me.test' ;; lf) printf 'https://acme.test\n' ;; us) printf 'https://acme.test/\037tail' ;; tab) printf 'https://acme.test/\ttail' ;; esac | sha256sum | cut -d' ' -f1)"
done

run_portal_status_case unsafe-reach 3035 '[{"hostname":"acme.test","port":3035,"pid":0}]' file:Acme file:https://acme.test raw-reach: none live none status
unsafe_reach_hash=$(sha256sum "$PORTAL_STATUS_ROOT/portal/portless-3035.reach" | cut -d' ' -f1)
is "a framing-unsafe reach falls back to local without rewriting bytes" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(wc -c < "$PORTAL_STATUS_ROOT/stderr")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")|$unsafe_reach_hash" \
  "[[\"portless\",3035,\"https://acme.test\",\"local\"]]|0|0|$(printf 'local\0public' | sha256sum | cut -d' ' -f1)"

run_portal_status_case reach-only 3025 '[{"hostname":"cache.test","port":3025,"pid":0}]' missing: missing: file:local none live none status
is "reach-only state stays on disk without a row" \
  "$(status_row "$PORTAL_STATUS_ROOT/out.1")|$(cat "$PORTAL_STATUS_ROOT/portal/portless-3025.reach")|$(wc -l < "$PORTAL_STATUS_ROOT/mutations")" '[]|local|0'

STOP_MARKER="$T/portal-stop-marker"; mkdir -p "$STOP_MARKER/portal" "$STOP_MARKER/portless"
printf '[]' > "$STOP_MARKER/portless/routes.json"
printf 'bad.name' > "$STOP_MARKER/portal/portless-3026.name"
: > "$STOP_MARKER/effects"
stop_marker_out=$(CASE_ROOT="$STOP_MARKER" PORTAL_STATE_DIR="$STOP_MARKER/portal" PORTLESS_STATE_DIR="$STOP_MARKER/portless" S="$S" bash -c '
  source "$S/tunnels.sh"
  proc() { printf "proc\n" >> "$CASE_ROOT/effects"; return 1; }
  kill() { printf "kill\n" >> "$CASE_ROOT/effects"; return 1; }
  provider_bin() { printf "provider\n" >> "$CASE_ROOT/effects"; return 1; }
  cmd_stop portless 3026
')
is "stop rejects a malformed Portal marker before provider resolution or effects" \
  "$(jq -c .ok <<< "$stop_marker_out")|$(wc -l < "$STOP_MARKER/effects")|$(cat "$STOP_MARKER/portal/portless-3026.name")" 'false|0|bad.name'

for unsafe_marker_kind in nul lf us tab; do
  marker_root="$T/portal-stop-marker-$unsafe_marker_kind"
  mkdir -p "$marker_root/portal" "$marker_root/portless"
  case $unsafe_marker_kind in
    nul) printf 'Ac\0me' > "$marker_root/portal/portless-3036.name" ;;
    lf) printf 'Acme\n' > "$marker_root/portal/portless-3036.name" ;;
    us) printf 'Ac\037me' > "$marker_root/portal/portless-3036.name" ;;
    tab) printf 'Ac\tme' > "$marker_root/portal/portless-3036.name" ;;
  esac
  printf '[]' > "$marker_root/portless/routes.json"
  marker_hash=$(sha256sum "$marker_root/portal/portless-3036.name" | cut -d' ' -f1)
  : > "$marker_root/effects"
  stop_marker_out=$(CASE_ROOT="$marker_root" PORTAL_STATE_DIR="$marker_root/portal" PORTLESS_STATE_DIR="$marker_root/portless" S="$S" bash -c '
    source "$S/tunnels.sh"
    proc() { printf "proc\n" >> "$CASE_ROOT/effects"; return 1; }
    kill() { printf "kill\n" >> "$CASE_ROOT/effects"; return 1; }
    provider_bin() { printf "provider\n" >> "$CASE_ROOT/effects"; return 1; }
    cmd_stop portless 3036
  ' 2> "$marker_root/stderr")
  is "stop rejects a raw $unsafe_marker_kind marker before provider resolution without warning" \
    "$(jq -c .ok <<< "$stop_marker_out")|$(wc -c < "$marker_root/stderr")|$(wc -l < "$marker_root/effects")|$(sha256sum "$marker_root/portal/portless-3036.name" | cut -d' ' -f1)" \
    "false|0|0|$marker_hash"
done

PUBLIC_STOP="$T/portal-public-leading-stop"; mkdir -p "$PUBLIC_STOP/portal" "$PUBLIC_STOP/portless"
printf Acme > "$PUBLIC_STOP/portal/portless-03000.name"
printf https://acme.test > "$PUBLIC_STOP/portal/portless-03000.url"
printf local > "$PUBLIC_STOP/portal/portless-03000.reach"
printf '[{"hostname":"other.test","port":3000,"pid":0},{"hostname":"acme.test","port":3000,"pid":0}]' > "$PUBLIC_STOP/portless/routes.json"
cat > "$PUBLIC_STOP/fake-portless" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$EFFECT_LOG"
jq --arg n "$3" '[.[] | select((.hostname | split(".")[0] | ascii_downcase) != ($n | ascii_downcase))]' \
  "$PORTLESS_STATE_DIR/routes.json" > "$PORTLESS_STATE_DIR/new"
mv "$PORTLESS_STATE_DIR/new" "$PORTLESS_STATE_DIR/routes.json"
SH
chmod 700 "$PUBLIC_STOP/fake-portless"
: > "$PUBLIC_STOP/signals"
public_stop_out=$(CASE_ROOT="$PUBLIC_STOP" EFFECT_LOG="$PUBLIC_STOP/provider" FAKE="$PUBLIC_STOP/fake-portless" \
  PORTAL_STATE_DIR="$PUBLIC_STOP/portal" PORTLESS_STATE_DIR="$PUBLIC_STOP/portless" S="$S" bash -c '
    source "$S/tunnels.sh"
    proc() { printf "proc\n" >> "$CASE_ROOT/signals"; return 1; }
    kill() { printf "kill\n" >> "$CASE_ROOT/signals"; return 1; }
    provider_bin() { printf "%s" "$FAKE"; }
    cmd_stop portless 3000
  ')
is "public single-stop resolves lexical leading-zero ownership before the provider effect" \
  "$(jq -c .ok <<< "$public_stop_out")|$(cat "$PUBLIC_STOP/provider")|$(jq -c . "$PUBLIC_STOP/portless/routes.json")|$(find "$PUBLIC_STOP/portal" -maxdepth 1 -type f | wc -l)|$(wc -l < "$PUBLIC_STOP/signals")" \
  $'true|alias --remove Acme|[{"hostname":"other.test","port":3000,"pid":0}]|0|0'

AMBIGUOUS_STOP="$T/portal-ambiguous-stop"; mkdir -p "$AMBIGUOUS_STOP/portal" "$AMBIGUOUS_STOP/portless"
printf One > "$AMBIGUOUS_STOP/refused-name"
ln -s "$AMBIGUOUS_STOP/refused-name" "$AMBIGUOUS_STOP/portal/portless-03000.name"
printf https://two.test > "$AMBIGUOUS_STOP/portal/portless-3000.url"
printf '[]' > "$AMBIGUOUS_STOP/portless/routes.json"
: > "$AMBIGUOUS_STOP/effects"
ambiguous_stop_out=$(CASE_ROOT="$AMBIGUOUS_STOP" PORTAL_STATE_DIR="$AMBIGUOUS_STOP/portal" PORTLESS_STATE_DIR="$AMBIGUOUS_STOP/portless" S="$S" bash -c '
  source "$S/tunnels.sh"
  proc() { printf "proc\n" >> "$CASE_ROOT/effects"; return 1; }
  kill() { printf "kill\n" >> "$CASE_ROOT/effects"; return 1; }
  provider_bin() { printf "provider\n" >> "$CASE_ROOT/effects"; return 1; }
  cmd_stop portless 3000
')
is "public single-stop refuses ambiguous lexical ownership before provider or signal effects" \
  "$(jq -c .ok <<< "$ambiguous_stop_out")|$(find "$AMBIGUOUS_STOP/portal" -maxdepth 1 \( -type f -o -type l \) | wc -l)|$(wc -l < "$AMBIGUOUS_STOP/effects")" \
  'false|2|0'

MIXED_STOP="$T/portal-mixed-stop"; mkdir -p "$MIXED_STOP/portal" "$MIXED_STOP/portless"
printf MiXeD > "$MIXED_STOP/portal/portless-3000.name"
printf https://mixed.test > "$MIXED_STOP/portal/portless-3000.url"
printf local > "$MIXED_STOP/portal/portless-3000.reach"
printf '[{"hostname":"mixed.test","port":3000,"pid":0}]' > "$MIXED_STOP/portless/routes.json"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$EFFECT_LOG"\n' > "$MIXED_STOP/fake-portless"
chmod 700 "$MIXED_STOP/fake-portless"
: > "$MIXED_STOP/signals"
mixed_stop_out=$(CASE_ROOT="$MIXED_STOP" EFFECT_LOG="$MIXED_STOP/provider" FAKE="$MIXED_STOP/fake-portless" \
  PORTAL_STATE_DIR="$MIXED_STOP/portal" PORTLESS_STATE_DIR="$MIXED_STOP/portless" S="$S" bash -c '
    source "$S/tunnels.sh"
    proc() { printf "proc\n" >> "$CASE_ROOT/signals"; return 1; }
    kill() { printf "kill\n" >> "$CASE_ROOT/signals"; return 1; }
    provider_bin() { printf "%s" "$FAKE"; }
    cmd_stop portless 3000
  ')
is "mixed-case stop verifies the lowercase route while preserving original effect bytes" \
  "$(jq -c .ok <<< "$mixed_stop_out")|$(cat "$MIXED_STOP/provider")|$(cat "$MIXED_STOP/portal/portless-3000.name")|$(wc -l < "$MIXED_STOP/signals")" \
  $'false|alias --remove MiXeD|MiXeD|0'

DUAL_STATUS="$T/portal-dual-status"; mkdir -p "$DUAL_STATUS/portal" "$DUAL_STATUS/portless"
printf '["test"]' > "$DUAL_STATUS/portless/proxy.tlds"
printf '[{"hostname":"one.test","port":3000,"pid":0},{"hostname":"two.test","port":3000,"pid":0}]' > "$DUAL_STATUS/portless/routes.json"
for dual in '03000 One one' '3000 Two two'; do
  set -- $dual
  printf '%s' "$2" > "$DUAL_STATUS/portal/portless-$1.name"
  printf 'https://%s.test' "$3" > "$DUAL_STATUS/portal/portless-$1.url"
  printf local > "$DUAL_STATUS/portal/portless-$1.reach"
done
dual_routes_hash=$(sha256sum "$DUAL_STATUS/portless/routes.json" | cut -d' ' -f1)
: > "$DUAL_STATUS/effects"
CASE_ROOT="$DUAL_STATUS" PORTAL_STATE_DIR="$DUAL_STATUS/portal" PORTLESS_STATE_DIR="$DUAL_STATUS/portless" PORTAL_PORTLESS_TLD=test S="$S" bash -c '
  source "$S/tunnels.sh"
  provider_bin() { printf "provider\n" >> "$CASE_ROOT/effects"; return 1; }
  proc() { printf "proc\n" >> "$CASE_ROOT/effects"; return 1; }
  kill() { printf "kill\n" >> "$CASE_ROOT/effects"; return 1; }
  cloudflared_adopt() { :; }; ngrok_adopt() { :; }
  portless_adopt() { printf "3000\thttps://adopted.test\n"; }
  portless_probe() { return 1; }
  ss() { :; }
  cmd_status > "$CASE_ROOT/public"
  cmd_status internal > "$CASE_ROOT/internal"
'
is "public status deduplicates canonical keys while internal status preserves lexical rows" \
  "$(jq -c '[(.tunnels | length), (.tunnels[0] | keys), [.tunnels[] | [.port,.url]]]' "$DUAL_STATUS/public")|$(jq -c '[(.tunnels | length), [.tunnels[]._statePort]]' "$DUAL_STATUS/internal")|$(sha256sum "$DUAL_STATUS/portless/routes.json" | cut -d' ' -f1)|$(wc -l < "$DUAL_STATUS/effects")" \
  "[1,[\"aliasName\",\"dns\",\"managed\",\"port\",\"provider\",\"reach\",\"targetHealthy\",\"url\"],[[3000,\"https://one.test\"]]]|[2,[\"03000\",\"3000\"]]|$dual_routes_hash|0"

LEXICAL_STOP="$T/portal-lexical-stop"; mkdir -p "$LEXICAL_STOP/portal" "$LEXICAL_STOP/portless"
printf target > "$LEXICAL_STOP/portal/cloudflared-03000.target"
printf keep > "$LEXICAL_STOP/portal/cloudflared-3000.target"
: > "$LEXICAL_STOP/effects"
lexical_stop_out=$(CASE_ROOT="$LEXICAL_STOP" PORTAL_STATE_DIR="$LEXICAL_STOP/portal" PORTLESS_STATE_DIR="$LEXICAL_STOP/portless" S="$S" bash -c '
  source "$S/tunnels.sh"
  proc() { printf "proc\n" >> "$CASE_ROOT/effects"; return 1; }
  kill() { printf "kill\n" >> "$CASE_ROOT/effects"; return 1; }
  cmd_stop cloudflared 3000 03000
')
is "cmd_stop uses numeric provider identity and only the lexical tracked paths" \
  "$(jq -c .ok <<< "$lexical_stop_out")|$(test -e "$LEXICAL_STOP/portal/cloudflared-03000.target" && echo lexical-kept || echo lexical-cleared)|$(cat "$LEXICAL_STOP/portal/cloudflared-3000.target")|$(wc -l < "$LEXICAL_STOP/effects")" \
  'true|lexical-cleared|keep|0'

LEXICAL_STOP_OWN="$T/portal-lexical-stop-own"; mkdir -p "$LEXICAL_STOP_OWN/portal" "$LEXICAL_STOP_OWN/portless"
printf first > "$LEXICAL_STOP_OWN/portal/cloudflared-03000.target"
printf second > "$LEXICAL_STOP_OWN/portal/cloudflared-3000.target"
: > "$LEXICAL_STOP_OWN/calls"; : > "$LEXICAL_STOP_OWN/effects"
lexical_stop_own_out=$(CASE_ROOT="$LEXICAL_STOP_OWN" PORTAL_STATE_DIR="$LEXICAL_STOP_OWN/portal" \
  PORTLESS_STATE_DIR="$LEXICAL_STOP_OWN/portless" S="$S" bash -c '
    source "$S/tunnels.sh"
    eval "$(declare -f cmd_stop | sed "1s/^cmd_stop /cmd_stop_real /")"
    cmd_stop() {
      printf "%s:%s:%s\n" "$1" "$2" "${3:-}" >> "$CASE_ROOT/calls"
      cmd_stop_real "$@"
    }
    proc() { printf "proc\n" >> "$CASE_ROOT/effects"; return 1; }
    kill() { printf "kill\n" >> "$CASE_ROOT/effects"; return 1; }
    provider_bin() { printf "provider\n" >> "$CASE_ROOT/effects"; return 1; }
    cloudflared_stop_adopted() { printf "provider-stop\n" >> "$CASE_ROOT/effects"; return 1; }
    cmd_stop_own
  ' 2> "$LEXICAL_STOP_OWN/stderr")
is "stop-own passes canonical Cloudflared ports with each exact lexical storage identity" \
  "$(jq -c .ok <<< "$lexical_stop_own_out")|$(sort "$LEXICAL_STOP_OWN/calls" | paste -sd,)|$(find "$LEXICAL_STOP_OWN/portal" -maxdepth 1 -type f | wc -l)|$(wc -l < "$LEXICAL_STOP_OWN/effects")|$(wc -c < "$LEXICAL_STOP_OWN/stderr")" \
  'true|cloudflared:3000:03000,cloudflared:3000:3000|0|0|0'

if [[ ${PORTAL_TEST_ONLY:-} == portless-status ]]; then
  echo; echo "$pass passed, $fail failed"
  exit $((fail > 0))
fi

is "configured_tld passes a clean TLD" "$(configured_tld)" "test"
is "configured_tld lowercases and strips" "$(PORTAL_PORTLESS_TLD=' My.Dev ' configured_tld)" "my.dev"
is "configured_tld falls back on junk" "$(PORTAL_PORTLESS_TLD='x;rm -rf /' configured_tld)" "localhost"
is "configured_tld falls back on empty" "$(PORTAL_PORTLESS_TLD='' configured_tld)" "localhost"

printf '["localhost","dev","x;echo pwned","UPPER","a..b","-lead"]' > "$PORTLESS_STATE_DIR/proxy.tlds"
is "running_tlds keeps only DNS labels" "$(portless_running_tlds | tr '\n' ' ')" "localhost dev "
is "tld_arg: configured first, running next, localhost kept" "$(portless_tld_arg)" "test,localhost,dev"
printf 'localhost,internal' > "$PORTLESS_STATE_DIR/proxy.tlds"
is "running_tlds reads the comma form" "$(portless_running_tlds | tr '\n' ' ')" "localhost internal "
rm -f "$PORTLESS_STATE_DIR/proxy.tlds"; printf 'test' > "$PORTLESS_STATE_DIR/proxy.tld"
is "running_tlds reads the legacy file" "$(portless_running_tlds)" "test"
is "tld_arg still appends localhost" "$(portless_tld_arg)" "test,localhost"
rm -f "$PORTLESS_STATE_DIR/proxy.tld"
is "running_tlds defaults to localhost" "$(portless_running_tlds)" "localhost"
case "$(portless_fix_cmd evict)" in
  "sudo fuser -k 443/tcp; sleep 1; PORTLESS_LAN=0 PORTLESS_LAN_IP= PORTLESS_STATE_DIR=\"\$HOME/.portless\" portless proxy start -p 443 --tld test,localhost") ok "fix command composes from validated parts" ;;
  *) bad "fix command: $(portless_fix_cmd evict)" ;;
esac
printf '[{"port":3000,"hostname":"acme.localhost","pid":0},{"port":5173,"hostname":"dash.test","pid":0},{"port":8,"hostname":"eight.test","pid":0}]' > "$PORTLESS_STATE_DIR/routes.json"
is "route_name strips the TLD" "$(portless_route_name 5173)" "dash"
is "route_name is empty for an unknown port" "$(portless_route_name 9)" ""
route_jq_arg="$T/route-jq-arg"
jq() {
  if [[ ${1:-} == -r && ${2:-} == --argjson && ${3:-} == p ]]; then
    printf '%s' "$4" > "$route_jq_arg"
  fi
  command jq "$@"
}
leading_zero_route=$(portless_route_name 00008)
unset -f jq
is "route_name gives jq a canonical leading-zero port and keeps the lookup" \
  "$(cat "$route_jq_arg")|$leading_zero_route" "8|eight"
route_label_63=$(printf 'a%.0s' {1..63})
route_label_64=${route_label_63}a
route_hostname_253="$route_label_63.$route_label_63.$route_label_63.$(printf 'b%.0s' {1..61})"
route_hostname_254="$route_label_63.$route_label_63.$route_label_63.$(printf 'b%.0s' {1..62})"
portless_route_cases=(
  "missing routes.json"$'\t'valid$'\t'__missing__
  "empty route array"$'\t'valid$'\t''[]'
  "minimum hostname port and pid"$'\t'valid$'\t''[{"hostname":"a","port":1,"pid":0}]'
  "internal hostname hyphen and mathematical integers"$'\t'valid$'\t''[{"hostname":"a-b.test","port":3000.0,"pid":999999.0}]'
  "scientific integer 3e3"$'\t'valid$'\t''[{"hostname":"three-e.test","port":3e3,"pid":3e3}]'
  "decimal scientific integer 3.1e3"$'\t'valid$'\t''[{"hostname":"three-one-e.test","port":3.1e3,"pid":3.1e3}]'
  "decimal scientific integer 9.99e2"$'\t'valid$'\t''[{"hostname":"nine-nine-nine.test","port":9.99e2,"pid":9.99e2}]'
  "decimal scientific integer 100e-2"$'\t'valid$'\t''[{"hostname":"one.test","port":100e-2,"pid":100e-2}]'
  "decimal scientific integer 120e-1"$'\t'valid$'\t''[{"hostname":"twelve.test","port":120e-1,"pid":120e-1}]'
  "negative-zero pid"$'\t'valid$'\t''[{"hostname":"negative-zero.test","port":1,"pid":-0}]'
  "zero pid with huge negative exponent"$'\t'valid$'\t''[{"hostname":"tiny-zero.test","port":1,"pid":0e-999999}]'
  "positive integer pid with huge exponent"$'\t'valid$'\t''[{"hostname":"huge-integer.test","port":1,"pid":1e999999}]'
  "exact exponent and precision suite"$'\t'valid$'\t''[{"hostname":"precision.test","port":3000.0000000000000000000,"pid":999999999999999999999999999999999999999.0000},{"hostname":"maximum.test","port":6.5535e4,"pid":1.2345e20},{"hostname":"shift.test","port":123400e-2,"pid":100000e-5}]'
  "replacement-decoded invalid UTF-8 in an ignored extra field"$'\t'valid$'\t'__invalid_utf8_extra__
  "63-byte hostname label"$'\t'valid$'\t'"[{\"hostname\":\"$route_label_63.test\",\"port\":3000,\"pid\":0}]"
  "253-byte hostname"$'\t'valid$'\t'"[{\"hostname\":\"$route_hostname_253\",\"port\":3000,\"pid\":0}]"
  "maximum port positive dead pid and extra fields"$'\t'valid$'\t''[{"hostname":"dead.test","port":65535,"pid":999999,"extra":{"kept":true}}]'
  "duplicate ports"$'\t'valid$'\t''[{"hostname":"one.test","port":3000,"pid":0},{"hostname":"two.test","port":3000,"pid":0}]'
  "non-object entry"$'\t'invalid$'\t''["bad"]'
  "missing required field"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000}]'
  "uppercase hostname"$'\t'invalid$'\t''[{"hostname":"App.test","port":3000,"pid":0}]'
  "trailing hostname dot"$'\t'invalid$'\t''[{"hostname":"app.test.","port":3000,"pid":0}]'
  "empty hostname label"$'\t'invalid$'\t''[{"hostname":"app..test","port":3000,"pid":0}]'
  "leading hostname hyphen"$'\t'invalid$'\t''[{"hostname":"-app.test","port":3000,"pid":0}]'
  "trailing hostname hyphen"$'\t'invalid$'\t''[{"hostname":"app-.test","port":3000,"pid":0}]'
  "64-byte hostname label"$'\t'invalid$'\t'"[{\"hostname\":\"$route_label_64.test\",\"port\":3000,\"pid\":0}]"
  "254-byte hostname"$'\t'invalid$'\t'"[{\"hostname\":\"$route_hostname_254\",\"port\":3000,\"pid\":0}]"
  "hostname underscore"$'\t'invalid$'\t''[{"hostname":"bad_name.test","port":3000,"pid":0}]'
  "hostname control byte"$'\t'invalid$'\t''[{"hostname":"bad\u0001.test","port":3000,"pid":0}]'
  "non-ASCII hostname"$'\t'invalid$'\t''[{"hostname":"café.test","port":3000,"pid":0}]'
  "hostname with a final LF"$'\t'invalid$'\t''[{"hostname":"app.test\n","port":3000,"pid":0}]'
  "hostname with replaced invalid UTF-8"$'\t'invalid$'\t'__invalid_utf8__
  "fractional port"$'\t'invalid$'\t''[{"hostname":"app.test","port":1.5,"pid":0}]'
  "precision-adjacent fractional port"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000.0000000000000000001,"pid":0}]'
  "string port"$'\t'invalid$'\t''[{"hostname":"app.test","port":"3000","pid":0}]'
  "zero port"$'\t'invalid$'\t''[{"hostname":"app.test","port":0,"pid":0}]'
  "negative-zero port"$'\t'invalid$'\t''[{"hostname":"app.test","port":-0,"pid":0}]'
  "port above range"$'\t'invalid$'\t''[{"hostname":"app.test","port":65536,"pid":0}]'
  "fractional pid"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":0.5}]'
  "nonzero pid underflow"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":1e-400}]'
  "huge fractional pid"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":999999999999999999999999999999999999999.5}]'
  "nonintegral pid shift 1201e-1"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":1201e-1}]'
  "nonintegral pid shift 1000e-4"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":1000e-4}]'
  "string pid"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":"0"}]'
  "negative pid"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":-1}]'
  "NaN parser constant in an ignored extra field"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":0,"extra":NaN}]'
  "Infinity parser constant in an ignored extra field"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":0,"extra":Infinity}]'
  "negative Infinity parser constant in an ignored extra field"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":0,"extra":-Infinity}]'
  "leading-plus port"$'\t'invalid$'\t''[{"hostname":"app.test","port":+3000,"pid":0}]'
  "leading-zero port"$'\t'invalid$'\t''[{"hostname":"app.test","port":03000,"pid":0}]'
  "negative double-zero pid"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":-00}]'
  "trailing-decimal-point port"$'\t'invalid$'\t''[{"hostname":"app.test","port":1.,"pid":0}]'
  "leading-decimal-point parser token in an ignored extra field"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":0,"extra":.5}]'
  "duplicate required route keys"$'\t'invalid$'\t''[{"hostname":"bad","hostname":"app.test","port":0,"port":3000,"pid":-1,"pid":0}]'
  "duplicate keys in an extra object"$'\t'invalid$'\t''[{"hostname":"app.test","port":3000,"pid":0,"extra":{"same":1,"same":2}}]'
  "duplicate hostname"$'\t'invalid$'\t''[{"hostname":"same.test","port":3000,"pid":0},{"hostname":"same.test","port":3001,"pid":0}]'
  "malformed route JSON"$'\t'invalid$'\t''{'
  "object route root"$'\t'invalid$'\t''{"hostname":"app.test","port":3000,"pid":0}'
  "null route root"$'\t'invalid$'\t''null'
  "string route root"$'\t'invalid$'\t''"routes"'
  "zero-byte routes.json"$'\t'invalid$'\t'
)
route_case_number=0
for route_case in "${portless_route_cases[@]}"; do
  IFS=$'\t' read -r route_label route_expected route_payload <<< "$route_case"
  route_case_number=$((route_case_number + 1))
  route_root="$T/portless-route-$route_case_number"
  mkdir -p "$route_root"
  case $route_payload in
    __missing__) ;;
    __invalid_utf8__) printf '[{"hostname":"bad\377.test","port":3000,"pid":0}]' > "$route_root/routes.json" ;;
    __invalid_utf8_extra__)
      printf '[{"hostname":"extra.test","port":3000,"pid":0,"extra":"bad\377"}]' > "$route_root/routes.json"
      route_payload=$'[{"hostname":"extra.test","port":3000,"pid":0,"extra":"bad\xef\xbf\xbd"}]'
      ;;
    *) printf '%s' "$route_payload" > "$route_root/routes.json" ;;
  esac
  PORTLESS_DIR=$route_root
  PORTLESS_STATE='{"files":{"routes.json":"stale"},"refused":[]}'
  if portless_state_load; then
    route_actual="valid|$PORTLESS_STATE_ERROR|$(routes_json)"
  else
    route_actual="invalid|$PORTLESS_STATE_ERROR|$PORTLESS_STATE"
  fi
  if [[ $route_expected == valid ]]; then
    [[ $route_payload == __missing__ ]] && route_payload=
    route_want="valid||$route_payload"
  else
    route_want="invalid|routes.json is malformed|"
  fi
  is "Portless routes boundary accepts only $route_label" "$route_actual" "$route_want"
done

route_cap_output=$({
  printf '{"files":{"routes.json":"[]'
  head -c 1048574 /dev/zero | tr '\0' ' '
  printf '"},"refused":[]}'
} | portless_routes_valid)
route_cap_rc=$?
route_over_cap_output=$({
  printf '{"files":{"routes.json":"[]'
  head -c 1048575 /dev/zero | tr '\0' ' '
  printf '"},"refused":[]}'
} | portless_routes_valid)
route_over_cap_rc=$?
route_nonstring_output=$(printf '{"files":{"routes.json":[]},"refused":[]}' | portless_routes_valid)
route_nonstring_rc=$?
is "the Portless route validator accepts one MiB without stdout" "$route_cap_rc|$route_cap_output" '0|'
is "the Portless route validator rejects input above one MiB without stdout" "$route_over_cap_rc|$route_over_cap_output" '1|'
is "the Portless route validator rejects a non-string embedded document without stdout" \
  "$route_nonstring_rc|$route_nonstring_output" '1|'

NUL_ROUTES="$T/nul-portless-routes"; mkdir -p "$NUL_ROUTES"
printf '[{"hostname":"nul\0.test","port":3000,"pid":0}]' > "$NUL_ROUTES/routes.json"
PORTLESS_DIR=$NUL_ROUTES; PORTLESS_STATE=stale
portless_state_load 2> "$NUL_ROUTES/stderr"; nul_routes_rc=$?
nul_routes_state=${PORTLESS_STATE:-empty}
nul_routes_stderr_bytes=$(wc -c < "$NUL_ROUTES/stderr")
is "a literal NUL route fails without a command-substitution warning or stale snapshot" \
  "$nul_routes_rc|$PORTLESS_STATE_ERROR|$nul_routes_state|$nul_routes_stderr_bytes" \
  '1|routes.json is malformed|empty|0'

STALE_ROUTES="$T/stale-portless-routes"; mkdir -p "$STALE_ROUTES"
printf '[{"hostname":"fresh.test","port":3000,"pid":0}]' > "$STALE_ROUTES/routes.json"
PORTLESS_DIR=$STALE_ROUTES; PORTLESS_STATE=
portless_state_load; stale_first_rc=$?
stale_first_routes=$(routes_json)
printf '[{"hostname":"STALE.test","port":3000,"pid":0}]' > "$STALE_ROUTES/routes.json"
portless_state_load; stale_reload_rc=$?
stale_reload_state=${PORTLESS_STATE:-empty}
stale_routes=$(routes_json 2>/dev/null); stale_routes_rc=$?
is "a failed Portless reload clears the prior route snapshot" \
  "$stale_first_rc|$stale_first_routes|$stale_reload_rc|$PORTLESS_STATE_ERROR|$stale_reload_state|$stale_routes_rc|$stale_routes" \
  '0|[{"hostname":"fresh.test","port":3000,"pid":0}]|1|routes.json is malformed|empty|1|'

PERMISSIVE_ROUTES="$T/permissive-portless-routes"; mkdir -p "$PERMISSIVE_ROUTES"
printf '[{"hostname":"fresh.test","port":3000,"pid":0}]' > "$PERMISSIVE_ROUTES/routes.json"
PORTLESS_DIR=$PERMISSIVE_ROUTES; PORTLESS_STATE=
portless_state_load; permissive_first_rc=$?
printf '[{"hostname":"permissive.test","port":+3000,"pid":0}]' > "$PERMISSIVE_ROUTES/routes.json"
portless_state_load; permissive_reload_rc=$?
permissive_reload_state=${PORTLESS_STATE:-empty}
permissive_routes=$(routes_json 2>/dev/null); permissive_routes_rc=$?
is "a failed permissive-jq reload clears the prior route snapshot" \
  "$permissive_first_rc|$permissive_reload_rc|$PORTLESS_STATE_ERROR|$permissive_reload_state|$permissive_routes_rc|$permissive_routes" \
  '0|1|routes.json is malformed|empty|1|'

STATE_DIR_FAILURE="$T/portless-state-not-directory"; printf refused > "$STATE_DIR_FAILURE"
PORTLESS_DIR=$STATE_DIR_FAILURE; PORTLESS_STATE=stale
portless_state_load; state_dir_failure_rc=$?
is "a Portless state directory failure clears the snapshot with its precise error" \
  "$state_dir_failure_rc|$PORTLESS_STATE_ERROR|$PORTLESS_STATE" '1|state directory refused|'
REQUESTED_LEAF_FAILURE="$T/portless-requested-leaf"; mkdir -p "$REQUESTED_LEAF_FAILURE"
printf '[]' > "$T/portless-routes-target"
ln -s "$T/portless-routes-target" "$REQUESTED_LEAF_FAILURE/routes.json"
PORTLESS_DIR=$REQUESTED_LEAF_FAILURE; PORTLESS_STATE=stale
portless_state_load; requested_leaf_failure_rc=$?
is "a refused Portless route leaf clears the snapshot with its precise error" \
  "$requested_leaf_failure_rc|$PORTLESS_STATE_ERROR|$PORTLESS_STATE" '1|requested state leaf refused|'
PORTLESS_DIR=$PORTLESS_STATE_DIR; PORTLESS_STATE=
portless_state_load || bad "could not restore the Portless route fixture"

# ---- tunnels.sh validators -------------------------------------------------
me=$(< /proc/$$/comm)
valid_url "https://a-b.trycloudflare.com" && ok "valid_url accepts a hostname" || bad "valid_url rejected a hostname"
valid_url "http://acme.localhost:1355/x?y=1" && ok "valid_url accepts port and path" || bad "valid_url rejected port+path"
valid_url "javascript:alert(1)" && bad "valid_url accepted javascript:" || ok "valid_url rejects javascript:"
valid_url "https://evil.com/x y" && bad "valid_url accepted a space" || ok "valid_url rejects whitespace"
valid_url "ftp://x" && bad "valid_url accepted ftp" || ok "valid_url rejects other schemes"
valid_url "https://x/a$(printf '\037')b" && bad "valid_url accepted a unit separator" || ok "valid_url rejects a unit separator"
is "url_host strips scheme, port and path" "$(url_host 'https://h.example:8443/p/q')" "h.example"
valid_port 65535 && ok "valid_port upper bound" || bad "valid_port rejected 65535"
valid_port 00008 && ok "valid_port accepts leading-zero decimal" || bad "valid_port rejected leading-zero decimal"
valid_port 65536 && bad "valid_port accepted 65536" || ok "valid_port rejects 65536"
valid_port 065536 && bad "valid_port accepted leading-zero 65536" || ok "valid_port rejects leading-zero 65536"
valid_port 18446744073709551617 && bad "valid_port accepted an overflowing integer" || ok "valid_port rejects an overflowing integer"
valid_port 0 && bad "valid_port accepted 0" || ok "valid_port rejects 0"
valid_port 12a && bad "valid_port accepted 12a" || ok "valid_port rejects non-digits"
unicode_port_stderr="$T/unicode-port-current.err"
valid_port '１２' 2> "$unicode_port_stderr"; unicode_port_rc=$?
is "valid_port silently rejects fullwidth digits in the current locale" \
  "$unicode_port_rc $(wc -c < "$unicode_port_stderr")" "1 0"
utf8_locale=$(locale -a 2>/dev/null | grep -iE 'utf-?8' | grep -iv '^C\.' | head -n 1)
[[ -n $utf8_locale ]] || utf8_locale=$(locale -a 2>/dev/null | grep -iE 'utf-?8' | head -n 1)
if [[ -n $utf8_locale ]]; then
  unicode_port_stderr="$T/unicode-port-utf8.err"
  LC_ALL="$utf8_locale" valid_port '１２' 2> "$unicode_port_stderr"; unicode_port_rc=$?
  is "valid_port silently rejects fullwidth digits under $utf8_locale" \
    "$unicode_port_rc $(wc -c < "$unicode_port_stderr")" "1 0"
else
  echo "  skip no UTF-8 locale for valid_port"
fi
owned_pid "$$" "$me" && ok "owned_pid matches this shell" || bad "owned_pid rejected this shell ($me)"
owned_pid "$$" ngrok && bad "owned_pid matched the wrong comm" || ok "owned_pid rejects the wrong comm"
owned_pid "0$$" bash && bad "owned_pid accepted a zero-padded pid" || ok "owned_pid rejects a zero-padded pid"
is "slug lowercases nothing, collapses runs, trims" "$(slug 'Hello  World!!')" "Hello-World"
long=$(slug "$(printf 'a%.0s' {1..60})"); is "slug caps length" "${#long}" "40"

signal_log="$T/safety-signals"
SIGNAL_LOG="$signal_log" S="$S" bash -c '
  source "$S/tunnels.sh"
  proc() { printf "proc %s\n" "$*" >> "$SIGNAL_LOG"; return 1; }
  kill() { printf "kill %s\n" "$*" >> "$SIGNAL_LOG"; return 1; }
  alive_line() { return 0; }
  group_alive() { return 0; }
  STOP_TERM_WAIT=0; STOP_KILL_WAIT=0
  stop_line "1 1" cloudflared; [[ $? -ne 0 ]] || exit 11
  for line in "0 0" "-1 1" "" "2 nope"; do stop_line "$line" cloudflared; [[ $? -ne 0 ]] || exit 12; done
  stop_line "999999999999999999999 1" cloudflared; [[ $? -ne 0 ]] || exit 13
' >/dev/null 2>&1; rc=$?
is "dangerous pid records fail before a signal path" "$rc $(grep -Ec -- '(^| )-(0|1)( |$)' "$signal_log" 2>/dev/null || true)" "0 0"

GROUP_ONLY="$T/group-only"; mkdir -p "$GROUP_ONLY"/{stop,start,status}; : > "$GROUP_ONLY/signals"; : > "$GROUP_ONLY/launches"
GROUP_ONLY="$GROUP_ONLY" S="$S" bash -c '
  source "$S/tunnels.sh"
  proc() { printf "proc %s\n" "$*" >> "$GROUP_ONLY/signals"; return 1; }
  kill() { printf "kill %s\n" "$*" >> "$GROUP_ONLY/signals"; return 1; }
  alive_line() { return 1; }
  group_alive() { return 0; }
  state() {
    if [[ $1 == launch-tracked ]]; then printf "launch %s\n" "$*" >> "$GROUP_ONLY/launches"; return 1; fi
    /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"
  }
  provider_bin() { printf /usr/bin/true; }
  target_owns_port() { return 0; }
  cloudflared_argv() { printf "300\n"; }
  ss() { return 0; }
  STOP_TERM_WAIT=0; STOP_KILL_WAIT=0

  stop_line "999999 1" cloudflared; stop_rc=$?
  printf "%s" "$((stop_rc != 0))" > "$GROUP_ONLY/stop-line-failed"

  STATE_DIR="$GROUP_ONLY/stop"
  printf "999999 1" > "$STATE_DIR/cloudflared-4501.pid"
  printf "https://group-only.trycloudflare.com" > "$STATE_DIR/cloudflared-4501.url"
  stop_out=$(cmd_stop cloudflared 4501); printf "%s" "$stop_out" > "$GROUP_ONLY/stop.out"

  STATE_DIR="$GROUP_ONLY/start"
  printf "999999 1" > "$STATE_DIR/cloudflared-4502.pid"
  printf "https://group-only.trycloudflare.com" > "$STATE_DIR/cloudflared-4502.url"
  state dump "$STATE_DIR" 8192 32 | jq -S . > "$GROUP_ONLY/start.before"
  start_out=$(cmd_start cloudflared 4502 --target 999999 1); printf "%s" "$start_out" > "$GROUP_ONLY/start.out"
  state dump "$STATE_DIR" 8192 32 | jq -S . > "$GROUP_ONLY/start.after"

  STATE_DIR="$GROUP_ONLY/status"
  printf "999999 1" > "$STATE_DIR/cloudflared-4503.pid"
  printf "https://group-only.trycloudflare.com" > "$STATE_DIR/cloudflared-4503.url"
  status_out=$(cmd_status); printf "%s" "$status_out" > "$GROUP_ONLY/status.out"
' >/dev/null 2>&1
is "a group-only identity makes stop_line fail closed" "$(cat "$GROUP_ONLY/stop-line-failed")" "1"
is "cmd_stop fails and keeps group-only records" "$(jq -c .ok "$GROUP_ONLY/stop.out") $(find "$GROUP_ONLY/stop" -maxdepth 1 -type f | wc -l)" "false 2"
cmp -s "$GROUP_ONLY/start.before" "$GROUP_ONLY/start.after" && group_start_state=same || group_start_state=changed
is "cmd_start fails without launching or altering group-only records" "$(jq -c .ok "$GROUP_ONLY/start.out") $(wc -l < "$GROUP_ONLY/launches") $group_start_state" "false 0 same"
is "cmd_status fails and keeps group-only records" "$(jq -c .ok "$GROUP_ONLY/status.out") $(find "$GROUP_ONLY/status" -maxdepth 1 -type f | wc -l)" "false 2"
is "group-only records never reach a signal path" "$(wc -l < "$GROUP_ONLY/signals") $(grep -Ec -- '(^| )-(0|1)( |$)' "$GROUP_ONLY/signals" 2>/dev/null || true)" "0 0"

RESTART_GROUP="$T/restart-group"; mkdir -p "$RESTART_GROUP"; : > "$RESTART_GROUP/effects"
printf '999999 1' > "$RESTART_GROUP/.restart-4499.pid"
PORTAL_STATE_DIR="$RESTART_GROUP" EFFECTS="$RESTART_GROUP/effects" S="$S" bash -c '
  set -- noop
  source "$S/lifecycle.sh" >/dev/null
  proc() { printf "proc %s\n" "$*" >> "$EFFECTS"; return 1; }
  kill() {
    printf "kill %s\n" "$*" >> "$EFFECTS"
    [[ $* == "-0 -- -999999" ]]
  }
  for pid in 1 0 -1 "" nope; do group_alive "$pid" >/dev/null 2>&1 || true; done
  rollback_replacement 999999 1 .restart-4499.pid; rollback_rc=$?
  [[ -e $PORTAL_RUNTIME_DIR/.restart-4499.pid ]] && rollback_record=kept || rollback_record=lost
  failure=$(fail_restart 999999 1 .restart-4499.pid "restart did not bring a listener back on port 4499")
  [[ -e $PORTAL_RUNTIME_DIR/.restart-4499.pid ]] && failure_record=kept || failure_record=lost
  printf "%s\t%s\t%s\t%s\t%s\n" "$rollback_rc" "$rollback_record" \
    "$(jq -r .ok <<<"$failure")" "$(jq -r .effect <<<"$failure")" "$failure_record"
' > "$RESTART_GROUP/result"
is "restart rollback keeps a live descendant group's identity record" \
  "$(cat "$RESTART_GROUP/result")" $'1\tkept\tfalse\tstopped\tkept'
is "restart rollback only probes the guarded replacement group" \
  "$(grep -c '^kill -0 -- -999999$' "$RESTART_GROUP/effects") $(grep -Ec ' -- -(0|1)$' "$RESTART_GROUP/effects" || true)" "2 0"

ESCALATE_LOG="$GROUP_ONLY/escalate-signals" S="$S" bash -c '
  source "$S/tunnels.sh"
  checks=0; group_dead=0
  alive_line() { checks=$((checks + 1)); (( checks == 1 )); }
  group_alive() { (( group_dead == 0 )); }
  proc() { printf "proc %s\n" "$*" >> "$ESCALATE_LOG"; return 0; }
  kill() {
    printf "kill %s\n" "$*" >> "$ESCALATE_LOG"
    [[ $1 == -KILL ]] && group_dead=1
    return 0
  }
  STOP_TERM_WAIT=0; STOP_KILL_WAIT=1
  stop_line "999999 1" cloudflared
' >/dev/null 2>&1; rc=$?
is "a verified stop still escalates after its leader exits" "$rc $(grep -c "kill -KILL -- -999999" "$GROUP_ONLY/escalate-signals")" "0 1"

# cmd_stop must never signal a pid the pidfile names unless it is still the provider.
mkdir -p "$STATE_DIR"
printf '%s' "$$" > "$STATE_DIR/cloudflared-4444.pid"
printf 'https://x.trycloudflare.com' > "$STATE_DIR/cloudflared-4444.url"
out=$(cmd_stop cloudflared 4444)
is "cmd_stop refuses a malformed pid record" "$(jq -r .error <<<"$out")" "cloudflared on port 4444 has a malformed pidfile; its records are kept"
is "and keeps malformed ownership records" "$(ls "$STATE_DIR"/cloudflared-4444.* | wc -l)" "2"
rm -f "$STATE_DIR"/cloudflared-4444.*

# Concurrent first use: many helpers creating the same missing directory all succeed.
R=$(mktemp -d); for i in $(seq 1 12); do state ensure "$R/a/b/c" & done; wait; [[ -d $R/a/b/c ]] && ok "concurrent ensure creates the directory once, without error" || bad "concurrent ensure failed"; rm -rf "$R"

# The install marker is JSON, so a path with a space survives.
M=$(mktemp -d); mkdir -p "$M/my bin"; printf 'x' > "$M/my bin/cloudflared"; d=$(sha256sum "$M/my bin/cloudflared" | cut -d' ' -f1)
jq -nc --arg p "$M/my bin/cloudflared" --arg s "$d" '{path:$p, sha256:$s}' | state write "$M/installed-cloudflared"
plan=$(PORTAL_BIN_DIR="$M/my bin" PORTAL_METRICS_DIR=$M PORTAL_STATE_DIR=$M/rt "$S/uninstall.sh" --dry 2>&1)
grep -qF "would: state remove-digest $M/my bin cloudflared $d 134217728" <<<"$plan" && ok "uninstall finds a marked binary in a path with a space" || bad "uninstall lost the marked binary: $plan"
# State roots pointed at a shared directory lose only Portal's own entries.
mkdir -p "$M/shared/metrics" "$M/rt2" "$M/rt2/cloudflared-2.url"; printf keep > "$M/link-target"
: > "$M/shared/thesis.txt"; : > "$M/shared/trusted-stores"; : > "$M/shared/metrics/3000.jsonl"; : > "$M/rt2/cloudflared-1.url"; : > "$M/rt2/notes.txt"
ln -s "$M/link-target" "$M/shared/watched.json"; mkfifo "$M/rt2/ngrok.ok"
ln -s "$M/link-target" "$M/shared/unknown-link"; mkfifo "$M/rt2/unknown-fifo"
plan=$(PORTAL_METRICS_DIR=$M/shared PORTAL_STATE_DIR=$M/rt2 "$S/uninstall.sh" --dry 2>/dev/null)
grep -q 'rm -rf' <<<"$plan" && bad "uninstall would remove a state root wholesale" || ok "uninstall never removes a state root wholesale"
planned_regular=0; for name in trusted-stores 3000.jsonl cloudflared-1.url; do grep -Fq "$name" <<<"$plan" && planned_regular=$((planned_regular + 1)); done
is "uninstall removes Portal's entries by name" "$planned_regular" "3"
planned_special=0; for name in watched.json ngrok.ok; do grep -Fq "$name" <<<"$plan" && planned_special=$((planned_special + 1)); done
is "uninstall includes exact known symlink and FIFO leaves" "$planned_special" "2"
grep -qE 'thesis|notes|unknown-link|unknown-fifo|cloudflared-2\.url' <<<"$plan" && bad "uninstall would touch unknown leaves or directories" || ok "and leaves unknown leaves and directories alone"
remove_rc=0
timeout 5 /usr/bin/python3 -I -S "$S/lib/statedir.py" remove "$M/shared" watched.json >/dev/null 2>&1 || remove_rc=$?
timeout 5 /usr/bin/python3 -I -S "$S/lib/statedir.py" remove "$M/rt2" ngrok.ok cloudflared-2.url >/dev/null 2>&1 || remove_rc=$?
[[ -e $M/shared/watched.json || -L $M/shared/watched.json ]] && removed_link=kept || removed_link=gone
[[ -e $M/rt2/ngrok.ok ]] && removed_fifo=kept || removed_fifo=gone
is "descriptor-relative removal unlinks a symlink and FIFO without blocking" "$remove_rc $removed_link $removed_fifo" "0 gone gone"
is "descriptor-relative removal does not follow the symlink" "$(cat "$M/link-target")" "keep"
[[ -d $M/rt2/cloudflared-2.url ]] && ok "descriptor-relative removal keeps directories" || bad "descriptor-relative removal removed a directory"

LEAF_UNINSTALL="$T/uninstall-leaves"
mkdir -p "$LEAF_UNINSTALL/app/lib" "$LEAF_UNINSTALL/bin" "$LEAF_UNINSTALL/home" \
  "$LEAF_UNINSTALL/runtime" "$LEAF_UNINSTALL/state/metrics"
cp "$S/uninstall.sh" "$LEAF_UNINSTALL/app/uninstall.sh"
cp "$S/lib/portless.sh" "$S/lib/files.sh" "$S/lib/statedir.py" "$S/lib/proc.py" "$LEAF_UNINSTALL/app/lib/"
cat >> "$LEAF_UNINSTALL/app/lib/files.sh" <<'SH'
eval "$(declare -f valid_port | sed '1s/valid_port/portal_uninstall_valid_port/')"
valid_port() {
  local port=$1
  printf '%s\n' "$port" >> "$PORTAL_VALID_PORT_LOG"
  portal_uninstall_valid_port "$port"
}
SH
printf '#!/bin/sh\nprintf "{\\"ok\\":true}\\n"\n' > "$LEAF_UNINSTALL/app/tunnels.sh"
printf '#!/bin/sh\nprintf "{\\"ok\\":true}\\n"\n' > "$LEAF_UNINSTALL/app/portless-setup.sh"
printf '#!/bin/sh\n[ "$*" = "plugin list --json" ] && { printf "[]\\n"; exit 0; }\nexit 99\n' > "$LEAF_UNINSTALL/bin/omarchy"
chmod 700 "$LEAF_UNINSTALL/app/uninstall.sh" "$LEAF_UNINSTALL/app/tunnels.sh" \
  "$LEAF_UNINSTALL/app/portless-setup.sh" "$LEAF_UNINSTALL/bin/omarchy"

leaf_runtime_owned=(
  cloudflared-3000.pid cloudflared-3000.url cloudflared-3000.reach cloudflared-3000.dns
  cloudflared-3000.idle cloudflared-3000.log cloudflared-3000.target
  ngrok-3001.pid ngrok-3001.url ngrok-3001.reach ngrok-3001.dns ngrok-3001.idle
  ngrok-3001.log ngrok-3001.target
  portless-3002.url portless-3002.reach portless-3002.name cloudflared-00001.log
  cloudflared-00008.log .restart-3004.pid
)
for leaf in "${leaf_runtime_owned[@]}"; do : > "$LEAF_UNINSTALL/runtime/$leaf"; done
printf keep > "$LEAF_UNINSTALL/link-target"
ln -s "$LEAF_UNINSTALL/link-target" "$LEAF_UNINSTALL/runtime/cloudflared-3003.log"
mkfifo "$LEAF_UNINSTALL/runtime/ngrok.ok"
leaf_runtime_kept=(
  cloudflared-0.log ngrok-65536.url portless-99999.name cloudflared-123456.log
  cloudflared-065536.log ngrok-18446744073709551617.url .restart-65536.pid
  .cloudflared-6100.log.0123456789abcdef.tmp .portless-6101.name.0123456789abcdef.tmp
  .ngrok.ok.0123456789abcdef.tmp server-3000.log
  $'cloudflared-03005.log\nngrok-03006.url' $'foreign\nnotes'
)
for leaf in "${leaf_runtime_kept[@]}"; do : > "$LEAF_UNINSTALL/runtime/$leaf"; done

leaf_metrics_owned=(4000.jsonl 65535.jsonl 00001.jsonl 00008.jsonl)
for leaf in "${leaf_metrics_owned[@]}"; do : > "$LEAF_UNINSTALL/state/metrics/$leaf"; done
leaf_metrics_kept=(
  0.jsonl 65536.jsonl 065536.jsonl 99999.jsonl 123456.jsonl
  18446744073709551617.jsonl .6102.jsonl.0123456789abcdef.tmp junk.jsonl
  $'5003.jsonl\n5004.jsonl'
)
for leaf in "${leaf_metrics_kept[@]}"; do : > "$LEAF_UNINSTALL/state/metrics/$leaf"; done

: > "$LEAF_UNINSTALL/state/trusted-stores"
ln -s "$LEAF_UNINSTALL/link-target" "$LEAF_UNINSTALL/state/watched.json"
mkfifo "$LEAF_UNINSTALL/state/ca-import.pem"
leaf_state_kept=(
  .trusted-stores.0123456789abcdef.tmp .watched.json.0123456789abcdef.tmp
  .ca-import.pem.0123456789abcdef.tmp .installed-cloudflared.0123456789abcdef.tmp foreign
)
for leaf in "${leaf_state_kept[@]}"; do : > "$LEAF_UNINSTALL/state/$leaf"; done

PATH="$LEAF_UNINSTALL/bin:/usr/bin:/bin" HOME="$LEAF_UNINSTALL/home" \
  PORTAL_STATE_DIR="$LEAF_UNINSTALL/runtime" PORTAL_METRICS_DIR="$LEAF_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$LEAF_UNINSTALL/portless" PORTAL_VALID_PORT_LOG="$LEAF_UNINSTALL/ports" \
  "$LEAF_UNINSTALL/app/uninstall.sh" > "$LEAF_UNINSTALL/out" 2>&1; leaf_uninstall_rc=$?
leaf_owned_remaining=0
for leaf in "${leaf_runtime_owned[@]}"; do
  [[ -e $LEAF_UNINSTALL/runtime/$leaf || -L $LEAF_UNINSTALL/runtime/$leaf ]] \
    && leaf_owned_remaining=$((leaf_owned_remaining + 1))
done
for leaf in "${leaf_metrics_owned[@]}"; do
  [[ -e $LEAF_UNINSTALL/state/metrics/$leaf || -L $LEAF_UNINSTALL/state/metrics/$leaf ]] \
    && leaf_owned_remaining=$((leaf_owned_remaining + 1))
done
for leaf in trusted-stores watched.json ca-import.pem cloudflared-3003.log ngrok.ok; do
  if [[ $leaf == cloudflared-3003.log || $leaf == ngrok.ok ]]; then
    leaf_path="$LEAF_UNINSTALL/runtime/$leaf"
  else
    leaf_path="$LEAF_UNINSTALL/state/$leaf"
  fi
  [[ -e $leaf_path || -L $leaf_path ]] && leaf_owned_remaining=$((leaf_owned_remaining + 1))
done
is "uninstall removes every stable Portal leaf, including leading-zero ports and special files" \
  "$leaf_uninstall_rc $leaf_owned_remaining $(cat "$LEAF_UNINSTALL/link-target")" "0 0 keep"

leaf_kept_missing=0
for leaf in "${leaf_runtime_kept[@]}"; do
  [[ -e $LEAF_UNINSTALL/runtime/$leaf || -L $LEAF_UNINSTALL/runtime/$leaf ]] \
    || leaf_kept_missing=$((leaf_kept_missing + 1))
done
for leaf in "${leaf_metrics_kept[@]}"; do
  [[ -e $LEAF_UNINSTALL/state/metrics/$leaf || -L $LEAF_UNINSTALL/state/metrics/$leaf ]] \
    || leaf_kept_missing=$((leaf_kept_missing + 1))
done
for leaf in "${leaf_state_kept[@]}"; do
  [[ -e $LEAF_UNINSTALL/state/$leaf || -L $LEAF_UNINSTALL/state/$leaf ]] \
    || leaf_kept_missing=$((leaf_kept_missing + 1))
done
is "uninstall keeps out-of-range stable-looking leaves and every random temporary envelope" \
  "$leaf_kept_missing $(grep -c "holds files that are not Portal's" "$LEAF_UNINSTALL/out" || true)" "0 2"
leaf_ports=$(sort -u "$LEAF_UNINSTALL/ports" 2>/dev/null)
expected_leaf_ports=$(printf '%s\n' 3000 3001 3002 00001 00008 3004 3003 0 65536 065536 99999 123456 18446744073709551617 4000 65535 | sort -u)
is "uninstall delegates every stable decimal port, and no temporary port, to valid_port" \
  "$leaf_ports" "$expected_leaf_ports"

UNREADABLE_UNINSTALL="$T/uninstall-unreadable"
mkdir -p "$UNREADABLE_UNINSTALL/home" "$UNREADABLE_UNINSTALL/runtime" \
  "$UNREADABLE_UNINSTALL/state/metrics"
: > "$UNREADABLE_UNINSTALL/state/metrics/5100.jsonl"
chmod 100 "$UNREADABLE_UNINSTALL/state/metrics"
PATH="$LEAF_UNINSTALL/bin:/usr/bin:/bin" HOME="$UNREADABLE_UNINSTALL/home" \
  PORTAL_STATE_DIR="$UNREADABLE_UNINSTALL/runtime" PORTAL_METRICS_DIR="$UNREADABLE_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$UNREADABLE_UNINSTALL/portless" PORTAL_VALID_PORT_LOG="$UNREADABLE_UNINSTALL/ports" \
  "$LEAF_UNINSTALL/app/uninstall.sh" > "$UNREADABLE_UNINSTALL/out" 2>&1; unreadable_uninstall_rc=$?
chmod 700 "$UNREADABLE_UNINSTALL/state/metrics"
is "uninstall fails when an existing state directory cannot be enumerated" \
  "$unreadable_uninstall_rc $(test -e "$UNREADABLE_UNINSTALL/state/metrics/5100.jsonl" && echo kept || echo lost) $(grep -c '^could not remove Portal metrics$' "$UNREADABLE_UNINSTALL/out" || true)" \
  "1 kept 1"

# A binary that could not be removed keeps its marker, and the removal stops there.
# (omarchy is a stub here so nothing about the live plugin is touched.)
mkdir -p "$M/stub" "$M/held" "$M/st3" "$M/rt3"; printf '#!/bin/bash\n[[ $1 == plugin && $2 == list ]] && { echo "[]"; exit 0; }\nexit 1\n' > "$M/stub/omarchy"; chmod 755 "$M/stub/omarchy"
printf 'x' > "$M/held/cloudflared"; d=$(sha256sum "$M/held/cloudflared" | cut -d' ' -f1)
jq -nc --arg p "$M/held/cloudflared" --arg s "$d" '{path:$p, sha256:$s}' | state write "$M/st3/installed-cloudflared"
chmod 770 "$M/held"
out=$(PATH="$M/stub:$PATH" PORTAL_BIN_DIR="$M/held" PORTAL_METRICS_DIR=$M/st3 PORTAL_STATE_DIR=$M/rt3 "$S/uninstall.sh" 2>&1); rc=$?
is "uninstall stops when the binary cannot be removed" "$rc" "1"
grep -q "$M/held/cloudflared.*its marker is kept" <<<"$out" && ok "and says so" || bad "no message about the kept marker: $out"
[[ -e $M/st3/installed-cloudflared ]] && ok "and the marker survives" || bad "the marker was deleted"
chmod 700 "$M/held"
# A marker whose path is not the bin path Portal installs to is never a delete target.
mkdir -p "$M/ev/st" "$M/ev/rt" "$M/ev/stub" "$M/ev/bin"; printf '#!/bin/bash\n[[ $1 == plugin && $2 == list ]] && { echo "[]"; exit 0; }\nexit 0\n' > "$M/ev/stub/omarchy"; chmod 755 "$M/ev/stub/omarchy"
printf 'secret' > "$M/ev/victim"; ed=$(sha256sum "$M/ev/victim" | cut -d' ' -f1)
jq -nc --arg p "$M/ev/victim" --arg s "$ed" '{path:$p, sha256:$s}' | state write "$M/ev/st/installed-cloudflared"
PATH="$M/ev/stub:$PATH" PORTAL_BIN_DIR="$M/ev/bin" PORTAL_METRICS_DIR=$M/ev/st PORTAL_STATE_DIR=$M/ev/rt "$S/uninstall.sh" --dry 2>/dev/null | grep -qF "$M/ev/victim" && bad "uninstall would delete a file the marker points at outside the bin dir" || ok "uninstall ignores a marker path outside the bin dir"
# A marker that exists but cannot be decoded aborts uninstall and is kept.
mkdir -p "$M/cor/st" "$M/cor/rt" "$M/cor/stub"; printf '#!/bin/bash\n[[ $1 == plugin && $2 == list ]] && { echo "[]"; exit 0; }\nexit 0\n' > "$M/cor/stub/omarchy"; chmod 755 "$M/cor/stub/omarchy"
printf 'not json at all' | state write "$M/cor/st/installed-cloudflared"
out=$(PATH="$M/cor/stub:$PATH" PORTAL_METRICS_DIR=$M/cor/st PORTAL_STATE_DIR=$M/cor/rt "$S/uninstall.sh" 2>&1); rc=$?
is "uninstall aborts on a malformed install marker" "$rc" "1"
[[ -e $M/cor/st/installed-cloudflared ]] && ok "and keeps the malformed marker" || bad "the malformed marker was deleted"
rm -rf "$M"

# stop-own ends only shares with a state file of their own, including one
# still minting its URL (a pidfile, no url yet).
printf 'https://own.trycloudflare.com' > "$STATE_DIR/cloudflared-4447.url"; printf '999999 1' > "$STATE_DIR/cloudflared-4447.pid"
printf '999999 1' > "$STATE_DIR/ngrok-4448.pid"
is "stop-own returns ok" "$(cmd_stop_own)" '{"ok":true}'
[[ -e $STATE_DIR/cloudflared-4447.url ]] && bad "stop-own left a created share" || ok "stop-own cleared the created share"
[[ -e $STATE_DIR/ngrok-4448.pid ]] && bad "stop-own skipped a tunnel still minting its URL" || ok "stop-own covers a tunnel that has a pidfile but no url yet"

restart_stop_own() {
  PORTAL_STATE_DIR="$1" GROUP_PRESENT="$2" EFFECTS="$3" LEADER_PRESENT="${4:-0}" S="$S" bash -c '
    source "$S/tunnels.sh"
    proc() { printf "proc %s\n" "$*" >> "$EFFECTS"; [[ $LEADER_PRESENT == 1 ]]; }
    kill() {
      printf "kill %s\n" "$*" >> "$EFFECTS"
      [[ $GROUP_PRESENT == 1 && $* == "-0 -- -999999" ]]
    }
    cmd_stop_own
  '
}
RESTART_OWN="$T/restart-stop-own"; mkdir -p "$RESTART_OWN/dead" "$RESTART_OWN/group" "$RESTART_OWN/live" "$RESTART_OWN/bad" "$RESTART_OWN/refused"
: > "$RESTART_OWN/effects"
printf '999999 1' > "$RESTART_OWN/dead/.restart-4497.pid"
dead_restart=$(restart_stop_own "$RESTART_OWN/dead" 0 "$RESTART_OWN/effects")
is "stop-own removes a restart record only after its group is gone" \
  "$(jq -r .ok <<<"$dead_restart") $(test -e "$RESTART_OWN/dead/.restart-4497.pid" && echo kept || echo gone)" "true gone"
printf '999999 1' > "$RESTART_OWN/group/.restart-4498.pid"
group_restart=$(restart_stop_own "$RESTART_OWN/group" 1 "$RESTART_OWN/effects")
is "stop-own keeps a restart record while its group survives" \
  "$(jq -r .ok <<<"$group_restart") $(test -e "$RESTART_OWN/group/.restart-4498.pid" && echo kept || echo gone)" "false kept"
printf '999999 1' > "$RESTART_OWN/live/.restart-4496.pid"
live_restart=$(restart_stop_own "$RESTART_OWN/live" 0 "$RESTART_OWN/effects" 1)
is "stop-own keeps a restart record while its exact leader survives" \
  "$(jq -r .ok <<<"$live_restart") $(test -e "$RESTART_OWN/live/.restart-4496.pid" && echo kept || echo gone)" "false kept"
printf 'bad identity' > "$RESTART_OWN/bad/.restart-4499.pid"
bad_restart=$(restart_stop_own "$RESTART_OWN/bad" 0 "$RESTART_OWN/effects")
is "stop-own rejects a malformed restart record before a process probe" \
  "$(jq -r .ok <<<"$bad_restart") $(test -e "$RESTART_OWN/bad/.restart-4499.pid" && echo kept || echo gone) $(grep -c '^proc ' "$RESTART_OWN/effects")" \
  "false kept 3"
ln -s /etc/hostname "$RESTART_OWN/refused/.restart-4495.pid"
refused_restart=$(restart_stop_own "$RESTART_OWN/refused" 0 "$RESTART_OWN/effects")
is "stop-own rejects a refused restart record before a process probe" \
  "$(jq -r .ok <<<"$refused_restart") $(test -L "$RESTART_OWN/refused/.restart-4495.pid" && echo kept || echo gone) $(grep -c '^proc ' "$RESTART_OWN/effects")" \
  "false kept 3"
is "restart cleanup only sends guarded group probes" \
  "$(grep -c '^kill -0 -- -999999$' "$RESTART_OWN/effects") $(grep -Ec ' -- -(0|1)$|^kill -(TERM|KILL)' "$RESTART_OWN/effects" || true)" "2 0"

# The pidfile binds pid and kernel start time; a matching comm is not enough.
mystart=$(proc_start "$$")
owned_pid "$$" "$me" "$mystart" && ok "owned_pid accepts the true start time" || bad "owned_pid rejected the true start time"
owned_pid "$$" "$me" "$((mystart + 1))" && bad "owned_pid accepted a stale start time" || ok "owned_pid rejects a stale start time"
printf '%s %s' "$$" "$mystart" > "$STATE_DIR/x-1.pid"
alive "$STATE_DIR/x-1.pid" "$me" && ok "alive reads pid and start from the pidfile" || bad "alive rejected a live pidfile"
printf '%s %s' "$$" "$((mystart + 1))" > "$STATE_DIR/x-1.pid"
alive "$STATE_DIR/x-1.pid" "$me" && bad "alive accepted a reused pid" || ok "alive rejects a reused pid"

# The state directory is read in one descriptor-relative pass; a planted FIFO
# cannot block it, a link is not a file, and too many entries fail closed.
mkfifo "$STATE_DIR/cloudflared-4446.pid"; printf 'https://f.trycloudflare.com' > "$STATE_DIR/cloudflared-4446.url"
out=$(timeout 10 bash -c 'source "'"$S"'/tunnels.sh"; cmd_status' 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "status returns with a FIFO planted at a pidfile path" || bad "status blocked or failed (rc=$rc)"
is "and reports the refused ownership record" "$(jq -c .ok <<<"$out")" "false"
[[ -e $STATE_DIR/cloudflared-4446.url ]] && ok "and the unreadable pidfile's records are kept" || bad "status cleared records over an unreadable pidfile"
rm -f "$STATE_DIR/cloudflared-4446".*
LOG_STATE="$T/status-log-cap"; mkdir -p "$LOG_STATE"; : > "$T/status-log-signals"
printf '999999 1' > "$LOG_STATE/cloudflared-4449.pid"
printf 'https://one-two.trycloudflare.com' > "$LOG_STATE/cloudflared-4449.url"
printf 'public' > "$LOG_STATE/cloudflared-4449.reach"
truncate -s $((LOG_CAP + 1)) "$LOG_STATE/cloudflared-4449.log"
log_cap_result=$(PORTAL_STATE_DIR="$LOG_STATE" PORTLESS_STATE_DIR="$PORTLESS_STATE_DIR" \
  SIGNAL_LOG="$T/status-log-signals" S="$S" bash -c '
  source "$S/tunnels.sh"
  ss() { return 0; }
  portless_state_load() { return 0; }
  alive_line() { return 0; }
  reconcile_idle() { return 0; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { :; }
  kill() { printf "kill %s\n" "$*" >> "$SIGNAL_LOG"; return 1; }
  proc() { printf "proc %s\n" "$*" >> "$SIGNAL_LOG"; return 1; }
  out=$(cmd_status)
  printf "%s %s %s" "$(jq -r .ok <<<"$out")" \
    "$(stat -c %s "$STATE_DIR/cloudflared-4449.log")" "$(wc -l < "$SIGNAL_LOG")"
')
is "status truncates an oversized provider log without treating it as ownership state" \
  "$log_cap_result" "true 0 0"
DNS_STATE="$T/status-dns-budget"; mkdir -p "$DNS_STATE"; : > "$T/status-dns-calls"; : > "$T/status-dns-effects"
for i in $(seq 1 7); do
  port=$((4100 + i))
  printf 'https://pending-%s.trycloudflare.com' "$i" > "$DNS_STATE/cloudflared-$port.url"
  printf 'public' > "$DNS_STATE/cloudflared-$port.reach"
  printf '999999 1' > "$DNS_STATE/cloudflared-$port.pid"
  : > "$DNS_STATE/cloudflared-$port.dns"
done
dns_budget_result=$(PORTAL_STATE_DIR="$DNS_STATE" PORTLESS_STATE_DIR="$PORTLESS_STATE_DIR" \
  CALLS="$T/status-dns-calls" EFFECTS="$T/status-dns-effects" S="$S" bash -c '
  source "$S/tunnels.sh"
  ss() { return 0; }
  portless_state_load() { return 0; }
  alive_line() { return 0; }
  reconcile_idle() { return 0; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { :; }
  dns_published() {
    local step=${2:-3}
    printf "%s\n" "$step" >> "$CALLS"
    SECONDS=$((SECONDS + step))
    return 1
  }
  dns_resolves_here() { printf "network\n" >> "$EFFECTS"; return 1; }
  kill() { printf "kill\n" >> "$EFFECTS"; return 1; }
  proc() { printf "proc\n" >> "$EFFECTS"; return 1; }
  out=$(cmd_status)
  printf "%s %s %s %s %s" "$(jq -r .ok <<<"$out")" \
    "$(jq -r ".tunnels | length" <<<"$out")" \
    "$(jq -r "[.tunnels[]? | select(.dns == \"pending\")] | length" <<<"$out")" \
    "$(wc -l < "$CALLS")" "$(wc -l < "$EFFECTS")"
')
is "status shares one DNS deadline and still returns every pending row" \
  "$dns_budget_result" "true 7 7 2 0"
crowd=$(mktemp -d); for i in $(seq 1 600); do : > "$crowd/f$i"; done
is "a state directory with too many entries dumps nothing" "$(state_dump "$crowd" | jq -c '.files|length')" "0"
rm -rf "$crowd"
# State is read only from plain files we own; a planted link is not a file.
ln -s /etc/hostname "$STATE_DIR/cloudflared-4445.url"; ln -s /proc/self/stat "$STATE_DIR/cloudflared-4445.pid"
is "read_own returns nothing for a symlink" "$(read_own "$STATE_DIR/cloudflared-4445.url")" ""
before=$(wc -c < /etc/hostname)
write_own "$STATE_DIR/cloudflared-4445.url" "replaced"
[[ -L $STATE_DIR/cloudflared-4445.url ]] && bad "write_own followed a link" || ok "write_own replaces a link with a file"
is "and the target was never touched" "$(wc -c < /etc/hostname)" "$before"
rm -f "$STATE_DIR"/cloudflared-4445.*
mkdir -p "$T/notmine"; chmod 700 "$T/notmine"; ln -s "$T/notmine" "$T/link-dir"
own_dir "$T/link-dir" && bad "own_dir accepted a symlinked directory" || ok "own_dir rejects a symlinked directory"
printf 'x' > "$T/notmine/leaf"; is "a leaf under a symlinked parent is refused" "$(cat_own "$T/link-dir/leaf")" ""
chmod 770 "$T/notmine"; is "a leaf under a group-writable directory is refused" "$(cat_own "$T/notmine/leaf")" ""; chmod 700 "$T/notmine"
is "write_own creates 0600" "$(write_own "$T/notmine/w" v; stat -c %a "$T/notmine/w")" "600"
printf 'x' > "$T/notmine/loose"; chmod 666 "$T/notmine/loose"
is "a leaf writable by others is refused" "$(cat_own "$T/notmine/loose")" ""
chmod 644 "$T/notmine/loose"; is "and read once it is not" "$(cat_own "$T/notmine/loose")" "x"

# Provider binaries run by absolute, validated path only.
mkdir -p "$T/bin"; printf '#!/bin/sh\n' > "$T/bin/fakeprov"; chmod 777 "$T/bin/fakeprov"
PATH="$T/bin:$PATH" resolve_bin fakeprov >/dev/null && bad "resolve_bin accepted a world-writable executable" || ok "resolve_bin rejects a world-writable executable"
chmod 755 "$T/bin/fakeprov"; is "resolve_bin returns the absolute path of a safe one" "$(PATH="$T/bin:$PATH" resolve_bin fakeprov)" "$T/bin/fakeprov"
resolve_bin definitely-not-a-command-xyz >/dev/null && bad "resolve_bin found a ghost" || ok "resolve_bin fails for a missing command"
# Every directory on the way must be root's or ours and swappable by nobody
# else: a world-writable ancestor fails, a sticky one (like /tmp) does not.
mkdir -p "$T/open/bin" "$T/stuck/bin"; cp "$T/bin/fakeprov" "$T/open/bin/"; cp "$T/bin/fakeprov" "$T/stuck/bin/"
chmod 777 "$T/open"; chmod 1777 "$T/stuck"
PATH="$T/open/bin:$PATH" resolve_bin fakeprov >/dev/null && bad "resolve_bin accepted a world-writable ancestor" || ok "resolve_bin rejects a world-writable ancestor"
is "resolve_bin accepts a sticky ancestor" "$(PATH="$T/stuck/bin:$PATH" resolve_bin fakeprov)" "$T/stuck/bin/fakeprov"
state launch "$STATE_DIR" open.log -- "$T/open/bin/fakeprov" >/dev/null 2>&1 && bad "launch ran a binary under a world-writable ancestor" || ok "launch refuses a binary under a world-writable ancestor"
cp /usr/bin/true "$T/bin/execute-only"; chmod 111 "$T/bin/execute-only"
execute_only=$(state launch "$STATE_DIR" execute-only.log -- "$T/bin/execute-only" 2>/dev/null); execute_only_rc=$?
if (( execute_only_rc == 0 )) && [[ $execute_only =~ ^[1-9][0-9]*\ [1-9][0-9]*$ ]] && (( ${execute_only%% *} > 1 )); then
  ok "launch binds an execute-only ELF"
else
  bad "launch refused an execute-only ELF: rc=$execute_only_rc out=$execute_only"
fi

# launch: a session of its own, a private log, pid bound to start time.
out=$(state launch "$STATE_DIR" launch-test.log -- /usr/bin/sleep 20); lpid=${out%% *}; lstart=${out#* }
owned_pid "$lpid" sleep "$lstart" && ok "launch reports a pid whose start time matches" || bad "launch pid/start mismatch: $out"
[[ $(ps -o sid= -p "$lpid" | tr -d ' ') == "$lpid" ]] && ok "the launched process leads its own session" || bad "launched process is not a session leader"
is "the launch log is private" "$(stat -c %a "$STATE_DIR/launch-test.log")" "600"
kill "$lpid" 2>/dev/null
TRACKED="$T/tracked-launch"; mkdir -p "$TRACKED/blocked.pid"
printf '#!/bin/sh\nprintf ran > "'"$TRACKED"'/ran"\n' > "$TRACKED/provider"; chmod 755 "$TRACKED/provider"
state launch-tracked "$TRACKED" provider.log blocked.pid -- "$TRACKED/provider" >/dev/null 2>&1; rc=$?
sleep 0.1
is "a failed pid record prevents provider execution" "$rc $(test -e "$TRACKED/ran" && echo ran || echo blocked)" "1 blocked"
# A launched tunnel keeps only stdio and its executable: any other inherited
# descriptor would stay open for the tunnel's whole life — a lifecycle lock
# held across the launch would never release, failing every later start and
# hanging uninstall's exclusive wait forever.
LT="$T/lockinh"; mkdir -p "$LT"
{ exec 8>"$LT/.lifecycle.lock"; } 2>/dev/null && flock -n -x 8 2>/dev/null || bad "could not hold a test lock"
lout=$(state launch "$LT" inh.log -- /usr/bin/sleep 300); lpid=${lout%% *}
exec 8>&- 2>/dev/null || true
if ls -l "/proc/$lpid/fd" 2>/dev/null | grep -q "lifecycle.lock"; then bad "the tunnel inherited the lifecycle lock"; else ok "the tunnel inherits no lock descriptor"; fi
flock -n -x "$LT/.lifecycle.lock" -c true 2>/dev/null && ok "the lock is acquirable while the tunnel lives" || bad "the tunnel still holds the lock"
kill "$lpid" 2>/dev/null
is "cmd_stop rejects an unknown provider" "$(cmd_stop nope 1 | jq -r .error)" "unknown provider"
# A stub provider: an ELF copy (so the process carries the provider's name)
# whose URL and argv the sourced functions supply. Nothing touches the network.
mkdir -p "$T/prov"; cp /usr/bin/sleep "$T/prov/cloudflared"
stub_env() {   # run a snippet with the stub as cloudflared and no DNS gate
  PATH="$T/prov:$PATH" PORTAL_STATE_DIR="$1" bash -c 'source "'"$S"'/tunnels.sh"
    cloudflared_argv() { echo 300; }; cloudflared_url_from_log() { echo https://stub-one-two.trycloudflare.com; }
    dns_gate() { return 0; }; listener_identity() { echo "999999 1"; }; target_owns_port() { return 0; }
    portless_state_load; '"$2"
}
real_stub_env() {
  PATH="$T/prov:$PATH" PORTAL_STATE_DIR="$1" bash -c 'source "'"$S"'/tunnels.sh"
    cloudflared_argv() { echo 300; }; cloudflared_url_from_log() { echo https://stub-one-two.trycloudflare.com; }
    dns_gate() { return 0; }; portless_state_load; '"$2"
}
CANCEL="$T/cancel-start"; mkdir -p "$CANCEL"
PATH="$T/prov:$PATH" PORTAL_STATE_DIR="$CANCEL" /usr/bin/python3 -I -S "$PR" run 1000 60 -- bash -c 'source "'"$S"'/tunnels.sh"
  cloudflared_argv() { echo 300; }; cloudflared_url_from_log() { return 1; }
  listener_identity() { echo "999999 1"; }; target_owns_port() { return 0; }
  dns_gate() { return 0; }; cmd_start cloudflared 4488' \
  >/dev/null 2>&1 & start_wrapper=$!
for _ in $(seq 1 100); do [[ -s $CANCEL/cloudflared-4488.pid ]] && break; sleep 0.02; done
cancel_identity=$(cat "$CANCEL/cloudflared-4488.pid" 2>/dev/null)
kill -TERM "$start_wrapper" 2>/dev/null; wait "$start_wrapper" 2>/dev/null; cancel_rc=$?
if [[ -n $cancel_identity ]] && proc check ${cancel_identity%% *} ${cancel_identity#* } >/dev/null 2>&1; then
  cancel_state=alive; proc signal ${cancel_identity%% *} ${cancel_identity#* } KILL >/dev/null 2>&1
else
  cancel_state=gone
fi
is "cancelling a public start ends its detached provider" "$((cancel_rc != 0)) $cancel_state" "1 gone"

PORTLESS_CANCEL="$T/cancel-portless"; mkdir -p "$PORTLESS_CANCEL/bin"
cat > "$PORTLESS_CANCEL/bin/portless" <<'SH'
#!/bin/bash
routes=$PORTLESS_STATE_DIR/routes.json
pause() {
  [[ $PORTLESS_TEST_PAUSE == "$1" && ! -e $PORTLESS_TEST_SYNC.used ]] || return 0
  : > "$PORTLESS_TEST_SYNC.used"
  trap 'exit 143' TERM INT HUP
  printf '%s' "$1" > "$PORTLESS_TEST_SYNC"
  while :; do sleep 1; done
}
[[ ${1:-} == alias ]] || exit 2
if [[ ${2:-} == --remove ]]; then
  pause before-remove
  jq --arg n "$3" 'map(select((.hostname | split(".")[0]) != $n))' "$routes" > "$routes.tmp.$$" || exit 1
  mv "$routes.tmp.$$" "$routes"
  exit 0
fi
name=$2 port=$3
jq --arg n "$name" --argjson p "$port" '
  map(select((.hostname | split(".")[0]) != $n))
  + [{hostname:($n + ".localhost"), port:$p, pid:0}]
' "$routes" > "$routes.tmp.$$" || exit 1
mv "$routes.tmp.$$" "$routes"
pause after-add
SH
chmod 700 "$PORTLESS_CANCEL/bin/portless"
portless_cancel_case() {
  local ownership="$1" pause_at="$2" root="$PORTLESS_CANCEL/$1-$2" wrapper wrapper_start rc route marker=absent state
  mkdir -p "$root/home" "$root/portal" "$root/portless"
  jq -nc '[{hostname:"old.localhost",port:45882,pid:0}]' > "$root/portless/routes.json"
  if [[ $ownership == owned ]]; then
    printf old > "$root/portal/portless-45882.name"
    printf https://old.localhost > "$root/portal/portless-45882.url"
    printf local > "$root/portal/portless-45882.reach"
  fi
  : > "$root/sync"
  HOME="$root/home" PATH="$PORTLESS_CANCEL/bin:/usr/bin:/bin" \
    PORTAL_STATE_DIR="$root/portal" PORTLESS_STATE_DIR="$root/portless" \
    PORTLESS_TEST_SYNC="$root/sync" PORTLESS_TEST_PAUSE="$pause_at" \
    /usr/bin/python3 -I -S "$PR" run 1048576 10 -- \
      /usr/bin/bash "$S/tunnels.sh" start portless 45882 new > "$root/out" 2>&1 &
  wrapper=$!
  wrapper_start=$(proc_start "$wrapper")
  for _ in $(seq 1 400); do [[ -s $root/sync ]] && break; sleep 0.01; done
  if (( wrapper > 1 )) && proc check "$wrapper" "$wrapper_start" >/dev/null 2>&1; then
    kill -TERM "$wrapper" 2>/dev/null
  fi
  wait "$wrapper" 2>/dev/null; rc=$?
  route=$(jq -r 'first(.[] | select(.port == 45882) | .hostname) // "absent"' "$root/portless/routes.json")
  [[ -e $root/portal/portless-45882.name ]] && marker=$(cat "$root/portal/portless-45882.name")
  proc check "$wrapper" "$wrapper_start" >/dev/null 2>&1 && state=alive || state=gone
  printf '%s/%s:%s:%s:%s:%s ' "$ownership" "$pause_at" "$rc" "$route" "$marker" "$state"
}
portless_cancelled=""
for ownership in owned unowned; do
  for pause_at in before-remove after-add; do
    portless_cancelled+=$(portless_cancel_case "$ownership" "$pause_at")
  done
done
is "cancelling a Portless rename restores its route and ownership" "$portless_cancelled" \
  "owned/before-remove:143:old.localhost:old:gone owned/after-add:143:old.localhost:old:gone unowned/before-remove:143:old.localhost:absent:gone unowned/after-add:143:old.localhost:absent:gone "

INCOMPLETE="$T/incomplete-start"; mkdir -p "$INCOMPLETE"
state launch-tracked "$INCOMPLETE" cloudflared-4489.log cloudflared-4489.pid -- "$T/prov/cloudflared" 300 >/dev/null
printf '999999 1' > "$INCOMPLETE/cloudflared-4489.target"
incomplete_identity=$(cat "$INCOMPLETE/cloudflared-4489.pid")
stub_env "$INCOMPLETE" 'cmd_status >/dev/null'
proc check ${incomplete_identity%% *} ${incomplete_identity#* } >/dev/null 2>&1 && incomplete_state=alive || incomplete_state=gone
is "status reconciles an owned provider with no URL" "$incomplete_state $(find "$INCOMPLETE" -maxdepth 1 -type f | wc -l)" "gone 0"

MALFORMED_URL="$T/malformed-url"; mkdir -p "$MALFORMED_URL"
state launch-tracked "$MALFORMED_URL" cloudflared-4490.log cloudflared-4490.pid -- "$T/prov/cloudflared" 300 >/dev/null
printf 'not-a-url' > "$MALFORMED_URL/cloudflared-4490.url"
malformed_status=$(stub_env "$MALFORMED_URL" 'cmd_status')
is "status reports a malformed owned URL" "$(jq -c .ok <<<"$malformed_status") $(test -e "$MALFORMED_URL/cloudflared-4490.pid" && echo kept || echo lost)" "false kept"
malformed_identity=$(cat "$MALFORMED_URL/cloudflared-4490.pid")
proc signal ${malformed_identity%% *} ${malformed_identity#* } KILL >/dev/null 2>&1
# A tunnel whose pidfile cannot be written is stopped again, not left public with no record.
R1="$T/rt1"; mkdir -p "$R1/cloudflared-4449.pid"
is "start refuses an unreadable pidfile before launch" "$(stub_env "$R1" 'cmd_start cloudflared 4449' | jq -r .error)" "cloudflared on port 4449 has a pidfile that cannot be read; its records are kept"
sleep 0.3; pgrep -f "$T/prov/cloudflared" >/dev/null && bad "the unrecorded tunnel is still running" || ok "and the unrecorded tunnel was stopped"
rmdir "$R1/cloudflared-4449.pid"
is "the same start succeeds once the pidfile can be written" "$(stub_env "$R1" 'cmd_start cloudflared 4449' | jq -r .url)" "https://stub-one-two.trycloudflare.com"
# A status snapshot taken before a replacement started does not clear the replacement.
snap=$(state dump "$R1" 8192 4096); old=$(cat "$R1/cloudflared-4449.pid")
stub_env "$R1" 'cmd_stop cloudflared 4449 >/dev/null'
stub_env "$R1" 'cmd_start cloudflared 4449 >/dev/null'
[[ $(cat "$R1/cloudflared-4449.pid") != "$old" ]] && ok "a replacement wrote its own pidfile" || bad "no replacement pidfile"
SNAP="$snap" stub_env "$R1" 'state() { if [[ $1 == dump && $2 == "$STATE_DIR" ]]; then printf "%s" "$SNAP"; else /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; fi; }; cmd_status >/dev/null'
is "status with a stale snapshot leaves the replacement's records" "$(ls "$R1" | grep -c '^cloudflared-4449\.')" "5"
# A share whose reach record is missing still carries its pid to the check.
rm -f "$R1/cloudflared-4449.reach"
stub_env "$R1" 'cmd_status >/dev/null'
is "status keeps a live share with no reach record" "$(ls "$R1" | grep -c -E '^cloudflared-4449\.(pid|url)$')" "2"
# stop-own refuses to guess when the state cannot be listed.
(cd "$R1" && touch $(seq -f 'crowd-%g' 1 4100))
is "stop-own fails closed when the state cannot be listed" "$(PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" stop-own | jq -r .error)" "could not list Portal's state; nothing was stopped"
is "status fails closed when the state cannot be listed" "$(PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" status | jq -r .error)" "could not list Portal's state"
is "stop-all fails instead of claiming success when the state cannot be listed" "$(PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" stop-all | jq -r .error)" "could not list tunnels; nothing was stopped"
# Rows are capped like the scanner's ports: past the cap, an error, not a document.
RC="$T/rows"; mkdir -p "$RC"; for i in $(seq 1 520); do printf 'https://a-b-%s.trycloudflare.com' "$i" > "$RC/cloudflared-$((10000 + i)).url"; printf '999999 1' > "$RC/cloudflared-$((10000 + i)).pid"; done
is "status reports an error past the row cap" "$(PORTAL_STATE_DIR="$RC" bash -c 'source "'"$S"'/tunnels.sh"; alive_line() { return 0; }; portless_state_load; cmd_status' | jq -r .error)" "more than 512 tunnels"
# When the Portless directory is over its cap, status keeps the local markers
# and returns independent public rows rather than treating routes as vanished.
PS="$T/pstate"; mkdir -p "$PS"; for i in $(seq 1 520); do : > "$PS/j$i"; done
PD="$T/prt"; mkdir -p "$PD"; printf 'https://acme.localhost' > "$PD/portless-3000.url"; printf 'acme' > "$PD/portless-3000.name"; printf 'local' > "$PD/portless-3000.reach"
printf 'https://one-two.trycloudflare.com' > "$PD/cloudflared-3001.url"; printf '999999 1' > "$PD/cloudflared-3001.pid"; printf 'public' > "$PD/cloudflared-3001.reach"
printf 'https://unit.ngrok.app' > "$PD/ngrok-3002.url"; printf '999999 1' > "$PD/ngrok-3002.pid"; printf 'public' > "$PD/ngrok-3002.reach"
: > "$T/pstate-effects"
portless_status=$(PORTLESS_STATE_DIR="$PS" PORTAL_STATE_DIR="$PD" EFFECTS="$T/pstate-effects" S="$S" bash -c '
  source "$S/tunnels.sh"
  ss() { return 0; }
  alive_line() { return 0; }
  reconcile_idle() { return 0; }
  cloudflared_adopt() { :; }
  ngrok_adopt() { :; }
  portless_adopt() { printf "portless-adopt\n" >> "$EFFECTS"; }
  portless_probe() { return 1; }
  kill() { printf "kill\n" >> "$EFFECTS"; return 1; }
  proc() { printf "proc\n" >> "$EFFECTS"; return 1; }
  cmd_status
')
is "unreadable Portless state keeps public and tracked local status rows" \
  "$(jq -c '[.ok, ([.tunnels[]? | select(.reach == "public") | .provider] | sort), [.tunnels[]? | select(.provider == "portless") | .port]]' <<<"$portless_status") $(wc -l < "$T/pstate-effects")" \
  '[true,["cloudflared","ngrok"],[3000]] 0'
is "status keeps portless markers when the Portless state is unreadable" "$(ls "$PD" | grep -c '^portless-3000\.')" "3"
rm -f "$R1"/crowd-*
is "stop-own stops what it can list" "$(PATH="$T/prov:$PATH" PORTAL_STATE_DIR="$R1" "$S/tunnels.sh" stop-own | jq -c .ok)" "true"
sleep 0.3; pgrep -f "$T/prov/cloudflared" >/dev/null && bad "stop-own left the tunnel running" || ok "and the tunnel is gone"
# An expired idle timer in a stale snapshot stops nothing but the snapshot's own process.
stub_env "$R1" 'cmd_start cloudflared 4449 >/dev/null'; old=$(cat "$R1/cloudflared-4449.pid")
printf '%s' $(( $(printf '%(%s)T' -1) - 700 )) > "$R1/cloudflared-4449.idle"
snap=$(state dump "$R1" 8192 4096)
state launch "$R1" cloudflared-4449.log -- "$T/prov/cloudflared" 300 > "$R1/cloudflared-4449.pid"; rm -f "$R1/cloudflared-4449.idle"
SNAP="$snap" stub_env "$R1" 'state() { if [[ $1 == dump && $2 == "$STATE_DIR" ]]; then printf "%s" "$SNAP"; else /usr/bin/python3 -I -S "$STATEDIR_PY" "$@"; fi; }; target_owns_port() { return 1; }; cmd_status >/dev/null'
sleep 0.2; kill -0 "${old%% *}" 2>/dev/null && ok "the snapshot's own process is left to its live status" || bad "the old process was stopped from a stale snapshot"
kill -0 "$(cut -d' ' -f1 "$R1/cloudflared-4449.pid")" 2>/dev/null && ok "and the replacement was not stopped" || bad "the replacement was stopped from a stale snapshot"
kill "${old%% *}" 2>/dev/null
# A stop is a stop only once the process is gone: it fails, keeping the records, when nothing works.
is "cmd_stop fails when the process will not die" "$(stub_env "$R1" 'STOP_TERM_WAIT=2; STOP_KILL_WAIT=2; proc() { :; }; kill() { :; }; cmd_stop cloudflared 4449' | jq -r .error)" "cloudflared on port 4449 did not stop; its records are kept"
is "and keeps its records" "$(ls "$R1" | grep -c -E '^cloudflared-4449\.(pid|url)$')" "2"
# An idle tunnel whose stop failed stays in the status, records and all.
printf '%s' $(( $(printf '%(%s)T' -1) - 700 )) > "$R1/cloudflared-4449.idle"
is "status keeps listing an idle tunnel it could not stop" "$(stub_env "$R1" 'STOP_TERM_WAIT=2; STOP_KILL_WAIT=2; target_owns_port() { return 1; }; proc() { :; }; kill() { :; }; cmd_status' | jq -c '[.tunnels[]|select(.provider=="cloudflared" and .port==4449)|.port]')" "[4449]"
is "and its records" "$(ls "$R1" | grep -c -E '^cloudflared-4449\.(pid|url)$')" "2"
stub_env "$R1" 'cmd_stop cloudflared 4449 >/dev/null'   # a real stop ends the replacement
# A process that ignores TERM is killed, and the stop reports only once it is gone.
setsid bash -c 'trap "" TERM; exec "'"$T"'/prov/cloudflared" 300' >/dev/null 2>&1 & sleep 0.4
ig=$(ps -eo pid,comm,args | awk -v p="$T/prov/cloudflared 300" '$2=="cloudflared" && index($0, p) {print $1}' | head -1)
printf '%s %s' "$ig" "$(awk '{print $22}' "/proc/$ig/stat")" > "$R1/cloudflared-4449.pid"
is "cmd_stop escalates past an ignored TERM" "$(stub_env "$R1" 'cmd_stop cloudflared 4449' | jq -c .ok)" "true"
kill -0 "$ig" 2>/dev/null && bad "the TERM-ignoring process is still alive after ok:true" || ok "and the process is gone before ok:true"
# stop-all reports a tunnel it could not stop, rather than claiming success.
setsid bash -c 'trap "" TERM; exec "'"$T"'/prov/cloudflared" 300' >/dev/null 2>&1 & sleep 0.4
sg=$(ps -eo pid,comm,args | awk -v p="$T/prov/cloudflared 300" '$2=="cloudflared" && index($0, p) {print $1}' | head -1)
printf '%s %s' "$sg" "$(awk '{print $22}' "/proc/$sg/stat")" > "$R1/cloudflared-4449.pid"
printf 'https://a-b-c.trycloudflare.com' > "$R1/cloudflared-4449.url"; printf 'public' > "$R1/cloudflared-4449.reach"
is "stop-all reports a tunnel it could not stop" "$(stub_env "$R1" 'STOP_TERM_WAIT=2; STOP_KILL_WAIT=2; proc() { :; }; kill() { :; }; cmd_stop_all' | jq -r .ok)" "false"
kill "$sg" 2>/dev/null
is "start rejects a bare --target" "$(timeout 5 bash -c 'source "'"$S"'/tunnels.sh"; portless_state_load; cmd_start cloudflared 3000 --target' | jq -r .error)" "invalid target identity"
# stop-own enumerates a portless name-only partial start (alias written, url not yet).
PN="$T/pn"; mkdir -p "$PN"; printf 'acme' > "$PN/portless-4460.name"
is "stop-own enumerates a portless name-only partial" "$(PORTAL_STATE_DIR="$PN" bash -c 'source "'"$S"'/tunnels.sh"; state dump "$STATE_DIR" 8192 "$STATE_FILES_CAP" 2>/dev/null | jq -r '"'"'.files | keys[] | select(test("^[a-z]+-[0-9]+\\.(url|pid|name)$")) | sub("\\.(url|pid|name)$"; "")'"'"'')" "portless-4460"
python3 -m http.server 4470 --bind 127.0.0.1 >/dev/null 2>&1 & lp=$!; sleep 0.6
lpstart=$(proc_start "$lp")
is "start refuses a stale process start" "$(real_stub_env "$R1" "cmd_start cloudflared 4470 --target $lp $((lpstart + 1))" | jq -r .error)" "port 4470 is no longer served by the approved process"
is "start rejects a malformed target" "$(real_stub_env "$R1" 'cmd_start cloudflared 4470 --target 0x1 2' | jq -r .error)" "invalid target identity"
is "start proceeds for the process that serves the port" "$(real_stub_env "$R1" "cmd_start cloudflared 4470 --target $lp $lpstart" | jq -c .ok)" "true"
is "the public share records the approved process" "$(cat "$R1/cloudflared-4470.target")" "$lp $lpstart"
stub_env "$R1" 'cmd_stop cloudflared 4470 >/dev/null'; kill "$lp" 2>/dev/null

R2="$T/target-idle"; mkdir -p "$R2"
python3 -m http.server 4471 --bind 127.0.0.1 >/dev/null 2>&1 & first_listener=$!; sleep 0.4
first_start=$(proc_start "$first_listener")
real_stub_env "$R2" "cmd_start cloudflared 4471 --target $first_listener $first_start >/dev/null"
tunnel_identity=$(cat "$R2/cloudflared-4471.pid")
kill "$first_listener" 2>/dev/null; wait "$first_listener" 2>/dev/null
python3 -m http.server 4471 --bind 127.0.0.1 >/dev/null 2>&1 & replacement_listener=$!; sleep 0.4
real_stub_env "$R2" 'cmd_status >/dev/null'
proc check ${tunnel_identity%% *} ${tunnel_identity#* } >/dev/null 2>&1 && tunnel_state=alive || tunnel_state=gone
is "a replacement listener cannot inherit a public share" "$tunnel_state" "gone"
kill "$replacement_listener" 2>/dev/null; wait "$replacement_listener" 2>/dev/null

R3="$T/idle-write"; mkdir -p "$R3"
python3 -m http.server 4472 --bind 127.0.0.1 >/dev/null 2>&1 & idle_listener=$!; sleep 0.4
idle_start=$(proc_start "$idle_listener")
real_stub_env "$R3" "cmd_start cloudflared 4472 --target $idle_listener $idle_start >/dev/null"
idle_tunnel=$(cat "$R3/cloudflared-4472.pid")
kill "$idle_listener" 2>/dev/null; wait "$idle_listener" 2>/dev/null
mkdir "$R3/cloudflared-4472.idle"
real_stub_env "$R3" 'cmd_status >/dev/null'
proc check ${idle_tunnel%% *} ${idle_tunnel#* } >/dev/null 2>&1 && idle_tunnel_state=alive || idle_tunnel_state=gone
is "an unwritable idle deadline closes the public tunnel" "$idle_tunnel_state" "gone"
is "cmd_stop rejects a bad port" "$(cmd_stop cloudflared x | jq -r .error)" "invalid port"
# A pidfile that is present but unreadable is a failure, not an adopt-and-forget.
UB="$T/unread"; mkdir -p "$UB"; : > "$UB/cloudflared-4600.pid"; printf 'https://x-y.trycloudflare.com' > "$UB/cloudflared-4600.url"
is "cmd_stop fails on an empty pidfile rather than clearing state" "$(PORTAL_STATE_DIR="$UB" bash -c 'source "'"$S"'/tunnels.sh"; portless_state_load; cmd_stop cloudflared 4600' | jq -r .error)" "cloudflared on port 4600 has a pidfile that cannot be read; its records are kept"
is "and the records are kept" "$(ls "$UB" | grep -c -E '^cloudflared-4600\.(pid|url)$')" "2"
# owned_pid accepts a process whose executable path shows "(deleted)".
sleep 300 & dpid=$!; dstart=$(cut -d')' -f2- "/proc/$dpid/stat" | awk '{print $20}')
is "owned_pid matches by comm regardless of a deleted exe" "$(bash -c 'source "'"$S"'/tunnels.sh"; owned_pid '"$dpid"' sleep '"$dstart"' && echo yes || echo no')" "yes"
kill "$dpid" 2>/dev/null

PY3=$(readlink -f -- "$(command -v python3)")
wait_listener_pid() {
  local p i
  for i in $(seq 1 50); do
    p=$(ss -tlnpH "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
    [[ -n $p ]] && { printf '%s' "$p"; return 0; }
    sleep 0.05
  done
  return 1
}
REL="$T/rel-launch"; mkdir -p "$REL/target/bin" "$REL/helper/bin"
cp "$PY3" "$REL/target/bin/dev"; cp /usr/bin/true "$REL/helper/bin/dev"
cat > "$REL/srv.py" <<'PYEOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
( cd "$REL/target" && setsid ./bin/dev "$REL/srv.py" 4499 >/dev/null 2>&1 & ) >/dev/null 2>&1
rel_pid=$(wait_listener_pid 4499) || bad "the relative-launcher fixture never listened"
rel_start=$(proc_start "$rel_pid")
rel_argv=$(jq -nc --arg a './bin/dev' --arg s "$REL/srv.py" '[$a,$s,"4499"]')
rel_out=$( cd "$REL/helper" && "$S/lifecycle.sh" restart "$rel_pid" "$rel_start" 4499 "$REL/target" "$rel_argv" )
sleep 0.6
new_pid=$(ss -tlnpH 'sport = :4499' 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
if [[ $(jq -r .ok <<<"$rel_out") == true && -n $new_pid ]]; then
  is "restart resolves a relative launcher from the process's own directory" "$(readlink "/proc/$new_pid/exe")" "$REL/target/bin/dev"
  is "and keeps the original argv[0]" "$(tr '\0' '\n' < "/proc/$new_pid/cmdline" | head -1)" "./bin/dev"
  is "and its output is discarded, not parked on a deleted log" "$(readlink "/proc/$new_pid/fd/1")$(readlink "/proc/$new_pid/fd/2")" "/dev/null/dev/null"
  is "and no restart leaf remains" "$(ls "$STATE_DIR"/.restart-4499.* 2>/dev/null | wc -l)" "0"
  kill "$new_pid" 2>/dev/null
else
  bad "a relative launcher restart failed: $rel_out"
fi
RB2="$T/rel-restart"; mkdir -p "$RB2"
( cd "$RB2" && setsid "$PY3" -m http.server 4499 --bind 127.0.0.1 >/dev/null 2>&1 & ) >/dev/null 2>&1
rb_pid=$(wait_listener_pid 4499) || bad "the non-serving-replacement fixture never listened"
rb_start=$(proc_start "$rb_pid")
rb_out=$( cd "$RB2" && "$S/lifecycle.sh" restart "$rb_pid" "$rb_start" 4499 "$RB2" '["/usr/bin/sleep","4590"]' )
stray=$(pgrep -f "sleep [4]590")
rb_leaves=$(ls "$STATE_DIR"/.restart-4499.* 2>/dev/null | wc -l)
if [[ -n $stray ]]; then s_start=$(proc_start "$stray"); proc signal "$stray" "$s_start" KILL >/dev/null 2>&1; fi
is "a replacement that never serves is ended" "$stray" ""
is "and its identity record cleared" "$rb_leaves" "0"
jq -e '.ok == false' <<<"$rb_out" >/dev/null 2>&1 && ok "and the restart reports failure" || bad "restart reported success for a non-serving replacement: $rb_out"
DIS="$T/discard-launch"; mkdir -p "$DIS"
discard_line=$(state launch-tracked "$DIS" --discard-output discard.pid -- /usr/bin/sleep 4591)
sleep 0.2
dpid=${discard_line%% *}; dstart=${discard_line#* }
is "a discard launch records the identity before execution" "$(cat "$DIS/discard.pid" 2>/dev/null)" "$discard_line"
is "and creates no log leaf" "$(ls "$DIS" | grep -vc '^discard\.pid$')" "0"
is "and its output goes to /dev/null" "$(readlink "/proc/$dpid/fd/1" 2>/dev/null)" "/dev/null"
proc signal "$dpid" "$dstart" KILL >/dev/null 2>&1

# ---- proc.py: capped runs, and signals bound to one process -----------------
is "run passes output and exit status through" "$(/usr/bin/python3 -I -S "$PR" run 1000 5 -- bash -c 'echo hello; exit 3'; echo "rc=$?")" "hello
rc=3"
out=$(/usr/bin/python3 -I -S "$PR" run 100 5 -- bash -c 'sleep 40 & yes | head -c 5000; wait' 2>/dev/null); rc=$?
is "run returns 125 past the output cap" "$rc" "125"
is "and passes nothing on" "${#out}" "0"
sleep 0.2; ps -eo args | grep -q '^sleep 40$' && bad "run left the helper's child behind past the cap" || ok "and ends the whole process group"
out=$(/usr/bin/python3 -I -S "$PR" run 1000 1 -- bash -c 'sleep 41 & wait' 2>/dev/null); rc=$?
is "run returns 124 past the deadline" "$rc" "124"
ps -eo args | grep -q '^sleep 41$' && bad "run left the helper's child behind past the deadline" || ok "and ends that group too"
# A descendant that stays in the group (no setsid), inherits the pipes and
# ignores TERM is still killed once the deadline's grace period passes. It
# records its own pid; run blocks for the deadline plus the grace, so by the
# time it returns the process is gone, not merely a zombie.
dmark="$T/desc.pid"
/usr/bin/python3 -I -S "$PR" run 100000 1 -- bash -c '(trap "" TERM; echo $BASHPID > "'"$dmark"'"; exec sleep 300) & exit 0' >/dev/null 2>&1
dp=$(cat "$dmark" 2>/dev/null)
if [[ -n $dp && -e /proc/$dp && $(awk '{print $3}' "/proc/$dp/stat" 2>/dev/null) != Z ]]; then
  bad "a TERM-ignoring descendant survived the deadline (pid $dp)"; kill -9 "$dp" 2>/dev/null
else ok "run kills a TERM-ignoring descendant after the grace period"; fi
term_mark="$T/term-child.pid"
/usr/bin/python3 -I -S "$PR" run 1000 60 -- bash -c 'printf "%s" "$BASHPID" > "'"$term_mark"'"; exec sleep 300' >/dev/null 2>&1 & wrapper=$!
for _ in $(seq 1 50); do [[ -s $term_mark ]] && break; sleep 0.02; done
term_child=$(cat "$term_mark" 2>/dev/null); term_start=$(proc_start "$term_child")
kill -TERM "$wrapper" 2>/dev/null; wait "$wrapper" 2>/dev/null; term_rc=$?
if [[ -n $term_child ]] && proc check "$term_child" "$term_start"; then
  term_state=alive; proc signal "$term_child" "$term_start" KILL 2>/dev/null
else
  term_state=gone
fi
is "terminating the wrapper ends its helper session" "$term_rc $term_state" "143 gone"
python3 -m http.server 4495 --bind 127.0.0.1 >/dev/null 2>&1 & lp=$!; sleep 0.6
lst=$(cut -d')' -f2- "/proc/$lp/stat" | awk '{print $20}')
/usr/bin/python3 -I -S "$PR" check "$lp" "$lst" && ok "check accepts the pid with its own start time" || bad "check refused the right process"
/usr/bin/python3 -I -S "$PR" check "$lp" "$((lst + 1))" && bad "check accepted a wrong start time" || ok "check refuses a wrong start time"
/usr/bin/python3 -I -S "$PR" signal "$lp" "$((lst + 1))" STOP && bad "signal sent to a wrong start time" || ok "signal refuses a wrong start time"
is "and the process was not touched" "$(cut -d')' -f2- "/proc/$lp/stat" | awk '{print $1}')" "S"
# lifecycle.sh carries the same identity from the scan to every signal.
is "lifecycle refuses a pid that is not the listed process" "$("$S/lifecycle.sh" pause "$lp" "$((lst + 1))" 4495 | jq -r .error)" "pid $lp is no longer the process that was listed"
is "lifecycle refuses a port the process does not own" "$("$S/lifecycle.sh" pause "$lp" "$lst" 4496 | jq -r .error)" "pid $lp no longer owns port 4496"
is "lifecycle pauses the listed process" "$("$S/lifecycle.sh" pause "$lp" "$lst" 4495 | jq -c .ok) $(cut -d')' -f2- "/proc/$lp/stat" | awk '{print $1}')" "true T"
is "lifecycle resumes it" "$("$S/lifecycle.sh" resume "$lp" "$lst" 4495 | jq -c .ok) $(cut -d')' -f2- "/proc/$lp/stat" | awk '{print $1}')" "true S"
is "lifecycle stops it" "$("$S/lifecycle.sh" stop "$lp" "$lst" 4495 | jq -c .ok)" "true"
sleep 0.5; kill -0 "$lp" 2>/dev/null && bad "the listener survived stop" || ok "and it is gone"

COMP="$T/restart-competitor"; mkdir -p "$COMP"
(cd "$COMP" && exec python3 -m http.server 4496 --bind 127.0.0.1 >/dev/null 2>&1) & old_server=$!; sleep 0.4
old_start=$(proc_start "$old_server")
(cd "$COMP"; while ss -tlnH 'sport = :4496' | grep -q .; do sleep 0.02; done; exec python3 -m http.server 4496 --bind 127.0.0.1 >/dev/null 2>&1) & competitor=$!
competitor_start=$(proc_start "$competitor")
restart_result=$("$S/lifecycle.sh" restart "$old_server" "$old_start" 4496 "$COMP" '["/usr/bin/true"]')
is "restart rejects an unrelated same-directory listener" "$(jq -c '[.ok,.effect]' <<<"$restart_result")" '[false,"stopped"]'
proc signal "$competitor" "$competitor_start" TERM >/dev/null 2>&1 || true
python3 -m http.server 4497 --bind 127.0.0.1 >/dev/null 2>&1 & scan_server=$!; sleep 0.4
scan_start=$(proc_start "$scan_server"); scan=$("$S/scan-ports.sh")
is "the scan carries the owned listener's kernel start time" "$(jq -r '.ports[] | select(.port == 4497) | "\(.pid) \(.start)"' <<<"$scan")" "$scan_server $scan_start"
is "a single-owner scan grants process authority" "$(jq -r '.ports[] | select(.port == 4497) | .exclusiveOwner' <<<"$scan")" "true"
/usr/bin/sleep 300 & scan_peer=$!; scan_peer_start=$(proc_start "$scan_peer")
scan_stub="$T/scan-stub"; mkdir -p "$scan_stub"
cat > "$scan_stub/ss" <<'SH'
#!/bin/bash
case "$*" in
  -tlnpH) printf 'LISTEN 0 5 127.0.0.1:4498 0.0.0.0:* users:(("python3",pid=%s,fd=3),("sleep",pid=%s,fd=4))\n' "$REP_PID" "$OTHER_PID" ;;
  '-tnH state established') ;;
  *) exit 1 ;;
esac
SH
chmod 755 "$scan_stub/ss"
shared_scan=$(REP_PID="$scan_server" OTHER_PID="$scan_peer" PATH="$scan_stub:/usr/bin:/bin" "$S/scan-ports.sh")
is "a shared scan keeps the representative listener identity" "$(jq -r '.ports[] | select(.port == 4498) | "\(.pid) \(.start)"' <<<"$shared_scan")" "$scan_server $scan_start"
is "a shared scan with two attributed owners denies process authority" "$(jq -r '.ports[] | select(.port == 4498) | .exclusiveOwner' <<<"$shared_scan")" "false"
proc signal "$scan_peer" "$scan_peer_start" TERM >/dev/null 2>&1 || true; wait "$scan_peer" 2>/dev/null || true
proc signal "$scan_server" "$scan_start" TERM >/dev/null 2>&1 || true; wait "$scan_server" 2>/dev/null || true

signal_bound_pid() {
  local pid=$1 expected_start=$2 signal_name=$3
  /usr/bin/python3 -I -S "$PR" signal "$pid" "$expected_start" "$signal_name"
}

atomic_signal_case() {
  local signal_name=$1 case_dir=$2 pid input_fd tmp start status residue
  local -a temps
  mkdir -p "$case_dir"
  unset SIGNAL_WRITE SIGNAL_WRITE_PID
  coproc SIGNAL_WRITE {
    exec /usr/bin/env --default-signal=HUP --default-signal=INT --default-signal=TERM \
      /usr/bin/python3 -I -S "$S/lib/statedir.py" write "$case_dir/value" >"$case_dir/out" 2>"$case_dir/err"
  }
  pid=$SIGNAL_WRITE_PID
  start=$(proc_start "$pid") || start=
  input_fd=${SIGNAL_WRITE[1]}
  tmp=
  for _ in {1..500}; do
    mapfile -t temps < <(find "$case_dir" -mindepth 1 -maxdepth 1 -type f -name '.value.*.tmp' -print)
    if [[ ${#temps[@]} -eq 1 ]]; then
      tmp=${temps[0]}
      break
    fi
    sleep 0.01
  done
  if [[ -z $tmp || -z $start ]]; then
    exec {input_fd}>&-
    wait "$pid" 2>/dev/null || true
    printf 'no-temp no-status no-temp-path'
    return
  fi
  if ! signal_bound_pid "$pid" "$start" "$signal_name"; then
    exec {input_fd}>&-
    wait "$pid" 2>/dev/null || true
    printf 'signal-failed no-status %s' "$tmp"
    return
  fi
  wait "$pid" 2>/dev/null
  status=$?
  exec {input_fd}>&-
  if [[ -e $tmp || -L $tmp ]]; then residue=present; else residue=absent; fi
  printf '%s %s %s' "$status" "$residue" "$tmp"
}

ATOMIC_SIGNAL="$T/atomic-signal"
for signal_case in HUP INT TERM; do
  signal_result=$(atomic_signal_case "$signal_case" "$ATOMIC_SIGNAL/$signal_case")
  case $signal_case in HUP) expected_status=129 ;; INT) expected_status=130 ;; TERM) expected_status=143 ;; esac
  is "atomic write exits with positive status and removes its exact temporary on $signal_case" \
    "${signal_result%% *} $(cut -d' ' -f2 <<< "$signal_result")" "$expected_status absent"
done

handled_signals_settled() {
  local pid=$1 expected_start=$2
  /usr/bin/python3 -I -S - "$pid" "$expected_start" <<'PY'
from pathlib import Path
import signal
import sys

pid_text, expected = sys.argv[1:]
if not pid_text.isdigit() or int(pid_text) <= 1 or not expected.isdigit():
    raise SystemExit(1)
pid = int(pid_text)

def starttime():
    try:
        fields = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b")", 1)[1].split()
    except (OSError, IndexError):
        return None
    return fields[19].decode() if len(fields) > 19 and fields[19].isdigit() else None

if starttime() != expected:
    raise SystemExit(1)
try:
    values = dict(line.split(":", 1) for line in Path(f"/proc/{pid}/status").read_text().splitlines() if ":" in line)
except OSError:
    raise SystemExit(1)
if starttime() != expected:
    raise SystemExit(1)
wanted = sum(1 << (int(signum) - 1) for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM))
blocked = int(values.get("SigBlk", "0"), 16)
ignored = int(values.get("SigIgn", "0"), 16)
raise SystemExit(0 if blocked & wanted == wanted and ignored & wanted == wanted else 1)
PY
}

held_lock_fds_match() {
  local pid=$1 expected_start=$2 manifest=$3
  /usr/bin/python3 -I -S - "$pid" "$expected_start" "$manifest" <<'PY'
import os
from pathlib import Path
import sys

pid_text, expected, manifest_path = sys.argv[1:]
if not pid_text.isdigit() or int(pid_text) <= 1 or not expected.isdigit():
    raise SystemExit(1)
pid = int(pid_text)

def starttime():
    try:
        fields = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b")", 1)[1].split()
    except (OSError, IndexError):
        return None
    return fields[19].decode() if len(fields) > 19 and fields[19].isdigit() else None

if starttime() != expected:
    raise SystemExit(1)
try:
    records = [line.split() for line in Path(manifest_path).read_text().splitlines()]
except OSError:
    raise SystemExit(1)
if len(records) < 3 or {record[0] for record in records} != {"dir", "lock", "keeper"}:
    raise SystemExit(1)
for label, fd_text, device_text, inode_text in records:
    if not fd_text.isdigit() or not device_text.isdigit() or not inode_text.isdigit():
        raise SystemExit(1)
    try:
        current = os.stat(f"/proc/{pid}/fd/{fd_text}")
    except OSError:
        raise SystemExit(1)
    if (current.st_dev, current.st_ino) != (int(device_text), int(inode_text)):
        raise SystemExit(1)
raise SystemExit(0 if starttime() == expected else 1)
PY
}

LOCK_SIGNAL="$ATOMIC_SIGNAL/lock-retention"
mkdir -p "$LOCK_SIGNAL"
cat > "$LOCK_SIGNAL/child.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$$" > "$1"
while [[ ! -e $2 ]]; do sleep 0.01; done
printf finished > "$3"
SH
chmod 700 "$LOCK_SIGNAL/child.sh"
/usr/bin/python3 -I -S "$S/lib/statedir.py" lock "$LOCK_SIGNAL/state" nowait .lock -- \
  "$LOCK_SIGNAL/child.sh" "$LOCK_SIGNAL/entered" "$LOCK_SIGNAL/release" "$LOCK_SIGNAL/finished" \
  >"$LOCK_SIGNAL/out" 2>"$LOCK_SIGNAL/err" &
lock_signal_pid=$!
lock_signal_start=$(proc_start "$lock_signal_pid") || lock_signal_start=
for _ in {1..500}; do [[ -s $LOCK_SIGNAL/entered ]] && break; sleep 0.01; done
lock_child_pid=$(cat "$LOCK_SIGNAL/entered" 2>/dev/null)
lock_child_start=
if [[ $lock_child_pid =~ ^[1-9][0-9]*$ && $lock_child_pid -gt 1 ]]; then
  lock_child_start=$(proc_start "$lock_child_pid") || lock_child_start=
fi
lock_signal_rc=1
if [[ -n $lock_signal_start && -n $lock_child_start ]]; then
  signal_bound_pid "$lock_signal_pid" "$lock_signal_start" TERM
  lock_signal_rc=$?
fi
lock_handler_state=unsettled
if [[ $lock_signal_rc -eq 0 ]]; then
  for _ in {1..500}; do
    if handled_signals_settled "$lock_signal_pid" "$lock_signal_start"; then
      lock_handler_state=settled
      break
    fi
    if ! /usr/bin/python3 -I -S "$PR" check "$lock_signal_pid" "$lock_signal_start"; then
      lock_handler_state=exited
      break
    fi
    sleep 0.01
  done
fi
if [[ -n $lock_child_start ]] \
    && /usr/bin/python3 -I -S "$PR" check "$lock_child_pid" "$lock_child_start" \
    && [[ ! -e $LOCK_SIGNAL/finished ]]; then
  lock_child_state=active
else
  lock_child_state=inactive
fi
/usr/bin/python3 -I -S "$S/lib/statedir.py" lock "$LOCK_SIGNAL/state" nowait .lock -- /usr/bin/true \
  >/dev/null 2>&1
lock_contended_rc=$?
: > "$LOCK_SIGNAL/release"
wait "$lock_signal_pid" 2>/dev/null
lock_first_rc=$?
for _ in {1..500}; do [[ -s $LOCK_SIGNAL/finished ]] && break; sleep 0.01; done
if [[ -s $LOCK_SIGNAL/finished ]]; then lock_finished=finished; else lock_finished=unfinished; fi
/usr/bin/python3 -I -S "$S/lib/statedir.py" lock "$LOCK_SIGNAL/state" nowait .lock -- /usr/bin/true \
  >/dev/null 2>&1
lock_reacquire_rc=$?
is "a signaled CLI lock retains every lock descriptor until its child finishes" \
  "$lock_signal_rc $lock_handler_state $lock_child_state $lock_contended_rc $lock_first_rc $lock_finished $lock_reacquire_rc" \
  "0 settled active 75 143 finished 0"

CONSTRUCTION_SIGNAL="$ATOMIC_SIGNAL/popen-construction"
mkdir -p "$CONSTRUCTION_SIGNAL"
cat > "$CONSTRUCTION_SIGNAL/send.py" <<'PY'
from pathlib import Path
import subprocess
import sys

python, proc, pid, start, result = sys.argv[1:]
completed = subprocess.run([python, "-I", "-S", proc, "signal", pid, start, "TERM"])
Path(result).write_text(str(completed.returncode))
PY
cat > "$CONSTRUCTION_SIGNAL/owner.py" <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time

(module_path, proc_path, state_root, child_path, entered, release, finished,
 identity_path, manifest_path, send_path, signal_result) = sys.argv[1:]
spec = importlib.util.spec_from_file_location("statedir_construction", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.install_signal_handlers()
while not Path(identity_path).exists():
    time.sleep(0.01)
expected_start = Path(identity_path).read_text()
real_acquire = module.acquire_lock
real_popen = subprocess.Popen

def capture_acquire(*args):
    held = real_acquire(*args)
    dirfd, lockfd, ledger = held
    records = []
    for label, fd in (("dir", dirfd), ("lock", lockfd)):
        current = os.fstat(fd)
        records.append(f"{label} {fd} {current.st_dev} {current.st_ino}")
    for fd in ledger.values():
        current = os.fstat(fd)
        records.append(f"keeper {fd} {current.st_dev} {current.st_ino}")
    Path(manifest_path).write_text("\n".join(records) + "\n")
    return held

def signal_before_return(argv, **kwargs):
    process = real_popen(argv, **kwargs)
    signaler = real_popen([
        sys.executable, "-I", "-S", send_path, sys.executable, proc_path,
        str(os.getpid()), expected_start, signal_result,
    ], close_fds=True)
    signaler.wait()
    return process

module.acquire_lock = capture_acquire
subprocess.Popen = signal_before_return
raise SystemExit(module.run_locked([
    state_root, "nowait", ".lock", "--", child_path, entered, release, finished,
], False))
PY
/usr/bin/python3 -I -S "$CONSTRUCTION_SIGNAL/owner.py" \
  "$S/lib/statedir.py" "$PR" "$CONSTRUCTION_SIGNAL/state" "$LOCK_SIGNAL/child.sh" \
  "$CONSTRUCTION_SIGNAL/entered" "$CONSTRUCTION_SIGNAL/release" "$CONSTRUCTION_SIGNAL/finished" \
  "$CONSTRUCTION_SIGNAL/identity" "$CONSTRUCTION_SIGNAL/manifest" "$CONSTRUCTION_SIGNAL/send.py" \
  "$CONSTRUCTION_SIGNAL/signal-result" >"$CONSTRUCTION_SIGNAL/out" 2>"$CONSTRUCTION_SIGNAL/err" &
construction_pid=$!
construction_start=$(proc_start "$construction_pid") || construction_start=
printf '%s' "$construction_start" > "$CONSTRUCTION_SIGNAL/identity"
for _ in {1..500}; do
  [[ -s $CONSTRUCTION_SIGNAL/entered && -s $CONSTRUCTION_SIGNAL/manifest \
      && -s $CONSTRUCTION_SIGNAL/signal-result ]] && break
  sleep 0.01
done
construction_signal_rc=$(cat "$CONSTRUCTION_SIGNAL/signal-result" 2>/dev/null)
construction_handler_state=unsettled
if [[ $construction_signal_rc == 0 && -n $construction_start ]]; then
  for _ in {1..500}; do
    if handled_signals_settled "$construction_pid" "$construction_start"; then
      construction_handler_state=settled
      break
    fi
    if ! /usr/bin/python3 -I -S "$PR" check "$construction_pid" "$construction_start"; then
      construction_handler_state=exited
      break
    fi
    sleep 0.01
  done
fi
construction_child_pid=$(cat "$CONSTRUCTION_SIGNAL/entered" 2>/dev/null)
construction_child_start=
if [[ $construction_child_pid =~ ^[1-9][0-9]*$ && $construction_child_pid -gt 1 ]]; then
  construction_child_start=$(proc_start "$construction_child_pid") || construction_child_start=
fi
if [[ -n $construction_child_start ]] \
    && /usr/bin/python3 -I -S "$PR" check "$construction_child_pid" "$construction_child_start" \
    && [[ ! -e $CONSTRUCTION_SIGNAL/finished ]]; then
  construction_child_state=active
else
  construction_child_state=inactive
fi
if [[ -n $construction_start ]] \
    && held_lock_fds_match "$construction_pid" "$construction_start" "$CONSTRUCTION_SIGNAL/manifest"; then
  construction_fds=held
else
  construction_fds=released
fi
/usr/bin/python3 -I -S "$S/lib/statedir.py" lock "$CONSTRUCTION_SIGNAL/state" nowait .lock -- /usr/bin/true \
  >/dev/null 2>&1
construction_contended_rc=$?
: > "$CONSTRUCTION_SIGNAL/release"
wait "$construction_pid" 2>/dev/null
construction_first_rc=$?
for _ in {1..500}; do [[ -s $CONSTRUCTION_SIGNAL/finished ]] && break; sleep 0.01; done
if [[ -s $CONSTRUCTION_SIGNAL/finished ]]; then construction_finished=finished; else construction_finished=unfinished; fi
/usr/bin/python3 -I -S "$S/lib/statedir.py" lock "$CONSTRUCTION_SIGNAL/state" nowait .lock -- /usr/bin/true \
  >/dev/null 2>&1
construction_reacquire_rc=$?
is "a construction-window signal keeps CLI lock ownership until the spawned child finishes" \
  "$construction_signal_rc $construction_handler_state $construction_child_state $construction_fds $construction_contended_rc $construction_first_rc $construction_finished $construction_reacquire_rc" \
  "0 settled active held 75 143 finished 0"

atomic_conformance=$(/usr/bin/python3 -I -S - "$S/lib/statedir.py" "$ATOMIC_SIGNAL/conformance" <<'PY'
import errno
import importlib.util
import os
from pathlib import Path
import signal
import sys
import traceback

module_path, root = sys.argv[1:]
root = Path(root)
root.mkdir()
handled = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)

class OsProxy:
    def __getattr__(self, name):
        return getattr(os, name)

def load(label):
    spec = importlib.util.spec_from_file_location(f"statedir_atomic_{label}", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.os = OsProxy()
    return module

def mask():
    return signal.pthread_sigmask(signal.SIG_BLOCK, set())

def kernel_start(pid):
    if not isinstance(pid, int) or pid <= 1:
        raise RuntimeError(f"refused unsafe pid {pid}")
    fields = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b")", 1)[1].split()
    if len(fields) <= 19 or not fields[19].isdigit():
        raise RuntimeError(f"pid {pid} has no kernel start time")
    return fields[19]

def signal_self(signum):
    pid = os.getpid()
    start = kernel_start(pid)
    if kernel_start(pid) != start:
        raise RuntimeError(f"pid {pid} changed before signal {signum}")
    os.kill(pid, signum)

def run_child(label, function):
    pid = os.fork()
    if pid == 0:
        try:
            function()
        except BaseException:
            traceback.print_exc()
            os._exit(1)
        os._exit(0)
    waited, status = os.waitpid(pid, 0)
    if waited != pid or status != 0:
        raise RuntimeError(f"{label} child failed with wait status {status}")
    print(label, flush=True)

before_handlers = {signum: signal.getsignal(signum) for signum in handled}
before_mask = mask()
module = load("neutral")
if ({signum: signal.getsignal(signum) for signum in handled} != before_handlers
        or mask() != before_mask):
    raise RuntimeError("import changed signal handlers or the signal mask")
print("import-handler-neutrality", flush=True)

module = load("open_error")
case = root / "open-error"
case.mkdir()
module.os.urandom = lambda size: b"\x12" * size
tmp = case / ".value.1212121212121212.tmp"
tmp.write_bytes(b"collision")
dirfd = os.open(case, os.O_RDONLY | os.O_DIRECTORY)
before_mask = mask()
try:
    module.atomic_write(dirfd, "value", b"new")
except FileExistsError as error:
    if error.errno != errno.EEXIST:
        raise
else:
    raise RuntimeError("an O_EXCL collision was accepted")
after_mask = mask()
os.close(dirfd)
if tmp.read_bytes() != b"collision" or case.joinpath("value").exists():
    raise RuntimeError("an O_EXCL collision received cleanup ownership")
print("exclusive-collision-ownership", flush=True)
if after_mask != before_mask:
    raise RuntimeError("an ordinary open error changed the local signal mask")
print("open-error-mask-restoration", flush=True)

def open_bookkeeping_case():
    module = load("open_bookkeeping")
    module.install_signal_handlers()
    case = root / "open-bookkeeping"
    case.mkdir()
    module.os.urandom = lambda size: b"\x23" * size
    tmp = case / ".value.2323232323232323.tmp"
    dirfd = os.open(case, os.O_RDONLY | os.O_DIRECTORY)
    real_open = module.os.open

    def open_then_signal(*args, **kwargs):
        fd = real_open(*args, **kwargs)
        signal_self(signal.SIGTERM)
        return fd

    module.os.open = open_then_signal
    try:
        try:
            module.atomic_write(dirfd, "value", b"new")
        except SystemExit as error:
            if error.code != 143:
                raise RuntimeError(f"wrong signal status {error.code}")
        else:
            raise RuntimeError("the blocked open signal did not exit")
    finally:
        os.close(dirfd)
    if tmp.exists() or case.joinpath("value").exists():
        raise RuntimeError("open-to-bookkeeping signal left state")

run_child("open-bookkeeping-delivery", open_bookkeeping_case)

def cleanup_signal_case():
    module = load("cleanup_signal")
    module.install_signal_handlers()
    case = root / "cleanup-signal"
    case.mkdir()
    module.os.urandom = lambda size: b"\x34" * size
    tmp = case / ".value.3434343434343434.tmp"
    dirfd = os.open(case, os.O_RDONLY | os.O_DIRECTORY)
    real_close = module.os.close
    close_calls = 0

    def close_then_signal(fd):
        nonlocal close_calls
        close_calls += 1
        signal_self(signal.SIGTERM)
        real_close(fd)

    def ordinary_error(_fd):
        raise RuntimeError("injected write failure")

    module.os.close = close_then_signal
    try:
        try:
            module.atomic_write(dirfd, "value", ordinary_error)
        except SystemExit as error:
            if error.code != 143:
                raise RuntimeError(f"wrong cleanup signal status {error.code}")
        else:
            raise RuntimeError("a cleanup signal preserved the ordinary error")
    finally:
        os.close(dirfd)
    if close_calls != 1 or tmp.exists() or case.joinpath("value").exists():
        raise RuntimeError("signal-safe cleanup leaked or closed its descriptor twice")

run_child("first-signal-during-cleanup", cleanup_signal_case)

def repeated_signal_case():
    module = load("repeated_signal")
    module.install_signal_handlers()
    try:
        signal_self(signal.SIGTERM)
    except SystemExit as error:
        if error.code != 143:
            raise RuntimeError(f"wrong first signal status {error.code}")
    else:
        raise RuntimeError("the first handled signal did not exit")
    for signum in handled:
        signal_self(signum)
    if not set(handled).issubset(mask()):
        raise RuntimeError("handled signals were not left blocked")
    if any(signal.getsignal(signum) != signal.SIG_IGN for signum in handled):
        raise RuntimeError("later handled signals were not ignored")

run_child("repeated-handled-signals", repeated_signal_case)

def post_rename_case():
    module = load("post_rename")
    module.install_signal_handlers()
    case = root / "post-rename"
    case.mkdir()
    module.os.urandom = lambda size: b"\x45" * size
    tmp_name = ".value.4545454545454545.tmp"
    tmp = case / tmp_name
    target = case / "value"
    dirfd = os.open(case, os.O_RDONLY | os.O_DIRECTORY)
    real_rename = module.os.rename

    def rename_then_collide_and_signal(*args, **kwargs):
        real_rename(*args, **kwargs)
        collisionfd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dirfd)
        try:
            os.write(collisionfd, b"collision")
        finally:
            os.close(collisionfd)
        signal_self(signal.SIGTERM)

    module.os.rename = rename_then_collide_and_signal
    try:
        try:
            module.atomic_write(dirfd, "value", b"new")
        except SystemExit as error:
            if error.code != 143:
                raise RuntimeError(f"wrong post-rename signal status {error.code}")
        else:
            raise RuntimeError("the post-rename signal did not exit")
    finally:
        os.close(dirfd)
    if target.read_bytes() != b"new" or tmp.read_bytes() != b"collision":
        raise RuntimeError("post-rename cleanup removed the target or a colliding temporary")
    tmp.unlink()

run_child("post-rename-collision", post_rename_case)
PY
); atomic_conformance_rc=$?

for conformance_case in \
  import-handler-neutrality exclusive-collision-ownership open-error-mask-restoration \
  open-bookkeeping-delivery first-signal-during-cleanup repeated-handled-signals \
  post-rename-collision; do
  if [[ $atomic_conformance_rc -eq 0 ]] && grep -qx "$conformance_case" <<< "$atomic_conformance"; then
    ok "atomic write conformance: $conformance_case"
  else
    bad "atomic write conformance: $conformance_case"
  fi
done

atomic_kill_case() {
  local case_dir=$1 pid input_fd tmp start residue cleaned
  local -a temps
  mkdir -p "$case_dir"
  unset SIGNAL_WRITE SIGNAL_WRITE_PID
  coproc SIGNAL_WRITE {
    exec /usr/bin/env --default-signal=HUP --default-signal=INT --default-signal=TERM \
      /usr/bin/python3 -I -S "$S/lib/statedir.py" write "$case_dir/value" >"$case_dir/out" 2>"$case_dir/err"
  }
  pid=$SIGNAL_WRITE_PID
  start=$(proc_start "$pid") || start=
  input_fd=${SIGNAL_WRITE[1]}
  tmp=
  for _ in {1..500}; do
    mapfile -t temps < <(find "$case_dir" -mindepth 1 -maxdepth 1 -type f -name '.value.*.tmp' -print)
    if [[ ${#temps[@]} -eq 1 ]]; then
      tmp=${temps[0]}
      break
    fi
    sleep 0.01
  done
  if [[ -z $tmp || -z $start ]]; then
    exec {input_fd}>&-
    wait "$pid" 2>/dev/null || true
    printf 'no-temp no-cleanup'
    return
  fi
  if ! signal_bound_pid "$pid" "$start" KILL; then
    exec {input_fd}>&-
    wait "$pid" 2>/dev/null || true
    printf 'signal-failed no-cleanup'
    return
  fi
  wait "$pid" 2>/dev/null || true
  exec {input_fd}>&-
  if [[ -e $tmp || -L $tmp ]]; then residue=present; else residue=absent; fi
  rm -f -- "$tmp"
  if [[ -e $tmp || -L $tmp ]]; then cleaned=present; else cleaned=removed; fi
  printf '%s %s' "$residue" "$cleaned"
}

kill_result=$(atomic_kill_case "$ATOMIC_SIGNAL/KILL")
is "SIGKILL leaves its exact atomic temporary outside catchable cleanup" "$kill_result" "present removed"

# ---- statedir.py: a short write is completed, never reported as done --------
SW=$(mktemp -d); /usr/bin/python3 - "$SW" "$S/lib/statedir.py" <<'PY'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("sd", sys.argv[2]); sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
real = os.write
os.write = lambda fd, data: real(fd, bytes(data)[:5])   # the kernel takes five bytes at a time
dirfd = sd.open_dir(sys.argv[1], create=True)
sd.append_one(dirfd, "3000.jsonl", b'{"t":1,"a":1}\n', 100, 1 << 20)
sd.append_one(dirfd, "3000.jsonl", b'{"t":2,"a":2}\n', 100, 1 << 20)
sd.atomic_write(dirfd, "whole", b"0123456789" * 3)
PY
is "append completes short writes" "$(cat "$SW/3000.jsonl" | tr '\n' ' ')" '{"t":1,"a":1} {"t":2,"a":2} '
is "atomic writes complete short writes" "$(wc -c < "$SW/whole")" "30"
rm -rf "$SW"

DR="$T/digest-race"; mkdir -p "$DR"; printf old > "$DR/cloudflared"
old_sum=$(sha256sum "$DR/cloudflared" | cut -d' ' -f1)
/usr/bin/python3 - "$DR" "$S/lib/statedir.py" "$old_sum" <<'PY'
import importlib.util, os, sys
root, path, expected = sys.argv[1:]
spec = importlib.util.spec_from_file_location("sd", path)
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
real = sd.rename_noreplace
swapped = False
def replace_before_quarantine(dirfd, old, new):
    global swapped
    if old == "cloudflared" and not swapped:
        swapped = True
        os.rename("cloudflared", "old-cloudflared", src_dir_fd=dirfd, dst_dir_fd=dirfd)
        fd = os.open("cloudflared", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dirfd)
        os.write(fd, b"replacement"); os.close(fd)
    return real(dirfd, old, new)
sd.rename_noreplace = replace_before_quarantine
try:
    sd.cmd_remove_digest([root, "cloudflared", expected, "1024"])
except sd.Refused:
    pass
else:
    raise SystemExit("replacement race was accepted")
PY
is "digest removal preserves a replacement inode" "$(cat "$DR/cloudflared")" "replacement"
printf 'existing' > "$DR/no-replace"
printf 'new' | state create "$DR/no-replace" >/dev/null 2>&1; rc=$?
is "atomic create never replaces a concurrent target" "$rc $(cat "$DR/no-replace")" "1 existing"

# ---- portless-setup.sh status: installed means runnable ---------------------
mkdir -p "$T/pl"; printf '#!/bin/sh\n' > "$T/pl/portless"; chmod 777 "$T/pl/portless"
rep=$(PATH="$T/pl:$PATH" PORTAL_METRICS_DIR=$T/plm "$S/portless-setup.sh" status)
is "a portless the trusted resolver refuses is not installed" "$(jq -c .checks.installed <<<"$rep")" "false"
jq -r '.remaining[0]' <<<"$rep" | grep -q "is not a trusted executable" && ok "and the report says how to fix it" || bad "no fix hint: $(jq -c .remaining <<<"$rep")"
# A cloudflared install shadowed by an untrusted one earlier on PATH is refused,
# not silently installed where provider_bin will never find it.
SH="$T/shadow"; mkdir -p "$SH"; printf '#!/bin/sh\n' > "$SH/cloudflared"; chmod 777 "$SH/cloudflared"
is "install refuses when an untrusted cloudflared shadows the target" "$(PATH="$SH:$PATH" "$S/provider-install.sh" cloudflared 2>/dev/null | jq -r '.error // empty' | grep -c 'shadows the install')" "1"
# A setup step carrying a command arrives split: title for the card, command
# for its copy button. The engine is stubbed; only the split is exercised.
FB="$T/fakebin"; mkdir -p "$FB"; OLD_SD="$SCRIPT_DIR"
printf '#!/bin/bash\necho %s\n' "'{\"ok\":true,\"remaining\":[\"Do the thing\\u001fdo --it --now\"]}'" > "$FB/portless-setup.sh"
chmod +x "$FB/portless-setup.sh"; SCRIPT_DIR="$FB"
is "setup splits a command-carrying step" "$(cmd_setup portless 2>/dev/null | jq -c '{hint,copy}')" '{"hint":"Do the thing","copy":"do --it --now"}'
printf '#!/bin/bash\necho %s\n' "'{\"ok\":true,\"remaining\":[\"Just words\"]}'" > "$FB/portless-setup.sh"
is "setup passes a plain step through with no copy" "$(cmd_setup portless 2>/dev/null | jq -c .)" '{"ok":true,"hint":"Just words"}'
printf '#!/bin/bash\necho %s\n' "'{\"ok\":true,\"remaining\":[]}'" > "$FB/portless-setup.sh"
is "setup with nothing remaining reports bare ok" "$(cmd_setup portless 2>/dev/null | jq -c .)" '{"ok":true}'
SCRIPT_DIR="$OLD_SD"

# ---- portless-setup.sh untrust: a store that keeps the CA stays on record ----
NO_TRUST="$T/untrust-empty"; mkdir -p "$NO_TRUST/home"
no_trust=$(HOME="$NO_TRUST/home" XDG_CONFIG_HOME="$NO_TRUST/home/.config" \
  PORTAL_STATE_DIR="$NO_TRUST/runtime" PORTAL_METRICS_DIR="$NO_TRUST/state" \
  PORTLESS_STATE_DIR="$NO_TRUST/portless" "$S/portless-setup.sh" untrust)
is "untrust treats an absent ledger as already cleared" \
  "$no_trust $(test ! -e "$NO_TRUST/state" && echo state-absent || echo state-created)" \
  '{"ok":true} state-absent'
if command -v certutil >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  U=$(mktemp -d); mkdir -p "$U/nss" "$U/portless"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$U/ca.key" -out "$U/portless/ca.pem" \
    -days 1 -subj "/CN=portless Local CA" >/dev/null 2>&1
  certutil -d "sql:$U/nss" -N --empty-password >/dev/null 2>&1
  # The import itself, through the setup script's own function, and its record.
  PORTAL_METRICS_DIR=$U PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$U"'/nss"' && ok "trust_store imports the CA" || bad "trust_store failed"
  certutil -d "sql:$U/nss" -L -n "portless Local CA" >/dev/null 2>&1 && ok "and the CA is in the store" || bad "the CA is not in the store"
  is "and the store is on record with a fingerprint" "$(cut -f1 "$U/trusted-stores"); $(cut -f2 "$U/trusted-stores" | grep -qE '^[0-9A-F]{64}$' && echo fp-ok)" "$U/nss; fp-ok"
  mkdir -p "$U/fd-import/nss"
  PORTAL_METRICS_DIR=$U/fd-import PORTLESS_STATE_DIR=$U/portless FD_PROOF=$U/fd-proof bash -c '
    set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1
    certutil() {
      local prev="" arg
      for arg in "$@"; do
        if [[ $prev == -i ]]; then
          printf "%s" "$arg" > "$FD_PROOF.path"
          cat "$arg" > "$FD_PROOF.pem"
        fi
        prev=$arg
      done
      return 0
    }
    trust_store "'"$U"'/fd-import/nss"
  ' >/dev/null 2>&1
  [[ $(cat "$U/fd-proof.path") =~ ^/proc/self/fd/[0-9]+$ ]] \
    && ok "browser trust imports through a held descriptor" || bad "browser trust reopened a pathname"
  printf '%s' "$(cat "$U/portless/ca.pem")" > "$U/validated-ca.pem"
  cmp -s "$U/validated-ca.pem" "$U/fd-proof.pem" && ok "and certutil reads the validated CA bytes" || bad "certutil read different CA bytes"
  mkdir -p "$U/rollback/nss" "$U/rollback-bin"
  cat > "$U/rollback-bin/certutil" <<'SH'
#!/bin/sh
case " $* " in
  *" -A "*) : > "$TRUST_ROLLBACK_MARK";;
  *" -L "*) [ ! -e "$TRUST_ROLLBACK_MARK" ];;
  *) exit 0;;
esac
SH
  chmod 755 "$U/rollback-bin/certutil"
  TRUST_ROLLBACK_MARK="$U/rollback/imported" PATH="$U/rollback-bin:$PATH" PORTAL_METRICS_DIR="$U/rollback" PORTLESS_STATE_DIR="$U/portless" bash -c '
    set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1
    state_remove() { return 1; }
    trust_store "'"$U"'/rollback/nss"
  ' >/dev/null 2>&1
  [[ -e $U/rollback/imported ]] && ok "rollback fixture reaches certificate import" || bad "rollback fixture failed before import"
  [[ -e $U/rollback/trusted-stores ]] && ok "a failed trust rollback keeps its ownership record" || bad "a failed trust rollback lost its ownership record"
  cp "$U/trusted-stores" "$U/trusted.before-error"; mkdir -p "$U/failbin"
  printf '#!/bin/sh\nexit 1\n' > "$U/failbin/certutil"; chmod 755 "$U/failbin/certutil"
  out=$(PATH="$U/failbin:$PATH" PORTAL_METRICS_DIR=$U "$S/portless-setup.sh" untrust)
  is "untrust retains a store when verification fails" "$(jq -c .ok <<<"$out") $(test -e "$U/trusted-stores" && echo kept || echo lost)" "false kept"
  cp "$U/trusted.before-error" "$U/trusted-stores"
  # A trust whose record cannot be written is undone: the store ends without the CA.
  mkdir -p "$U/rb/nss"; certutil -d "sql:$U/rb/nss" -N --empty-password >/dev/null 2>&1; mkdir -p "$U/rb/trusted-stores"
  PORTAL_METRICS_DIR=$U/rb PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$U"'/rb/nss"' && bad "trust_store reported success without a record" || ok "trust_store fails when the record cannot be written"
  certutil -d "sql:$U/rb/nss" -L -n "portless Local CA" >/dev/null 2>&1 && bad "and left the CA trusted" || ok "and undoes the import"
  [[ -e $U/rb/ca-import.pem ]] && bad "the import file was left behind" || ok "and leaves no import file behind"
  # A record that exists but cannot be read is not treated as empty.
  cp "$U/trusted-stores" "$U/keep"; head -c 70000 /dev/zero | tr '\0' x > "$U/trusted-stores"
  is "untrust refuses an unreadable record" "$(PORTAL_METRICS_DIR=$U "$S/portless-setup.sh" untrust | jq -c .ok)" "false"
  [[ -e $U/trusted-stores ]] && ok "and keeps it" || bad "and deleted it"
  mv "$U/keep" "$U/trusted-stores"
  chmod 500 "$U/nss"
  is "untrust reports a store it could not clear" "$(PORTAL_METRICS_DIR=$U "$S/portless-setup.sh" untrust | jq -c '[.ok, (.remaining|length)]')" "[false,1]"
  chmod 700 "$U/nss"
  is "untrust succeeds once the store is writable" "$(PORTAL_METRICS_DIR=$U "$S/portless-setup.sh" untrust | jq -c .ok)" "true"
  certutil -d "sql:$U/nss" -L -n "portless Local CA" >/dev/null 2>&1 && bad "the CA is still in the store" || ok "and the CA is gone from the store"
  # A certificate that replaced Portal's under the same name is not deleted.
  V=$(mktemp -d); mkdir -p "$V/nss"; certutil -d "sql:$V/nss" -N --empty-password >/dev/null 2>&1
  PORTAL_METRICS_DIR=$V PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$V"'/nss"' >/dev/null
  valid_ledger=$(cat "$V/trusted-stores")
  printf '%s\t%s\n' "$V/nss" NOT-A-FINGERPRINT > "$V/trusted-stores"
  out=$(PORTAL_METRICS_DIR=$V "$S/portless-setup.sh" untrust)
  malformed_state=$(certutil -d "sql:$V/nss" -L -n "portless Local CA" >/dev/null 2>&1 && echo cert-kept || echo cert-lost)
  is "untrust refuses a malformed trust fingerprint before changing the store" \
    "$(jq -r .ok <<<"$out") $malformed_state $(test -e "$V/trusted-stores" && echo ledger-kept || echo ledger-lost)" \
    "false cert-kept ledger-kept"
  printf '%s\n' "$valid_ledger" > "$V/trusted-stores"
  # replace the cert under the same nickname with a different self-signed CA
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$V/k.pem" -out "$V/other.pem" -days 1 -subj "/CN=portless Local CA" >/dev/null 2>&1
  certutil -d "sql:$V/nss" -D -n "portless Local CA" >/dev/null 2>&1
  certutil -d "sql:$V/nss" -A -t "C,," -n "portless Local CA" -i "$V/other.pem" >/dev/null 2>&1
  printf '%s\n' "$V/nss" > "$V/trusted-stores"
  out=$(PORTAL_METRICS_DIR=$V "$S/portless-setup.sh" untrust)
  missing_state=$(certutil -d "sql:$V/nss" -L -n "portless Local CA" >/dev/null 2>&1 && echo cert-kept || echo cert-lost)
  is "untrust refuses a missing trust fingerprint before changing the store" \
    "$(jq -r .ok <<<"$out") $missing_state $(test -e "$V/trusted-stores" && echo ledger-kept || echo ledger-lost)" \
    "false cert-kept ledger-kept"
  certutil -d "sql:$V/nss" -D -n "portless Local CA" >/dev/null 2>&1 || true
  certutil -d "sql:$V/nss" -A -t "C,," -n "portless Local CA" -i "$V/other.pem" >/dev/null 2>&1
  printf '%s\n' "$valid_ledger" > "$V/trusted-stores"
  out=$(PORTAL_METRICS_DIR=$V "$S/portless-setup.sh" untrust)
  is "untrust reports success when the recorded cert is gone" "$(jq -c .ok <<<"$out")" "true"
  certutil -d "sql:$V/nss" -L -n "portless Local CA" >/dev/null 2>&1 && ok "and leaves a replacement cert under the same name in place" || bad "untrust deleted a cert Portal did not import"
  rm -rf "$V"
  # A ledger that exists but cannot be read is not an empty one: no import may
  # overwrite it and orphan every earlier record.
  W=$(mktemp -d); mkdir -p "$W/nss" "$W/nss2"
  certutil -d "sql:$W/nss" -N --empty-password >/dev/null 2>&1
  certutil -d "sql:$W/nss2" -N --empty-password >/dev/null 2>&1
  PORTAL_METRICS_DIR=$W PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$W"'/nss"' >/dev/null
  valid_ledger=$(cat "$W/trusted-stores")
  printf '%s\t%s\n' "$W/nss" NOT-A-FINGERPRINT > "$W/trusted-stores"
  PORTAL_METRICS_DIR=$W PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$W"'/nss2"' >/dev/null 2>&1; rc=$?
  certutil -d "sql:$W/nss2" -L -n "portless Local CA" >/dev/null 2>&1 && malformed_import=trusted || malformed_import=clean
  is "trust_store refuses a malformed ledger before importing" "$rc $malformed_import" "1 clean"
  certutil -d "sql:$W/nss2" -D -n "portless Local CA" >/dev/null 2>&1 || true
  printf '%s\n' "$valid_ledger" > "$W/trusted-stores"
  chmod 777 "$W/trusted-stores"
  PORTAL_METRICS_DIR=$W PORTLESS_STATE_DIR=$U/portless bash -c 'set -- status; source "'"$S"'/portless-setup.sh" >/dev/null 2>&1; trust_store "'"$W"'/nss2"' >/dev/null 2>&1 \
    && bad "trust_store imported over an unreadable ledger" || ok "trust_store refuses when the ledger cannot be read"
  is "and the earlier record survives" "$(wc -l < "$W/trusted-stores")" "1"
  chmod 700 "$W/trusted-stores"; rm -rf "$W"
  rm -rf "$U"
else
  ok "untrust checks skipped (no certutil or openssl)"
fi

# ---- metrics.sh --------------------------------------------------------------
export PORTAL_METRICS_DIR="$T/metrics"
M="$S/metrics.sh"
is "watched starts empty" "$("$M" watched)" '{"ok":true,"ports":[]}'
"$M" watch 3000 >/dev/null; "$M" watch 5173 >/dev/null
is "watch appends and dedups" "$("$M" watch 3000 | jq -c .ports)" '[3000,5173]'
printf '{"a":1}' > "$PORTAL_METRICS_DIR/watched.json"
is "a non-array watched file reads as empty" "$("$M" watched | jq -c .ports)" '[]'
printf '[1]\n[2]\n' > "$PORTAL_METRICS_DIR/watched.json"
is "a multi-document watched file reads its first array" "$("$M" watched | jq -c .ports)" '[1]'
is "watch rejects a bad port" "$("$M" watch 70000 | jq -r .error)" "invalid port"
"$M" append-batch '{"3000":{"t":1,"conns":2},"junk":{"t":1}}' >/dev/null
is "append-batch writes one line per valid port" "$(wc -l < "$PORTAL_METRICS_DIR/metrics/3000.jsonl")" "1"
[[ -e $PORTAL_METRICS_DIR/metrics/junk.jsonl ]] && bad "append-batch wrote an invalid port" || ok "append-batch skips an invalid port"
printf '{"t":2,"con' >> "$PORTAL_METRICS_DIR/metrics/3000.jsonl"   # a torn line
is "read survives a torn last line" "$("$M" read 3000 | jq -c '.samples|length')" "1"
ln -s /etc/hostname "$PORTAL_METRICS_DIR/metrics/5000.jsonl"
is "read refuses a symlinked sample file" "$("$M" read 5000 | jq -c '.samples|length')" "0"
"$M" append-batch '{"5000":{"t":1}}' >/dev/null
[[ ! -L $PORTAL_METRICS_DIR/metrics/5000.jsonl && -f $PORTAL_METRICS_DIR/metrics/5000.jsonl && $(wc -c < /etc/hostname) == "$before" ]] && ok "append replaces a planted link with a fresh file and never follows it" || bad "append followed or kept a symlinked path"
mkfifo "$PORTAL_METRICS_DIR/metrics/5001.jsonl"
is "read of a planted FIFO returns at once, empty" "$(timeout 5 "$M" read 5001 | jq -c '.samples|length')" "0"
"$M" append-batch '{"5001":{"t":1}}' >/dev/null; [[ -f $PORTAL_METRICS_DIR/metrics/5001.jsonl && ! -p $PORTAL_METRICS_DIR/metrics/5001.jsonl ]] && ok "append replaces a planted FIFO with a fresh file" || bad "append left or blocked on a FIFO"
big=$(mktemp -p "$PORTAL_METRICS_DIR/metrics"); head -c 9000000 /dev/zero > "$big"; mv "$big" "$PORTAL_METRICS_DIR/metrics/5002.jsonl"
is "read refuses a file past the cap" "$(timeout 5 "$M" read 5002 | jq -c '.samples|length')" "0"
# 19300 x ~130 B is past MAX_BYTES, so the append trims to MAX_LINES.
yes '{"t":1756700000,"conns":0,"cpuPct":0,"rssKb":73000,"latMs":12,"httpCode":200,"pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' | head -n 19300 > "$PORTAL_METRICS_DIR/metrics/4000.jsonl"
"$M" append-batch '{"4000":{"t":2}}' >/dev/null
lines=$(wc -l < "$PORTAL_METRICS_DIR/metrics/4000.jsonl"); bytes=$(wc -c < "$PORTAL_METRICS_DIR/metrics/4000.jsonl")
(( lines > 0 && lines <= 17280 && bytes <= 2097152 )) && ok "append-batch trims to what fits under the cap ($lines lines, $bytes bytes)" || bad "trim left $lines lines, $bytes bytes"
"$M" unwatch 3000 >/dev/null
[[ -e $PORTAL_METRICS_DIR/metrics/3000.jsonl ]] && bad "unwatch left the metric file" || ok "unwatch deletes the metric file"
is "state files are private" "$(stat -c %a "$PORTAL_METRICS_DIR/metrics/4000.jsonl")" "600"
exec 6>"$PORTAL_METRICS_DIR/.metrics.lock"; flock -x 6
locked_append=$(timeout 2 "$M" append-batch '{"6000":{"t":1}}')
exec 6>&-
is "metric append fails fast behind a watched-state update" "$(jq -c .ok <<<"$locked_append") $(test -e "$PORTAL_METRICS_DIR/metrics/6000.jsonl" && echo wrote || echo clean)" "false clean"

RB="$T/review"; mkdir -p "$RB/lock" "$RB/append" "$RB/portless" "$RB/cli" "$RB/bin" "$RB/fake"
printf 'keep' > "$RB/victim"; ln -s "$RB/victim" "$RB/lock/.lifecycle.lock"
state lock "$RB/lock" nowait .lifecycle.lock -- /usr/bin/true >/dev/null 2>&1; rc=$?
is "a lifecycle lock symlink is refused" "$rc $(cat "$RB/victim")" "1 keep"
rm "$RB/lock/.lifecycle.lock"
is "a safe lifecycle lock runs its command" "$(state lock "$RB/lock" nowait .lifecycle.lock -- /usr/bin/printf ran 2>/dev/null)" "ran"
is "an ordinary lock keeps its stable lock file" "$(test -f "$RB/lock/.lifecycle.lock" && echo kept || echo lost)" "kept"

LOCK_CLEAN="$RB/lock-clean"; mkdir -p "$LOCK_CLEAN/foreign"; printf keep > "$LOCK_CLEAN/foreign/keep"
state lock-clean "$LOCK_CLEAN/success" nowait .lock -- /usr/bin/true >/dev/null 2>&1; clean_success_rc=$?
state lock-clean "$LOCK_CLEAN/failure" nowait .lock -- /usr/bin/false >/dev/null 2>&1; clean_failure_rc=$?
state lock-clean "$LOCK_CLEAN/foreign" nowait .lock -- /usr/bin/true >/dev/null 2>&1; clean_foreign_rc=$?
is "lock-clean removes its empty root only after child success" \
  "$clean_success_rc $(test -e "$LOCK_CLEAN/success" && echo present || echo absent)" "0 absent"
is "lock-clean keeps its lock and root after child failure" \
  "$clean_failure_rc $(test -f "$LOCK_CLEAN/failure/.lock" && echo kept || echo lost)" "1 kept"
is "lock-clean removes only its lock from a nonempty root" \
  "$clean_foreign_rc $(test -e "$LOCK_CLEAN/foreign/.lock" && echo lock || echo no-lock) $(cat "$LOCK_CLEAN/foreign/keep")" \
  "0 no-lock keep"
mkdir -p "$LOCK_CLEAN/kept" "$LOCK_CLEAN/ordered/child"
kept_before=$(stat -c '%d:%i' "$LOCK_CLEAN/kept")
state lock-clean "$LOCK_CLEAN/kept" nowait .lock --keep-existing-root -- /usr/bin/true >/dev/null 2>&1; kept_rc=$?
kept_after=$(stat -c '%d:%i' "$LOCK_CLEAN/kept" 2>/dev/null || echo absent)
state lock-clean "$LOCK_CLEAN/created" nowait .lock --keep-existing-root -- /usr/bin/true >/dev/null 2>&1; kept_created_rc=$?
state lock-clean "$LOCK_CLEAN/ordered/child" nowait .lock --keep-existing-root --prune-to "$LOCK_CLEAN/ordered" -- /usr/bin/true >/dev/null 2>&1; ordered_rc=$?
state lock-clean "$LOCK_CLEAN/reversed" nowait .lock --prune-to "$LOCK_CLEAN" --keep-existing-root -- \
  /usr/bin/touch "$LOCK_CLEAN/reversed-entered" >/dev/null 2>&1; reversed_rc=$?
is "lock-clean keeps only pre-existing roots when the fixed-order option requests it" \
  "$kept_rc $kept_after $kept_created_rc $(test -e "$LOCK_CLEAN/created" && echo present || echo absent)" \
  "0 $kept_before 0 absent"
is "lock-clean accepts keep-before-prune and rejects reverse option order before effects" \
  "$ordered_rc $(test -d "$LOCK_CLEAN/ordered/child" && echo kept || echo lost) $reversed_rc $(test -e "$LOCK_CLEAN/reversed-entered" && echo entered || echo clean)" \
  "0 kept 1 clean"
exec 9<"$LOCK_CLEAN"; flock -x 9
timeout 2 /usr/bin/python3 -I -S "$S/lib/statedir.py" lock "$LOCK_CLEAN/namespace" nowait .lock -- \
  /usr/bin/touch "$LOCK_CLEAN/entered" >/dev/null 2>&1; namespace_rc=$?
exec 9>&-
is "a nowait lock fails fast behind root namespace cleanup" \
  "$namespace_rc $(test -e "$LOCK_CLEAN/entered" && echo entered || echo clean)" "75 clean"
state lock-clean "$LOCK_CLEAN/not-ancestor" nowait .lock --prune-to "$LOCK_CLEAN/other" -- \
  /usr/bin/touch "$LOCK_CLEAN/not-ancestor-entered" >/dev/null 2>&1; nonancestor_rc=$?
state lock-clean "$LOCK_CLEAN/equal" nowait .lock --prune-to "$LOCK_CLEAN/equal" -- \
  /usr/bin/touch "$LOCK_CLEAN/equal-entered" >/dev/null 2>&1; equal_rc=$?
state lock-clean "$LOCK_CLEAN/parent" nowait .lock --prune-to "$LOCK_CLEAN/parent/child" -- \
  /usr/bin/touch "$LOCK_CLEAN/descendant-entered" >/dev/null 2>&1; descendant_rc=$?
is "lock-clean rejects invalid prune boundaries before effects" \
  "$nonancestor_rc $equal_rc $descendant_rc $(find "$LOCK_CLEAN" -name '*-entered' -o -name 'not-ancestor' -o -name equal -o -name parent | wc -l)" \
  "1 1 1 0"

/usr/bin/python3 -I -S - "$S/lib/statedir.py" "$RB/directory-publication" <<'PY'
import errno
import importlib.util
import os
from pathlib import Path
import signal
import stat
import sys

module_path, case = sys.argv[1:]
case = Path(case)
case.mkdir()

class OsProxy:
    def __getattr__(self, name):
        return getattr(os, name)

def load(name):
    spec = importlib.util.spec_from_file_location(f"statedir_{name}", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.os = OsProxy()
    return module

def identity(value):
    st = os.stat(value, follow_symlinks=False) if isinstance(value, Path) else os.fstat(value)
    return st.st_dev, st.st_ino

def open_fds():
    result = set()
    for name in os.listdir("/proc/self/fd"):
        try:
            os.fstat(int(name))
        except OSError:
            continue
        result.add(int(name))
    return result

def assert_closed(fd):
    try:
        os.fstat(fd)
    except OSError as error:
        if error.errno == errno.EBADF:
            return
    raise RuntimeError(f"descriptor {fd} remained open")

def close_ledger(module, ledger):
    keepers = list(ledger.values())
    module.close_creation_ledger(ledger)
    for keeper in keepers:
        assert_closed(keeper)

module = load("direct")
parent = case / "direct"
parent.mkdir()
real_urandom = module.os.urandom
random_sizes = []

def record_random(size):
    random_sizes.append(size)
    return real_urandom(size)

module.os.urandom = record_random
before = open_fds()
fd = module.open_dir(str(parent / "target"), create=True)
direct_identity = identity(fd)
if random_sizes != [16] or open_fds() - before != {fd}:
    raise RuntimeError("open_dir without a ledger retained a keeper")
os.close(fd)
if open_fds() != before or identity(parent / "target") != direct_identity:
    raise RuntimeError("open_dir without a ledger leaked a descriptor")

module = load("collision")
parent = case / "collision"
parent.mkdir()
real_mkdir = module.os.mkdir
real_open = module.os.open
real_rmdir = module.os.rmdir
seen = {"name": None, "opened": [], "removed": []}

def collide_once(name, mode=0o777, *, dir_fd=None):
    if seen["name"] is None:
        real_mkdir(name, mode, dir_fd=dir_fd)
        collisionfd = real_open(name, module.DIR_FLAGS, dir_fd=dir_fd)
        try:
            markerfd = real_open("keep", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=collisionfd)
            os.close(markerfd)
        finally:
            os.close(collisionfd)
        seen["name"] = name
        raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), name)
    return real_mkdir(name, mode, dir_fd=dir_fd)

def record_open(name, *args, **kwargs):
    seen["opened"].append(name)
    return real_open(name, *args, **kwargs)

def record_rmdir(name, *args, **kwargs):
    seen["removed"].append(name)
    return real_rmdir(name, *args, **kwargs)

module.os.mkdir = collide_once
module.os.open = record_open
module.os.rmdir = record_rmdir
ledger = {}
fd = module.open_dir(str(parent / "target"), create=True, created=ledger)
os.close(fd)
collision = parent / seen["name"]
if not collision.joinpath("keep").is_file() or seen["name"] in seen["opened"] or seen["name"] in seen["removed"]:
    raise RuntimeError("a colliding private name was opened or removed")
if len(ledger) != 1:
    raise RuntimeError("the published target did not enter the ledger")
close_ledger(module, ledger)

module = load("bounded_collision")
parent = case / "bounded-collision"
parent.mkdir()
attempts = []
opened = []
real_open = module.os.open

def collide_always(name, mode=0o777, *, dir_fd=None):
    attempts.append(name)
    raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), name)

def observe_open(name, *args, **kwargs):
    opened.append(name)
    return real_open(name, *args, **kwargs)

module.os.mkdir = collide_always
module.os.open = observe_open
before = open_fds()
try:
    module.open_dir(str(parent / "target"), create=True, created={})
except module.Refused:
    pass
else:
    raise RuntimeError("private-name collisions were not bounded")
if len(attempts) != 16 or any(name in opened for name in attempts) or open_fds() != before:
    raise RuntimeError("private-name collision handling opened a name or leaked a descriptor")

module = load("publication_eexist")
parent = case / "publication-eexist"
parent.mkdir()
target = parent / "target"
target.mkdir()
target_identity = identity(target)
real_open = module.os.open
first_target_open = True

def miss_existing_once(name, *args, **kwargs):
    global first_target_open
    if name == "target" and first_target_open:
        first_target_open = False
        raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), name)
    return real_open(name, *args, **kwargs)

module.os.open = miss_existing_once
ledger = {}
before = open_fds()
fd = module.open_dir(str(target), create=True, created=ledger)
if identity(fd) != target_identity or ledger:
    raise RuntimeError("a publication winner received creation authority")
os.close(fd)
if sorted(entry.name for entry in parent.iterdir()) != ["target"] or open_fds() != before:
    raise RuntimeError("publication EEXIST left a private entry or descriptor")

module = load("prebind")
parent = case / "prebind"
parent.mkdir()
real_mkdir = module.os.mkdir
real_open = module.os.open
real_rmdir = module.os.rmdir
state = {"private": None, "removed": []}

def remember_private(name, mode=0o777, *, dir_fd=None):
    result = real_mkdir(name, mode, dir_fd=dir_fd)
    state["private"] = name
    return result

def replace_before_bind(name, *args, **kwargs):
    if name == state["private"]:
        dir_fd = kwargs["dir_fd"]
        real_rmdir(name, dir_fd=dir_fd)
        real_mkdir(name, 0o700, dir_fd=dir_fd)
        replacementfd = real_open(name, module.DIR_FLAGS, dir_fd=dir_fd)
        try:
            markerfd = real_open("replacement", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=replacementfd)
            os.close(markerfd)
        finally:
            os.close(replacementfd)
        raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), name)
    return real_open(name, *args, **kwargs)

def observe_rmdir(name, *args, **kwargs):
    state["removed"].append(name)
    return real_rmdir(name, *args, **kwargs)

module.os.mkdir = remember_private
module.os.open = replace_before_bind
module.os.rmdir = observe_rmdir
before_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
before = open_fds()
ledger = {}
try:
    module.open_dir(str(parent / "target"), create=True, created=ledger)
except module.Refused:
    pass
else:
    raise RuntimeError("an unbound private directory was accepted")
after_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
replacement = parent / state["private"] / "replacement"
if not replacement.is_file() or state["private"] in state["removed"] or ledger or open_fds() != before:
    raise RuntimeError("the accepted same-UID pre-bind limit removed or recorded an unbound replacement")
if after_mask != before_mask:
    raise RuntimeError("an ordinary pre-bind error changed the signal mask")

module = load("postbind")
parent = case / "postbind"
parent.mkdir()
target = parent / "target"
moved = parent / "published"
real_rename = module.rename_noreplace
replacement_identity = None

def replace_after_publish(dirfd, old, new):
    global replacement_identity
    real_rename(dirfd, old, new)
    os.rename(new, moved.name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
    os.mkdir(new, 0o700, dir_fd=dirfd)
    replacement_identity = identity(target)

module.rename_noreplace = replace_after_publish
before = open_fds()
ledger = {}
try:
    module.open_dir(str(target), create=True, created=ledger)
except module.Refused:
    pass
else:
    raise RuntimeError("a post-bind replacement was accepted")
if identity(target) != replacement_identity or not moved.is_dir() or ledger or open_fds() != before:
    raise RuntimeError("a post-bind replacement was removed, recorded, or leaked")

module = load("validation")
parent = case / "validation"
parent.mkdir()
real_mkdir = module.os.mkdir
real_open = module.os.open
real_fstat = module.os.fstat
state = {"private": None, "fd": None, "failed": False}

def remember_name(name, mode=0o777, *, dir_fd=None):
    result = real_mkdir(name, mode, dir_fd=dir_fd)
    state["private"] = name
    return result

def remember_fd(name, *args, **kwargs):
    fd = real_open(name, *args, **kwargs)
    if name == state["private"]:
        state["fd"] = fd
    return fd

def fail_validation(fd):
    current = real_fstat(fd)
    if fd == state["fd"] and not state["failed"]:
        state["failed"] = True
        fields = list(current)
        fields[0] |= stat.S_IWGRP
        return os.stat_result(fields)
    return current

module.os.mkdir = remember_name
module.os.open = remember_fd
module.os.fstat = fail_validation
before = open_fds()
try:
    module.open_dir(str(parent / "target"), create=True, created={})
except module.Refused:
    pass
else:
    raise RuntimeError("a failed private-directory validation was accepted")
if list(parent.iterdir()) or open_fds() != before:
    raise RuntimeError("validation failure left a private entry or descriptor")

for label, raised in (("rename-error", OSError(errno.EIO, os.strerror(errno.EIO))),
                      ("system-exit", SystemExit(143))):
    module = load(label)
    parent = case / label
    parent.mkdir()

    def fail_rename(*args, error=raised):
        raise error

    module.rename_noreplace = fail_rename
    before_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    before = open_fds()
    try:
        module.open_dir(str(parent / "target"), create=True, created={})
    except BaseException as error:
        if isinstance(raised, SystemExit) and (not isinstance(error, SystemExit) or error.code != 143):
            raise
        if isinstance(raised, OSError) and not isinstance(error, (OSError, module.Refused)):
            raise
    else:
        raise RuntimeError(f"{label} did not propagate")
    after_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    if list(parent.iterdir()) or open_fds() != before or after_mask != before_mask:
        raise RuntimeError(f"{label} left a private entry, descriptor, or signal mask")

module = load("fsync")
parent = case / "fsync"
parent.mkdir()
parent_identity = identity(parent)
real_rename = module.rename_noreplace
real_fsync = module.os.fsync
published = False

def mark_published(*args):
    global published
    real_rename(*args)
    published = True

def fail_parent_fsync(fd):
    if published and identity(fd) == parent_identity:
        raise OSError(errno.EIO, os.strerror(errno.EIO))
    return real_fsync(fd)

module.rename_noreplace = mark_published
module.os.fsync = fail_parent_fsync
before = open_fds()
ledger = {}
try:
    module.open_dir(str(parent / "target"), create=True, created=ledger)
except (OSError, module.Refused) as error:
    if isinstance(error, OSError) and error.errno != errno.EIO:
        raise
else:
    raise RuntimeError("parent fsync failure was hidden")
if not parent.joinpath("target").is_dir() or len(ledger) != 1:
    raise RuntimeError("parent fsync failure rolled back publication or provenance")
keeper = next(iter(ledger.values()))
if open_fds() - before != {keeper}:
    raise RuntimeError("parent fsync failure leaked a transient descriptor")
close_ledger(module, ledger)
if open_fds() != before:
    raise RuntimeError("parent fsync keeper did not close")

module = load("later-component")
parent = case / "later-component"
parent.mkdir()
real_rename = module.rename_noreplace

def plant_later_failure(dirfd, old, new):
    real_rename(dirfd, old, new)
    if new == "first":
        firstfd = os.open(new, module.DIR_FLAGS, dir_fd=dirfd)
        try:
            os.symlink("/etc", "second", dir_fd=firstfd)
        finally:
            os.close(firstfd)

module.rename_noreplace = plant_later_failure
before = open_fds()
ledger = {}
try:
    module.open_dir(str(parent / "first" / "second"), create=True, created=ledger)
except module.Refused:
    pass
else:
    raise RuntimeError("a later-component failure was accepted")
if len(ledger) != 1 or not parent.joinpath("first", "second").is_symlink():
    raise RuntimeError("later-component failure lost published provenance")
keeper = next(iter(ledger.values()))
if open_fds() - before != {keeper}:
    raise RuntimeError("later-component failure leaked a transient descriptor")
close_ledger(module, ledger)
if open_fds() != before:
    raise RuntimeError("later-component keeper did not close")
PY
directory_publication_rc=$?
is "bound directory publication keeps exact authority and closes transient descriptors" "$directory_publication_rc" "0"

/usr/bin/python3 -I -S - "$S/lib/statedir.py" "$RB/keeper-ledger" <<'PY'
import errno
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

module_path, case = sys.argv[1:]
case = Path(case)
case.mkdir()

def load(name):
    spec = importlib.util.spec_from_file_location(f"statedir_keeper_{name}", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def assert_closed(fd):
    try:
        os.fstat(fd)
    except OSError as error:
        if error.errno == errno.EBADF:
            return
    raise RuntimeError(f"keeper {fd} remained open")

def close_held(module, held):
    dirfd, lockfd, ledger = held
    keepers = list(ledger.values())
    try:
        os.close(dirfd)
    finally:
        try:
            os.close(lockfd)
        finally:
            module.close_creation_ledger(ledger)
    for keeper in keepers:
        assert_closed(keeper)

module = load("attempts")
root = case / "attempts"
real_open_dir = module.open_dir
real_root_current = module.lock_root_current
ledgers = []
keeper_during_retry = None

def observe_open(path, create=False, created=None):
    global keeper_during_retry
    ledgers.append(created)
    if len(ledgers) == 2:
        keeper_during_retry = next(iter(created.values()))
        os.fstat(keeper_during_retry)
    return real_open_dir(path, create=create, created=created)

root_checks = 0

def retry_once(*args):
    global root_checks
    root_checks += 1
    if root_checks <= 15:
        return False
    return real_root_current(*args)

module.open_dir = observe_open
module.lock_root_current = retry_once
held = module.acquire_lock(str(root), "wait", ".lock")
if len(ledgers) != 16 or any(ledger is not ledgers[0] for ledger in ledgers) or len(held[2]) != 1:
    raise RuntimeError("lock attempts did not share one identity ledger")
if keeper_during_retry != next(iter(held[2].values())):
    raise RuntimeError("one created identity received more than one keeper")
close_held(module, held)

for label, refusal in (("contention", "contention"), ("refusal", "refusal")):
    module = load(label)
    root = case / label
    real_open_dir = module.open_dir
    keepers = []

    def capture_created(path, create=False, created=None):
        fd = real_open_dir(path, create=create, created=created)
        keepers.extend(created.values())
        return fd

    module.open_dir = capture_created
    if refusal == "contention":
        module.lock_namespace = lambda *args, **kwargs: False
        if module.acquire_lock(str(root), "nowait", ".lock") is not None:
            raise RuntimeError("contention returned a lock")
    else:
        def refuse_parent(*args):
            raise module.Refused("injected refusal")
        module.open_lock_parent = refuse_parent
        try:
            module.acquire_lock(str(root), "wait", ".lock")
        except module.Refused:
            pass
        else:
            raise RuntimeError("acquisition refusal returned a lock")
    if not keepers:
        raise RuntimeError(f"{label} did not create a keeper")
    for keeper in keepers:
        assert_closed(keeper)

def run_case(label, command, clean, cleanup_error=None, run_error=None):
    module = load(label)
    root = case / label
    real_acquire = module.acquire_lock
    keepers = []

    def capture_held(*args):
        held = real_acquire(*args)
        keepers.extend(held[2].values())
        return held

    module.acquire_lock = capture_held
    if cleanup_error is not None:
        def fail_cleanup(*args, **kwargs):
            raise module.Refused(cleanup_error)
        module.cleanup_lock = fail_cleanup
    real_run = subprocess.run
    if run_error is not None:
        def fail_run(*args, **kwargs):
            raise run_error
        subprocess.run = fail_run
    try:
        try:
            result = module.run_locked([str(root), "wait", ".lock", "--", command], clean)
        except BaseException as error:
            result = error
    finally:
        subprocess.run = real_run
    if not keepers:
        raise RuntimeError(f"{label} did not transfer a keeper")
    for keeper in keepers:
        assert_closed(keeper)
    return result, root

result, root = run_case("success", "/usr/bin/true", True)
if result != 0 or root.exists():
    raise RuntimeError("successful cleanup did not close and remove its created root")
result, root = run_case("child-failure", "/usr/bin/false", True)
if result != 1 or not root.joinpath(".lock").is_file():
    raise RuntimeError("child failure did not retain lock state")
result, root = run_case("cleanup-refusal", "/usr/bin/true", True, cleanup_error="cleanup refused")
if result.__class__.__name__ != "Refused":
    raise RuntimeError("cleanup refusal did not propagate")
result, root = run_case("ordinary-error", "/usr/bin/true", False, run_error=RuntimeError("ordinary"))
if not isinstance(result, RuntimeError):
    raise RuntimeError("ordinary child setup error did not propagate")
result, root = run_case("signal-exit", "/usr/bin/true", False, run_error=SystemExit(143))
if not isinstance(result, SystemExit) or result.code != 143:
    raise RuntimeError("signal exit did not propagate")

module = load("close-fds")
root = case / "close-fds"
observed = []
real_run = subprocess.run

class Result:
    returncode = 0

def observe_run(*args, **kwargs):
    observed.append(kwargs.get("close_fds"))
    return Result()

subprocess.run = observe_run
try:
    if module.run_locked([str(root), "wait", ".lock", "--", "/usr/bin/true"], False) != 0:
        raise RuntimeError("close_fds probe failed")
finally:
    subprocess.run = real_run
if observed != [True]:
    raise RuntimeError("the child did not retain close_fds=True")
PY
keeper_ledger_rc=$?
is "lock acquisition pins one keeper per identity and closes every keeper" "$keeper_ledger_rc" "0"

/usr/bin/python3 -I -S - "$S/lib/statedir.py" "$RB/lock-race" <<'PY'
import importlib.util
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

module_path, case = sys.argv[1:]
case = Path(case)
case.mkdir()
root = case / "root"
locker_script = case / "locker.py"
owner_entered = case / "owner-entered"
owner_release = case / "owner-release"
cleanup_unlinked = case / "cleanup-unlinked"
cleanup_release = case / "cleanup-release"
replacement_entered = case / "replacement-entered"
replacement_release = case / "replacement-release"
waiter_entered = case / "waiter-entered"
waiter_release = case / "waiter-release"

locker_script.write_text("""import importlib.util, os, pathlib, subprocess, sys, time
module_path, verb, root, entered, release, *cleanup = sys.argv[1:]
spec = importlib.util.spec_from_file_location("statedir", module_path)
sd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sd)
class Result:
    returncode = 0
def run(*args, **kwargs):
    pathlib.Path(entered).touch()
    while not pathlib.Path(release).exists():
        time.sleep(0.01)
    return Result()
subprocess.run = run
if cleanup:
    unlinked, cleanup_release = cleanup
    real_unlink = sd.os.unlink
    def unlink_then_wait(*args, **kwargs):
        real_unlink(*args, **kwargs)
        pathlib.Path(unlinked).touch()
        while not pathlib.Path(cleanup_release).exists():
            time.sleep(0.01)
    sd.os.unlink = unlink_then_wait
raise SystemExit(sd.main([verb, root, "wait", ".lock", "--", "/usr/bin/true"]))
""")

def wait_for(path, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if path.exists():
            return
        time.sleep(0.01)
    raise RuntimeError(f"timed out waiting for {path.name}")

def wait_for_one(first, second, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if first.exists() or second.exists():
            return
        time.sleep(0.01)
    raise RuntimeError(f"timed out waiting for {first.name} or {second.name}")

def wait_for_fd(pid, identity, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        try:
            for entry in Path(f"/proc/{pid}/fd").iterdir():
                try:
                    st = entry.stat()
                except FileNotFoundError:
                    continue
                if (st.st_dev, st.st_ino) == identity:
                    return
        except FileNotFoundError:
            break
        time.sleep(0.01)
    raise RuntimeError(f"pid {pid} never opened lock inode {identity}")

python = "/usr/bin/python3"
processes = []
try:
    owner = subprocess.Popen([python, "-I", "-S", str(locker_script), module_path, "lock-clean", str(root),
                              str(owner_entered), str(owner_release),
                              str(cleanup_unlinked), str(cleanup_release)])
    processes.append(owner)
    wait_for(owner_entered)
    old_root = root.stat()
    old_root_identity = (old_root.st_dev, old_root.st_ino)
    old = root.joinpath(".lock").stat()
    old_identity = (old.st_dev, old.st_ino)

    waiter = subprocess.Popen([python, "-I", "-S", str(locker_script), module_path, "lock", str(root),
                               str(waiter_entered), str(waiter_release)])
    processes.append(waiter)
    wait_for_fd(waiter.pid, old_identity)

    owner_release.touch()
    wait_for(cleanup_unlinked)
    replacement = subprocess.Popen([python, "-I", "-S", str(locker_script), module_path, "lock", str(root),
                                    str(replacement_entered), str(replacement_release)])
    processes.append(replacement)
    wait_for_fd(replacement.pid, old_root_identity)
    if replacement_entered.exists():
        raise RuntimeError("replacement owner bypassed root cleanup")

    cleanup_release.touch()
    if owner.wait(timeout=5) != 0:
        raise RuntimeError("cleanup owner failed")
    wait_for_one(replacement_entered, waiter_entered)
    if replacement_entered.exists() and waiter_entered.exists():
        raise RuntimeError("both rebound owners entered the replacement lock")
    current = root.joinpath(".lock").stat()
    current_identity = (current.st_dev, current.st_ino)
    if current_identity == old_identity:
        raise RuntimeError("replacement reused the retired lock inode")

    wait_for_fd(waiter.pid, current_identity)
    if replacement_entered.exists():
        replacement_release.touch()
        if replacement.wait(timeout=5) != 0:
            raise RuntimeError("replacement owner failed")
        wait_for(waiter_entered)
        waiter_release.touch()
        if waiter.wait(timeout=5) != 0:
            raise RuntimeError("rebound waiter failed")
    else:
        waiter_release.touch()
        if waiter.wait(timeout=5) != 0:
            raise RuntimeError("rebound waiter failed")
        wait_for(replacement_entered)
        replacement_release.touch()
        if replacement.wait(timeout=5) != 0:
            raise RuntimeError("replacement owner failed")

    spec = importlib.util.spec_from_file_location("statedir", module_path)
    statedir = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(statedir)
    directory_root = case / "directory-race"
    directory_root.mkdir()
    dirfd = statedir.open_dir(str(directory_root))
    lockfd = statedir.open_lock(dirfd, ".lock")
    fcntl.flock(lockfd, fcntl.LOCK_EX)
    real_rmdir = statedir.os.rmdir
    actor = []

    def race_rmdir(*args, **kwargs):
        actorfd = os.open(case, os.O_RDONLY | os.O_DIRECTORY)
        try:
            try:
                fcntl.flock(actorfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                actor.append("blocked")
            else:
                actor.append("entered")
                real_rmdir(directory_root)
                directory_root.mkdir()
        finally:
            os.close(actorfd)
        return real_rmdir(*args, **kwargs)

    statedir.os.rmdir = race_rmdir
    try:
        statedir.cleanup_lock(str(directory_root), "wait", ".lock", dirfd, lockfd, {})
    finally:
        statedir.os.rmdir = real_rmdir
        os.close(dirfd)
        os.close(lockfd)
    if actor != ["blocked"]:
        raise RuntimeError(f"directory replacement actor was not serialized: {actor}")

    contended_root = case / "cleanup-contention"
    contended_root.mkdir()
    dirfd = statedir.open_dir(str(contended_root))
    lockfd = statedir.open_lock(dirfd, ".lock")
    fcntl.flock(lockfd, fcntl.LOCK_EX)
    actorfd = os.open(case, os.O_RDONLY | os.O_DIRECTORY)
    fcntl.flock(actorfd, fcntl.LOCK_EX)

    def release_namespace():
        time.sleep(0.1)
        fcntl.flock(actorfd, fcntl.LOCK_UN)

    release_thread = threading.Thread(target=release_namespace)
    release_thread.start()
    started = time.monotonic()
    try:
        statedir.cleanup_lock(str(contended_root), "nowait", ".lock", dirfd, lockfd, {})
    finally:
        release_thread.join()
        os.close(actorfd)
        os.close(dirfd)
        os.close(lockfd)
    elapsed = time.monotonic() - started
    if elapsed < 0.08 or elapsed > 2 or contended_root.exists():
        raise RuntimeError(f"cleanup did not survive brief namespace contention: {elapsed:.3f}s")
finally:
    owner_release.touch()
    cleanup_release.touch()
    replacement_release.touch()
    waiter_release.touch()
    timed_out = []
    for process in processes:
        if process.poll() is None:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                timed_out.append(process)
    for process in timed_out:
        process.terminate()
    for process in timed_out:
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
PY
race_rc=$?
is "a stale waiter reopens the replacement lock before entering" "$race_rc" "0"

exec 5>"$RB/lock/.lifecycle.lock"; flock -x 5
PORTAL_STATE_DIR="$RB/lock" timeout 2 "$S/tunnels.sh" stop cloudflared 6000 >/dev/null 2>&1; rc=$?
exec 5>&-
is "tunnel mutations fail fast behind the lifecycle lock" "$rc" "75"

mkdir -p "$RB/uninstall-state" "$RB/uninstall-runtime" "$RB/uninstall-bin"
printf '#!/bin/sh\nprintf called >> "'"$RB"'/uninstall-called"\nexit 0\n' > "$RB/uninstall-bin/omarchy"
chmod 755 "$RB/uninstall-bin/omarchy"
exec 5>"$RB/uninstall-state/.metrics.lock"; flock -x 5
PATH="$RB/uninstall-bin:$PATH" PORTAL_METRICS_DIR="$RB/uninstall-state" PORTAL_STATE_DIR="$RB/uninstall-runtime" \
  timeout 2 "$S/uninstall.sh" >/dev/null 2>&1; rc=$?
exec 5>&-
is "uninstall fails before effects when metrics are being updated" "$rc $(test -e "$RB/uninstall-called" && echo called || echo clean)" "75 clean"

CLEAN_UNINSTALL="$RB/uninstall-clean"; mkdir -p "$CLEAN_UNINSTALL/home" "$CLEAN_UNINSTALL/bin"
printf '#!/bin/sh\n[ "$*" = "plugin list --json" ] && { printf "[]\\n"; exit 0; }\nexit 99\n' > "$CLEAN_UNINSTALL/bin/omarchy"
chmod 700 "$CLEAN_UNINSTALL/bin/omarchy"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$CLEAN_UNINSTALL/home" \
  PORTAL_STATE_DIR="$CLEAN_UNINSTALL/runtime" PORTAL_METRICS_DIR="$CLEAN_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$CLEAN_UNINSTALL/portless" "$S/uninstall.sh" > "$CLEAN_UNINSTALL/out" 2>&1; clean_uninstall_rc=$?
is "successful uninstall restores initially absent state roots" \
  "$clean_uninstall_rc $(test -e "$CLEAN_UNINSTALL/runtime" && echo present || echo absent) $(test -e "$CLEAN_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$CLEAN_UNINSTALL/out" || true)" \
  "0 absent absent 0"

OVERRIDE_UNINSTALL="$RB/uninstall-overrides"; mkdir -p "$OVERRIDE_UNINSTALL/home" "$OVERRIDE_UNINSTALL/runtime" "$OVERRIDE_UNINSTALL/state"
override_runtime_before=$(stat -c '%d:%i' "$OVERRIDE_UNINSTALL/runtime")
override_state_before=$(stat -c '%d:%i' "$OVERRIDE_UNINSTALL/state")
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$OVERRIDE_UNINSTALL/home" \
  PORTAL_STATE_DIR="$OVERRIDE_UNINSTALL/runtime" PORTAL_METRICS_DIR="$OVERRIDE_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$OVERRIDE_UNINSTALL/portless" "$S/uninstall.sh" > "$OVERRIDE_UNINSTALL/out" 2>&1; override_uninstall_rc=$?
override_runtime_after=$(stat -c '%d:%i' "$OVERRIDE_UNINSTALL/runtime" 2>/dev/null || echo absent)
override_state_after=$(stat -c '%d:%i' "$OVERRIDE_UNINSTALL/state" 2>/dev/null || echo absent)
is "successful uninstall preserves pre-existing override roots" \
  "$override_uninstall_rc $override_runtime_after $override_state_after $(grep -c "holds files that are not Portal's" "$OVERRIDE_UNINSTALL/out" || true) $(grep -c 'is an explicit state root' "$OVERRIDE_UNINSTALL/out" || true)" \
  "0 $override_runtime_before $override_state_before 0 2"

/usr/bin/python3 -I -S - "$S/uninstall.sh" "$RB/uninstall-root-topology" <<'PY'
import itertools
import os
from pathlib import Path
import subprocess
import sys

uninstall, case = sys.argv[1:]
case = Path(case)
case.mkdir()
stub = case / "bin"
stub.mkdir()
omarchy = stub / "omarchy"
omarchy.write_text('#!/bin/sh\n[ "$*" = "plugin list --json" ] && { printf "[]\\n"; exit 0; }\nexit 99\n')
omarchy.chmod(0o700)

def inode(path):
    current = path.stat()
    return current.st_dev, current.st_ino

def environment(root):
    env = os.environ.copy()
    for name in ("PORTAL_STATE_DIR", "PORTAL_METRICS_DIR", "PORTAL_LIFECYCLE_LOCKED",
                 "PORTAL_METRICS_LOCKED", "XDG_RUNTIME_DIR", "XDG_STATE_HOME"):
        env.pop(name, None)
    home = root / "home"
    home.mkdir(parents=True)
    env.update({
        "HOME": str(home),
        "PATH": f"{stub}:/usr/bin:/bin",
        "PORTLESS_STATE_DIR": str(root / "portless"),
    })
    return env

def configure(env, logical, override, path, raw=None):
    if logical == "runtime":
        override_name, default_name = "PORTAL_STATE_DIR", "XDG_RUNTIME_DIR"
    else:
        override_name, default_name = "PORTAL_METRICS_DIR", "XDG_STATE_HOME"
    if override:
        env[override_name] = str(raw or path)
    else:
        if path.name != "portal":
            raise RuntimeError(f"default {logical} path is not a portal leaf: {path}")
        env[default_name] = str(path.parent)

def run(root, env):
    result = subprocess.run([uninstall], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=10)
    if result.returncode != 0:
        raise RuntimeError(f"uninstall failed for {root.name}: {result.returncode}\n{result.stdout}")
    locks = list(root.rglob(".lifecycle.lock")) + list(root.rglob(".metrics.lock"))
    if locks:
        raise RuntimeError(f"uninstall left lock files for {root.name}: {locks}")
    return result.stdout

def snapshot(root):
    result = []
    for path in sorted(root.rglob("*")):
        current = path.lstat()
        target = os.readlink(path) if path.is_symlink() else None
        result.append((str(path.relative_to(root)), current.st_dev, current.st_ino,
                       current.st_mode, current.st_size, target))
    return result

def run_dry(root, env):
    before = snapshot(root)
    result = subprocess.run([uninstall, "--dry"], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=10)
    if result.returncode != 0:
        raise RuntimeError(f"dry uninstall failed for {root.name}: {result.returncode}\n{result.stdout}")
    if snapshot(root) != before:
        raise RuntimeError(f"dry uninstall changed the filesystem for {root.name}")
    return result.stdout.splitlines()

def root_removals(output, path):
    expected = f"would: rmdir --ignore-fail-on-non-empty -- {path}"
    return sum(line == expected for line in output)

for runtime_override, metrics_override, runtime_present, metrics_present in itertools.product((False, True), repeat=4):
    label = f"distinct-r{int(runtime_override)}m{int(metrics_override)}-p{int(runtime_present)}{int(metrics_present)}"
    root = case / label
    root.mkdir()
    runtime = root / ("runtime-override" if runtime_override else "runtime-default/portal")
    metrics = root / ("metrics-override" if metrics_override else "metrics-default/portal")
    if runtime_present:
        runtime.mkdir(parents=True)
    if metrics_present:
        metrics.mkdir(parents=True)
    runtime_before = inode(runtime) if runtime_present else None
    metrics_before = inode(metrics) if metrics_present else None
    env = environment(root)
    configure(env, "runtime", runtime_override, runtime)
    configure(env, "metrics", metrics_override, metrics)
    run(root, env)
    runtime_expected = runtime_present and runtime_override
    metrics_expected = metrics_present and metrics_override
    if runtime.exists() != runtime_expected or metrics.exists() != metrics_expected:
        raise RuntimeError(f"distinct root policy mismatch for {label}")
    if runtime_expected and inode(runtime) != runtime_before:
        raise RuntimeError(f"runtime override identity changed for {label}")
    if metrics_expected and inode(metrics) != metrics_before:
        raise RuntimeError(f"metrics override identity changed for {label}")

for outer_logical, outer_override, inner_override, presence in itertools.product(
        ("runtime", "metrics"), (False, True), (False, True), ("both", "outer", "neither")):
    inner_logical = "metrics" if outer_logical == "runtime" else "runtime"
    label = f"nested-{outer_logical}-o{int(outer_override)}i{int(inner_override)}-{presence}"
    root = case / label
    root.mkdir()
    outer = root / ("outer-override" if outer_override else "outer-default/portal")
    inner = outer / ("inner-override" if inner_override else "portal")
    if presence == "both":
        inner.mkdir(parents=True)
    elif presence == "outer":
        outer.mkdir(parents=True)
    outer_present = presence != "neither"
    inner_present = presence == "both"
    outer_before = inode(outer) if outer_present else None
    inner_before = inode(inner) if inner_present else None
    env = environment(root)
    configure(env, outer_logical, outer_override, outer)
    configure(env, inner_logical, inner_override, inner)
    run(root, env)
    inner_expected = inner_present and inner_override
    outer_expected = inner_expected or (outer_present and outer_override)
    if outer.exists() != outer_expected or inner.exists() != inner_expected:
        raise RuntimeError(f"nested root policy mismatch for {label}")
    if outer_expected and outer_present and inode(outer) != outer_before:
        raise RuntimeError(f"outer identity changed for {label}")
    if inner_expected and inode(inner) != inner_before:
        raise RuntimeError(f"inner identity changed for {label}")

for runtime_override, metrics_override, present in itertools.product((False, True), (False, True), (False, True)):
    label = f"equal-r{int(runtime_override)}m{int(metrics_override)}-p{int(present)}"
    root = case / label
    root.mkdir()
    shared = root / "shared/portal"
    if present:
        shared.mkdir(parents=True)
    before = inode(shared) if present else None
    env = environment(root)
    configure(env, "runtime", runtime_override, shared)
    configure(env, "metrics", metrics_override, shared)
    run(root, env)
    expected = present and (runtime_override or metrics_override)
    if shared.exists() != expected:
        raise RuntimeError(f"equal root policy mismatch for {label}")
    if expected and inode(shared) != before:
        raise RuntimeError(f"equal override identity changed for {label}")

root = case / "empty-overrides"
root.mkdir()
shared = root / "shared/portal"
shared.mkdir(parents=True)
env = environment(root)
env.update({
    "PORTAL_STATE_DIR": "",
    "PORTAL_METRICS_DIR": "",
    "XDG_RUNTIME_DIR": str(shared.parent),
    "XDG_STATE_HOME": str(shared.parent),
})
run(root, env)
if shared.exists():
    raise RuntimeError("empty overrides preserved a default shared root")

root = case / "lexical-equal"
root.mkdir()
shared = root / "shared/portal"
shared.mkdir(parents=True)
alias = root / "shared/alias"
alias.mkdir()
before = inode(shared)
env = environment(root)
configure(env, "runtime", True, shared, alias / ".." / "portal")
configure(env, "metrics", False, shared)
run(root, env)
if inode(shared) != before:
    raise RuntimeError("lexically different equal roots did not share the override veto")

for outer_logical in ("runtime", "metrics"):
    inner_logical = "metrics" if outer_logical == "runtime" else "runtime"
    root = case / f"preexisting-intermediate-{outer_logical}"
    root.mkdir()
    outer = root / "outer"
    intermediate = outer / "middle"
    inner = intermediate / "inner"
    intermediate.mkdir(parents=True)
    outer_before = inode(outer)
    intermediate_before = inode(intermediate)
    env = environment(root)
    configure(env, outer_logical, True, outer)
    configure(env, inner_logical, True, inner)
    run(root, env)
    if inode(outer) != outer_before or inode(intermediate) != intermediate_before or inner.exists():
        raise RuntimeError(f"pre-existing intermediate changed with {outer_logical} outside")

    root = case / f"created-intermediate-{outer_logical}"
    root.mkdir()
    outer = root / "outer"
    inner = outer / "middle/inner"
    env = environment(root)
    configure(env, outer_logical, True, outer)
    configure(env, inner_logical, True, inner)
    run(root, env)
    if outer.exists():
        raise RuntimeError(f"created nested topology remained with {outer_logical} outside")

for logical in ("runtime", "metrics"):
    root = case / f"symlink-dotdot-{logical}"
    root.mkdir()
    kernel_parent = root / "kernel"
    kernel_child = kernel_parent / "child"
    kernel_child.mkdir(parents=True)
    jump = root / "jump"
    jump.symlink_to(kernel_child, target_is_directory=True)
    normalized = root / "selected-root"
    kernel_resolved = kernel_parent / "selected-root"
    other = root / "other-root"
    normalized.mkdir()
    kernel_resolved.mkdir()
    other.mkdir()
    if logical == "runtime":
        kernel_resolved.joinpath(".restart-1234.pid").write_text("bad")
    else:
        kernel_resolved.joinpath("trusted-stores").write_text("wrong-root")
        kernel_resolved.joinpath("installed-cloudflared").write_text("wrong-root")
    normalized_before = inode(normalized)
    kernel_before = inode(kernel_resolved)
    other_before = inode(other)
    wrong_before = snapshot(kernel_resolved)
    env = environment(root)
    raw = jump / ".." / "selected-root"
    configure(env, logical, True, normalized, raw)
    configure(env, "metrics" if logical == "runtime" else "runtime", True, other)
    output = run(root, env)
    if (inode(normalized) != normalized_before or inode(kernel_resolved) != kernel_before
            or inode(other) != other_before or snapshot(kernel_resolved) != wrong_before):
        raise RuntimeError(f"symlink-plus-dot-dot selected different {logical} roots across effects")
    if str(raw) in output or str(kernel_resolved) in output or str(normalized) not in output:
        raise RuntimeError(f"symlink-plus-dot-dot reported a non-normalized {logical} root")

for runtime_override, metrics_override in itertools.product((False, True), repeat=2):
    label = f"dry-distinct-r{int(runtime_override)}m{int(metrics_override)}"
    root = case / label
    root.mkdir()
    runtime = root / ("runtime-override" if runtime_override else "runtime-default/portal")
    metrics = root / ("metrics-override" if metrics_override else "metrics-default/portal")
    runtime.mkdir(parents=True)
    metrics.mkdir(parents=True)
    env = environment(root)
    configure(env, "runtime", runtime_override, runtime)
    configure(env, "metrics", metrics_override, metrics)
    output = run_dry(root, env)
    if root_removals(output, runtime) != int(not runtime_override):
        raise RuntimeError(f"dry runtime root policy mismatch for {label}")
    if root_removals(output, metrics) != int(not metrics_override):
        raise RuntimeError(f"dry metrics root policy mismatch for {label}")

for runtime_override, metrics_override in itertools.product((False, True), repeat=2):
    label = f"dry-equal-r{int(runtime_override)}m{int(metrics_override)}"
    root = case / label
    root.mkdir()
    shared = root / "shared/portal"
    shared.mkdir(parents=True)
    env = environment(root)
    configure(env, "runtime", runtime_override, shared)
    configure(env, "metrics", metrics_override, shared)
    output = run_dry(root, env)
    if root_removals(output, shared) != int(not (runtime_override or metrics_override)):
        raise RuntimeError(f"dry equal-root policy mismatch for {label}")

for outer_logical in ("runtime", "metrics"):
    inner_logical = "metrics" if outer_logical == "runtime" else "runtime"
    root = case / f"dry-nested-{outer_logical}"
    root.mkdir()
    outer = root / "outer/portal"
    inner = outer / "inner/portal"
    inner.mkdir(parents=True)
    env = environment(root)
    configure(env, outer_logical, False, outer)
    configure(env, inner_logical, False, inner)
    output = run_dry(root, env)
    outer_line = f"would: rmdir --ignore-fail-on-non-empty -- {outer}"
    inner_line = f"would: rmdir --ignore-fail-on-non-empty -- {inner}"
    if root_removals(output, outer) != 1 or root_removals(output, inner) != 1:
        raise RuntimeError(f"dry nested root policy mismatch for {outer_logical}")
    if output.index(inner_line) > output.index(outer_line):
        raise RuntimeError(f"dry nested roots were not planned inner-first for {outer_logical}")

root = case / "dry-absent-overrides"
root.mkdir()
runtime = root / "runtime"
metrics = root / "state"
env = environment(root)
configure(env, "runtime", True, runtime)
configure(env, "metrics", True, metrics)
output = run_dry(root, env)
if runtime.exists() or metrics.exists() or root_removals(output, runtime) or root_removals(output, metrics):
    raise RuntimeError("dry uninstall created or planned removal of absent override roots")
PY
root_topology_rc=$?
is "uninstall applies one root model across real and dry cleanup" "$root_topology_rc" "0"

SHARED_UNINSTALL="$RB/uninstall-shared"; mkdir -p "$SHARED_UNINSTALL/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$SHARED_UNINSTALL/home" \
  PORTAL_STATE_DIR="$SHARED_UNINSTALL/state" PORTAL_METRICS_DIR="$SHARED_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$SHARED_UNINSTALL/portless" "$S/uninstall.sh" > "$SHARED_UNINSTALL/out" 2>&1; shared_uninstall_rc=$?
is "successful uninstall removes a shared lock-only state root" \
  "$shared_uninstall_rc $(test -e "$SHARED_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$SHARED_UNINSTALL/out" || true)" \
  "0 absent 0"

NESTED_UNINSTALL="$RB/uninstall-nested"; mkdir -p "$NESTED_UNINSTALL/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$NESTED_UNINSTALL/home" \
  PORTAL_STATE_DIR="$NESTED_UNINSTALL/state/runtime" PORTAL_METRICS_DIR="$NESTED_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$NESTED_UNINSTALL/portless" "$S/uninstall.sh" > "$NESTED_UNINSTALL/out" 2>&1; nested_uninstall_rc=$?
is "successful uninstall removes a runtime root nested directly under state" \
  "$nested_uninstall_rc $(test -e "$NESTED_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$NESTED_UNINSTALL/out" || true)" \
  "0 absent 0"

REVERSE_UNINSTALL="$RB/uninstall-reverse-nested"; mkdir -p "$REVERSE_UNINSTALL/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$REVERSE_UNINSTALL/home" \
  PORTAL_STATE_DIR="$REVERSE_UNINSTALL/state" PORTAL_METRICS_DIR="$REVERSE_UNINSTALL/state/metrics-state" \
  PORTLESS_STATE_DIR="$REVERSE_UNINSTALL/portless" "$S/uninstall.sh" > "$REVERSE_UNINSTALL/out" 2>&1; reverse_uninstall_rc=$?
is "successful uninstall removes state nested directly under runtime" \
  "$reverse_uninstall_rc $(test -e "$REVERSE_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$REVERSE_UNINSTALL/out" || true)" \
  "0 absent 0"

DEEP_UNINSTALL="$RB/uninstall-deep"; mkdir -p "$DEEP_UNINSTALL/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$DEEP_UNINSTALL/home" \
  PORTAL_STATE_DIR="$DEEP_UNINSTALL/state/a/runtime" PORTAL_METRICS_DIR="$DEEP_UNINSTALL/state" \
  PORTLESS_STATE_DIR="$DEEP_UNINSTALL/portless" "$S/uninstall.sh" > "$DEEP_UNINSTALL/out" 2>&1; deep_uninstall_rc=$?
is "successful uninstall removes a deeply nested runtime root" \
  "$deep_uninstall_rc $(test -e "$DEEP_UNINSTALL/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$DEEP_UNINSTALL/out" || true)" \
  "0 absent 0"

REVERSE_DEEP="$RB/uninstall-reverse-deep"; mkdir -p "$REVERSE_DEEP/home"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$REVERSE_DEEP/home" \
  PORTAL_STATE_DIR="$REVERSE_DEEP/state" PORTAL_METRICS_DIR="$REVERSE_DEEP/state/a/metrics-state" \
  PORTLESS_STATE_DIR="$REVERSE_DEEP/portless" "$S/uninstall.sh" > "$REVERSE_DEEP/out" 2>&1; reverse_deep_rc=$?
is "successful uninstall removes deeply nested metrics state" \
  "$reverse_deep_rc $(test -e "$REVERSE_DEEP/state" && echo present || echo absent) $(grep -c 'holds files that are not Portal' "$REVERSE_DEEP/out" || true)" \
  "0 absent 0"

FOREIGN_DEEP="$RB/uninstall-foreign-deep"; mkdir -p "$FOREIGN_DEEP/home" "$FOREIGN_DEEP/state/a"
printf keep > "$FOREIGN_DEEP/state/a/foreign"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$FOREIGN_DEEP/home" \
  PORTAL_STATE_DIR="$FOREIGN_DEEP/state/a/runtime" PORTAL_METRICS_DIR="$FOREIGN_DEEP/state" \
  PORTLESS_STATE_DIR="$FOREIGN_DEEP/portless" "$S/uninstall.sh" > "$FOREIGN_DEEP/out" 2>&1; foreign_deep_rc=$?
is "uninstall preserves and reports a foreign nested runtime parent" \
  "$foreign_deep_rc $(cat "$FOREIGN_DEEP/state/a/foreign") $(grep -c 'holds files that are not Portal' "$FOREIGN_DEEP/out" || true)" \
  "0 keep 1"

REVERSE_FOREIGN="$RB/uninstall-reverse-foreign"; mkdir -p "$REVERSE_FOREIGN/home" "$REVERSE_FOREIGN/state/a"
printf keep > "$REVERSE_FOREIGN/state/a/foreign"
PATH="$CLEAN_UNINSTALL/bin:/usr/bin:/bin" HOME="$REVERSE_FOREIGN/home" \
  PORTAL_STATE_DIR="$REVERSE_FOREIGN/state" PORTAL_METRICS_DIR="$REVERSE_FOREIGN/state/a/metrics-state" \
  PORTLESS_STATE_DIR="$REVERSE_FOREIGN/portless" "$S/uninstall.sh" > "$REVERSE_FOREIGN/out" 2>&1; reverse_foreign_rc=$?
is "uninstall preserves and reports a foreign nested metrics parent" \
  "$reverse_foreign_rc $(cat "$REVERSE_FOREIGN/state/a/foreign") $(grep -c 'holds files that are not Portal' "$REVERSE_FOREIGN/out" || true)" \
  "0 keep 1"

exec 7<"$RB/append"; flock -x 7
printf 'x\n' | timeout 2 /usr/bin/python3 -I -S "$S/lib/statedir.py" append "$RB/append/sample" 10 1024 >/dev/null 2>&1; rc=$?
exec 7>&-
is "append refuses a held directory lock without blocking" "$rc" "1"

p1start=$(cut -d')' -f2- /proc/1/stat 2>/dev/null | awk '{print $20}')
/usr/bin/python3 -I -S "$PR" check 1 "${p1start:-1}" >/dev/null 2>&1; rc=$?
is "process identity rejects pid 1" "$rc" "1"

printf '[]' > "$RB/route-target"; ln -s "$RB/route-target" "$RB/portless/routes.json"
PORTLESS_STATE_DIR="$RB/portless" PORTAL_STATE_DIR="$RB/runtime" bash -c 'source "'"$S"'/lib/portless.sh"; portless_state_load' >/dev/null 2>&1; rc=$?
is "a refused Portless route makes the state load fail" "$rc" "1"
refused_providers=$(PORTLESS_STATE_DIR="$RB/portless" PORTAL_STATE_DIR="$RB/runtime" bash -c '
  source "'"$S"'/tunnels.sh"
  cloudflared_status() { printf "ready|Cloudflare ready|"; }
  ngrok_status() { printf "ready|ngrok ready|"; }
  cmd_providers
')
is "refused Portless state keeps independent public providers available" \
  "$(jq -c '[.ok, [.providers[]? | select(.reach == "public") | .id], (.providers[]? | select(.id == "portless") | [.status, .detail])]' <<<"$refused_providers")" \
  '[true,["cloudflared","ngrok"],["unavailable","State could not be read safely"]]'

mkdir -p "$RB/portless-stop" "$RB/portless-stop-state" "$RB/fake-portless"
printf '[{"port":45882,"hostname":"acme.test","pid":0}]' > "$RB/portless-stop/routes.json"
printf 'acme' > "$RB/portless-stop-state/portless-45882.name"
printf 'https://acme.test' > "$RB/portless-stop-state/portless-45882.url"
printf '#!/bin/sh\nexit 0\n' > "$RB/fake-portless/portless"; chmod 755 "$RB/fake-portless/portless"
stubborn=$(PATH="$RB/fake-portless:$PATH" PORTLESS_STATE_DIR="$RB/portless-stop" PORTAL_STATE_DIR="$RB/portless-stop-state" \
  bash -c 'source "'"$S"'/tunnels.sh"; PROVIDER_BIN[portless]="'"$RB"'/fake-portless/portless"; cmd_stop portless 45882')
is "Portless removal keeps ownership when the route remains" "$(jq -c .ok <<<"$stubborn") $(test -e "$RB/portless-stop-state/portless-45882.name" && echo kept || echo lost)" "false kept"

printf '#!/bin/bash\necho '\''{"ok":false,"error":"setup engine failed"}'\''\n' > "$RB/fake/portless-setup.sh"; chmod 755 "$RB/fake/portless-setup.sh"
OLD_SD="$SCRIPT_DIR"; SCRIPT_DIR="$RB/fake"
is "Portless setup propagates an engine failure" "$(cmd_setup portless | jq -c .)" '{"ok":false,"error":"setup engine failed"}'
SCRIPT_DIR="$OLD_SD"

cp "$S/portal" "$RB/cli/portal"; printf '#!/bin/bash\necho '\''{"ok":false,"error":"sentinel"}'\''\n' > "$RB/cli/tunnels.sh"; chmod 755 "$RB/cli/portal" "$RB/cli/tunnels.sh"
printf '#!/bin/sh\nexit 1\n' > "$RB/fake/omarchy-shell"; chmod 755 "$RB/fake/omarchy-shell"
"$RB/cli/portal" expose cloudflared 3000 >/dev/null 2>&1; rc=$?
is "portal expose returns failure for an action error" "$rc" "1"
shared_error=$(PATH="$RB/fake:$PATH" "$RB/cli/portal" shared 2>&1); rc=$?
is "portal shared preserves an offline status failure" "$rc $(grep -c sentinel <<<"$shared_error")" "1 1"

printf 'mine' > "$RB/bin/cloudflared"
printf '#!/bin/bash\nprintf called > "'"$RB"'/curl-called"; exit 1\n' > "$RB/fake/curl"; chmod 755 "$RB/fake/curl"
PORTAL_BIN_DIR="$RB/bin" PORTAL_METRICS_DIR="$RB/provider-state" PATH="$RB/fake:/usr/bin:/bin" "$S/provider-install.sh" cloudflared >/dev/null 2>&1
[[ -e $RB/curl-called ]] && bad "provider install tried to overwrite an existing target" || ok "provider install refuses an existing target before download"

mkdir -p "$RB/home/.local/share/mise/installs/node/1/bin" "$RB/home/.local/share/mise/shims"
printf '#!/bin/sh\nexit 0\n' > "$RB/home/.local/share/mise/installs/node/1/bin/portless"
chmod 755 "$RB/home/.local/share/mise/installs/node/1/bin/portless"
ln -s /usr/bin/true "$RB/home/.local/share/mise/shims/portless"
resolved_portless=$(HOME="$RB/home" PATH="$RB/home/.local/share/mise/shims:/usr/bin:/bin" bash -c 'source "'"$S"'/tunnels.sh"; provider_bin portless')
is "provider resolution prefers a concrete version-manager binary over its shim" "$resolved_portless" "$RB/home/.local/share/mise/installs/node/1/bin/portless"

printf '#!/bin/bash\nexit 1\n' > "$RB/fake/ss"; chmod 755 "$RB/fake/ss"
scan_fail=$(PATH="$RB/fake:/usr/bin:/bin" "$S/scan-ports.sh")
is "a failed socket listing is an explicit scan error" "$(jq -r '.error // empty' <<<"$scan_fail")" "could not query listening sockets"
printf '#!/bin/sh\nprintf "%%s\\n" '\''{"version":1,"error":"more than 512 listening ports","ports":[]}'\''\n' > "$RB/scan-error"
chmod 700 "$RB/scan-error"
qmljs_scan_error=$(node "$S/lib/qmljs.mjs" decorate "$RB/scan-error" 2>&1); qmljs_scan_rc=$?
is "offline decoration propagates a scan error" \
  "$qmljs_scan_rc $(grep -c 'more than 512 listening ports' <<<"$qmljs_scan_error")" "1 1"

mkdir -p "$RB/shared/metrics" "$RB/shared-runtime"
: > "$RB/shared-runtime/server-3000.log"; : > "$RB/shared-runtime/.foreign.tmp"; : > "$RB/shared-runtime/ngrok.ok"
: > "$RB/shared/ca-import.pem"; : > "$RB/shared/watched.json"
plan=$(PORTAL_METRICS_DIR="$RB/shared" PORTAL_STATE_DIR="$RB/shared-runtime" "$S/uninstall.sh" --dry 2>/dev/null)
grep -qE 'server-3000|foreign' <<<"$plan" && bad "uninstall selected unrelated shared files" || ok "uninstall ignores unrelated shared files"
is "uninstall includes its exact transient files" "$(grep -Ec 'ngrok.ok|ca-import.pem' <<<"$plan")" "2"

echo; echo "$pass passed, $fail failed"
exit $((fail > 0))
