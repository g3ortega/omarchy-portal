#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export PORTAL_METRICS_DIR="$T/state"
mkdir -p "$PORTAL_METRICS_DIR/metrics"
read_metrics() { bash "$ROOT/scripts/metrics.sh" read 3307; }
file="$PORTAL_METRICS_DIR/metrics/3307.jsonl"
read_metrics | jq -e '.ok == true and .samples == []' >/dev/null
printf '%s\n' '{"t":1,"rssKb":100}' '{torn' '{"t":2,"rssKb":101}' > "$file"
read_metrics | jq -e '.ok == true and .samples == [{t:1,rssKb:100},{t:2,rssKb:101}]' >/dev/null
: > "$file"
read_metrics | jq -e '.ok == true and .samples == []' >/dev/null
rm "$file"
echo 'ok absent and empty history are empty; valid samples survive torn lines'
for kind in symlink broken-symlink directory unreadable oversized; do
  case $kind in
    symlink) printf 'PRIVATE_HISTORY_SENTINEL' > "$T/secret"; ln -s "$T/secret" "$file" ;;
    broken-symlink) ln -s "$T/missing" "$file" ;;
    directory) mkdir "$file" ;;
    unreadable) printf 'PRIVATE_HISTORY_SENTINEL' > "$file"; chmod 000 "$file" ;;
    oversized) python3 - "$file" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'PRIVATE_HISTORY_SENTINEL'+b'x'*2097152)
PY
      ;;
  esac
  out=$(read_metrics 2> "$T/stderr")
  jq -e '.ok == false and (.error | type == "string") and (has("samples") | not)' <<<"$out" >/dev/null
  [[ $out != *PRIVATE_HISTORY_SENTINEL* && ! -s $T/stderr ]]
  if [[ $kind == directory ]]; then rmdir "$file"; else rm "$file"; fi
done
echo 'ok symlink, dangling link, directory, unreadable and oversized history fail without leaking content'
