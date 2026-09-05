#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
state() { /usr/bin/python3 -I -S "$ROOT/scripts/lib/statedir.py" "$@"; }
state dump-existing "$T/missing/parents/bin" 0 4096 cloudflared | jq -e '.files == {} and .refused == []' >/dev/null
[[ ! -e $T/missing ]]
mkdir "$T/bin"
printf original > "$T/bin/cloudflared"
state dump-existing "$T/bin" 32 4096 cloudflared | jq -e '.files.cloudflared == "original"' >/dev/null
ln -s "$T/bin" "$T/link"
if state dump-existing "$T/link/missing" 32 4096 cloudflared > "$T/output" 2>/dev/null; then exit 1; fi
[[ ! -s $T/output && ! -e $T/bin/missing ]]
rm "$T/bin/cloudflared"
ln -s "$T/missing-file" "$T/bin/cloudflared"
state dump-existing "$T/bin" 32 4096 cloudflared | jq -e '.files == {} and .refused == ["cloudflared"]' >/dev/null
chmod 770 "$T/bin"
if state dump-existing "$T/bin" 32 4096 cloudflared > "$T/output" 2>/dev/null; then exit 1; fi
[[ ! -s $T/output ]]
echo 'ok read-only state snapshots distinguish absent directories from refused parents and leaves'
