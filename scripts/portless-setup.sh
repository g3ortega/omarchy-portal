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
#   proxy          serving this user's routes on any port
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
die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
have jq || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }

case "${1:-status}" in
  run|untrust)
    lifecycle_mutation nowait /usr/bin/bash "$SETUP_DIR/portless-setup.sh" "$@"
    ;;
esac

# The file at $CA is trusted browser-wide, so it must be what portless mints:
# a self-signed root whose subject is its own nickname. Anything else in that
# path (a swapped file, a different state dir) is not imported.
# The CA bytes, read once through the state helper; reloaded after a proxy
# start, which is what mints the file the first time.
CA_PEM=""
ca_load() { CA_PEM=$(cat_own "$CA" 16384); }
ca_load
# Stores Portal imported into, so removal touches nothing it did not add.
# Written and read under the same cap, so a record that could be made can be
# read back.
TRUSTED="$PORTAL_STATE_HOME/trusted-stores"
TRUSTED_CAP=65536
MAX_TRUSTED_STORES=512
valid_trust_ledger() {
  local record="$1" line store fp count=0
  [[ -n $record ]] || return 1
  while IFS= read -r line; do
    [[ $line == *$'\t'* && ${line#*$'\t'} != *$'\t'* ]] || return 1
    store=${line%%$'\t'*}; fp=${line#*$'\t'}
    [[ $store == /* && $store != *[[:cntrl:]]* && $fp =~ ^[0-9A-F]{64}$ ]] || return 1
    (( ++count <= MAX_TRUSTED_STORES )) || return 1
  done <<<"$record"
  return 0
}
# Import into one store and record it; a trust that could not be recorded is
# undone at once, since removal would never find it. certutil sizes its input
# with stat, so the verified bytes go through a file: one written by the state
# helper inside Portal's own directory, where nothing else can swap it.
# The SHA-256 fingerprint of a PEM certificate, uppercase hex, no colons.
ca_fingerprint() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g'; }
write_trust_record() {  # <store> <fingerprint> <current ledger>
  local store="$1" fp="$2" current="$3" d oldfp rows=()
  while IFS=$'\t' read -r d oldfp; do
    [[ -n $d && $d != "$store" ]] && rows+=("$d"$'\t'"$oldfp")
  done <<<"$current"
  (( ${#rows[@]} < MAX_TRUSTED_STORES )) || return 1
  rows+=("$store"$'\t'"$fp")
  printf '%s\n' "${rows[@]}" | state write "$TRUSTED"
}
drop_trust_record() {  # <store>
  local store="$1" current d fp rows=()
  current=$(cat_own "$TRUSTED" "$TRUSTED_CAP") || return 1
  valid_trust_ledger "$current" || return 1
  while IFS=$'\t' read -r d fp; do
    [[ -n $d && $d != "$store" ]] && rows+=("$d"$'\t'"$fp")
  done <<<"$current"
  if (( ${#rows[@]} )); then printf '%s\n' "${rows[@]}" | state write "$TRUSTED"
  else state_remove "$PORTAL_STATE_HOME" trusted-stores
  fi
}
trust_store() {  # <nss dir>
  local pem="$PORTAL_STATE_HOME/ca-import.pem" pemfd rc fp bound_fp rec="" cert_state
  fp=$(printf '%s' "$CA_PEM" | ca_fingerprint)
  [[ -n $fp ]] || return 1
  cert_state=$(store_cert_state "$1" "$fp")
  case $cert_state in
    absent) ;;
    matches) store_ca_trusted "$1" "$fp"; return $? ;;
    *) return 1 ;;
  esac
  # A ledger that exists but cannot be read is not an empty one: importing
  # over it would replace every earlier record with this one entry.
  if [[ -e $TRUSTED || -L $TRUSTED ]]; then
    rec=$(cat_own "$TRUSTED" "$TRUSTED_CAP" 2>/dev/null) || return 1
    valid_trust_ledger "$rec" || return 1
  fi
  { own_dir "$PORTAL_STATE_HOME" && printf '%s' "$CA_PEM" | state write "$pem"; } 2>/dev/null || return 1
  write_trust_record "$1" "$fp" "$rec" || { state_remove "$PORTAL_STATE_HOME" ca-import.pem; return 1; }
  exec {pemfd}<"$pem" || { drop_trust_record "$1"; state_remove "$PORTAL_STATE_HOME" ca-import.pem; return 1; }
  bound_fp=$(ca_fingerprint < "/proc/self/fd/$pemfd")
  if [[ $bound_fp != "$fp" ]]; then
    exec {pemfd}<&-
    drop_trust_record "$1"; state_remove "$PORTAL_STATE_HOME" ca-import.pem
    return 1
  fi
  certutil -d "sql:$1" -A -t "C,," -n "$NICK" -i "/proc/self/fd/$pemfd" >/dev/null 2>&1; rc=$?
  exec {pemfd}<&-
  state_remove "$PORTAL_STATE_HOME" ca-import.pem || rc=1
  (( rc == 0 )) && store_ca_trusted "$1" "$fp" && return 0
  [[ $(store_cert_state "$1" "$fp") != matches ]] \
    || certutil -d "sql:$1" -D -n "$NICK" >/dev/null 2>&1
  cert_state=$(store_cert_state "$1" "$fp")
  case $cert_state in absent|different) drop_trust_record "$1" || true ;; esac
  return 1
}
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

store_cert_state() {  # <nss dir> <expected fingerprint>: absent|matches|different|unreadable
  local listing pem fp
  have certutil || { echo unreadable; return; }
  listing=$(certutil -d "sql:$1" -L 2>/dev/null) || { echo unreadable; return; }
  grep -qF "$NICK" <<<"$listing" || { echo absent; return; }
  pem=$(certutil -d "sql:$1" -L -n "$NICK" -a 2>/dev/null) || { echo unreadable; return; }
  fp=$(ca_fingerprint <<<"$pem")
  [[ -n $fp ]] || { echo unreadable; return; }
  [[ $fp == "$2" ]] && echo matches || echo different
}

store_ca_trusted() {  # <nss dir> <current CA fingerprint>
  [[ -n $2 && $(store_cert_state "$1" "$2") == matches ]] || return 1
  certutil -d "sql:$1" -L 2>/dev/null | awk -v nick="$NICK" '
    { name = $0; sub(/[[:space:]]+$/, "", name)
      sub(/[[:space:]]+[^[:space:]]+$/, "", name)
      split($NF, trust, ",")
      if (name == nick && trust[1] ~ /C/) found = 1 }
    END { exit !found }'
}

proxy_state() {  # echoes: ok | wrong-tld | foreign | off | lan | unknown
  local scope; scope=$(portless_proxy_scope)
  [[ $scope == local ]] || { echo "$scope"; return; }
  if ! portless_probe; then echo off; return; fi
  if ! portless_serving_routes; then echo foreign; return; fi
  # A proxy serves the TLD set it was started with; a newly configured suffix
  # is dead until a restart adds it, and Settings already says so.
  portless_serves_tld "$(configured_tld)" || { echo wrong-tld; return; }
  echo ok
}

nss_trusted() {
  store_ca_trusted "$NSSDB" "$(ca_fingerprint <<<"$CA_PEM")"
}

firefox_untrusted() {
  local fp; fp=$(ca_fingerprint <<<"$CA_PEM")
  firefox_profiles | while read -r d; do
    store_ca_trusted "$d" "$fp" || printf '%s\n' "$d"
  done
}

report() {
  local installed ca proxy nss ff_missing tldok repair="" remaining=()
  # Installed means runnable by Portal: on PATH and a trusted executable.
  resolve_bin portless >/dev/null 2>&1 && installed=true || installed=false
  [[ -n $CA_PEM ]] && ca=true || ca=false
  proxy=$(proxy_state)
  nss_trusted && nss=true || nss=false
  ff_missing=$(firefox_untrusted | wc -l)
  tld_resolves && tldok=true || tldok=false

  if ! $installed; then
    if have portless; then
      remaining+=("portless at $(command -v portless) is not a trusted executable (it and every directory above it must belong to root or you and be writable by nobody else): fix the permissions or reinstall it")
    else
      remaining+=("install portless"$'\x1f'"npm install -g portless")
    fi
  fi
  if [[ $proxy == wrong-tld ]]; then
    portless_probe && repair=$(portless_fix_cmd "" "$PROBE_PORT")
    remaining+=("restart the portless proxy so it serves .$(configured_tld) too${repair:+$'\x1f'$repair}")
  elif [[ $proxy == foreign ]]; then
    remaining+=("restart the proxy with your routes"$'\x1f'"$(portless_fix_cmd evict)")
  elif [[ $proxy == off ]]; then
    remaining+=("Start local names in Portal settings")
  elif [[ $proxy == lan ]]; then
    portless_probe && repair=$(portless_fix_cmd "" "$PROBE_PORT")
    remaining+=("The proxy listens beyond this device; restart it for local-only names${repair:+$'\x1f'$repair}")
  elif [[ $proxy == unknown ]]; then
    remaining+=("Could not verify the proxy listener; local-only naming is unavailable")
  fi
  $ca || remaining+=("CA appears after the first proxy start")
  have certutil || remaining+=("Install certutil to trust the Portless CA in browsers")
  $nss || remaining+=("Chrome/Chromium has not trusted the current Portless CA")
  (( ff_missing == 0 )) || remaining+=("$ff_missing Firefox profiles have not trusted the current Portless CA")
  $tldok || remaining+=("wildcard-resolve .$(configured_tld) once (root, replaces per-name hosts syncs)"$'\x1f'"$(tld_fix_cmd)")

  jq -nc --argjson installed "$installed" --argjson ca "$ca" --arg proxy "$proxy" \
        --argjson nss "$nss" --argjson ffMissing "${ff_missing:-0}" \
        --argjson tldResolves "$tldok" \
        --args '{ok:true, checks:{installed:$installed, ca:$ca, proxy:$proxy,
                 chromeTrust:$nss, firefoxProfilesUntrusted:$ffMissing,
                 tldResolves:$tldResolves},
                 remaining:$ARGS.positional}' "${remaining[@]}"
}

case "${1:-status}" in
  status)
    portless_state_load || die "could not read Portless state safely: ${PORTLESS_STATE_ERROR:-unknown error}"
    report
    ;;
  run)
    portless_state_load || die "could not read Portless state safely: ${PORTLESS_STATE_ERROR:-unknown error}"
    portless_probe || :
    if [[ $(portless_proxy_scope) != local ]]; then
      die "the proxy is not verified as local-only; repair its listener before setup"
    fi
    PORTLESS=$(resolve_bin portless)
    # Even a high-port proxy can belong to root. Portless may elevate to stop
    # it, so existing proxies require an explicit repair command.
    # Proxy-start is an unprivileged rung like any other: when portless is
    # installed and nothing answers, start a high-port proxy so names work
    # immediately.
    if [[ -n $PORTLESS ]] && [[ $(proxy_state) == off ]]; then
      proxy_port=$(canonical_port "${PORTAL_PORTLESS_PORT:-1355}") \
        || die "invalid Portless proxy port"
      (( proxy_port >= 1024 )) || die "automatic setup requires a Portless proxy port of 1024 or higher"
      PORTLESS_LAN=0 PORTLESS_LAN_IP= "$PORTLESS" proxy start -p "$proxy_port" --skip-trust \
        --tld "$(portless_tld_arg)" >/dev/null 2>&1 \
        || die "could not start the Portless proxy"
      sleep 1
      portless_state_load || die "Portless started, but its state could not be read safely"
      portless_probe_reset
      ca_load   # the proxy just wrote its port and minted the CA
      [[ $(proxy_state) != off ]] || die "Portless reported success but its proxy is not reachable"
    fi
    portless_probe || :
    if [[ $(portless_proxy_scope) != local ]]; then
      die "the proxy is not verified as local-only; browser trust was not changed"
    fi
    if ca_is_portless && have certutil; then
      if [[ ! -d $NSSDB ]]; then
        own_dir "$NSSDB" || die "could not create the browser trust store"
        certutil -d "sql:$NSSDB" -N --empty-password >/dev/null 2>&1 \
          || die "could not initialize the browser trust store"
      fi
      nss_trusted || trust_store "$NSSDB" || die "could not trust the Portless CA in $NSSDB; check for an existing certificate or an inaccessible store"
      while read -r d; do
        trust_store "$d" || die "could not trust the Portless CA in $d; check for an existing certificate or an inaccessible store"
      done < <(firefox_untrusted)
    fi
    report
    ;;
  untrust)
    # Only the stores Portal itself imported into; trust the user set up
    # before Portal stays. A store is forgotten only once the certificate is
    # gone from it; what could not be removed stays on record and is reported.
    # certutil -D can report success without deleting (a store whose directory
    # is not writable), so the listing afterwards is what decides.
    # A record that exists but cannot be read is not an empty one.
    record=""
    if [[ -e $TRUSTED || -L $TRUSTED ]]; then
      record=$(cat_own "$TRUSTED" "$TRUSTED_CAP") \
        || die "the record of the stores the CA was imported into could not be read"
      valid_trust_ledger "$record" \
        || die "the record of the stores the CA was imported into is malformed; no stores were changed"
    fi
    left=()
    while IFS=$'\t' read -r d fp; do
      [[ -n $d && -d $d ]] || continue          # a store that is gone holds nothing
      cert_state=$(store_cert_state "$d" "$fp")
      case $cert_state in
        absent|different) continue ;;
        unreadable) left+=("$d	$fp"); continue ;;
        matches) ;;
      esac
      certutil -d "sql:$d" -D -n "$NICK" >/dev/null 2>&1 || true
      cert_state=$(store_cert_state "$d" "$fp")
      case $cert_state in
        absent|different) ;;
        *) left+=("$d	$fp") ;;
      esac
    done <<<"$record"
    if (( ${#left[@]} )); then
      printf '%s\n' "${left[@]}" | state write "$TRUSTED" \
        || die "the remaining browser trust records could not be saved"
      jq -nc --args '{ok:false, error:"the CA is still trusted in some stores", remaining:$ARGS.positional}' "${left[@]%%$'\t'*}"
    else
      if [[ -n $record ]]; then
        state_remove "${TRUSTED%/*}" "${TRUSTED##*/}" \
          || die "the browser trust ledger could not be cleared"
      fi
      echo '{"ok":true}'
    fi
    ;;
  *) echo '{"ok":false,"error":"usage: portless-setup.sh status|run|untrust"}' ;;
esac
