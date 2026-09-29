#!/usr/bin/env bash
# Installs rtl-sdr tools and multimon-ng (built from source, not packaged in Homebrew).
# Supports macOS (Homebrew) and Debian/Ubuntu/Raspberry Pi OS (apt).
set -euo pipefail

MULTIMON_REPO="https://github.com/EliasOenal/multimon-ng.git"
BUILD_DIR="${BUILD_DIR:-$(cd "$(dirname "$0")" && pwd)/.build}"
PREFIX="${PREFIX:-/usr/local}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo"

install_deps() {
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"
      log "Installing librtlsdr, cmake, git, sox via Homebrew"
      brew install librtlsdr cmake git sox
      ;;
    Linux)
      command -v apt-get >/dev/null || die "Only apt-based distros are handled; install rtl-sdr, cmake, git, build tools, sox manually."
      log "Installing rtl-sdr, cmake, build tools, sox via apt"
      $SUDO apt-get update
      $SUDO apt-get install -y rtl-sdr librtlsdr-dev cmake git build-essential sox
      # The kernel DVB-T driver grabs the dongle and blocks librtlsdr.
      if [ ! -f /etc/modprobe.d/blacklist-rtl-sdr.conf ]; then
        log "Blacklisting dvb_usb_rtl28xxu kernel driver"
        printf 'blacklist dvb_usb_rtl28xxu\nblacklist rtl2832\nblacklist rtl2830\n' \
          | $SUDO tee /etc/modprobe.d/blacklist-rtl-sdr.conf >/dev/null
        $SUDO modprobe -r dvb_usb_rtl28xxu 2>/dev/null || true
      fi
      ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
}

build_multimon() {
  if command -v multimon-ng >/dev/null && [ "${FORCE:-0}" != "1" ]; then
    log "multimon-ng already installed at $(command -v multimon-ng) (FORCE=1 to rebuild)"
    return
  fi
  if [ -d "$BUILD_DIR/multimon-ng/.git" ]; then
    log "Updating multimon-ng source"
    git -C "$BUILD_DIR/multimon-ng" pull --ff-only
  else
    log "Cloning multimon-ng into $BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    git clone --depth 1 "$MULTIMON_REPO" "$BUILD_DIR/multimon-ng"
  fi
  log "Building multimon-ng"
  cmake -S "$BUILD_DIR/multimon-ng" -B "$BUILD_DIR/multimon-ng/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build "$BUILD_DIR/multimon-ng/build" -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  log "Installing multimon-ng to $PREFIX/bin"
  if [ -w "$PREFIX/bin" ]; then
    cmake --install "$BUILD_DIR/multimon-ng/build"
  else
    $SUDO cmake --install "$BUILD_DIR/multimon-ng/build"
  fi
}

check() {
  log "Checking installation"
  command -v rtl_fm >/dev/null || die "rtl_fm not found"
  command -v multimon-ng >/dev/null || die "multimon-ng not found"
  echo "  rtl_fm:      $(command -v rtl_fm)"
  echo "  multimon-ng: $(command -v multimon-ng)"
  log "Probing for an RTL-SDR dongle"
  # rtl_test exits non-zero even on success, so capture its output first.
  local probe
  probe="$(rtl_test -t 2>&1 || true)"
  if printf '%s\n' "$probe" | grep -q "Found [1-9]"; then
    printf '%s\n' "$probe" | grep -E "^ +[0-9]+:|tuner" || true
  else
    echo "  No dongle detected (plug it in; on Linux, unplug/replug after the blacklist)."
  fi
  log "Done. Run ./decode.sh --help"
}

install_deps
build_multimon
check
