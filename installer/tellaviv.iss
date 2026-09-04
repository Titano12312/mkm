; TellAviv — Inno Setup script (Windows Setup Wizard)
; Requires: flutter build windows --release  (or .\tools\build_windows.ps1)
; Compile:  iscc installer\tellaviv.iss
; Output:   installer\Output\TellAviv-Setup-0.1.0.exe
;
; ARCHITECTURE: wraps the flutter build output verbatim. No Node.js needed
; on the client — the app talks to your hosted backend over WebSocket.

#define MyAppName "TellAviv"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "TellAviv Friends"
#define MyAppExeName "tellaviv.exe"
; Flutter emits to frontend\build\windows\x64\runner\Release — resolved
; relative to this script in installer\.
#define BuildDir "..\frontend\build\windows\x64\runner\Release"

[Setup]
AppId={{3A7F2C1E-9B4A-4E1F-TELL-AVIV000001}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=Output
OutputBaseFilename=TellAviv-Setup-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Uncomment + add your .pfx to ship a signed installer (removes SmartScreen warning):
; SignTool=default

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Flutter Windows bundle: exe + flutter_windows.dll + data\ + plugins.
Source: "{#BuildDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
