; Dayflow Windows Installer Script (NSIS)
; Equivalent to macOS .dmg distribution

!define APPNAME "Dayflow"
!define COMPANYNAME "Dayflow"
!define DESCRIPTION "A timeline of your day, automatically"

; Version can be passed from command line: /DVERSION=1.2.3
; Otherwise defaults to 1.0.0
!ifndef VERSION
  !define VERSION "1.0.0"
!endif

; Parse version into components
!searchparse /noerrors "${VERSION}" "" VERSIONMAJOR "." VERSIONMINOR "." VERSIONBUILD
!ifndef VERSIONMAJOR
  !define VERSIONMAJOR 1
!endif
!ifndef VERSIONMINOR
  !define VERSIONMINOR 0
!endif
!ifndef VERSIONBUILD
  !define VERSIONBUILD 0
!endif

; Architecture can be passed from command line: /DARCH=ARM64
; Otherwise defaults to x64
!ifndef ARCH
  !define ARCH "x64"
!endif

; Source directory can be passed from command line
!ifndef SOURCEDIR
  !define SOURCEDIR "publish\current"
!endif

!define HELPURL "https://github.com/JerryZLiu/Dayflow"
!define UPDATEURL "https://github.com/JerryZLiu/Dayflow/releases"
!define ABOUTURL "https://dayflow.so"

!include "MUI2.nsh"

Name "${APPNAME}"
OutFile "DayflowSetup.exe"

; Use appropriate Program Files directory based on architecture
!if "${ARCH}" == "ARM64"
  InstallDir "$PROGRAMFILES64\${APPNAME}"
!else
  InstallDir "$PROGRAMFILES64\${APPNAME}"
!endif

RequestExecutionLevel admin

; Version Info
VIProductVersion "${VERSIONMAJOR}.${VERSIONMINOR}.${VERSIONBUILD}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "CompanyName" "${COMPANYNAME}"
VIAddVersionKey "FileDescription" "${DESCRIPTION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "© ${COMPANYNAME}"

!define MUI_ABORTWARNING
!define MUI_ICON "DayflowWindows\Assets\AppIcon.ico"
!define MUI_UNICON "DayflowWindows\Assets\AppIcon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "Install"
    SetOutPath "$INSTDIR"

    ; Install files from source directory
    File /r "${SOURCEDIR}\*.*"

    WriteUninstaller "$INSTDIR\Uninstall.exe"

    CreateDirectory "$SMPROGRAMS\${APPNAME}"
    CreateShortCut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\Dayflow.exe"
    CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\Dayflow.exe"

    ; Write registry keys for Add/Remove Programs
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayName" "${APPNAME}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayVersion" "${VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "UninstallString" "$INSTDIR\Uninstall.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "Publisher" "${COMPANYNAME}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "HelpLink" "${HELPURL}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "URLUpdateInfo" "${UPDATEURL}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "URLInfoAbout" "${ABOUTURL}"
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "VersionMajor" ${VERSIONMAJOR}
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "VersionMinor" ${VERSIONMINOR}
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "NoRepair" 1

    ; Register dayflow:// protocol handler
    WriteRegStr HKCR "dayflow" "" "URL:Dayflow Protocol"
    WriteRegStr HKCR "dayflow" "URL Protocol" ""
    WriteRegStr HKCR "dayflow\shell\open\command" "" '"$INSTDIR\Dayflow.exe" "%1"'
SectionEnd

Section "Uninstall"
    Delete "$INSTDIR\*.*"
    RMDir /r "$INSTDIR"

    Delete "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk"
    RMDir "$SMPROGRAMS\${APPNAME}"
    Delete "$DESKTOP\${APPNAME}.lnk"

    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
    DeleteRegKey HKCR "dayflow"
SectionEnd
