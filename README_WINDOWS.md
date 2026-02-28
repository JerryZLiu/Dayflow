# Dayflow for Windows

This repository now includes a Windows-native implementation of Dayflow under `dayflow_windows/`.

## What this Windows build does

- Captures periodic screenshots of all monitors.
- Records active window title and process name for each capture.
- Stores metadata in SQLite (`%LOCALAPPDATA%\\DayflowWindows\\dayflow.sqlite3`).
- Timeline view with date navigation, capture controls, AI timeline cards, and Markdown export.
- Dashboard view for AI Q&A on your selected day (or week-style questions), with fallback to captured timeline evidence plus saved tiles.
- Journal view with intentions, reflections, AI summary, weekly history, and reminders.
- Settings view for providers, endpoints, API keys, capture interval, and storage cleanup.
- Local-first storage with configurable auto-cleanup.

## Requirements

- Windows 10 or newer
- Python 3.10+

## Quickstart

```powershell
cd Dayflow
python -m pip install -r requirements-windows.txt
python -m dayflow_windows
```

Or run:

```powershell
python run_dayflow_windows.py
```

## AI Setup

1. Open the app and go to `Settings`.
2. Pick provider: `gemini`, `openai`, or `local`.
3. Enter model and (for cloud providers) your API key.
4. For local models, set endpoint (default: `http://localhost:1234/v1/chat/completions`).
5. Go back to `Timeline` and click `Generate AI Timeline`.

Suggested models:
- Gemini: `gemini-1.5-flash`
- OpenAI: `gpt-4.1-mini`
- Local (LM Studio / Ollama OpenAI-compatible): your configured local model id

## Build Installer EXE

```powershell
pwsh -File .\scripts\build_windows_installer.ps1
```

Output is created at `dist-installer\DayflowWindowsSetup.exe`.

If you are in the repo root (`Dayflow/`), the installer is:

- `dist-installer\DayflowWindowsSetup.exe`

## Build Portable EXE (optional)

```powershell
pwsh -File .\scripts\build_windows.ps1
```

Portable output is created under `dist\`.

## Storage paths

- App data root: `%LOCALAPPDATA%\\DayflowWindows`
- Screenshots: `%LOCALAPPDATA%\\DayflowWindows\\screenshots`
- Database: `%LOCALAPPDATA%\\DayflowWindows\\dayflow.sqlite3`

## Main UI structure

- `Timeline`: capture controls, AI timeline generation, export, timelapse.
- `Dashboard`: ask AI about your day and save Q&A tiles.
- `Journal`: intentions/reflections/notes with AI summary + weekly entries.
- `Settings`: providers, model/API key/endpoint, cleanup limits, reminder times.

## Notes

- Got CODEX GPT5.3 to make a windows compatible version since I do not have a Mac
- This Windows port does not rely on Xcode, SwiftUI, or macOS frameworks.
- The original Swift app in `Dayflow/` remains unchanged for macOS builds.
