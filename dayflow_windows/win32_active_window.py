from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from dataclasses import dataclass
from pathlib import Path

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


@dataclass(frozen=True)
class ActiveWindowInfo:
    title: str
    process_name: str


if sys.platform == "win32":
    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    _user32.GetForegroundWindow.restype = wintypes.HWND
    _user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
    _user32.GetWindowTextLengthW.restype = ctypes.c_int
    _user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    _user32.GetWindowTextW.restype = ctypes.c_int
    _user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    _user32.GetWindowThreadProcessId.restype = wintypes.DWORD

    _kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _kernel32.OpenProcess.restype = wintypes.HANDLE
    _kernel32.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE,
        wintypes.DWORD,
        wintypes.LPWSTR,
        ctypes.POINTER(wintypes.DWORD),
    ]
    _kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    _kernel32.CloseHandle.restype = wintypes.BOOL


def current_active_window() -> ActiveWindowInfo:
    if sys.platform != "win32":
        return ActiveWindowInfo(title="Unknown Window", process_name="unknown")

    hwnd = _user32.GetForegroundWindow()
    if not hwnd:
        return ActiveWindowInfo(title="Unknown Window", process_name="unknown")

    title = _window_title(hwnd) or "Unknown Window"
    process_name = _process_name_for_hwnd(hwnd) or "unknown"
    return ActiveWindowInfo(title=title, process_name=process_name)


def _window_title(hwnd: wintypes.HWND) -> str:
    length = _user32.GetWindowTextLengthW(hwnd)
    if length <= 0:
        return ""

    buffer = ctypes.create_unicode_buffer(length + 1)
    copied = _user32.GetWindowTextW(hwnd, buffer, len(buffer))
    if copied <= 0:
        return ""
    return buffer.value.strip()


def _process_name_for_hwnd(hwnd: wintypes.HWND) -> str:
    pid = wintypes.DWORD()
    _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if pid.value == 0:
        return ""

    handle = _kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
    if not handle:
        return ""

    try:
        size = wintypes.DWORD(2048)
        buffer = ctypes.create_unicode_buffer(size.value)
        ok = _kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size))
        if not ok:
            return ""

        name = Path(buffer.value).name
        if name.lower().endswith(".exe"):
            name = name[:-4]
        return name
    finally:
        _kernel32.CloseHandle(handle)
