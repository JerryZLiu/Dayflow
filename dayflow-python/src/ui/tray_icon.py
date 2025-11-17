"""
System tray icon for Dayflow
"""

import pystray
from PIL import Image, ImageDraw
from threading import Thread


class TrayIcon:
    """System tray icon manager"""

    def __init__(self, app_controller):
        self.app = app_controller
        self.icon = None
        self._create_icon()

    def _create_icon_image(self):
        """Create icon image"""
        # Create a simple icon (red/green dot)
        width = 64
        height = 64
        color = (255, 0, 0) if self.app.is_recording else (128, 128, 128)

        image = Image.new('RGB', (width, height), (255, 255, 255))
        draw = ImageDraw.Draw(image)
        draw.ellipse([4, 4, width-4, height-4], fill=color)

        return image

    def _create_icon(self):
        """Create and configure system tray icon"""
        menu = pystray.Menu(
            pystray.MenuItem(
                'Show Dayflow',
                self._show_window,
                default=True
            ),
            pystray.MenuItem(
                'Start Recording',
                self._toggle_recording,
                checked=lambda item: self.app.is_recording
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                'Settings',
                self._show_settings
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                'Quit',
                self._quit
            )
        )

        self.icon = pystray.Icon(
            'dayflow',
            self._create_icon_image(),
            'Dayflow',
            menu
        )

    def _show_window(self, icon, item):
        """Show main window"""
        if self.app.window:
            self.app.window.deiconify()
            self.app.window.lift()
            self.app.window.focus_force()

    def _toggle_recording(self, icon, item):
        """Toggle recording"""
        if self.app.is_recording:
            self.app.stop_recording()
        else:
            self.app.start_recording()
        # Update icon
        self.icon.icon = self._create_icon_image()

    def _show_settings(self, icon, item):
        """Show settings"""
        self._show_window(icon, item)
        if self.app.window:
            self.app.window.after(100, lambda: self.app.window._show_settings())

    def _quit(self, icon, item):
        """Quit application"""
        self.icon.stop()
        if self.app.window:
            self.app.window.quit()

    def run(self):
        """Run icon in background thread"""
        Thread(target=self.icon.run, daemon=True).start()

    def stop(self):
        """Stop icon"""
        if self.icon:
            self.icon.stop()
