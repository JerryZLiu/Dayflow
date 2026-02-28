from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from dayflow_windows.database import DayflowWindowsDatabase


class DatabaseTests(unittest.TestCase):
    def test_insert_and_query_screenshot(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            db = DayflowWindowsDatabase(Path(tmp_dir) / "dayflow.sqlite3")
            ts = datetime(2026, 1, 2, 10, 15, 0, tzinfo=timezone.utc)
            db.insert_screenshot(
                captured_at=ts,
                file_path=Path("C:/tmp/screenshot.jpg"),
                file_size=1000,
                window_title="Working",
                process_name="Code",
            )

            rows = db.list_screenshots_for_date(ts.date())
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].window_title, "Working")
            self.assertEqual(rows[0].process_name, "Code")

    def test_settings_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            db = DayflowWindowsDatabase(Path(tmp_dir) / "dayflow.sqlite3")
            db.set_setting("capture_interval_seconds", "12")
            self.assertEqual(db.get_setting("capture_interval_seconds"), "12")
            self.assertEqual(db.get_setting_float("capture_interval_seconds", 10.0), 12.0)

    def test_ai_timeline_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            db = DayflowWindowsDatabase(Path(tmp_dir) / "dayflow.sqlite3")
            day = "2026-01-02"
            cards = [
                {
                    "start": "09:00",
                    "end": "10:15",
                    "title": "Coding feature",
                    "summary": "Implemented timeline generation logic.",
                    "category": "Coding",
                },
                {
                    "start": "10:30",
                    "end": "11:00",
                    "title": "Standup",
                    "summary": "Shared progress and blockers.",
                    "category": "Meeting",
                },
            ]
            db.replace_ai_timeline_for_day(day, cards, "Solid maker-focused morning.")

            stored = db.list_ai_timeline_for_day(day)
            self.assertEqual(len(stored), 2)
            self.assertEqual(stored[0].title, "Coding feature")
            self.assertEqual(db.get_ai_daily_summary(day), "Solid maker-focused morning.")

    def test_journal_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            db = DayflowWindowsDatabase(Path(tmp_dir) / "dayflow.sqlite3")
            day = "2026-01-03"
            db.upsert_journal_entry(
                day=day,
                intentions="Ship alpha",
                reflections="Made progress",
                notes="Need to improve tests",
                summary="Productive day overall.",
            )
            entry = db.get_journal_entry(day)
            self.assertEqual(entry.intentions, "Ship alpha")
            self.assertEqual(entry.summary, "Productive day overall.")
            recent = db.list_recent_journal_entries(limit=3)
            self.assertEqual(len(recent), 1)
            self.assertEqual(recent[0].day, day)

    def test_dashboard_tiles_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            db = DayflowWindowsDatabase(Path(tmp_dir) / "dayflow.sqlite3")
            day = "2026-01-04"
            db.insert_dashboard_tile(day, "What did I focus on?", "Mostly coding and review.")
            db.insert_dashboard_tile(day, "How much distraction?", "About 30 minutes.")
            tiles = db.list_dashboard_tiles(day)
            self.assertEqual(len(tiles), 2)
            self.assertEqual(tiles[0].day, day)
            db.clear_dashboard_tiles(day)
            self.assertEqual(len(db.list_dashboard_tiles(day)), 0)

    def test_storage_limit_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            db = DayflowWindowsDatabase(Path(tmp_dir) / "dayflow.sqlite3")
            ts = datetime(2026, 1, 5, 9, 0, 0, tzinfo=timezone.utc)
            file1 = Path(tmp_dir) / "a.jpg"
            file2 = Path(tmp_dir) / "b.jpg"
            file1.write_bytes(b"a" * 1200)
            file2.write_bytes(b"b" * 1200)

            db.insert_screenshot(ts, file1, 1200, "A", "Code")
            db.insert_screenshot(ts.replace(minute=1), file2, 1200, "B", "Code")

            removed_count, removed_bytes = db.enforce_storage_limit(max_bytes=1500)
            self.assertGreaterEqual(removed_count, 1)
            self.assertGreaterEqual(removed_bytes, 1200)
            self.assertLessEqual(db.total_screenshot_bytes(), 1500)


if __name__ == "__main__":
    unittest.main()
