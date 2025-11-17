"""
Timeline generation from recorded chunks
Manages batch analysis every 15 minutes
"""

import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from threading import Thread, Event
from typing import Optional, Callable


# Category color mapping
CATEGORY_COLORS = {
    'Work': '#4CAF50',
    'Communication': '#2196F3',
    'Development': '#9C27B0',
    'Design': '#FF5722',
    'Entertainment': '#FF9800',
    'Productivity': '#00BCD4',
    'Research': '#3F51B5',
    'Social Media': '#E91E63',
    'Video': '#F44336',
    'Music': '#673AB7',
    'Gaming': '#009688',
    'Other': '#757575'
}


class TimelineGenerator:
    """Manages analysis and timeline card generation"""

    def __init__(self, config, storage):
        self.config = config
        self.storage = storage
        self.is_running = False
        self._stop_event = Event()
        self._analysis_thread: Optional[Thread] = None
        self.llm_provider = None
        self.on_card_generated: Optional[Callable] = None

    def set_llm_provider(self, provider):
        """Set the LLM provider (Gemini or Ollama)"""
        self.llm_provider = provider

    def start(self):
        """Start timeline generation background process"""
        if self.is_running:
            return

        self.is_running = True
        self._stop_event.clear()
        self._analysis_thread = Thread(target=self._analysis_loop, daemon=True)
        self._analysis_thread.start()
        print("📊 Timeline generator started")

    def stop(self):
        """Stop timeline generation"""
        if not self.is_running:
            return

        self.is_running = False
        self._stop_event.set()
        if self._analysis_thread:
            self._analysis_thread.join(timeout=5)
        print("⏹️  Timeline generator stopped")

    def _analysis_loop(self):
        """Background loop to analyze batches periodically"""
        analysis_interval = self.config.get('analysis_interval', 900)  # 15 minutes

        while not self._stop_event.wait(timeout=60):  # Check every minute
            try:
                # Check if it's time to analyze
                now = datetime.now()
                last_analysis_time = self.config.get('last_analysis_time', 0)

                if now.timestamp() - last_analysis_time >= analysis_interval:
                    self._analyze_recent_chunks()
                    self.config.set('last_analysis_time', now.timestamp())

            except Exception as e:
                print(f"❌ Analysis loop error: {e}")

    def _analyze_recent_chunks(self):
        """Analyze chunks from the last analysis period"""
        if not self.llm_provider:
            print("⚠️  No LLM provider configured, skipping analysis")
            return

        analysis_interval = self.config.get('analysis_interval', 900)
        now = datetime.now()
        last_analysis_time = self.config.get('last_analysis_time', 0)

        # Get time range for analysis
        if last_analysis_time == 0:
            # First analysis - use last 15 minutes
            start_time = (now - timedelta(seconds=analysis_interval)).timestamp()
        else:
            start_time = last_analysis_time

        end_time = now.timestamp()

        # Get chunks in this range
        chunks = self.storage.get_chunks_for_batch(start_time, end_time)

        if not chunks:
            print("📭 No chunks to analyze")
            return

        print(f"📊 Analyzing {len(chunks)} chunks from last {analysis_interval//60} minutes...")

        # Create batch record
        batch_id = str(uuid.uuid4())
        self.storage.insert_batch(batch_id, start_time, end_time)

        try:
            # Get video file paths
            video_paths = [Path(chunk['file_path']) for chunk in chunks
                          if Path(chunk['file_path']).exists()]

            if not video_paths:
                print("❌ No valid video files found")
                self.storage.update_batch_status(batch_id, 'failed')
                return

            # Analyze videos
            results = self.llm_provider.analyze_batch(video_paths)

            if not results:
                print("❌ Analysis returned no results")
                self.storage.update_batch_status(batch_id, 'failed')
                return

            # Create timeline cards from results
            for i, result in enumerate(results):
                chunk = chunks[min(i, len(chunks)-1)]  # Match to chunk (or use last if fewer results)

                card_id = str(uuid.uuid4())
                title = result.get('title', 'Screen Activity')
                summary = result.get('summary', '')
                category = result.get('category', 'Other')
                color = CATEGORY_COLORS.get(category, '#757575')

                self.storage.insert_timeline_card(
                    card_id=card_id,
                    batch_id=batch_id,
                    start_time=chunk['start_time'],
                    end_time=chunk['end_time'],
                    title=title,
                    summary=summary,
                    category=category,
                    color=color
                )

                print(f"✅ Created card: {title}")

                # Notify callback
                if self.on_card_generated:
                    self.on_card_generated(card_id)

            self.storage.update_batch_status(batch_id, 'completed')
            print(f"🎉 Analysis complete: {len(results)} cards generated")

        except Exception as e:
            print(f"❌ Analysis error: {e}")
            self.storage.update_batch_status(batch_id, 'failed')

    def analyze_now(self):
        """Trigger immediate analysis of recent chunks"""
        Thread(target=self._analyze_recent_chunks, daemon=True).start()
