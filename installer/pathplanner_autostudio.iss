; PathPlanner AutoStudio Windows installer
; Built by installer/build_installer.ps1 or GitHub Actions.

#ifndef MyAppName
#define MyAppName "PathPlanner AutoStudio"
#endif

#ifndef MyAppVersion
#define MyAppVersion "2026.0.0"
#endif

#ifndef MyAppPublisher
#define MyAppPublisher "Nick Wight"
#endif

#ifndef MyAppExeName
#define MyAppExeName "pathplanner.exe"
#endif

#ifndef BuildDir
#define BuildDir "..\build\windows\x64\runner\Release"
#endif

#ifndef OutputDir
#define OutputDir "Output"
#endif

[Setup]
; Keep this stable forever so future installers update the same app.
AppId={{C8B6BB5A-8E91-4F2C-A51A-3B4E7B5C2A20}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}

; Per-user install avoids admin rights on most team/school laptops.
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest

OutputDir={#OutputDir}
OutputBaseFilename=PathPlanner-AutoStudio-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
