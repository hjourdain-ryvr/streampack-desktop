# =============================================================================
# StreamPack — minimal ffmpeg build
#
# Produces static ffmpeg + ffprobe binaries containing only what StreamPack
# needs: libx264, AAC, HLS muxer, DASH muxer, scale/pad/split filters, and
# common input demuxers.
#
# Usage (run from the desktop/ directory):
#
#   Build Linux binaries:
#     docker build --target linux-export -t streampack-ffmpeg-linux .
#     docker run --rm -v "$(pwd)/vendor/linux:/out" streampack-ffmpeg-linux
#
#   Build Windows binaries:
#     docker build --target windows-export -t streampack-ffmpeg-windows .
#     docker run --rm -v "$(pwd)/vendor/windows:/out" streampack-ffmpeg-windows
#
# Output:
#   vendor/linux/ffmpeg
#   vendor/linux/ffprobe
#   vendor/windows/ffmpeg.exe
#   vendor/windows/ffprobe.exe
#
# Expected binary sizes after stripping + UPX compression:
#   Linux:   ~8–14 MB each
#   Windows: ~10–16 MB each
# =============================================================================

# ── Versions (pin for reproducible builds) ────────────────────────────────────
ARG FFMPEG_VERSION=7.1.3
ARG X264_VERSION=stable
ARG NASM_VERSION=2.16.01

# =============================================================================
# Stage 1 — base build environment (shared by Linux and Windows stages)
# =============================================================================
FROM ubuntu:22.04 AS base

RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y --no-install-recommends \
    # Build tools
    build-essential \
    pkg-config \
    git \
    curl \
    wget \
    ca-certificates \
    cmake \
    # clang required for --enable-cuda-llvm (scale_cuda filter)
    clang \
    # Compression (for UPX)
    upx-ucl \
    # Needed by x264 configure
    yasm \
    && rm -rf /var/lib/apt/lists/*

# Install NASM (newer than Debian's packaged version — required by x264)
ARG NASM_VERSION
RUN curl -fsSL "https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/nasm-${NASM_VERSION}.tar.bz2" \
    | tar -xj \
    && cd "nasm-${NASM_VERSION}" \
    && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" \
    && make install \
    && cd .. && rm -rf "nasm-${NASM_VERSION}"


# =============================================================================
# Stage 2 — Linux build
# =============================================================================
FROM base AS linux-build

ARG FFMPEG_VERSION
ARG X264_VERSION
ARG NV_CODEC_TAG=n12.1.14.0

WORKDIR /build

# ── NVIDIA codec headers (no GPU needed at build time) ────────────────────────
# These headers enable NVENC/NVDEC support via dynamic loading at runtime.
# The built binary works on machines without NVIDIA — it falls back to CPU.
RUN git clone --depth 1 --branch "${NV_CODEC_TAG}" \
      https://github.com/FFmpeg/nv-codec-headers.git \
    && cd nv-codec-headers \
    && make install PREFIX=/usr/local

# ── Build x264 (static) ───────────────────────────────────────────────────────
RUN git clone --depth 1 --branch "${X264_VERSION}" \
      https://code.videolan.org/videolan/x264.git x264 \
    && cd x264 \
    && ./configure \
         --prefix=/build/linux-prefix \
         --enable-static \
         --disable-opencl \
         --disable-avs \
         --disable-swscale \
         --disable-lavf \
         --disable-ffms \
         --disable-gpac \
         --disable-lsmash \
    && make -j"$(nproc)" \
    && make install

# ── Build ffmpeg (static, Linux) ──────────────────────────────────────────────
RUN curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.bz2" \
    | tar -xj

RUN cd "ffmpeg-${FFMPEG_VERSION}" \
    && PKG_CONFIG_PATH=/build/linux-prefix/lib/pkgconfig \
       ./configure \
         --prefix=/build/linux-out \
         --pkg-config-flags="--static" \
         --extra-cflags="-I/build/linux-prefix/include" \
         --extra-ldflags="-L/build/linux-prefix/lib" \
         --extra-libs="-lpthread -lm" \
         --enable-gpl \
         --enable-static \
         --disable-shared \
         \
         `# Disable everything first, then enable only what we need` \
         --disable-everything \
         \
         `# Encoders` \
         --enable-libx264 \
         --enable-encoder=libx264 \
         --enable-encoder=aac \
         \
         `# NVIDIA hardware acceleration (NVENC/NVDEC)` \
         `# Built via nv-codec-headers -- loaded dynamically at runtime` \
         `# Falls back to CPU automatically when no NVIDIA GPU is present` \
         --enable-ffnvcodec \
         --enable-cuda \
         --enable-cuda-llvm \
         --enable-cuvid \
         --enable-nvenc \
         --enable-nvdec \
         --enable-encoder=h264_nvenc \
         --enable-encoder=hevc_nvenc \
         --enable-decoder=h264_cuvid \
         --enable-decoder=hevc_cuvid \
         --enable-decoder=mpeg4_cuvid \
         --enable-hwaccel=h264_nvdec \
         --enable-hwaccel=hevc_nvdec \
         `# Decoders — needed to read input files` \
         --enable-decoder=h264 \
         --enable-decoder=hevc \
         --enable-decoder=mpeg4 \
         --enable-decoder=mpeg2video \
         --enable-decoder=vp8 \
         --enable-decoder=vp9 \
         --enable-decoder=aac \
         --enable-decoder=aac_latm \
         --enable-decoder=ac3 \
         --enable-decoder=mp3 \
         --enable-decoder=mp2 \
         --enable-decoder=pcm_s16le \
         --enable-decoder=pcm_s24le \
         --enable-decoder=pcm_s32le \
         --enable-decoder=pcm_f32le \
         --enable-decoder=flac \
         --enable-decoder=vorbis \
         --enable-decoder=opus \
         --enable-decoder=wrapped_avframe \
         \
         `# Demuxers — input container formats` \
         --enable-demuxer=mov \
         --enable-demuxer=mp4 \
         --enable-demuxer=matroska \
         --enable-demuxer=avi \
         --enable-demuxer=flv \
         --enable-demuxer=mpegts \
         --enable-demuxer=mpegps \
         --enable-demuxer=m4v \
         --enable-demuxer=h264 \
         --enable-demuxer=hevc \
         --enable-demuxer=aac \
         --enable-demuxer=mp3 \
         --enable-demuxer=wav \
         --enable-demuxer=flac \
         --enable-demuxer=ogg \
         --enable-demuxer=webm_dash_manifest \
         --enable-demuxer=hls \
         \
         `# Muxers — output formats` \
         --enable-muxer=hls \
         --enable-muxer=dash \
         --enable-muxer=mp4 \
         --enable-muxer=mpegts \
         --enable-muxer=null \
         \
         `# Filters — only what the StreamPack filter graph uses` \
         --enable-filter=scale \
         --enable-filter=scale_cuda \
         --enable-filter=setsar \
         --enable-filter=setdar \
         --enable-filter=pad \
         --enable-filter=split \
         --enable-filter=aresample \
         --enable-filter=anull \
         --enable-filter=null \
         \
         `# Protocols` \
         --enable-protocol=file \
         --enable-protocol=pipe \
         --enable-protocol=http \
         --enable-protocol=https \
         --enable-protocol=tcp \
         --enable-protocol=crypto \
         --enable-protocol=data \
         \
         `# Parsers — needed for correct stream detection` \
         --enable-parser=h264 \
         --enable-parser=hevc \
         --enable-parser=aac \
         --enable-parser=aac_latm \
         --enable-parser=ac3 \
         --enable-parser=mpeg4video \
         --enable-parser=mpegvideo \
         \
         `# Bitstream filters — required by some muxers` \
         --enable-bsf=h264_mp4toannexb \
         --enable-bsf=hevc_mp4toannexb \
         --enable-bsf=aac_adtstoasc \
         --enable-bsf=dump_extradata \
         \
         `# Build ffprobe alongside ffmpeg` \
         --enable-indev=lavfi \
         --enable-filter=color \
         --enable-filter=nullsrc \
         --enable-ffprobe \
         --disable-ffplay \
         --disable-doc \
         --disable-htmlpages \
         --disable-manpages \
         --disable-podpages \
         --disable-txtpages \
    && make -j"$(nproc)" \
    && make install

# Strip and compress
RUN strip /build/linux-out/bin/ffmpeg /build/linux-out/bin/ffprobe \
    && upx --best /build/linux-out/bin/ffmpeg /build/linux-out/bin/ffprobe \
    || true   # UPX failure is non-fatal (some builds resist compression)

# ── Linux export stage ────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS linux-export-runner
COPY --from=linux-build /build/linux-out/bin/ffmpeg  /ffmpeg
COPY --from=linux-build /build/linux-out/bin/ffprobe /ffprobe
CMD ["sh", "-c", "cp /ffmpeg /ffprobe /out/ && echo 'Linux binaries copied to /out'"]


# =============================================================================
# Stage 3 — Windows cross-compilation (mingw-w64)
# =============================================================================
FROM base AS windows-build

ARG FFMPEG_VERSION
ARG X264_VERSION
ARG NV_CODEC_TAG=n12.1.14.0

RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y --no-install-recommends \
    mingw-w64 \
    mingw-w64-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ENV HOST=x86_64-w64-mingw32
ENV PREFIX=/build/win-prefix
ENV PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig

# ── NVIDIA codec headers for Windows cross-compile ────────────────────────────
# nv-codec-headers are platform-agnostic C headers — they work fine for
# cross-compilation. At runtime, ffmpeg.exe loads nvenc64_*.dll dynamically
# via LoadLibrary; if no NVIDIA GPU is present the binary works normally
# without NVENC (falls back to libx264).
# Install to both /usr/local (default) AND ${PREFIX} so ffmpeg configure
# can find them regardless of which include path it searches.
RUN git clone --depth 1 --branch "${NV_CODEC_TAG}" \
      https://github.com/FFmpeg/nv-codec-headers.git \
    && cd nv-codec-headers \
    && make install PREFIX=/usr/local \
    && make install PREFIX=${PREFIX}

# ── Build x264 for Windows ────────────────────────────────────────────────────
RUN git clone --depth 1 --branch "${X264_VERSION}" \
      https://code.videolan.org/videolan/x264.git x264-win \
    && cd x264-win \
    && CC=${HOST}-gcc \
       ./configure \
         --prefix=${PREFIX} \
         --host=${HOST} \
         --cross-prefix=${HOST}- \
         --enable-static \
         --disable-opencl \
         --disable-avs \
         --disable-swscale \
         --disable-lavf \
         --disable-ffms \
         --disable-gpac \
         --disable-lsmash \
    && make -j"$(nproc)" \
    && make install

# ── Build ffmpeg for Windows ──────────────────────────────────────────────────
# Re-use the already-downloaded tarball from the linux-build stage if possible,
# otherwise download again.
RUN curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.bz2" \
    | tar -xj

RUN cd "ffmpeg-${FFMPEG_VERSION}" \
    && ./configure \
         --prefix=/build/win-out \
         --pkg-config-flags="--static" \
         --extra-cflags="-I${PREFIX}/include -I/usr/local/include" \
         --extra-ldflags="-L${PREFIX}/lib -static" \
         --extra-libs="-lpthread -lm" \
         --target-os=mingw32 \
         --arch=x86_64 \
         --cross-prefix=${HOST}- \
         --enable-cross-compile \
         --enable-gpl \
         --enable-static \
         --disable-shared \
         \
         --disable-everything \
         \
         --enable-libx264 \
         --enable-encoder=libx264 \
         --enable-encoder=aac \
         \
         `# NVIDIA hardware acceleration (runtime dynamic loading via LoadLibrary)` \
         --enable-ffnvcodec \
         --enable-cuda \
         --enable-cuda-llvm \
         --enable-cuvid \
         --enable-nvenc \
         --enable-nvdec \
         --enable-encoder=h264_nvenc \
         --enable-encoder=hevc_nvenc \
         --enable-decoder=h264_cuvid \
         --enable-decoder=hevc_cuvid \
         --enable-hwaccel=h264_nvdec \
         --enable-hwaccel=hevc_nvdec \
         \
         --enable-decoder=hevc \
         --enable-decoder=mpeg4 \
         --enable-decoder=mpeg2video \
         --enable-decoder=vp8 \
         --enable-decoder=vp9 \
         --enable-decoder=aac \
         --enable-decoder=aac_latm \
         --enable-decoder=ac3 \
         --enable-decoder=mp3 \
         --enable-decoder=mp2 \
         --enable-decoder=pcm_s16le \
         --enable-decoder=pcm_s24le \
         --enable-decoder=pcm_s32le \
         --enable-decoder=pcm_f32le \
         --enable-decoder=flac \
         --enable-decoder=vorbis \
         --enable-decoder=opus \
         --enable-decoder=wrapped_avframe \
         \
         --enable-demuxer=mov \
         --enable-demuxer=mp4 \
         --enable-demuxer=matroska \
         --enable-demuxer=avi \
         --enable-demuxer=flv \
         --enable-demuxer=mpegts \
         --enable-demuxer=mpegps \
         --enable-demuxer=m4v \
         --enable-demuxer=h264 \
         --enable-demuxer=hevc \
         --enable-demuxer=aac \
         --enable-demuxer=mp3 \
         --enable-demuxer=wav \
         --enable-demuxer=flac \
         --enable-demuxer=ogg \
         --enable-demuxer=webm_dash_manifest \
         --enable-demuxer=hls \
         \
         --enable-muxer=hls \
         --enable-muxer=dash \
         --enable-muxer=mp4 \
         --enable-muxer=mpegts \
         --enable-muxer=null \
         \
         --enable-filter=scale \
         --enable-filter=scale_cuda \
         --enable-filter=setsar \
         --enable-filter=setdar \
         --enable-filter=pad \
         --enable-filter=split \
         --enable-filter=aresample \
         --enable-filter=anull \
         --enable-filter=null \
         \
         --enable-protocol=file \
         --enable-protocol=pipe \
         --enable-protocol=http \
         --enable-protocol=https \
         --enable-protocol=tcp \
         --enable-protocol=crypto \
         --enable-protocol=data \
         \
         --enable-parser=h264 \
         --enable-parser=hevc \
         --enable-parser=aac \
         --enable-parser=aac_latm \
         --enable-parser=ac3 \
         --enable-parser=mpeg4video \
         --enable-parser=mpegvideo \
         \
         --enable-bsf=h264_mp4toannexb \
         --enable-bsf=hevc_mp4toannexb \
         --enable-bsf=aac_adtstoasc \
         --enable-bsf=dump_extradata \
         \
         --enable-indev=lavfi \
         --enable-filter=color \
         --enable-filter=nullsrc \
         --enable-ffprobe \
         --disable-ffplay \
         --disable-doc \
         --disable-htmlpages \
         --disable-manpages \
         --disable-podpages \
         --disable-txtpages \
    && make -j"$(nproc)" \
    && make install

# Strip and compress
RUN ${HOST}-strip /build/win-out/bin/ffmpeg.exe /build/win-out/bin/ffprobe.exe \
    && upx --best /build/win-out/bin/ffmpeg.exe /build/win-out/bin/ffprobe.exe \
    || true

# ── Windows export stage ──────────────────────────────────────────────────────
FROM ubuntu:22.04 AS windows-export-runner
COPY --from=windows-build /build/win-out/bin/ffmpeg.exe  /ffmpeg.exe
COPY --from=windows-build /build/win-out/bin/ffprobe.exe /ffprobe.exe
CMD ["sh", "-c", "cp /ffmpeg.exe /ffprobe.exe /out/ && echo 'Windows binaries copied to /out'"]
