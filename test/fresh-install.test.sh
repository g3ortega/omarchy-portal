#!/bin/bash
set -eo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
export ROOT FIXTURE
for mask in {0..7}; do
  export CASE="$FIXTURE/$mask" MASK=$mask
  mkdir -p "$CASE/bin" "$CASE/home"
  for pair in portless:1 cloudflared:2 ngrok:4; do
    name=${pair%:*}; bit=${pair#*:}
    if (( mask & bit )); then
      cat > "$CASE/bin/$name" <<'BIN'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >> "$CASE/calls"
[[ ${0##*/} == ngrok && $* == 'config check' ]]
BIN
      chmod 700 "$CASE/bin/$name"
    fi
  done
  HOME="$CASE/home" PORTAL_STATE_DIR="$CASE/runtime" PORTAL_METRICS_DIR="$CASE/state" \
    PORTLESS_STATE_DIR="$CASE/portless" bash <<'CASE'
set -eo pipefail
source "$ROOT/scripts/tunnels.sh" >/dev/null
augment_path() { :; }
command() {
  if [[ ${1:-} == -v && ${2:-} == -- && ${3:-} =~ ^(portless|cloudflared|ngrok)$ ]]; then
    [[ -x $CASE/bin/$3 ]] || return 1
    printf '%s\n' "$CASE/bin/$3"
  else builtin command "$@"; fi
}
curl() { return 1; }
ss() { return 0; }
sudo() { echo sudo >> "$CASE/calls"; return 99; }
result=$(cmd_providers)
jq -e --argjson mask "$MASK" '
  .ok and (.providers|length == 3) and
  ([.providers[] | . as $p |
    (if .id == "portless" then 1 elif .id == "cloudflared" then 2 else 4 end) as $bit |
    .available == (($mask / $bit | floor) % 2 == 1)] | all) and
  ([.providers[] | if .id == "portless" then .status == "setup"
    elif .available then .status == "ready"
    elif .id == "cloudflared" then .status == "setup" else .status == "missing" end] | all)
' <<<"$result" >/dev/null
if [[ -f $CASE/calls ]]; then
  [[ $(sort -u "$CASE/calls") == 'ngrok config check' ]]
fi
[[ ! -e $HOME/.local/bin && ! -e $PORTAL_METRICS_DIR/installed-cloudflared ]]
"$ROOT/scripts/metrics.sh" stats | jq -e '.ok' >/dev/null
"$ROOT/scripts/metrics.sh" watched | jq -e '.ok and .ports == []' >/dev/null
# Installed tools remain available when a separate state snapshot is refused.
portless_state_load() { return 1; }
cmd_providers | jq -e --argjson mask "$MASK" '
  .providers[] | select(.id == "portless") |
  .status == "unavailable" and .available == ($mask % 2 == 1)' >/dev/null
if [[ -x $CASE/bin/portless ]]; then
  chmod 777 "$CASE/bin/portless"
  cmd_providers | jq -e '.providers[] | select(.id == "portless") | .available == false' >/dev/null
fi
CASE
  echo "PASS fresh provider availability combination $mask"
done
