#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/app/lib" "$T/state"
cp "$ROOT/scripts/lifecycle.sh" "$T/app/lifecycle.sh"
export REAL_FILES="$ROOT/scripts/lib/files.sh" PORTAL_STATE_DIR="$T/state" CASE_ROOT="$T"
cat > "$T/app/lib/files.sh" <<'LIB'
source "$REAL_FILES"
lifecycle_mutation() { :; }
ss() { [[ ${SS_FAIL:-0} == 0 ]] || return 1; printf '%s\n' "$SOCKETS"; }
proc() { if [[ $1 == signal ]]; then printf '%s\n' "$*" >> "$CASE_ROOT/signals"; fi; }
kill() { printf '%s\n' "$*" >> "$CASE_ROOT/forbidden"; return 99; }
LIB
single='LISTEN 0 128 127.0.0.1:3000 0.0.0.0:* users:(("app",pid=999999,fd=3))'
shared='LISTEN 0 128 127.0.0.1:3000 0.0.0.0:* users:(("app",pid=999999,fd=3),("worker",pid=999998,fd=3))'
foreign='LISTEN 0 128 [::1]:3000 [::]:* users:(("worker",pid=999998,fd=4))'
unattributed='LISTEN 0 128 [::1]:3000 [::]:*'
for sockets in "$shared" "$single"$'\n'"$foreign" "$single"$'\n'"$unattributed" "$unattributed" ''; do
  for action in pause resume stop restart; do
    out=$(SOCKETS="$sockets" bash "$T/app/lifecycle.sh" "$action" 999999 1 3000 /tmp '["/usr/bin/false"]')
    jq -e '.ok == false' <<<"$out" >/dev/null
    [[ ! -e $T/signals && ! -e $T/forbidden ]]
  done
done
echo 'ok shared and unattributed listeners reject every lifecycle action before signals'
for action in pause resume stop; do
  out=$(SOCKETS="$single"$'\n'"$single" bash "$T/app/lifecycle.sh" "$action" 999999 1 3000)
  jq -e '.ok == true' <<<"$out" >/dev/null
done
[[ $(wc -l < "$T/signals") == 3 ]]
rm "$T/signals"
echo 'ok repeated socket rows from one PID keep lifecycle actions available'
for identity in '1 1' '0 0' '-1 1' '999999999999999999999 1' '999999 nope' ''; do
  read -r pid start <<<"$identity" || :
  out=$(SOCKETS="$single" bash "$T/app/lifecycle.sh" stop "${pid:-}" "${start:-}" 3000)
  jq -e '.ok == false' <<<"$out" >/dev/null
  [[ ! -e $T/signals && ! -e $T/forbidden ]]
done
out=$(SS_FAIL=1 SOCKETS="$single" bash "$T/app/lifecycle.sh" stop 999999 1 3000)
jq -e '.ok == false and (.error | contains("query"))' <<<"$out" >/dev/null
[[ ! -e $T/signals && ! -e $T/forbidden ]]
echo 'ok invalid identities and socket-query failure never reach signals'
