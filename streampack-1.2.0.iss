; ============================================================================
; StreamPack — Inno Setup installer script
;
; Usage (from the streampack-desktop directory):
;   iscc streampack.iss
;
; Prerequisites:
;   1. flutter build windows --release  (produces build\windows\x64\runner\Release\)
;   2. Inno Setup 6+ installed          (https://jrsoftware.org/isinfo.php)
;
; Output:
;   installer\StreamPack-1.2.0-Setup.exe
; ============================================================================

#define AppName      "StreamPack"
#define AppVersion   "1.2.0"
#define AppPublisher "Hervé Jourdain"
#define AppURL       "https://github.com/hjourdain-ryvr/streampack-desktop"
#define AppExeName   "streampack.exe"
#define AppCopyright "© 2026 Hervé Jourdain — hjourdain@ryvrtech.com"
#define ReleaseDir   "streampack_flutter\build\windows\x64\runner\Release"

[Setup]
AppId={{A3F2C1B4-7D8E-4F5A-9C0B-2E6D1A3F4B5C}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
AppCopyright={#AppCopyright}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Require no admin rights — installs per-user by default
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=installer
OutputBaseFilename=StreamPack-{#AppVersion}-Setup
SetupIconFile=streampack_flutter\assets\icons\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
WizardSizePercent=120
; Minimum Windows 10
MinVersion=10.0.17763
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startupicon"; Description: "Start {#AppName} with Windows"; GroupDescription: "Startup"; Flags: unchecked

[Files]
; Main executable
Source: "{#ReleaseDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; All DLLs — Flutter engine, plugins (window_manager, etc.), and VC++ runtime
Source: "{#ReleaseDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion

; Bundled ffmpeg binaries (cross-compiled, statically linked — no extra DLLs needed)
Source: "{#ReleaseDir}\ffmpeg.exe";                   DestDir: "{app}"; Flags: ignoreversion
Source: "{#ReleaseDir}\ffprobe.exe";                  DestDir: "{app}"; Flags: ignoreversion

; Flutter data directory (assets, fonts, shaders)
Source: "{#ReleaseDir}\data\*";                       DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}";             Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}";   Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";       Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}";       Filename: "{app}\{#AppExeName}"; Tasks: startupicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
// Warn if Visual C++ runtime is missing (ffmpeg is statically linked so this
// only affects the Flutter engine DLLs — unlikely but possible on very minimal systems)
function VCRedistInstalled: Boolean;
var
  ver: String;
begin
  Result := RegQueryStringValue(HKEY_LOCAL_MACHINE,
    'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
    'Version', ver);
end;

procedure InitializeWizard;
begin
  if not VCRedistInstalled then
    MsgBox(
      'The Microsoft Visual C++ Redistributable (x64) does not appear to be installed.' + #13#10 +
      'StreamPack may still work, but if it fails to start please install it from:' + #13#10 +
      'https://aka.ms/vs/17/release/vc_redist.x64.exe',
      mbInformation, MB_OK);
end;
