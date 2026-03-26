# =============================================================================
# StreamPack Desktop - Windows setup script
#
# Run ONCE after initialising the Flutter platform scaffolding:
#
#   cd desktop\streampack_flutter
#   flutter create --platforms=windows .
#   cd ..
#   powershell.exe -ExecutionPolicy Bypass -File .\setup.ps1
# =============================================================================

$ScriptDir  = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$FlutterDir = Join-Path $ScriptDir 'streampack_flutter'
$LibSrc     = Join-Path $FlutterDir 'lib.streampack'
$LibDst     = Join-Path $FlutterDir 'lib'
$WinCMake   = Join-Path $FlutterDir 'windows\CMakeLists.txt'

function Info($m)  { Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Ok($m)    { Write-Host "[OK]    $m" -ForegroundColor Green }
function Warn($m)  { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

# -- Validate ------------------------------------------------------------------
if (-not (Test-Path $LibSrc))   { Fail "lib.streampack\ not found at: $LibSrc" }
if (-not (Test-Path $FlutterDir\windows)) { Fail "windows\ not found. Run 'flutter create --platforms=windows .' first." }

# -- Step 1: Copy lib.streampack\ -> lib\ -------------------------------------
Info "Copying lib.streampack\ -> lib\ ..."

# Remove lib\ entirely and recreate from scratch
if (Test-Path $LibDst) {
    Remove-Item -Path $LibDst -Recurse -Force
    Start-Sleep -Milliseconds 200
}
New-Item -ItemType Directory -Force -Path $LibDst | Out-Null
New-Item -ItemType Directory -Force -Path "$LibDst\ui" | Out-Null

# Copy root .dart files
Get-ChildItem -Path $LibSrc -Filter "*.dart" -File |
    ForEach-Object { Copy-Item $_.FullName -Destination $LibDst -Force }

# Copy ui\ .dart files
Get-ChildItem -Path "$LibSrc\ui" -Filter "*.dart" -File |
    ForEach-Object { Copy-Item $_.FullName -Destination "$LibDst\ui" -Force }

# Verify
$mainContent = Get-Content "$LibDst\main.dart" -Raw -ErrorAction SilentlyContinue
if ($mainContent -notmatch 'windowManager') {
    Fail "lib\main.dart does not contain StreamPack code. Copy failed."
}
Ok "lib\ updated ($((Get-ChildItem $LibDst -Recurse -Filter '*.dart' | Measure-Object).Count) dart files copied)"

# -- Step 1b: Install Windows icon ------------------------------------------------
$AssetsIcon = Join-Path $FlutterDir 'assets\icons\app_icon.ico'
$WinResDir  = Join-Path $FlutterDir 'windows\runner\resources'
$WinIconDst = Join-Path $WinResDir 'app_icon.ico'
if (Test-Path $AssetsIcon) {
    # Create resources\ if flutter create hasn't run yet
    if (-not (Test-Path $WinResDir)) {
        New-Item -ItemType Directory -Force -Path $WinResDir | Out-Null
    }
    Copy-Item $AssetsIcon -Destination $WinIconDst -Force
    Ok "Windows icon installed ($WinIconDst)"
} else {
    Warn "assets\icons\app_icon.ico not found -- skipping icon installation"
}

# -- Step 2: Patch windows\CMakeLists.txt -------------------------------------
$Marker = '# StreamPack: bundle ffmpeg'

if (-not (Test-Path $WinCMake)) {
    Warn "windows\CMakeLists.txt not found - skipping CMake patch"
} elseif ((Get-Content $WinCMake -Raw) -match [regex]::Escape($Marker)) {
    Warn "windows\CMakeLists.txt already patched - skipping"
} else {
    Info "Patching windows\CMakeLists.txt ..."
    $Patch = "`n# StreamPack: bundle ffmpeg + ffprobe into the output directory`nset(STREAMPACK_VENDOR_DIR `"`${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/windows`")`nif(EXISTS `"`${STREAMPACK_VENDOR_DIR}/ffmpeg.exe`" AND EXISTS `"`${STREAMPACK_VENDOR_DIR}/ffprobe.exe`")`n  message(STATUS `"StreamPack: bundling ffmpeg`")`n  install(PROGRAMS `"`${STREAMPACK_VENDOR_DIR}/ffmpeg.exe`" `"`${STREAMPACK_VENDOR_DIR}/ffprobe.exe`" DESTINATION `"`${CMAKE_INSTALL_PREFIX}`")`nendif()"
    Add-Content -Path $WinCMake -Value $Patch
    Ok "windows\CMakeLists.txt patched"
}

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host "  cd streampack_flutter"
Write-Host "  flutter pub get"
Write-Host "  flutter build windows --release"
