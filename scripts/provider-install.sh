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
# The download lands in a private temp dir, must match its digest, must parse
# as an ELF, and must execute `--version` before it is installed into
# ~/.local/bin through the same descriptor-relative path as every other file
# Portal writes. Nothing runs elevated.
set -o pipefail
# shellcheck source=lib/files.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/files.sh"

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
  if [[ -z ${PORTAL_BIN_DIR:-} ]] && cf=$(resolve_bin cloudflared); then
    jq -nc --arg v "$("$cf" --version 2>/dev/null | head -1)" '{ok:true,version:$v}'
    return
  fi

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

  local sum; sum=$(sha256sum "$tmp/cloudflared" | cut -d' ' -f1)
  [[ $sum == "${CLOUDFLARED_SHA256[$arch]}" ]] \
    || die "checksum mismatch for cloudflared $CLOUDFLARED_VERSION ($arch): got $sum"
  # It must be an ELF binary, not an error page that got a 200.
  [[ $(head -c 4 "$tmp/cloudflared" | od -An -tx1 | tr -d ' \n') == 7f454c46 ]] \
    || die "downloaded file is not an ELF binary"
  chmod 700 "$tmp/cloudflared"
  local ver
  ver=$("$tmp/cloudflared" --version 2>/dev/null | head -1)
  [[ $ver == cloudflared* ]] || die "binary failed its own --version check"

  own_dir "$BIN_DIR" || die "$BIN_DIR is not a private directory of yours"
  state write "$BIN_DIR/cloudflared" 755 < "$tmp/cloudflared" || die "could not install into $BIN_DIR"
  own_dir "${MARK%/*}" && write_own "$MARK" "$BIN_DIR/cloudflared $sum"

  jq -nc --arg v "$ver" --arg p "$BIN_DIR/cloudflared" \
    '{ok:true, version:$v, path:$p, note:"official Cloudflare release, checksum-pinned; prefer sudo pacman -S cloudflared for repo signatures"}'
}

case "${1:-}" in
  cloudflared) install_cloudflared ;;
  *) echo '{"ok":false,"error":"usage: provider-install.sh cloudflared"}' ;;
esac
