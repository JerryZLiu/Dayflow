from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone

from dayflow_windows.models import ScreenshotRecord
from dayflow_windows.timeline import build_timeline_cards


def _record(
    idx: int,
    seconds_from_base: int,
    process_name: str = "Code",
    window_title: str = "Editing app.py",
) -> ScreenshotRecord:
    base = datetime(2026, 1, 1, 9, 0, 0, tzinfo=timezone.utc)
    captured_at = base + timedelta(seconds=seconds_from_base)
    return ScreenshotRecord(
        id=idx,
        captured_at=captured_at,
        file_path=f"shot-{idx}.jpg",
        file_size=12345,
        window_title=window_title,
        process_name=process_name,
    )


class TimelineTests(unittest.TestCase):
    def test_merges_contiguous_same_activity(self) -> None:
        records = [
            _record(1, 0),
            _record(2, 10),
            _record(3, 20),
        ]
        cards = build_timeline_cards(records, fallback_interval_seconds=10)
        self.assertEqual(len(cards), 1)
        self.assertEqual(cards[0].screenshot_count, 3)
        self.assertEqual(cards[0].duration_seconds, 30)

    def test_splits_when_app_changes(self) -> None:
        records = [
            _record(1, 0, process_name="Code"),
            _record(2, 10, process_name="Chrome", window_title="Research"),
        ]
        cards = build_timeline_cards(records, fallback_interval_seconds=10)
        self.assertEqual(len(cards), 2)
        self.assertEqual(cards[0].process_name, "Code")
        self.assertEqual(cards[1].process_name, "Chrome")

    def test_clamps_large_capture_gaps(self) -> None:
        records = [
            _record(1, 0),
            _record(2, 600),
        ]
        cards = build_timeline_cards(records, fallback_interval_seconds=10)
        self.assertEqual(len(cards), 2)
        self.assertEqual(cards[0].duration_seconds, 30)


if __name__ == "__main__":
    unittest.main()
