# StreamPack Desktop

A native Flutter desktop application for encoding video to HLS/DASH and
validating manifests. Calls `ffmpeg`/`ffprobe` directly — no browser, no
server, no Python required.

ffmpeg is built from source via Docker and bundled into the app automatically
by CMake during `flutter build`.

## Features

- **HLS and DASH encoding** — produce adaptive streaming content ready to serve
- **Format selector** — HLS, DASH, or Both in a single pass
- **Quality toggle** — Balanced (`p4`/`medium`) or High (`p6`/`slow`)
- **Rendition picker** — 240p through 4K, upscale prevention built in
- **Manifest validator** — validate local `.m3u8` or `.mpd` files, or remote URLs
- **Job queue** — run and monitor multiple encode jobs with progress and elapsed time
- **Localization** — English, Deutsch, Svenska, Français (runtime switching, no restart)

### NVIDIA GPU acceleration

When an NVIDIA GPU is detected at runtime, StreamPack automatically uses
`h264_nvenc` for encoding (typically 10–12× realtime on 1080p content).
Falls back to `libx264` CPU encoding when no GPU is present — no
configuration needed.

| Format | CPU path | GPU path |
|--------|----------|----------|
| HLS  | CPU decode + CPU scale + libx264 | CPU decode + CPU scale + h264_nvenc |
| DASH | CPU decode + CPU scale + libx264 | GPU decode + scale_cuda + h264_nvenc |

The GPU/CPU indicator dots in the status bar show which path is active.

---

## Complete build workflow

```
Step 1: Build ffmpeg binaries (Docker, on Linux)
Step 2: Build the Flutter app (flutter build, on target platform)
```

---

## Step 1 — Build ffmpeg binaries

Run once (or when updating ffmpeg version). Requires Docker.

The bundled ffmpeg includes:
- `libx264` — CPU H.264 encoding
- `h264_nvenc` / `hevc_nvenc` — NVIDIA GPU encoding (NVENC)
- `scale_cuda` — NVIDIA GPU scaling (requires `--enable-cuda-llvm`, uses `clang`)
- `scale`, `setsar`, `setdar`, `split`, `pad` — CPU filters
- HLS and DASH muxers, common demuxers and decoders

```bash
# Build for both Linux and Windows:
bash build-ffmpeg.sh

# Or build individually:
bash build-ffmpeg.sh linux
bash build-ffmpeg.sh windows

# Force full rebuild from scratch (bypass Docker layer cache):
bash build-ffmpeg.sh --no-cache
bash build-ffmpeg.sh linux --no-cache
bash build-ffmpeg.sh windows --no-cache
```

Output:
```
vendor/
├── linux/
│   ├── ffmpeg          (~10 MB, static, stripped + UPX compressed)
│   └── ffprobe
└── windows/
    ├── ffmpeg.exe      (~12 MB, cross-compiled via mingw-w64)
    └── ffprobe.exe
```

Build times (first run, no Docker cache):
- Linux binary: ~15–25 minutes
- Windows binary: ~25–40 minutes

Subsequent runs use Docker layer cache and take ~2–3 minutes.

---

## Step 2 — Initialise Flutter platform scaffolding (once)

Flutter generates the platform directories itself — they must not be written
by hand. It also regenerates `lib/main.dart` with a placeholder, which is why
StreamPack's source lives in `lib.streampack/` instead of `lib/` directly.

### Linux

```bash
cd streampack_flutter
flutter config --enable-linux-desktop
flutter create --platforms=linux .
cd ..
bash setup.sh
```

`setup.sh` only requires the `linux/` platform directory — `windows/` is
optional. If `windows/` is also present, `setup.sh` patches it too.

### Windows

```powershell
cd streampack_flutter
flutter config --enable-windows-desktop
flutter create --platforms=windows .
cd ..
.\setup.ps1
```

If PowerShell blocks script execution, run once:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

The setup scripts do two things:
1. Copy `lib.streampack/` → `lib/`, overwriting Flutter's generated placeholder
2. Patch `linux/CMakeLists.txt` or `windows/CMakeLists.txt` to bundle ffmpeg

**Important:** if you ever re-run `flutter create`, re-run the setup script
afterwards to restore `lib/` from `lib.streampack/`.

---

## Step 3 — Build the Flutter app

### Linux

```bash
cd streampack_flutter
flutter pub get
flutter build linux --release
```

CMake automatically copies `vendor/linux/ffmpeg` and `vendor/linux/ffprobe`
into the build output directory alongside the executable.

Output: `build/linux/x64/release/bundle/`

### Windows

Build on a Windows machine (Flutter's Windows build requires MSVC):

```bat
cd streampack_flutter
flutter pub get
flutter build windows --release
```

Before building, copy the cross-compiled binaries from your Linux machine:
```
vendor\windows\ffmpeg.exe
vendor\windows\ffprobe.exe
```

CMake will copy them into:
```
build\windows\x64\runner\Release\ffmpeg.exe
build\windows\x64\runner\Release\ffprobe.exe
```

### Windows — installer

An [Inno Setup](https://jrsoftware.org/isinfo.php) script is included:

```bat
iscc streampack-1.1.0.iss
```

Output: `installer\StreamPack-1.1.0-Setup.exe`

---

## Directory layout

```
streampack-desktop/
├── Dockerfile                   ← multi-stage build: Linux + Windows ffmpeg
├── build-ffmpeg.sh              ← convenience script wrapping Docker
├── setup.sh                     ← Linux: copies lib.streampack/→lib/ and patches CMakeLists.txt
├── setup.ps1                    ← Windows: same as setup.sh but PowerShell
├── streampack-1.1.0.iss         ← Inno Setup installer script
├── README.md                    ← this file
├── vendor/                      ← built ffmpeg binaries (git-ignored)
│   ├── linux/
│   │   ├── ffmpeg
│   │   └── ffprobe
│   └── windows/
│       ├── ffmpeg.exe
│       └── ffprobe.exe
└── streampack_flutter/
    ├── pubspec.yaml
    ├── linux/                   ← generated by: flutter create --platforms=linux .
    │   └── CMakeLists.txt       ← patched by setup.sh to bundle ffmpeg
    ├── windows/                 ← generated by: flutter create --platforms=windows .
    │   └── CMakeLists.txt       ← patched by setup.ps1 to bundle ffmpeg
    ├── lib.streampack/          ← StreamPack source (source of truth, never overwritten)
    │   ├── main.dart
    │   ├── models.dart
    │   ├── ffmpeg.dart          ← binary location + process helpers
    │   ├── encoder.dart         ← HLS/DASH command builders
    │   ├── validator.dart       ← m3u8 + mpd validation
    │   ├── job_runner.dart      ← ChangeNotifier job queue
    │   ├── l10n.dart            ← localization (en/de/sv/fr)
    │   └── ui/
    │       ├── app.dart
    │       ├── encoder_tab.dart
    │       ├── validator_tab.dart
    │       ├── job_card.dart
    │       └── validation_report.dart
    └── lib/                     ← populated by setup.sh from lib.streampack/
```

---

## How ffmpeg binary location works

`lib/ffmpeg.dart` checks for bundled binaries at runtime:

```dart
String _toolPath(String name) {
  // 1. Check next to the executable (bundled)
  final sibling = File('${executableDir}/$name${.exe on Windows}');
  if (sibling.existsSync()) return sibling.path;
  // 2. Fall back to system PATH (development mode)
  return name;
}
```

In development (`flutter run`), ffmpeg is looked up on PATH.
In release builds, the bundled binary next to the executable is used.

---

## Distribute

### Linux — tar.gz

```bash
tar -czf streampack-linux.tar.gz \
    -C build/linux/x64/release bundle
```

The `bundle/` directory is self-contained — copy it anywhere and run
`./bundle/streampack`.

### Linux — AppImage

```bash
# Install appimagetool: https://appimage.github.io/appimagetool/
cp -r build/linux/x64/release/bundle StreamPack.AppDir
# Add AppRun symlink, .desktop file, and icon
# (see appimagetool documentation)
appimagetool StreamPack.AppDir StreamPack-x86_64.AppImage
```

### Windows — installer

```bat
iscc streampack-1.1.0.iss
```

Produces a per-user installer (`installer\StreamPack-1.1.0-Setup.exe`) that
bundles the executable, all Flutter DLLs, ffmpeg, ffprobe, and assets.

### Windows — zip

```powershell
Compress-Archive `
    build\windows\x64\runner\Release `
    streampack-windows.zip
```

---

## Development (no Docker required)

Install ffmpeg system-wide, then run directly:

```bash
# Linux
sudo apt install ffmpeg
flutter run -d linux

# Windows
winget install ffmpeg
flutter run -d windows
```

`ffmpeg.dart` falls back to PATH when no bundled binary is found.

---

## Troubleshooting

**`ffmpeg not found` on startup**
→ Either install ffmpeg system-wide, or run `build-ffmpeg.sh` and rebuild
  the Flutter app so CMake bundles the binaries.

**NVENC not detected (CPU dot lit instead of GPU dot)**
→ The bundled ffmpeg tests NVENC at startup using a `nullsrc=s=256x256` test
  encode. Ensure NVIDIA drivers are installed and up to date. On Linux,
  verify `nvidia-smi` works. The test requires the `lavfi` input device and
  `wrapped_avframe` decoder, both included in the bundled build.

**`scale_cuda` not available**
→ The bundled ffmpeg requires `--enable-cuda-llvm` and `clang` in the build
  environment. Rebuild with `bash build-ffmpeg.sh` from the latest Dockerfile
  which includes these. `scale_cuda` only appears in `-filters` output when
  an NVIDIA GPU is present at runtime.

**Docker build fails on x264**
→ Check network access from the container (needed to clone from videolan.org).
  Set `--build-arg X264_VERSION=stable` explicitly if the default tag changed.

**Windows .exe won't run**
→ Verify the cross-compiled binary: `file vendor/windows/ffmpeg.exe` should
  show `PE32+ executable (console) x86-64, for MS Windows`.
  The binary is statically linked and requires no DLLs.

**CMake warning: ffmpeg binaries not found**
→ Run `build-ffmpeg.sh` first, then rebuild. The app will still build and
  run but will require system ffmpeg on the target machine.
