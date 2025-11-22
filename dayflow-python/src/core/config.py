"""
Configuration management for Dayflow
Handles settings storage and retrieval
"""

import os
import json
from pathlib import Path
from typing import Any, Optional


class Config:
    """Manage application configuration"""

    def __init__(self):
        # Determine config directory based on platform
        if os.name == 'nt':  # Windows
            base = os.environ.get('LOCALAPPDATA', os.path.expanduser('~'))
            self.config_dir = Path(base) / 'Dayflow'
        else:  # macOS/Linux
            self.config_dir = Path.home() / 'Library' / 'Application Support' / 'Dayflow'

        self.config_dir.mkdir(parents=True, exist_ok=True)
        self.config_file = self.config_dir / 'config.json'
        self.recordings_dir = self.config_dir / 'recordings'
        self.db_path = self.config_dir / 'dayflow.db'

        self.recordings_dir.mkdir(exist_ok=True)

        # Load or create config
        self._config = self._load_config()

    def _load_config(self) -> dict:
        """Load configuration from file"""
        if self.config_file.exists():
            try:
                with open(self.config_file, 'r') as f:
                    return json.load(f)
            except Exception as e:
                print(f"Error loading config: {e}")
                return self._default_config()
        return self._default_config()

    def _default_config(self) -> dict:
        """Get default configuration"""
        return {
            'first_launch': True,
            'recording_enabled': False,
            'fps': 1,
            'chunk_duration': 15,  # seconds
            'target_height': 1080,
            'retention_days': 3,
            'llm_provider': 'gemini',  # 'gemini' or 'ollama'
            'gemini_api_key': '',
            'ollama_base_url': 'http://localhost:11434',
            'ollama_model': 'llava',
            'analysis_interval': 900,  # 15 minutes in seconds
            'idle_timeout': 300,  # 5 minutes
            'window_width': 1200,
            'window_height': 800,
        }

    def save(self):
        """Save configuration to file"""
        try:
            with open(self.config_file, 'w') as f:
                json.dump(self._config, f, indent=2)
        except Exception as e:
            print(f"Error saving config: {e}")

    def get(self, key: str, default: Any = None) -> Any:
        """Get configuration value"""
        return self._config.get(key, default)

    def set(self, key: str, value: Any):
        """Set configuration value and save"""
        self._config[key] = value
        self.save()

    def get_recordings_path(self, date_str: Optional[str] = None) -> Path:
        """Get path for recordings, optionally for specific date"""
        if date_str:
            path = self.recordings_dir / date_str
            path.mkdir(exist_ok=True)
            return path
        return self.recordings_dir


# Global config instance
config = Config()
