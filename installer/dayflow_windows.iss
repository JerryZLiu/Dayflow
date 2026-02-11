#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{9A1F4F2C-6D53-4E80-B065-7198D2A296A6}
AppName=Dayflow Windows
AppVersion={#AppVersion}
AppPublisher=Dayflow
DefaultDirName={localappdata}\Programs\DayflowWindows
DefaultGroupName=Dayflow Windows
PrivilegesRequired=lowest
OutputDir=..\dist-installer
OutputBaseFilename=DayflowWindowsSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\dayflow_windows\assets\dayflow-logo.ico
UninstallDisplayIcon={app}\DayflowWindows.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "..\dist\DayflowWindows.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README_WINDOWS.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Dayflow Windows"; Filename: "{app}\DayflowWindows.exe"
Name: "{autodesktop}\Dayflow Windows"; Filename: "{app}\DayflowWindows.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\DayflowWindows.exe"; Description: "Launch Dayflow Windows"; Flags: nowait postinstall skipifsilent
