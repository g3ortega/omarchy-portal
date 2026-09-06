#!/bin/bash
# Shared portless facts for tunnels.sh and portless-setup.sh: probing,
# route-serving verification, and the canonical fix commands.
# Source this; it defines functions and PROBE_PORT/PROBE_SCHEME globals.

PORTLESS_DIR="${PORTLESS_STATE_DIR:-$HOME/.portless}"
# shellcheck source=files.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/files.sh"

# The browser trust for portless's CA, shared by setup and removal.
CA="$PORTLESS_DIR/ca.pem"
NSSDB="$HOME/.pki/nssdb"
NICK="portless Local CA"
firefox_profiles() {
  local d
  for d in "$HOME"/.mozilla/firefox/*/; do
    [[ -f "$d/cert9.db" || -f "$d/prefs.js" ]] && printf '%s\n' "${d%/}"
  done
}

# portless's own state files, read in one descriptor-relative pass per
# command (owner-only rules, same as ours). Commands call portless_state_load
# once in the parent shell; a caller inside $(...) that finds nothing loaded
# loads for itself. Reload after anything that changes routes.
PORTLESS_STATE=""
PORTLESS_STATE_ERROR=""
portless_routes_valid() {
  /usr/bin/python3 -I -S -c '
import json
import re
import sys
from decimal import Decimal, InvalidOperation

CAP = 1048576
LABEL = re.compile(rb"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?").fullmatch
ONE = Decimal("1")
MAX_PORT = Decimal("65535")

def reject_constant(_value):
    raise ValueError

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result

def strict_loads(value):
    return json.loads(
        value,
        parse_int=Decimal,
        parse_float=Decimal,
        parse_constant=reject_constant,
        object_pairs_hook=unique_object,
        strict=True,
    )

def mathematical_integer(value):
    return type(value) is Decimal and value.is_finite() and value == value.to_integral_value()

def canonical_hostname(value):
    if type(value) is not str:
        return False
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError:
        return False
    return 1 <= len(encoded) <= 253 and all(
        1 <= len(label) <= 63 and LABEL(label) is not None
        for label in encoded.split(b".")
    )

def valid_routes(routes):
    if type(routes) is not list:
        return False
    hostnames = set()
    for route in routes:
        if type(route) is not dict:
            return False
        hostname = route.get("hostname")
        port = route.get("port")
        pid = route.get("pid")
        if not canonical_hostname(hostname) or hostname in hostnames:
            return False
        if not mathematical_integer(port) or not ONE <= port <= MAX_PORT:
            return False
        if not mathematical_integer(pid) or pid.is_signed() and not pid.is_zero():
            return False
        hostnames.add(hostname)
    return True

try:
    snapshot = strict_loads(sys.stdin.buffer.read().decode("utf-8"))
    if type(snapshot) is not dict or type(snapshot.get("files")) is not dict:
        raise ValueError
    if "routes.json" not in snapshot["files"]:
        raise SystemExit(0)
    document = snapshot["files"]["routes.json"]
    if type(document) is not str or len(document.encode("utf-8")) > CAP:
        raise ValueError
    routes = strict_loads(document)
except (InvalidOperation, UnicodeDecodeError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if valid_routes(routes) else 1)
'
}
# Returns nonzero when the read was refused (for example the directory is over
# its entry cap), so a caller can tell "refused" from "empty" instead of acting
# as if every route vanished.
portless_state_load() {
  local snapshot
  PORTLESS_STATE=""
  PORTLESS_STATE_ERROR=""
  if [[ ! -e $PORTLESS_DIR && ! -L $PORTLESS_DIR ]]; then
    PORTLESS_STATE='{"files":{},"refused":[]}'
    return 0
  fi
  snapshot=$(state dump "$PORTLESS_DIR" 1048576 512 routes.json proxy.port proxy.tlds proxy.tld 2>/dev/null) \
    || { PORTLESS_STATE_ERROR="state directory refused"; return 1; }
  jq -e '(.files | type == "object") and ((.refused // []) | length == 0)' <<<"$snapshot" >/dev/null 2>&1 \
    || { PORTLESS_STATE_ERROR="requested state leaf refused"; return 1; }
  portless_routes_valid < <(printf '%s' "$snapshot") >/dev/null 2>&1 \
    || { PORTLESS_STATE_ERROR="routes.json is malformed"; return 1; }
  PORTLESS_STATE=$snapshot
  return 0
}
portless_file() {  # <name>: contents, or empty
  [[ -n $PORTLESS_STATE ]] || portless_state_load || return 1
  jq -r --arg n "$1" '.files[$n] // empty' <<<"$PORTLESS_STATE"
}
routes_json() { portless_file routes.json; }

# Probe for a live proxy instead of trusting state files: pidfiles go stale,
# kill -0 answers EPERM (not "running") for a root-owned proxy, and the
# recorded port can belong to a previous run. portless stamps every response
# with `x-portless: 1`, which makes the probe exact.
PROBE_PORT=""
PROBE_SCHEME=""
portless_probe_reset() { PROBE_PORT=""; PROBE_SCHEME=""; }
portless_listener_scope() {  # <proxy port> [socket snapshot]: local|lan|unknown
  local port sockets
  port=$(canonical_port "$1") || { echo unknown; return; }
  if (( $# > 1 )); then sockets=$2
  else sockets=$(ss -tlnH "sport = :$port" 2>/dev/null) || { echo unknown; return; }
  fi
  printf '%s' "$sockets" | /usr/bin/python3 -I -S -c '
import ipaddress, sys
found = lan = malformed = False
for row in sys.stdin:
    fields = row.split()
    if len(fields) < 5:
        malformed = True
        continue
    host, separator, port = fields[3].rpartition(":")
    if not separator or not port.isdecimal():
        malformed = True
        continue
    if int(port) != int(sys.argv[1]):
        continue
    found = True
    if host == "*":
        lan = True
        continue
    try:
        address = ipaddress.ip_address(host.strip("[]"))
        address = getattr(address, "ipv4_mapped", None) or address
        lan |= not address.is_loopback
    except ValueError:
        malformed = True
print("lan" if lan else "local" if found and not malformed else "unknown")
' "$port" || echo unknown
}
portless_proxy_scope() {  # [socket snapshot]: local|lan|unknown, including an unresponsive proxy
  local sockets recorded candidates=" 443 80 1355 " endpoint port
  if (( $# )); then sockets=$1
  else sockets=$(ss -tlnH 2>/dev/null) || { echo unknown; return; }
  fi
  if portless_probe; then
    portless_listener_scope "$PROBE_PORT" "$sockets"
    return
  fi
  recorded=$(canonical_port "$(portless_file proxy.port | head -n 1)") && candidates+="$recorded "
  while read -r _ _ _ endpoint _; do
    [[ -n $endpoint ]] || { [[ -z $sockets ]] && break; echo unknown; return; }
    port=${endpoint##*:}
    [[ $port =~ ^[0-9]+$ ]] || { echo unknown; return; }
    [[ $candidates != *" $port "* ]] || { echo unknown; return; }
  done <<<"$sockets"
  echo local
}
portless_probe() {
  [[ -n $PROBE_PORT ]] && return 0
  local cand p seen=" "
  cand="$(portless_file proxy.port | head -n 1) 443 80"
  for p in $cand; do
    [[ $p =~ ^[0-9]+$ ]] || continue
    [[ $seen == *" $p "* ]] && continue
    seen+="$p "
    local scheme
    for scheme in https http; do
      if curl -q -sk --max-time 0.4 --max-redirs 0 -o /dev/null -D - "$scheme://127.0.0.1:$p/" 2>/dev/null \
           | head -c 16384 | grep -qi '^x-portless:'; then
        PROBE_PORT="$p"; PROBE_SCHEME="$scheme"
        return 0
      fi
    done
  done
  return 1
}

# Does the live proxy serve THIS user's routes? A proxy started from another
# state directory (typically root's) answers portless's own branded 404 for
# them. Served responses carry x-portless too, and a backend may honestly 404
# "/" — so only the branded 404 body means "route unknown".
portless_serving_routes() {
  local first
  first=$(routes_json | jq -r '.[0].hostname // empty' 2>/dev/null)
  [[ -n $first ]] || return 0   # nothing registered: nothing to disprove
  valid_tld "$first" || return 0
  local code
  code=$(curl -q -sk --max-time 0.6 --max-redirs 0 -o /dev/null -w '%{http_code}' \
    --resolve "$first:$PROBE_PORT:127.0.0.1" \
    "$PROBE_SCHEME://$first:$PROBE_PORT/" 2>/dev/null)
  [[ $code == 404 ]] || return 0
  curl -q -sk --max-time 0.6 --max-redirs 0 --max-filesize 4096 \
    --resolve "$first:$PROBE_PORT:127.0.0.1" \
    "$PROBE_SCHEME://$first:$PROBE_PORT/" 2>/dev/null | head -c 4096 \
    | grep -qi portless && return 1
  return 0
}

# The TLD the user configured. A function, not a captured value: tunnels.sh
# exports PORTAL_PORTLESS_TLD after sourcing this file.
# portless's own rule for a TLD: lowercase DNS labels with dots between them.
# Every TLD that reaches a command line passes through this, because TLDs are
# read from shell.json and from portless's own state files, and both are
# interpolated into commands the user is invited to paste into a root shell.
valid_tld() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]; }

configured_tld() {
  local raw="${PORTAL_PORTLESS_TLD:-localhost}"
  raw="${raw,,}"; raw="${raw// /}"
  valid_tld "$raw" || raw=localhost
  printf '%s' "$raw"
}

# The bare name portless holds for a port, if any.
portless_route_name() {  # <port>
  local n port tld suffix=""
  port=$(canonical_port "${1:-}") || return 1
  n=$(routes_json | jq -r --argjson p "$port" 'first(.[] | select(.port == $p) | .hostname) // empty' 2>/dev/null) || return 1
  [[ -n $n ]] || return 0
  while read -r tld || [[ -n $tld ]]; do
    [[ $n == *".$tld" && ${#tld} -gt ${#suffix} ]] && suffix=$tld
  done < <(portless_tld_arg | tr ',' '\n')
  [[ -n $suffix ]] || return 1
  printf '%s' "${n%.$suffix}"
}

portless_alias_routes() {  # <name>: every matching hostname under the configured suffixes
  local name=${1,,} tlds
  valid_tld "$name" || return 1
  tlds=$(portless_tld_arg) || return 1
  routes_json | jq -c --arg n "$name" --arg tlds "$tlds" \
    '[.[] | select(.hostname as $h | any($tlds | split(",")[]; $h == ($n + "." + .)))]'
}

portless_alias_safe() {  # <name> <port>: unclaimed or static aliases for this port only
  local routes port
  port=$(canonical_port "$2") || return 1
  routes=$(portless_alias_routes "$1") || return 1
  jq -e --argjson p "$port" 'all(.[]; .pid == 0 and .port == $p)' <<<"$routes" >/dev/null
}

portless_managed_port() {  # <port>
  local port
  port=$(canonical_port "$1") || return 1
  routes_json | jq -e --argjson p "$port" 'any(.[]; .port == $p and .pid != 0)' >/dev/null
}

# The URL portless serves for an already-assembled hostname. Scheme and port
# depend on how the proxy was started, so neither can be assumed.
# A proxy on a standard port gives clean URLs; any other port rides in them.
portless_clean_port() { [[ $PROBE_PORT == 443 || $PROBE_PORT == 80 ]]; }
portless_serves_tld() { portless_running_tlds | grep -qxF -- "$1"; }

portless_host_url() {  # <fqdn>
  portless_probe || return 0
  if portless_clean_port; then
    printf '%s://%s' "$PROBE_SCHEME" "$1"
  else
    printf '%s://%s:%s' "$PROBE_SCHEME" "$1" "$PROBE_PORT"
  fi
}

# The TLD list a proxy start should carry: the configured suffix first (so
# portless makes it primary), everything the live proxy already serves, and
# always .localhost (zero-setup, never worth breaking).
portless_tld_arg() {
  local want out t
  want=$(configured_tld)
  # First, so portless makes it primary (tlds[0]) — the TLD new names land on.
  out="$want"
  # Then everything the live proxy serves, so a restart adds rather than
  # replaces: portless REPLACES its TLD set on an explicit --tld.
  while read -r t; do
    [[ -n $t && $t != "$want" && ",$out," != *",$t,"* ]] && out+=",$t"
  done < <(portless_running_tlds)
  # localhost is free and zero-setup; never drop it.
  [[ ",$out," == *",localhost,"* ]] || out+=",localhost"
  printf '%s' "$out"
}

# The TLD set the LIVE proxy serves: proxy.tlds (JSON array or comma/line
# list), the legacy proxy.tld, else the built-in localhost default.
portless_running_tlds() {
  local raw t
  {
    if raw=$(portless_file proxy.tlds) && [[ -n $raw ]]; then
      if [[ $raw == \[* ]]; then jq -r '.[]' <<<"$raw" 2>/dev/null; else tr ',' '\n' <<<"$raw"; fi
    elif raw=$(portless_file proxy.tld) && [[ -n $raw ]]; then
      printf '%s\n' "$raw"
    else
      echo localhost
    fi
  } | tr -d ' \t' | while IFS= read -r t || [[ -n $t ]]; do   # last line may lack a newline
    valid_tld "$t" && printf '%s\n' "$t"
  done
}

# Explicit proxy repair preserves the current port when provided. Portless
# hard-checks uid before binding a port under 1024 and
# self-elevates through `sudo env`, forwarding every PORTLESS_* variable;
# PORTLESS_STATE_DIR overrides state resolution outright. `sudo portless` is
# never used: version-managed installs are not on root's PATH; eviction goes
# through fuser by port number.
portless_fix_cmd() {  # [evict] [port]
  local stop="portless proxy stop" port skip_trust=""
  port=$(canonical_port "${2:-443}") || return 1
  (( port >= 1024 )) && skip_trust=" --skip-trust"
  [[ ${1:-} == evict ]] && stop="sudo fuser -k $port/tcp; sleep 1"
  printf '%s; PORTLESS_LAN=0 PORTLESS_LAN_IP= PORTLESS_STATE_DIR="$HOME/.portless" portless proxy start -p %s%s --tld %s' \
    "$stop" "$port" "$skip_trust" "$(portless_tld_arg)"
}

# Wildcard resolution for the configured TLD. .localhost needs nothing —
# browsers and systemd-resolved both hardwire it to loopback. Any other TLD
# resolves per-name via /etc/hosts (no wildcards possible there) unless a
# wildcard resolver answers; the probe uses a random name so one hosts entry
# cannot fake a pass.
tld_resolves() {
  local tld; tld=$(configured_tld)
  [[ $tld == localhost ]] && return 0
  getent hosts "portal-probe-$RANDOM.$tld" >/dev/null 2>&1
}

# One-time root recipe: dnsmasq answering only the custom TLD on a loopback
# alias, with systemd-resolved routing that domain to it. Ends per-name hosts
# syncing forever.
tld_fix_cmd() {
  local tld; tld=$(configured_tld)
  # \\n, not \n: these belong to the inner printf that writes the config file.
  # Expanding them here would put real newlines in a value the status protocol
  # carries on one pipe-delimited line, and the copied command would be cut
  # off mid-quote.
  printf 'sudo pacman -S --needed dnsmasq && printf "listen-address=127.0.0.2\\nbind-interfaces\\naddress=/%s/127.0.0.1\\n" | sudo tee /etc/dnsmasq.d/portless-%s.conf && sudo systemctl enable --now dnsmasq && sudo mkdir -p /etc/systemd/resolved.conf.d && printf "[Resolve]\\nDNS=127.0.0.2\\nDomains=~%s\\n" | sudo tee /etc/systemd/resolved.conf.d/portless-%s.conf && sudo systemctl restart systemd-resolved' \
    "$tld" "$tld" "$tld" "$tld"
}
