param(
    [string]$Python = "python"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Push-Location (Join-Path $PSScriptRoot "..")
try {
    & $Python -m pip install -r requirements-windows.txt
    & $Python -m pip install pyinstaller
    & $Python -m PyInstaller `
        --name DayflowWindows `
        --noconfirm `
        --windowed `
        --icon dayflow_windows/assets/dayflow-logo.ico `
        --add-data "dayflow_windows/assets;dayflow_windows/assets" `
        --collect-all PIL `
        run_dayflow_windows.py
}
finally {
    Pop-Location
}
