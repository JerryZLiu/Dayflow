param(
    [string]$Python = "python"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-IsccPath {
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $fromPath = (Get-Command iscc -ErrorAction SilentlyContinue)
    if ($fromPath) {
        return $fromPath.Source
    }

    return $null
}

function Install-InnoSetupIfMissing {
    $iscc = Get-IsccPath
    if ($iscc) {
        return $iscc
    }

    $installerExe = Join-Path $env:TEMP "innosetup-setup.exe"
    $url = "https://jrsoftware.org/download.php/is.exe"
    Write-Host "Downloading Inno Setup from $url"
    Invoke-WebRequest -Uri $url -OutFile $installerExe

    Write-Host "Installing Inno Setup silently (current user)..."
    $args = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/CURRENTUSER")
    $proc = Start-Process -FilePath $installerExe -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Inno Setup installer failed with exit code $($proc.ExitCode)"
    }

    $iscc = Get-IsccPath
    if (-not $iscc) {
        throw "Inno Setup compiler (ISCC.exe) was not found after installation."
    }
    return $iscc
}

Push-Location (Join-Path $PSScriptRoot "..")
try {
    & $Python -m pip install -r requirements-windows.txt
    & $Python -m pip install pyinstaller

    Remove-Item -Recurse -Force dist -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force dist-installer -ErrorAction SilentlyContinue
    Remove-Item -Force DayflowWindows.spec -ErrorAction SilentlyContinue

    & $Python -m PyInstaller `
        --name DayflowWindows `
        --noconfirm `
        --clean `
        --onefile `
        --windowed `
        --icon dayflow_windows/assets/dayflow-logo.ico `
        --add-data "dayflow_windows/assets;dayflow_windows/assets" `
        --collect-all PIL `
        --hidden-import PIL._tkinter_finder `
        run_dayflow_windows.py

    if (-not (Test-Path -LiteralPath "dist\DayflowWindows.exe")) {
        throw "PyInstaller build failed: dist\\DayflowWindows.exe not found."
    }

    $version = (& $Python -c "import dayflow_windows; print(dayflow_windows.__version__)").Trim()
    if (-not $version) {
        $version = "0.1.0"
    }

    $isccPath = Install-InnoSetupIfMissing
    & $isccPath "/DAppVersion=$version" "installer\dayflow_windows.iss"

    $installerPath = Join-Path (Get-Location) "dist-installer\DayflowWindowsSetup.exe"
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Installer build failed: $installerPath not found."
    }

    Write-Host ""
    Write-Host "Installer ready:"
    Write-Host $installerPath
}
finally {
    Pop-Location
}
