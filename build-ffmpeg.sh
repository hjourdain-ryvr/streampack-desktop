#!/usr/bin/env bash
# =============================================================================
# StreamPack — build minimal ffmpeg binaries for Linux and Windows
#
# Runs the Dockerfile to produce stripped, UPX-compressed ffmpeg + ffprobe
# binaries and places them in vendor/linux/ and vendor/windows/.
#
# Usage:
#   bash build-ffmpeg.sh                      # build both Linux and Windows
#   bash build-ffmpeg.sh linux                # Linux only
#   bash build-ffmpeg.sh windows              # Windows only
#   bash build-ffmpeg.sh linux --no-cache     # force full rebuild from scratch
#   bash build-ffmpeg.sh windows --no-cache
#   bash build-ffmpeg.sh both --no-cache
#
# Requirements:
#   docker (with BuildKit support — Docker 18.09+)
#
# Build times (first run, no cache):
#   Linux:   ~15–25 minutes
#   Windows: ~25–40 minutes
# Subsequent runs use Docker layer cache and take ~2–3 minutes.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

TARGET="both"
NO_CACHE=""

for arg in "$@"; do
    case "$arg" in
        --no-cache) NO_CACHE="--no-cache"; info "Cache disabled — full rebuild from scratch" ;;
        linux|windows|both) TARGET="$arg" ;;
        *) die "Unknown argument '$arg' — usage: build-ffmpeg.sh [linux|windows|both] [--no-cache]" ;;
    esac
done

command -v docker &>/dev/null || die "Docker is not installed or not in PATH"

mkdir -p vendor/linux vendor/windows

build_linux() {
    info "Building Linux ffmpeg/ffprobe ..."
    docker build \
        $NO_CACHE \
        --target linux-export-runner \
        --tag streampack-ffmpeg-linux \
        --file Dockerfile \
        .
    docker run --rm \
        -v "${SCRIPT_DIR}/vendor/linux:/out" \
        streampack-ffmpeg-linux
    chmod +x vendor/linux/ffmpeg vendor/linux/ffprobe
    success "Linux binaries ready:"
    ls -lh vendor/linux/ffmpeg vendor/linux/ffprobe
}

build_windows() {
    info "Building Windows ffmpeg.exe/ffprobe.exe (cross-compiling via mingw-w64) ..."
    info "NVENC/NVDEC support included via nv-codec-headers (runtime dynamic loading)"
    docker build \
        $NO_CACHE \
        --target windows-export-runner \
        --tag streampack-ffmpeg-windows \
        --file Dockerfile \
        .
    docker run --rm \
        -v "${SCRIPT_DIR}/vendor/windows:/out" \
        streampack-ffmpeg-windows
    success "Windows binaries ready (with NVENC support):"
    ls -lh vendor/windows/ffmpeg.exe vendor/windows/ffprobe.exe
}

case "$TARGET" in
    linux)   build_linux   ;;
    windows) build_windows ;;
    both)    build_linux && build_windows ;;
    *)       die "Unknown target '$TARGET' — use: linux | windows | both" ;;
esac

echo
echo -e "${GREEN}Done.${NC} Binaries are in:"
[[ "$TARGET" != "windows" ]] && echo -e "  ${CYAN}vendor/linux/${NC}   ffmpeg  ffprobe"
[[ "$TARGET" != "linux"   ]] && echo -e "  ${CYAN}vendor/windows/${NC} ffmpeg.exe  ffprobe.exe"
echo
echo "Next step: run the Flutter CMake build to bundle these into the app."
echo "See desktop/README.md for instructions."
