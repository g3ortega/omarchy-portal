#!/bin/bash
# Full portless setup, owned by Portal: audit every rung of the ladder, do all
# the unprivileged ones, and report exactly what (if anything) remains for a
# terminal with sudo. Never elevates by itself.
#
#   status  -> {"ok":true,"checks":{...},"remaining":[...]}
#   run     -> performs unprivileged fixes, then prints the same report
#
# The rungs:
#   installed      portless on PATH (fix: npm install -g portless — user-level)
#   ca             the user's own CA exists (minted by portless on first run)
#   proxy          serving on 443/80 with THIS user's routes (sudo — copy only)
#   trust_system   CA in the system store (portless trusts it during the
#                  elevated proxy start; reported, not forced)
#   trust_nss      CA in ~/.pki/nssdb — Chrome/Chromium/Brave read this,
#                  NOT the system store (fix: certutil import of the user's CA)
#   trust_firefox  CA in each Firefox profile's cert9.db (fix: certutil)
#
# Security: the only certificate ever imported is ~/.portless/ca.pem — the CA
# this user's own portless generated. Nothing is fetched, nothing elevates.
set -o pipefail

SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portless.sh
source "$SETUP_DIR/lib/portless.sh"
CA="$PORTLESS_DIR/ca.pem"
NSSDB="$HOME/.pki/nssdb"
NICK="portless Local CA"

have() { command -v "$1" >/dev/null 2>&1; }
have jq || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }

# The file at $CA is trusted browser-wide, so it must be what portless mints:
# a self-signed root whose subject is its own nickname. Anything else in that
# path (a swapped file, a different state dir) is not imported.
ca_is_portless() {
  own_file "$CA" || return 1
  (( $(stat -c %s -- "$CA") <= 16384 )) || return 1
  have openssl || return 1
  local subj issuer
  subj=$(openssl x509 -in "$CA" -noout -subject 2>/dev/null)
  issuer=$(openssl x509 -in "$CA" -noout -issuer 2>/dev/null)
  [[ $subj == *"CN=$NICK"* && $issuer == *"CN=$NICK"* ]] || return 1
  # The file is trusted browser-wide only when it is the CA behind the
  # certificate the live proxy actually presents: a replaced file that signs
  # nothing running here is never imported.
  portless_probe && [[ $PROBE_SCHEME == https ]] || return 1
  local leaf; leaf=$(mktemp) || return 1
  openssl s_client -connect "127.0.0.1:$PROBE_PORT" -servername "portal-probe.$(configured_tld)" </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > "$leaf" 2>/dev/null
  openssl verify -CAfile "$CA" "$leaf" >/dev/null 2>&1; local rc=$?
  rm -f -- "$leaf"
  return $rc
}

proxy_state() {  # echoes: ok | wrong-tld | odd-port | foreign | off
  if ! portless_probe; then echo off; return; fi
  if ! portless_serving_routes; then echo foreign; return; fi
  portless_clean_port || { echo odd-port; return; }
  # A proxy serves the TLD set it was started with; a newly configured suffix
  # is dead until a restart adds it, and the panel's strip already says so.
  portless_serves_tld "$(configured_tld)" || { echo wrong-tld; return; }
  echo ok
}

nss_trusted() {
  have certutil && [[ -d $NSSDB ]] \
    && certutil -d "sql:$NSSDB" -L 2>/dev/null | grep -q "$NICK"
}

firefox_profiles() {
  local d
  for d in "$HOME"/.mozilla/firefox/*/; do
    [[ -f "$d/cert9.db" || -f "$d/prefs.js" ]] && printf '%s\n' "${d%/}"
  done
}

firefox_untrusted() {
  have certutil || return 0
  firefox_profiles | while read -r d; do
    certutil -d "sql:$d" -L 2>/dev/null | grep -q "$NICK" || printf '%s\n' "$d"
  done
}

report() {
  local installed ca proxy nss ff_missing tldok remaining=()
  have portless && installed=true || installed=false
  [[ -f $CA ]] && ca=true || ca=false
  proxy=$(proxy_state)
  nss_trusted && nss=true || nss=false
  ff_missing=$(firefox_untrusted | wc -l)
  tld_resolves && tldok=true || tldok=false

  $installed || remaining+=("install portless: handled by 'run' (npm install -g portless)")
  if [[ $proxy == wrong-tld ]]; then
    remaining+=("restart the proxy so it serves .$(configured_tld) too: $(portless_fix_cmd)")
  elif [[ $proxy != ok ]]; then
    remaining+=("start the proxy on 443 (needs sudo once): $(portless_fix_cmd "$([[ $proxy == foreign ]] && echo evict)")")
  fi
  $ca || remaining+=("CA appears after the first proxy start")
  $tldok || remaining+=("wildcard-resolve .$(configured_tld) once (root, replaces per-name hosts syncs): $(tld_fix_cmd)")

  jq -nc --argjson installed "$installed" --argjson ca "$ca" --arg proxy "$proxy" \
        --argjson nss "$nss" --argjson ffMissing "${ff_missing:-0}" \
        --argjson tldResolves "$tldok" \
        --args '{ok:true, checks:{installed:$installed, ca:$ca, proxy:$proxy,
                 chromeTrust:$nss, firefoxProfilesUntrusted:$ffMissing,
                 tldResolves:$tldResolves},
                 remaining:$ARGS.positional}' "${remaining[@]}"
}

case "${1:-status}" in
  status) report ;;
  run)
    if ! have portless && have npm; then
      npm install -g portless >/dev/null 2>&1
    fi
    # A proxy missing the configured TLD is restarted only when that is
    # unprivileged (ours, on a high port); the 443 case stays in `remaining`
    # as a copyable command.
    if have portless && [[ $(proxy_state) == wrong-tld ]]; then
      portless_clean_port || portless proxy stop >/dev/null 2>&1
      portless_probe_reset
    fi
    # Proxy-start is an unprivileged rung like any other: when portless is
    # installed and nothing answers, start a high-port proxy so names work
    # immediately; the report keeps carrying the 443 upgrade.
    if have portless && [[ $(proxy_state) == off ]]; then
      portless proxy start -p "${PORTAL_PORTLESS_PORT:-1355}" \
        --tld "$(portless_tld_arg)" >/dev/null 2>&1
      sleep 1
      portless_probe_reset
    fi
    if ca_is_portless && have certutil; then
      if [[ ! -d $NSSDB ]]; then
        mkdir -p "$NSSDB" && certutil -d "sql:$NSSDB" -N --empty-password >/dev/null 2>&1
      fi
      nss_trusted || certutil -d "sql:$NSSDB" -A -t "C,," -n "$NICK" -i "$CA" >/dev/null 2>&1
      firefox_untrusted | while read -r d; do
        certutil -d "sql:$d" -A -t "C,," -n "$NICK" -i "$CA" >/dev/null 2>&1
      done
    fi
    report
    ;;
  *) echo '{"ok":false,"error":"usage: portless-setup.sh status|run"}' ;;
esac
