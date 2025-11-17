"""
Storage cleanup service - removes old recordings
"""

import os
from datetime import datetime, timedelta
from pathlib import Path
from threading import Thread, Event
import time


class CleanupService:
    """Manages automatic cleanup of old recordings"""

    def __init__(self, config, storage):
        self.config = config
        self.storage = storage
        self.is_running = False
        self._stop_event = Event()
        self._cleanup_thread = None

    def start(self):
        """Start cleanup service"""
        if self.is_running:
            return

        self.is_running = True
        self._stop_event.clear()
        self._cleanup_thread = Thread(target=self._cleanup_loop, daemon=True)
        self._cleanup_thread.start()
        print("🧹 Cleanup service started")

    def stop(self):
        """Stop cleanup service"""
        if not self.is_running:
            return

        self.is_running = False
        self._stop_event.set()
        if self._cleanup_thread:
            self._cleanup_thread.join(timeout=5)
        print("⏹️  Cleanup service stopped")

    def _cleanup_loop(self):
        """Background loop to clean up old recordings"""
        # Run cleanup daily at 3 AM, or immediately if first run
        last_cleanup = self.config.get('last_cleanup_time', 0)
        now = time.time()

        # If never run or more than 24 hours ago, run immediately
        if now - last_cleanup > 24 * 3600:
            self._run_cleanup()

        while not self._stop_event.is_set():
            # Check every hour
            if self._stop_event.wait(timeout=3600):
                break

            # Run cleanup at 3 AM
            current_hour = datetime.now().hour
            if current_hour == 3:
                last_cleanup = self.config.get('last_cleanup_time', 0)
                if now - last_cleanup > 12 * 3600:  # Don't run twice in 12 hours
                    self._run_cleanup()

    def _run_cleanup(self):
        """Execute cleanup of old recordings"""
        print("🧹 Running storage cleanup...")

        retention_days = self.config.get('retention_days', 3)
        cutoff_time = (datetime.now() - timedelta(days=retention_days)).timestamp()

        try:
            # Get old chunks from database
            chunks = self.storage.get_chunks_for_batch(0, cutoff_time)

            deleted_count = 0
            freed_bytes = 0

            for chunk in chunks:
                file_path = Path(chunk['file_path'])
                if file_path.exists():
                    try:
                        file_size = file_path.stat().st_size
                        file_path.unlink()
                        freed_bytes += file_size
                        deleted_count += 1
                    except Exception as e:
                        print(f"❌ Error deleting {file_path}: {e}")

            # Delete from database
            deleted_db_count = self.storage.delete_old_chunks(cutoff_time)

            freed_mb = freed_bytes / (1024 * 1024)
            print(f"✅ Cleanup complete: Deleted {deleted_count} files "
                  f"({freed_mb:.1f} MB), {deleted_db_count} database records")

            # Update last cleanup time
            self.config.set('last_cleanup_time', time.time())

        except Exception as e:
            print(f"❌ Cleanup error: {e}")

    def run_now(self):
        """Trigger immediate cleanup"""
        Thread(target=self._run_cleanup, daemon=True).start()
