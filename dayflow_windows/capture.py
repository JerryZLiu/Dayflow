from __future__ import annotations

import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Callable

from PIL import ImageGrab

from .database import DayflowWindowsDatabase
from .models import CaptureResult
from .paths import screenshot_path
from .win32_active_window import current_active_window

CaptureCallback = Callable[[CaptureResult], None]
ErrorCallback = Callable[[Exception], None]


class ScreenCaptureService:
    def __init__(self, db: DayflowWindowsDatabase):
        self._db = db
        self._interval_seconds = 10.0
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._lock = threading.Lock()
        self._on_sample: CaptureCallback | None = None
        self._on_error: ErrorCallback | None = None

    @property
    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(
        self,
        interval_seconds: float,
        on_sample: CaptureCallback | None = None,
        on_error: ErrorCallback | None = None,
    ) -> bool:
        interval_seconds = max(1.0, float(interval_seconds))
        with self._lock:
            if self.is_running:
                return False

            self._interval_seconds = interval_seconds
            self._on_sample = on_sample
            self._on_error = on_error
            self._stop_event.clear()
            self._thread = threading.Thread(
                target=self._run_capture_loop,
                name="dayflow-windows-capture",
                daemon=True,
            )
            self._thread.start()
            return True

    def stop(self, timeout_seconds: float = 5.0) -> None:
        with self._lock:
            thread = self._thread
            if thread is None:
                return
            self._stop_event.set()

        thread.join(timeout=timeout_seconds)

        with self._lock:
            if self._thread is thread:
                self._thread = None

    def capture_once(self) -> CaptureResult:
        captured_at = datetime.now().astimezone()
        active_window = current_active_window()
        path = self._capture_screenshot_to_file(captured_at)
        file_size = path.stat().st_size

        row_id = self._db.insert_screenshot(
            captured_at=captured_at,
            file_path=path,
            file_size=file_size,
            window_title=active_window.title,
            process_name=active_window.process_name,
        )

        return CaptureResult(
            id=row_id,
            captured_at=captured_at,
            file_path=str(path),
            file_size=file_size,
            window_title=active_window.title,
            process_name=active_window.process_name,
        )

    def _run_capture_loop(self) -> None:
        next_due = time.monotonic()

        while not self._stop_event.is_set():
            now = time.monotonic()
            if now < next_due:
                if self._stop_event.wait(next_due - now):
                    break

            try:
                result = self.capture_once()
                callback = self._on_sample
                if callback is not None:
                    callback(result)
            except Exception as exc:  # noqa: BLE001
                callback = self._on_error
                if callback is not None:
                    callback(exc)

            next_due = max(next_due + self._interval_seconds, time.monotonic() + 0.05)

    @staticmethod
    def _capture_screenshot_to_file(captured_at: datetime) -> Path:
        target_path = screenshot_path(captured_at)
        image = ImageGrab.grab(all_screens=True)
        if image.mode != "RGB":
            image = image.convert("RGB")
        image.save(target_path, format="JPEG", quality=85, optimize=True)
        return target_path
