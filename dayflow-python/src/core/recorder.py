"""
Screen recording functionality using mss (fast cross-platform screen capture)
Records at 1 FPS into 15-second chunks
"""

import time
import uuid
from datetime import datetime
from pathlib import Path
from threading import Thread, Event
from typing import Optional, Callable
import mss
import cv2
import numpy as np
from PIL import Image


class ScreenRecorder:
    """Records screen at 1 FPS in 15-second chunks"""

    def __init__(self, config, storage):
        self.config = config
        self.storage = storage
        self.is_recording = False
        self._stop_event = Event()
        self._record_thread: Optional[Thread] = None
        self._current_chunk_id: Optional[str] = None
        self.on_chunk_completed: Optional[Callable] = None

    def start_recording(self):
        """Start screen recording"""
        if self.is_recording:
            print("Already recording")
            return

        self.is_recording = True
        self._stop_event.clear()
        self._record_thread = Thread(target=self._recording_loop, daemon=True)
        self._record_thread.start()
        print("🎥 Recording started")

    def stop_recording(self):
        """Stop screen recording"""
        if not self.is_recording:
            return

        self.is_recording = False
        self._stop_event.set()
        if self._record_thread:
            self._record_thread.join(timeout=5)
        print("⏹️  Recording stopped")

    def _recording_loop(self):
        """Main recording loop - runs in separate thread"""
        fps = self.config.get('fps', 1)
        chunk_duration = self.config.get('chunk_duration', 15)
        interval = 1.0 / fps

        frames = []
        chunk_start_time = time.time()
        chunk_start_dt = datetime.now()

        with mss.mss() as sct:
            # Get primary monitor
            monitor = sct.monitors[1]  # Monitor 1 is primary (0 is all monitors combined)

            while not self._stop_event.is_set():
                frame_start = time.time()

                try:
                    # Capture screenshot
                    screenshot = sct.grab(monitor)

                    # Convert to numpy array (BGR for OpenCV)
                    frame = np.array(screenshot)
                    frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)

                    # Resize to target height while maintaining aspect ratio
                    target_height = self.config.get('target_height', 1080)
                    if frame.shape[0] != target_height:
                        aspect_ratio = frame.shape[1] / frame.shape[0]
                        target_width = int(target_height * aspect_ratio)
                        frame = cv2.resize(frame, (target_width, target_height))

                    frames.append(frame)

                    # Check if chunk duration reached
                    elapsed = time.time() - chunk_start_time
                    if elapsed >= chunk_duration:
                        # Save chunk
                        self._save_chunk(frames, chunk_start_dt, datetime.now())

                        # Reset for next chunk
                        frames = []
                        chunk_start_time = time.time()
                        chunk_start_dt = datetime.now()

                except Exception as e:
                    print(f"Error capturing frame: {e}")

                # Sleep to maintain FPS
                frame_time = time.time() - frame_start
                sleep_time = max(0, interval - frame_time)
                time.sleep(sleep_time)

        # Save any remaining frames
        if frames:
            self._save_chunk(frames, chunk_start_dt, datetime.now())

    def _save_chunk(self, frames, start_dt: datetime, end_dt: datetime):
        """Save frames as video chunk"""
        if not frames:
            return

        chunk_id = str(uuid.uuid4())
        date_str = start_dt.strftime('%Y-%m-%d')
        recordings_path = self.config.get_recordings_path(date_str)

        # Generate filename
        timestamp_str = start_dt.strftime('%H-%M-%S')
        filename = f"chunk_{timestamp_str}_{chunk_id[:8]}.mp4"
        filepath = recordings_path / filename

        try:
            # Get video dimensions from first frame
            height, width, _ = frames[0].shape

            # Create video writer (H.264 codec)
            fourcc = cv2.VideoWriter_fourcc(*'mp4v')  # or 'avc1' for H.264
            fps = self.config.get('fps', 1)
            out = cv2.VideoWriter(str(filepath), fourcc, fps, (width, height))

            # Write frames
            for frame in frames:
                out.write(frame)

            out.release()

            # Store in database
            self.storage.insert_chunk(
                chunk_id=chunk_id,
                start_time=start_dt.timestamp(),
                end_time=end_dt.timestamp(),
                file_path=str(filepath),
                status='completed'
            )

            print(f"✅ Saved chunk: {filename} ({len(frames)} frames)")

            # Notify callback
            if self.on_chunk_completed:
                self.on_chunk_completed(chunk_id)

        except Exception as e:
            print(f"❌ Error saving chunk: {e}")
            # Mark as failed in database
            self.storage.insert_chunk(
                chunk_id=chunk_id,
                start_time=start_dt.timestamp(),
                end_time=end_dt.timestamp(),
                file_path=str(filepath),
                status='failed'
            )
