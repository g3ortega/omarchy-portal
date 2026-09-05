#!/bin/bash
# Unprivileged installer for exposure providers. Currently: cloudflared.
#
# Trust model, stated plainly: the binary is one specific Cloudflare release,
# pinned by version and SHA256 below, fetched from GitHub over TLS. A hash
# mismatch aborts before the file is ever executed. Bumping the release means
# editing the three digests, which is the point. If you prefer repository
# signatures, install the distro package instead (sudo pacman -S cloudflared);
# the setup surfaces that alternative rather than hiding it.
#
# The download lands in a private temp dir, must match its digest, and must
# parse as an ELF before it is installed into
# ~/.local/bin through the same descriptor-relative path as every other file
# Portal writes. Nothing runs elevated.
set -o pipefail
INSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/files.sh
source "$INSTALL_DIR/lib/files.sh"

BIN_DIR="${PORTAL_BIN_DIR:-$HOME/.local/bin}"
MARK="$PORTAL_STATE_HOME/installed-cloudflared"   # so removal knows the binary is Portal's to delete

CLOUDFLARED_VERSION="2026.8.3"
declare -A CLOUDFLARED_SHA256=(
  [amd64]=f29324fe934d1e100617484c78deef803c4dc2cd351d645bbde42e96b4fccc5e
  [arm64]=4bcfd35521a7cbc545ebfd5d57334a71ee180e2a64874981f374c81472118391
  [arm]=7a7cac4ad4561ff55797eaf27aae1a0be37498c85502715bc87e3bad919d928c
)

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq not found"}'; exit 0; }
command -v curl >/dev/null 2>&1 || die "curl not found"

install_cloudflared() {
  local cf
  if [[ -z ${PORTAL_BIN_DIR:-} ]]; then
    if cf=$(resolve_bin cloudflared); then
      jq -nc --arg v "$("$cf" --version 2>/dev/null | head -1)" '{ok:true,version:$v}'
      return
    fi
    # An untrusted cloudflared earlier on PATH than our install target would
    # keep shadowing the copy we are about to write, so installing would report
    # success while provider_bin still refuses it. Say so instead.
    local found; found=$(command -v cloudflared 2>/dev/null)
    [[ -z $found || $found == "$HOME/.local/bin/cloudflared" ]] \
      || die "cloudflared at $found is not a trusted executable and shadows the install location; fix its permissions or remove it, then set up again"
  fi

  local target="$BIN_DIR/cloudflared"
  [[ ! -e $target && ! -L $target ]] \
    || die "refusing to overwrite the existing $target"
  [[ ! -e $MARK && ! -L $MARK ]] \
    || die "the cloudflared install marker already exists; remove the prior Portal install first"

  local arch
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    armv7l)  arch=arm ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  local url="https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-$arch"

  local tmp
  tmp=$(mktemp -d) || die "mktemp failed"
  chmod 700 "$tmp"
  trap 'rm -rf "$tmp"' EXIT

  curl -q -fsSL --proto =https --proto-redir =https --max-redirs 3 --max-time 300 \
    --max-filesize 134217728 -o "$tmp/cloudflared" "$url" \
    || die "download failed from $url"

  # Open the download once and never reopen it by path: /proc/self/fd/$dl is
  # the inode we opened, so a same-uid process cannot swap the file between the
  # checksum and the install. Every check and the install read that descriptor.
  exec {dl}<"$tmp/cloudflared" || die "could not open the download"
  local sum; sum=$(sha256sum "/proc/self/fd/$dl" | cut -d' ' -f1)
  [[ $sum == "${CLOUDFLARED_SHA256[$arch]}" ]] \
    || { exec {dl}<&-; die "checksum mismatch for cloudflared $CLOUDFLARED_VERSION ($arch): got $sum"; }
  # It must be an ELF binary, not an error page that got a 200. The checksum
  # already pins the exact official bytes, so no separate --version reopen.
  [[ $(head -c 4 "/proc/self/fd/$dl" | od -An -tx1 | tr -d ' \n') == 7f454c46 ]] \
    || { exec {dl}<&-; die "downloaded file is not an ELF binary"; }

  own_dir "$BIN_DIR" || { exec {dl}<&-; die "$BIN_DIR is not a private directory of yours"; }
  state create "$target" 755 < "/proc/self/fd/$dl" || { exec {dl}<&-; die "could not install into $BIN_DIR"; }
  exec {dl}<&-
  # Without the marker removal could not tell this copy from the user's own:
  # no marker, no install.
  if ! { own_dir "${MARK%/*}" && jq -nc --arg p "$target" --arg s "$sum" '{path:$p, sha256:$s}' | state create "$MARK"; }; then
    state remove-digest "$BIN_DIR" cloudflared "$sum" 134217728 \
      || die "could not record the install under ${MARK%/*}; the installed path changed before digest-bound rollback"
    die "could not record the install under ${MARK%/*}; the installed copy was removed again"
  fi

  rm -rf -- "$tmp" || die "could not remove the private download directory $tmp"
  trap - EXIT
  jq -nc --arg v "$CLOUDFLARED_VERSION" --arg p "$BIN_DIR/cloudflared" \
    '{ok:true, version:$v, path:$p, note:"official Cloudflare release, checksum-pinned"}'
}

case "${1:-}" in
  cloudflared)
    lifecycle_mutation nowait /usr/bin/bash "$INSTALL_DIR/provider-install.sh" "$@"
    ;;
esac

case "${1:-}" in
  cloudflared) install_cloudflared ;;
  *) echo '{"ok":false,"error":"usage: provider-install.sh cloudflared"}' ;;
esac
