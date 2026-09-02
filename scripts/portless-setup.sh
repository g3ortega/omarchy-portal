#!/bin/bash
# Full portless setup, owned by Portal: audit every rung of the ladder, do all
# the unprivileged ones, and report exactly what (if anything) remains for a
# terminal with sudo. Never elevates by itself.
#
#   status  -> {"ok":true,"checks":{...},"remaining":[...]}
#   run     -> performs unprivileged fixes, then prints the same report
#   untrust -> removes the CA from the browser stores it was imported into
#
# The rungs:
#   installed      portless on PATH (the npm install is a copyable command;
#                  the plugin never runs a package manager)
#   ca             the user's own CA exists (minted by portless on first run)
#   proxy          serving on 443/80 with THIS user's routes (sudo — copy only)
#   trust_system   CA in the system store (portless trusts it during the
#                  elevated proxy start; reported, not forced)
#   trust_nss      CA in ~/.pki/nssdb — Chrome/Chromium/Brave read this,
#                  NOT the system store (fix: certutil import of the user's CA)
#   trust_firefox  CA in each Firefox profile's cert9.db (fix: certutil)
#
# Security: the only certificate ever imported is ~/.portless/ca.pem — the CA
# this user's own portless generated, read once through the state helper and
# verified against the live proxy. Nothing is fetched, nothing is installed,
# nothing elevates.
set -o pipefail

SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portless.sh
source "$SETUP_DIR/lib/portless.sh"

have() { command -v "$1" >/dev/null 2>&1; }
have jq || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }

# The file at $CA is trusted browser-wide, so it must be what portless mints:
# a self-signed root whose subject is its own nickname. Anything else in that
# path (a swapped file, a different state dir) is not imported.
# The CA bytes, read once through the state helper; reloaded after a proxy
# start, which is what mints the file the first time.
CA_PEM=""
ca_load() { CA_PEM=$(cat_own "$CA" 16384); }
ca_load
# Stores Portal imported into, so removal touches nothing it did not add.
TRUSTED="$PORTAL_STATE_HOME/trusted-stores"
ca_is_portless() {
  [[ -n $CA_PEM ]] || return 1
  have openssl || return 1
  local subj issuer
  subj=$(openssl x509 -noout -subject <<<"$CA_PEM" 2>/dev/null)
  issuer=$(openssl x509 -noout -issuer <<<"$CA_PEM" 2>/dev/null)
  [[ $subj == *"CN=$NICK"* && $issuer == *"CN=$NICK"* ]] || return 1
  # The file is trusted browser-wide only when it is the CA behind the
  # certificate the live proxy actually presents: a replaced file that signs
  # nothing running here is never imported.
  portless_probe && [[ $PROBE_SCHEME == https ]] || return 1
  local leaf; leaf=$(mktemp) || return 1
  openssl s_client -connect "127.0.0.1:$PROBE_PORT" -servername "portal-probe.$(configured_tld)" </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > "$leaf" 2>/dev/null
  openssl verify -CAfile <(printf '%s' "$CA_PEM") "$leaf" >/dev/null 2>&1; local rc=$?
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

firefox_untrusted() {
  have certutil || return 0
  firefox_profiles | while read -r d; do
    certutil -d "sql:$d" -L 2>/dev/null | grep -q "$NICK" || printf '%s\n' "$d"
  done
}

report() {
  local installed ca proxy nss ff_missing tldok remaining=()
  have portless && installed=true || installed=false
  [[ -n $CA_PEM ]] && ca=true || ca=false
  proxy=$(proxy_state)
  nss_trusted && nss=true || nss=false
  ff_missing=$(firefox_untrusted | wc -l)
  tld_resolves && tldok=true || tldok=false

  $installed || remaining+=("install portless: npm install -g portless")
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

portless_state_load
case "${1:-status}" in
  status) report ;;
  run)
    # A proxy missing the configured TLD is restarted only when that is
    # unprivileged (ours, on a high port); the 443 case stays in `remaining`
    # as a copyable command.
    PORTLESS=$(resolve_bin portless)
    if [[ -n $PORTLESS ]] && [[ $(proxy_state) == wrong-tld ]]; then
      portless_clean_port || "$PORTLESS" proxy stop >/dev/null 2>&1
      portless_probe_reset
    fi
    # Proxy-start is an unprivileged rung like any other: when portless is
    # installed and nothing answers, start a high-port proxy so names work
    # immediately; the report keeps carrying the 443 upgrade.
    if [[ -n $PORTLESS ]] && [[ $(proxy_state) == off ]]; then
      "$PORTLESS" proxy start -p "${PORTAL_PORTLESS_PORT:-1355}" \
        --tld "$(portless_tld_arg)" >/dev/null 2>&1
      sleep 1
      portless_state_load; portless_probe_reset; ca_load   # the proxy just wrote its port and minted the CA
    fi
    if ca_is_portless && have certutil; then
      if [[ ! -d $NSSDB ]]; then
        own_dir "$NSSDB" && certutil -d "sql:$NSSDB" -N --empty-password >/dev/null 2>&1
      fi
      nss_trusted || { certutil -d "sql:$NSSDB" -A -t "C,," -n "$NICK" -i <(printf '%s' "$CA_PEM") >/dev/null 2>&1 \
        && printf '%s\n' "$NSSDB" | state_append "$TRUSTED" 64; }
      firefox_untrusted | while read -r d; do
        certutil -d "sql:$d" -A -t "C,," -n "$NICK" -i <(printf '%s' "$CA_PEM") >/dev/null 2>&1 \
          && printf '%s\n' "$d" | state_append "$TRUSTED" 64
      done
    fi
    report
    ;;
  untrust)
    # Only the stores Portal itself imported into; trust the user set up
    # before Portal stays. A store is forgotten only once the certificate is
    # gone from it; what could not be removed stays on record and is reported.
    # certutil -D can report success without deleting (a store whose directory
    # is not writable), so the listing afterwards is what decides.
    left=()
    while read -r d; do
      [[ -n $d && -d $d ]] || continue          # a store that is gone holds nothing
      have certutil || { left+=("$d"); continue; }
      certutil -d "sql:$d" -D -n "$NICK" >/dev/null 2>&1
      certutil -d "sql:$d" -L -n "$NICK" >/dev/null 2>&1 && left+=("$d")
    done < <(cat_own "$TRUSTED" 4096)
    if (( ${#left[@]} )); then
      printf '%s\n' "${left[@]}" | state write "$TRUSTED"
      jq -nc --args '{ok:false, error:"the CA is still trusted in some stores", remaining:$ARGS.positional}' "${left[@]}"
    else
      state_remove "${TRUSTED%/*}" "${TRUSTED##*/}"
      echo '{"ok":true}'
    fi
    ;;
  *) echo '{"ok":false,"error":"usage: portless-setup.sh status|run|untrust"}' ;;
esac
