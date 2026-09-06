#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export PORTAL_METRICS_DIR="$T/state"
read_metrics() { bash "$ROOT/scripts/metrics.sh" query 3307 1800 "$(date +%s)"; }
read_metrics | jq -e '.ok == true and .view.count == 0' >/dev/null
now=$(date +%s)
bash "$ROOT/scripts/metrics.sh" append-batch "{\"3307\":{\"t\":$now,\"rssKb\":100}}" | jq -e '.ok' >/dev/null
bash "$ROOT/scripts/metrics.sh" append-batch "{\"3307\":{\"t\":$now,\"rssKb\":101}}" | jq -e '.ok' >/dev/null
read_metrics | jq -e '.ok == true and .view.count == 2 and .view.stats.rssKb == {lo:100,hi:101}' >/dev/null
echo 'ok absent history is empty and native samples remain readable'
for kind in symlink broken-symlink directory unreadable oversized; do
  export PORTAL_METRICS_DIR="$T/$kind"
  mkdir -p "$PORTAL_METRICS_DIR/metrics/store"
  chmod 700 "$PORTAL_METRICS_DIR/metrics/store"
  file="$PORTAL_METRICS_DIR/metrics/store/metrics.db"
  case $kind in
    symlink) printf 'PRIVATE_HISTORY_SENTINEL' > "$T/secret"; ln -s "$T/secret" "$file" ;;
    broken-symlink) ln -s "$T/missing" "$file" ;;
    directory) mkdir "$file" ;;
    unreadable) printf 'PRIVATE_HISTORY_SENTINEL' > "$file"; chmod 000 "$file" ;;
    oversized) printf 'PRIVATE_HISTORY_SENTINEL' > "$file"; truncate -s 1073741825 "$file"; chmod 600 "$file" ;;
  esac
  out=$(read_metrics 2> "$T/stderr")
  jq -e '.ok == false and (.error | type == "string") and (has("view") | not)' <<<"$out" >/dev/null
  [[ $out != *PRIVATE_HISTORY_SENTINEL* && ! -s $T/stderr ]]
  if [[ $kind == directory ]]; then rmdir "$file"; else rm "$file"; fi
done
echo 'ok symlink, dangling link, directory, unreadable and oversized databases fail without leaking content'
