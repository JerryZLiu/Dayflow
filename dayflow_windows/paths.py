from __future__ import annotations

import os
import sys
from datetime import datetime
from pathlib import Path

APP_DIR_NAME = "DayflowWindows"


def data_directory() -> Path:
    local_appdata = os.environ.get("LOCALAPPDATA")
    if local_appdata:
        base = Path(local_appdata)
    else:
        base = Path.home() / "AppData" / "Local"
    return base / APP_DIR_NAME


def screenshots_directory() -> Path:
    return data_directory() / "screenshots"


def database_path() -> Path:
    return data_directory() / "dayflow.sqlite3"


def ensure_directories() -> None:
    screenshots_directory().mkdir(parents=True, exist_ok=True)


def screenshot_path(captured_at: datetime) -> Path:
    day_folder = screenshots_directory() / captured_at.strftime("%Y-%m-%d")
    day_folder.mkdir(parents=True, exist_ok=True)
    filename = captured_at.strftime("%Y%m%d_%H%M%S_%f") + ".jpg"
    return day_folder / filename


def package_directory() -> Path:
    if getattr(sys, "frozen", False):
        base = Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent))
        packaged = base / "dayflow_windows"
        return packaged if packaged.exists() else base
    return Path(__file__).resolve().parent


def asset_path(filename: str) -> Path:
    return package_directory() / "assets" / filename
