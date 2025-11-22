"""
Main application controller
Coordinates all components of Dayflow
"""

from pathlib import Path
from core.config import config
from core.storage import Storage
from core.recorder import ScreenRecorder
from core.cleanup import CleanupService
from ai.gemini_provider import GeminiProvider
from ai.ollama_provider import OllamaProvider
from analysis.timeline_generator import TimelineGenerator


class AppController:
    """Main application controller"""

    def __init__(self):
        # Core components
        self.config = config
        self.storage = Storage(config.db_path)

        # Recording
        self.recorder = ScreenRecorder(config, self.storage)
        self.is_recording = False

        # Analysis
        self.timeline_generator = TimelineGenerator(config, self.storage)
        self.llm_provider = None

        # Cleanup
        self.cleanup_service = CleanupService(config, self.storage)

        # UI (set later)
        self.window = None
        self.tray_icon = None

        # Initialize LLM provider
        self.init_llm_provider()

    def init_llm_provider(self):
        """Initialize LLM provider based on config"""
        provider_type = self.config.get('llm_provider', 'gemini')

        try:
            if provider_type == 'gemini':
                api_key = self.config.get('gemini_api_key', '')
                if not api_key:
                    print("⚠️  Gemini API key not configured")
                    self.llm_provider = None
                else:
                    self.llm_provider = GeminiProvider(api_key)
                    print("✅ Gemini provider initialized")
            else:  # ollama
                base_url = self.config.get('ollama_base_url', 'http://localhost:11434')
                model = self.config.get('ollama_model', 'llava')
                self.llm_provider = OllamaProvider(base_url, model)
                print("✅ Ollama provider initialized")

            # Set provider for timeline generator
            self.timeline_generator.set_llm_provider(self.llm_provider)

        except Exception as e:
            print(f"❌ Error initializing LLM provider: {e}")
            self.llm_provider = None

    def start_recording(self):
        """Start screen recording"""
        self.recorder.start_recording()
        self.is_recording = True
        self.config.set('recording_enabled', True)

    def stop_recording(self):
        """Stop screen recording"""
        self.recorder.stop_recording()
        self.is_recording = False
        self.config.set('recording_enabled', False)

    def analyze_now(self):
        """Trigger immediate analysis"""
        self.timeline_generator.analyze_now()

    def start_services(self):
        """Start background services"""
        # Start timeline generator
        self.timeline_generator.start()

        # Start cleanup service
        self.cleanup_service.start()

        # Auto-start recording if enabled
        if self.config.get('recording_enabled', False):
            self.start_recording()

    def stop_services(self):
        """Stop all background services"""
        self.stop_recording()
        self.timeline_generator.stop()
        self.cleanup_service.stop()

    def run(self):
        """Run the application"""
        # Import here to avoid circular dependency
        from ui.main_window import MainWindow
        from ui.tray_icon import TrayIcon

        # Start services
        self.start_services()

        # Create and show main window
        self.window = MainWindow(self)

        # Create tray icon
        self.tray_icon = TrayIcon(self)
        self.tray_icon.run()

        # Run main loop
        try:
            self.window.mainloop()
        finally:
            # Cleanup
            self.stop_services()
            if self.tray_icon:
                self.tray_icon.stop()
