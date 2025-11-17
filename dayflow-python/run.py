#!/usr/bin/env python3
"""
Dayflow - Your day, automatically tracked

Cross-platform screen recording and AI-powered timeline app
Runs on Windows, macOS, and Linux
"""

import sys
import os

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from src.app_controller import AppController


def main():
    """Main entry point"""
    print("=" * 60)
    print("  Dayflow - Your Day, Automatically Tracked")
    print("=" * 60)
    print()

    # Create and run app
    app = AppController()

    # Check if first launch
    if app.config.get('first_launch', True):
        print("👋 Welcome to Dayflow!")
        print()
        print("To get started:")
        print("1. Click ⚙️  Settings to configure your AI provider")
        print("2. Click 🎥 Start Recording to begin tracking")
        print("3. Your timeline will appear automatically!")
        print()
        app.config.set('first_launch', False)

    print("🚀 Starting Dayflow...")
    print()

    try:
        app.run()
    except KeyboardInterrupt:
        print("\n👋 Shutting down Dayflow...")
        app.stop_services()
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
