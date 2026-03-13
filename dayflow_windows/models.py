from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True)
class ScreenshotRecord:
    id: int
    captured_at: datetime
    file_path: str
    file_size: int
    window_title: str
    process_name: str


@dataclass(frozen=True)
class CaptureResult:
    id: int
    captured_at: datetime
    file_path: str
    file_size: int
    window_title: str
    process_name: str


@dataclass(frozen=True)
class TimelineCard:
    start: datetime
    end: datetime
    duration_seconds: int
    process_name: str
    window_title: str
    screenshot_count: int


@dataclass(frozen=True)
class AITimelineCard:
    id: int
    day: str
    start: str
    end: str
    title: str
    summary: str
    category: str


@dataclass(frozen=True)
class JournalEntry:
    day: str
    intentions: str
    reflections: str
    notes: str
    summary: str
    updated_at: str


@dataclass(frozen=True)
class DashboardTile:
    id: int
    day: str
    question: str
    answer: str
    created_at: str
