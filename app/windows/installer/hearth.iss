; SPDX-License-Identifier: AGPL-3.0-or-later
#define MyAppName "Hearth"
#define MyAppPublisher "Hearth"
#define MyAppExeName "hearth.exe"

#ifndef MyAppVersion
  #error MyAppVersion must be provided to ISCC
#endif
#ifndef BuildDir
  #error BuildDir must be provided to ISCC
#endif
#ifndef OutputDir
  #error OutputDir must be provided to ISCC
#endif

[Setup]
AppId={{F31C61E4-A6ED-4DD9-BE97-573571788966}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppVerName={#MyAppName} {#MyAppVersion}
DefaultDirName={localappdata}\Programs\Hearth
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=hearth-windows-setup
SetupIconFile={#BuildDir}\data\flutter_assets\assets\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Start {#MyAppName}"; Flags: nowait runascurrentuser
