"""
Database storage for chunks, batches, and timeline cards
"""

import sqlite3
import json
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Any
from contextlib import contextmanager


class Storage:
    """SQLite database manager for Dayflow"""

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self._init_database()

    @contextmanager
    def _get_connection(self):
        """Context manager for database connections"""
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row  # Return rows as dictionaries
        try:
            yield conn
            conn.commit()
        except Exception as e:
            conn.rollback()
            raise e
        finally:
            conn.close()

    def _init_database(self):
        """Initialize database schema"""
        with self._get_connection() as conn:
            cursor = conn.cursor()

            # Chunks table - individual 15-second recordings
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS chunks (
                    id TEXT PRIMARY KEY,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    file_path TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    batch_id TEXT
                )
            """)

            # Batches table - groups of chunks for analysis
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS batches (
                    id TEXT PRIMARY KEY,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    analyzed_at REAL
                )
            """)

            # Timeline cards table - generated timeline entries
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS timeline_cards (
                    id TEXT PRIMARY KEY,
                    batch_id TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT,
                    category TEXT,
                    color TEXT,
                    created_at REAL NOT NULL,
                    FOREIGN KEY (batch_id) REFERENCES batches(id)
                )
            """)

            # Create indexes
            cursor.execute("""
                CREATE INDEX IF NOT EXISTS idx_chunks_start_time
                ON chunks(start_time)
            """)
            cursor.execute("""
                CREATE INDEX IF NOT EXISTS idx_chunks_batch_id
                ON chunks(batch_id)
            """)
            cursor.execute("""
                CREATE INDEX IF NOT EXISTS idx_timeline_cards_start_time
                ON timeline_cards(start_time)
            """)

            conn.commit()

    # Chunk operations
    def insert_chunk(self, chunk_id: str, start_time: float, end_time: float,
                     file_path: str, status: str = 'pending') -> str:
        """Insert a new chunk record"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO chunks (id, start_time, end_time, file_path, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (chunk_id, start_time, end_time, file_path, status, datetime.now().timestamp()))
        return chunk_id

    def update_chunk_status(self, chunk_id: str, status: str):
        """Update chunk status"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                UPDATE chunks SET status = ? WHERE id = ?
            """, (status, chunk_id))

    def get_chunks_for_batch(self, start_time: float, end_time: float) -> List[Dict]:
        """Get all chunks in a time range"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT * FROM chunks
                WHERE start_time >= ? AND end_time <= ? AND status = 'completed'
                ORDER BY start_time
            """, (start_time, end_time))
            return [dict(row) for row in cursor.fetchall()]

    def delete_old_chunks(self, before_timestamp: float) -> int:
        """Delete chunks older than specified timestamp"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                DELETE FROM chunks WHERE start_time < ?
            """, (before_timestamp,))
            return cursor.rowcount

    # Batch operations
    def insert_batch(self, batch_id: str, start_time: float, end_time: float) -> str:
        """Insert a new batch record"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO batches (id, start_time, end_time, status, created_at)
                VALUES (?, ?, ?, ?, ?)
            """, (batch_id, start_time, end_time, 'pending', datetime.now().timestamp()))
        return batch_id

    def update_batch_status(self, batch_id: str, status: str):
        """Update batch status"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                UPDATE batches SET status = ?, analyzed_at = ?
                WHERE id = ?
            """, (status, datetime.now().timestamp(), batch_id))

    # Timeline card operations
    def insert_timeline_card(self, card_id: str, batch_id: str, start_time: float,
                            end_time: float, title: str, summary: str = '',
                            category: str = 'Other', color: str = '#808080') -> str:
        """Insert a new timeline card"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO timeline_cards
                (id, batch_id, start_time, end_time, title, summary, category, color, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (card_id, batch_id, start_time, end_time, title, summary,
                  category, color, datetime.now().timestamp()))
        return card_id

    def get_timeline_cards(self, start_date: Optional[datetime] = None,
                          end_date: Optional[datetime] = None) -> List[Dict]:
        """Get timeline cards, optionally filtered by date range"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if start_date and end_date:
                cursor.execute("""
                    SELECT * FROM timeline_cards
                    WHERE start_time >= ? AND start_time <= ?
                    ORDER BY start_time DESC
                """, (start_date.timestamp(), end_date.timestamp()))
            else:
                cursor.execute("""
                    SELECT * FROM timeline_cards
                    ORDER BY start_time DESC
                    LIMIT 100
                """)
            return [dict(row) for row in cursor.fetchall()]

    def get_timeline_cards_for_today(self) -> List[Dict]:
        """Get timeline cards for today"""
        today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
        today_end = datetime.now()
        return self.get_timeline_cards(today_start, today_end)
