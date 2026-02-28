from __future__ import annotations

import sqlite3
import threading
from contextlib import contextmanager
from datetime import date, datetime
from pathlib import Path

from .models import AITimelineCard, DashboardTile, JournalEntry, ScreenshotRecord


class DayflowWindowsDatabase:
    def __init__(self, db_file: Path):
        self._db_file = Path(db_file)
        self._db_file.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self._db_file, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        return conn

    @contextmanager
    def _connection(self):
        conn = self._connect()
        try:
            yield conn
        finally:
            conn.close()

    def _init_schema(self) -> None:
        with self._lock, self._connection() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    captured_at TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    file_size INTEGER NOT NULL,
                    window_title TEXT NOT NULL DEFAULT '',
                    process_name TEXT NOT NULL DEFAULT ''
                );

                CREATE INDEX IF NOT EXISTS idx_screenshots_captured_at
                ON screenshots(captured_at);

                CREATE TABLE IF NOT EXISTS app_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS ai_timeline_cards (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    day TEXT NOT NULL,
                    start_time TEXT NOT NULL,
                    end_time TEXT NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    category TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_ai_timeline_cards_day
                ON ai_timeline_cards(day);

                CREATE TABLE IF NOT EXISTS ai_daily_summaries (
                    day TEXT PRIMARY KEY,
                    summary TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS journal_entries (
                    day TEXT PRIMARY KEY,
                    intentions TEXT NOT NULL DEFAULT '',
                    reflections TEXT NOT NULL DEFAULT '',
                    notes TEXT NOT NULL DEFAULT '',
                    summary TEXT NOT NULL DEFAULT '',
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS dashboard_tiles (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    day TEXT NOT NULL,
                    question TEXT NOT NULL,
                    answer TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_dashboard_tiles_day
                ON dashboard_tiles(day, id);
                """
            )
            conn.commit()

    def insert_screenshot(
        self,
        captured_at: datetime,
        file_path: Path,
        file_size: int,
        window_title: str,
        process_name: str,
    ) -> int:
        with self._lock, self._connection() as conn:
            cursor = conn.execute(
                """
                INSERT INTO screenshots(
                    captured_at,
                    file_path,
                    file_size,
                    window_title,
                    process_name
                )
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    captured_at.isoformat(),
                    str(file_path),
                    int(file_size),
                    window_title or "",
                    process_name or "",
                ),
            )
            conn.commit()
            return int(cursor.lastrowid)

    def list_screenshots_for_date(self, day: date) -> list[ScreenshotRecord]:
        with self._lock, self._connection() as conn:
            rows = conn.execute(
                """
                SELECT id, captured_at, file_path, file_size, window_title, process_name
                FROM screenshots
                WHERE substr(captured_at, 1, 10) = ?
                ORDER BY captured_at ASC
                """,
                (day.isoformat(),),
            ).fetchall()
        return [self._row_to_record(row) for row in rows]

    def get_setting(self, key: str, default: str | None = None) -> str | None:
        with self._lock, self._connection() as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?",
                (key,),
            ).fetchone()
        if row is None:
            return default
        return str(row["value"])

    def get_setting_float(self, key: str, default: float) -> float:
        value = self.get_setting(key)
        if value is None:
            return default
        try:
            parsed = float(value)
        except ValueError:
            return default
        if parsed <= 0:
            return default
        return parsed

    def set_setting(self, key: str, value: str) -> None:
        with self._lock, self._connection() as conn:
            conn.execute(
                """
                INSERT INTO app_settings(key, value)
                VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                (key, value),
            )
            conn.commit()

    def replace_ai_timeline_for_day(
        self,
        day: str,
        cards: list[dict[str, str]],
        daily_summary: str,
    ) -> None:
        now = datetime.now().astimezone().isoformat()
        with self._lock, self._connection() as conn:
            conn.execute("DELETE FROM ai_timeline_cards WHERE day = ?", (day,))
            for card in cards:
                conn.execute(
                    """
                    INSERT INTO ai_timeline_cards(
                        day, start_time, end_time, title, summary, category
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        day,
                        str(card.get("start", "")).strip(),
                        str(card.get("end", "")).strip(),
                        str(card.get("title", "")).strip(),
                        str(card.get("summary", "")).strip(),
                        str(card.get("category", "")).strip(),
                    ),
                )
            conn.execute(
                """
                INSERT INTO ai_daily_summaries(day, summary, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET
                    summary = excluded.summary,
                    updated_at = excluded.updated_at
                """,
                (day, daily_summary.strip(), now),
            )
            conn.commit()

    def list_ai_timeline_for_day(self, day: str) -> list[AITimelineCard]:
        with self._lock, self._connection() as conn:
            rows = conn.execute(
                """
                SELECT id, day, start_time, end_time, title, summary, category
                FROM ai_timeline_cards
                WHERE day = ?
                ORDER BY start_time ASC, id ASC
                """,
                (day,),
            ).fetchall()
        return [
            AITimelineCard(
                id=int(row["id"]),
                day=str(row["day"]),
                start=str(row["start_time"]),
                end=str(row["end_time"]),
                title=str(row["title"]),
                summary=str(row["summary"]),
                category=str(row["category"]),
            )
            for row in rows
        ]

    def get_ai_daily_summary(self, day: str) -> str:
        with self._lock, self._connection() as conn:
            row = conn.execute(
                "SELECT summary FROM ai_daily_summaries WHERE day = ?",
                (day,),
            ).fetchone()
        if row is None:
            return ""
        return str(row["summary"])

    def upsert_journal_entry(
        self,
        day: str,
        intentions: str,
        reflections: str,
        notes: str,
        summary: str,
    ) -> None:
        now = datetime.now().astimezone().isoformat()
        with self._lock, self._connection() as conn:
            conn.execute(
                """
                INSERT INTO journal_entries(day, intentions, reflections, notes, summary, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET
                    intentions = excluded.intentions,
                    reflections = excluded.reflections,
                    notes = excluded.notes,
                    summary = excluded.summary,
                    updated_at = excluded.updated_at
                """,
                (day, intentions, reflections, notes, summary, now),
            )
            conn.commit()

    def get_journal_entry(self, day: str) -> JournalEntry:
        with self._lock, self._connection() as conn:
            row = conn.execute(
                """
                SELECT day, intentions, reflections, notes, summary, updated_at
                FROM journal_entries
                WHERE day = ?
                """,
                (day,),
            ).fetchone()

        if row is None:
            return JournalEntry(
                day=day,
                intentions="",
                reflections="",
                notes="",
                summary="",
                updated_at="",
            )

        return JournalEntry(
            day=str(row["day"]),
            intentions=str(row["intentions"]),
            reflections=str(row["reflections"]),
            notes=str(row["notes"]),
            summary=str(row["summary"]),
            updated_at=str(row["updated_at"]),
        )

    def list_recent_journal_entries(self, limit: int = 7) -> list[JournalEntry]:
        with self._lock, self._connection() as conn:
            rows = conn.execute(
                """
                SELECT day, intentions, reflections, notes, summary, updated_at
                FROM journal_entries
                ORDER BY day DESC
                LIMIT ?
                """,
                (int(limit),),
            ).fetchall()
        return [
            JournalEntry(
                day=str(row["day"]),
                intentions=str(row["intentions"]),
                reflections=str(row["reflections"]),
                notes=str(row["notes"]),
                summary=str(row["summary"]),
                updated_at=str(row["updated_at"]),
            )
            for row in rows
        ]

    def insert_dashboard_tile(self, day: str, question: str, answer: str) -> int:
        now = datetime.now().astimezone().isoformat()
        with self._lock, self._connection() as conn:
            cursor = conn.execute(
                """
                INSERT INTO dashboard_tiles(day, question, answer, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (day, question, answer, now),
            )
            conn.commit()
            return int(cursor.lastrowid)

    def list_dashboard_tiles(self, day: str) -> list[DashboardTile]:
        with self._lock, self._connection() as conn:
            rows = conn.execute(
                """
                SELECT id, day, question, answer, created_at
                FROM dashboard_tiles
                WHERE day = ?
                ORDER BY id DESC
                """,
                (day,),
            ).fetchall()
        return [
            DashboardTile(
                id=int(row["id"]),
                day=str(row["day"]),
                question=str(row["question"]),
                answer=str(row["answer"]),
                created_at=str(row["created_at"]),
            )
            for row in rows
        ]

    def clear_dashboard_tiles(self, day: str) -> None:
        with self._lock, self._connection() as conn:
            conn.execute("DELETE FROM dashboard_tiles WHERE day = ?", (day,))
            conn.commit()

    def list_screenshot_paths_for_day(self, day: date) -> list[str]:
        with self._lock, self._connection() as conn:
            rows = conn.execute(
                """
                SELECT file_path
                FROM screenshots
                WHERE substr(captured_at, 1, 10) = ?
                ORDER BY captured_at ASC
                """,
                (day.isoformat(),),
            ).fetchall()
        return [str(row["file_path"]) for row in rows]

    def total_screenshot_bytes(self) -> int:
        with self._lock, self._connection() as conn:
            row = conn.execute("SELECT COALESCE(SUM(file_size), 0) AS total FROM screenshots").fetchone()
        return int(row["total"]) if row is not None else 0

    def enforce_storage_limit(self, max_bytes: int) -> tuple[int, int]:
        if max_bytes <= 0:
            return (0, 0)

        removed_count = 0
        removed_bytes = 0

        with self._lock, self._connection() as conn:
            total = conn.execute("SELECT COALESCE(SUM(file_size), 0) AS total FROM screenshots").fetchone()
            current = int(total["total"]) if total else 0
            if current <= max_bytes:
                return (0, 0)

            rows = conn.execute(
                """
                SELECT id, file_path, file_size
                FROM screenshots
                ORDER BY captured_at ASC
                """
            ).fetchall()

            for row in rows:
                if current <= max_bytes:
                    break
                file_size = int(row["file_size"])
                file_path = Path(str(row["file_path"]))
                try:
                    if file_path.exists():
                        file_path.unlink()
                except OSError:
                    # Continue cleanup even if file deletion fails
                    pass

                conn.execute("DELETE FROM screenshots WHERE id = ?", (int(row["id"]),))
                current -= file_size
                removed_count += 1
                removed_bytes += file_size

            conn.commit()

        return (removed_count, removed_bytes)

    @staticmethod
    def _row_to_record(row: sqlite3.Row) -> ScreenshotRecord:
        try:
            captured_at = datetime.fromisoformat(str(row["captured_at"]))
        except ValueError:
            captured_at = datetime.now().astimezone()

        return ScreenshotRecord(
            id=int(row["id"]),
            captured_at=captured_at,
            file_path=str(row["file_path"]),
            file_size=int(row["file_size"]),
            window_title=str(row["window_title"]),
            process_name=str(row["process_name"]),
        )
