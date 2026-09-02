#!/bin/bash
# Shared portless facts for tunnels.sh and portless-setup.sh: probing,
# route-serving verification, and the canonical fix commands.
# Source this; it defines functions and PROBE_PORT/PROBE_SCHEME globals.

PORTLESS_DIR="${PORTLESS_STATE_DIR:-$HOME/.portless}"
# shellcheck source=files.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/files.sh"
# portless's own state is read with the same owner-only rules as ours.
routes_json() { cat_own "$PORTLESS_DIR/routes.json" 1048576; }

# Probe for a live proxy instead of trusting state files: pidfiles go stale,
# kill -0 answers EPERM (not "running") for a root-owned proxy, and the
# recorded port can belong to a previous run. portless stamps every response
# with `x-portless: 1`, which makes the probe exact.
PROBE_PORT=""
PROBE_SCHEME=""
portless_probe_reset() { PROBE_PORT=""; PROBE_SCHEME=""; }
portless_probe() {
  [[ -n $PROBE_PORT ]] && return 0
  local cand p seen=" " saved=""
  saved=$(read_own "$PORTLESS_DIR/proxy.port" 64)
  cand="$saved 443 80"
  for p in $cand; do
    [[ $p =~ ^[0-9]+$ ]] || continue
    [[ $seen == *" $p "* ]] && continue
    seen+="$p "
    local scheme
    for scheme in https http; do
      if curl -sk --max-time 0.4 -o /dev/null -D - "$scheme://127.0.0.1:$p/" 2>/dev/null \
           | grep -qi '^x-portless:'; then
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
  code=$(curl -sk --max-time 0.6 -o /dev/null -w '%{http_code}' \
    --resolve "$first:$PROBE_PORT:127.0.0.1" \
    "$PROBE_SCHEME://$first:$PROBE_PORT/" 2>/dev/null)
  [[ $code == 404 ]] || return 0
  curl -sk --max-time 0.6 \
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
  local n
  n=$(routes_json | jq -r --argjson p "$1" 'first(.[] | select(.port == $p) | .hostname) // empty' 2>/dev/null)
  printf '%s' "${n%%.*}"
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
  local f="$PORTLESS_DIR/proxy.tlds" t
  {
    if own_file "$f" && [[ -s $f ]]; then
      if [[ $(head -c1 -- "$f") == "[" ]]; then cat_own "$f" 4096 | jq -r '.[]' 2>/dev/null
      else cat_own "$f" 4096 | tr ',' '\n'; fi
    elif own_file "$PORTLESS_DIR/proxy.tld" && [[ -s "$PORTLESS_DIR/proxy.tld" ]]; then
      cat_own "$PORTLESS_DIR/proxy.tld" 4096
    else
      echo localhost
    fi
  } | tr -d ' \t' | while IFS= read -r t || [[ -n $t ]]; do   # last line may lack a newline
    valid_tld "$t" && printf '%s\n' "$t"
  done
}

# The command that reaches the end state: portless on 443, serving THIS user's
# routes. portless hard-checks uid before binding a port under 1024 and
# self-elevates through `sudo env`, forwarding every PORTLESS_* variable;
# PORTLESS_STATE_DIR overrides state resolution outright. `sudo portless` is
# never used: version-managed installs are not on root's PATH; eviction goes
# through fuser by port number.
portless_fix_cmd() {  # $1 = "evict" when another proxy owns the port
  local stop="portless proxy stop"
  [[ ${1:-} == evict ]] && stop="sudo fuser -k 443/tcp; sleep 1"
  printf '%s; PORTLESS_STATE_DIR="$HOME/.portless" portless proxy start -p 443 --tld %s' \
    "$stop" "$(portless_tld_arg)"
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
