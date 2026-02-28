from __future__ import annotations

import argparse
import hashlib
import queue
import subprocess
import threading
import tkinter as tk
import webbrowser
from datetime import date, datetime, timedelta
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

from PIL import Image, ImageTk

from . import __version__
from .ai import AITimelineGenerator
from .capture import ScreenCaptureService
from .database import DayflowWindowsDatabase
from .models import AITimelineCard, CaptureResult
from .paths import asset_path, data_directory, database_path, ensure_directories, screenshots_directory
from .timeline import build_timeline_cards, format_duration

INTERVAL_SETTING_KEY = "capture_interval_seconds"
AI_PROVIDER_SETTING_KEY = "ai_provider"
AI_MODEL_SETTING_KEY = "ai_model"
AI_API_KEY_SETTING_KEY = "ai_api_key"
AI_ENDPOINT_SETTING_KEY = "ai_endpoint"
STORAGE_LIMIT_GB_SETTING_KEY = "storage_limit_gb"
AUTO_CLEANUP_SETTING_KEY = "auto_cleanup"
REMINDERS_ENABLED_SETTING_KEY = "reminders_enabled"
MORNING_REMINDER_TIME_SETTING_KEY = "morning_reminder_time"
EVENING_REMINDER_TIME_SETTING_KEY = "evening_reminder_time"
BUG_REPORT_URL = "https://github.com/JerryZLiu/Dayflow/issues"
JOURNAL_UNLOCKED_SETTING_KEY = "journal_unlocked"
JOURNAL_ONBOARDED_SETTING_KEY = "journal_onboarded"
JOURNAL_ACCESS_HASH = "909ca0096d519dcf94aba6069fa664842bdf9de264725a6c543c4926abe6bdfa"
LAUNCH_AT_LOGIN_SETTING_KEY = "launch_at_login"
ANALYTICS_ENABLED_SETTING_KEY = "analytics_enabled"
SHOW_DOCK_ICON_SETTING_KEY = "show_dock_icon"
SHOW_TIMELINE_ICONS_SETTING_KEY = "show_timeline_icons"
SHOW_JOURNAL_DEBUG_SETTING_KEY = "show_journal_debug"
OUTPUT_LANGUAGE_SETTING_KEY = "output_language_override"


class TimelapseWindow(tk.Toplevel):
    def __init__(self, master: tk.Tk, image_paths: list[str]):
        super().__init__(master)
        self.title("Dayflow Timelapse")
        self.geometry("1120x720")
        self.minsize(760, 500)
        self.configure(bg="#111111")

        self.image_paths = [p for p in image_paths if Path(p).exists()]
        self.index = 0
        self.playing = True
        self.speed_var = tk.DoubleVar(value=6.0)
        self._photo: ImageTk.PhotoImage | None = None

        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)

        self.image_label = tk.Label(self, bg="#111111", fg="white")
        self.image_label.grid(row=0, column=0, sticky="nsew")

        controls = ttk.Frame(self, padding=8)
        controls.grid(row=1, column=0, sticky="ew")
        controls.columnconfigure(4, weight=1)

        ttk.Button(controls, text="<<", command=self._prev).grid(row=0, column=0, padx=(0, 6))
        ttk.Button(controls, text="Play/Pause", command=self._toggle_play).grid(row=0, column=1, padx=(0, 6))
        ttk.Button(controls, text=">>", command=self._next).grid(row=0, column=2, padx=(0, 10))
        ttk.Label(controls, text="FPS").grid(row=0, column=3, padx=(0, 4))
        tk.Scale(
            controls,
            from_=1,
            to=24,
            orient=tk.HORIZONTAL,
            resolution=1,
            variable=self.speed_var,
            showvalue=True,
            length=220,
        ).grid(row=0, column=4, sticky="w")

        self._render_current()
        self._tick()

    def _toggle_play(self) -> None:
        self.playing = not self.playing

    def _prev(self) -> None:
        if not self.image_paths:
            return
        self.index = (self.index - 1) % len(self.image_paths)
        self._render_current()

    def _next(self) -> None:
        if not self.image_paths:
            return
        self.index = (self.index + 1) % len(self.image_paths)
        self._render_current()

    def _tick(self) -> None:
        if self.playing and self.image_paths:
            self.index = (self.index + 1) % len(self.image_paths)
            self._render_current()
        fps = max(1.0, float(self.speed_var.get()))
        self.after(max(40, int(1000 / fps)), self._tick)

    def _render_current(self) -> None:
        if not self.image_paths:
            self.image_label.configure(text="No screenshots available for this day.", image="")
            self._photo = None
            return
        path = self.image_paths[self.index]
        try:
            image = Image.open(path)
        except OSError:
            return
        max_w = max(320, self.winfo_width() - 40)
        max_h = max(240, self.winfo_height() - 120)
        image.thumbnail((max_w, max_h), Image.Resampling.LANCZOS)
        self._photo = ImageTk.PhotoImage(image)
        self.image_label.configure(image=self._photo, text="")


class DayflowWindowsApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Dayflow for Windows")
        self.geometry("1480x920")
        self.minsize(1200, 760)
        self.configure(bg="#f7e3cb")

        self._image_refs: dict[str, ImageTk.PhotoImage] = {}
        self.sidebar_images: dict[tuple[str, bool], ImageTk.PhotoImage] = {}
        self._preview_photo: ImageTk.PhotoImage | None = None
        self._load_assets()

        ensure_directories()
        self.db = DayflowWindowsDatabase(database_path())
        self.capture_service = ScreenCaptureService(self.db)
        self.ai_generator = AITimelineGenerator()
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()

        self._configure_style()

        self.selected_view = tk.StringVar(value="timeline")
        self.date_var = tk.StringVar(value=date.today().isoformat())
        self.interval_var = tk.StringVar(value=f"{self.db.get_setting_float(INTERVAL_SETTING_KEY, 10.0):g}")

        self.ai_provider_var = tk.StringVar(value=self.db.get_setting(AI_PROVIDER_SETTING_KEY, "gemini") or "gemini")
        self.ai_model_var = tk.StringVar(value=self.db.get_setting(AI_MODEL_SETTING_KEY, "gemini-1.5-flash") or "gemini-1.5-flash")
        self.ai_api_key_var = tk.StringVar(value=self.db.get_setting(AI_API_KEY_SETTING_KEY, "") or "")
        self.ai_endpoint_var = tk.StringVar(value=self.db.get_setting(AI_ENDPOINT_SETTING_KEY, "http://localhost:1234/v1/chat/completions") or "http://localhost:1234/v1/chat/completions")
        self.storage_limit_gb_var = tk.StringVar(value=self.db.get_setting(STORAGE_LIMIT_GB_SETTING_KEY, "8") or "8")
        self.auto_cleanup_var = tk.BooleanVar(value=(self.db.get_setting(AUTO_CLEANUP_SETTING_KEY, "1") == "1"))
        self.reminders_enabled_var = tk.BooleanVar(value=(self.db.get_setting(REMINDERS_ENABLED_SETTING_KEY, "0") == "1"))
        self.morning_reminder_var = tk.StringVar(value=self.db.get_setting(MORNING_REMINDER_TIME_SETTING_KEY, "09:00") or "09:00")
        self.evening_reminder_var = tk.StringVar(value=self.db.get_setting(EVENING_REMINDER_TIME_SETTING_KEY, "18:30") or "18:30")
        self.journal_unlocked_var = tk.BooleanVar(value=(self.db.get_setting(JOURNAL_UNLOCKED_SETTING_KEY, "0") == "1"))
        self.journal_onboarded_var = tk.BooleanVar(value=(self.db.get_setting(JOURNAL_ONBOARDED_SETTING_KEY, "0") == "1"))
        self.journal_access_code_var = tk.StringVar()

        self.launch_at_login_var = tk.BooleanVar(value=(self.db.get_setting(LAUNCH_AT_LOGIN_SETTING_KEY, "0") == "1"))
        self.analytics_enabled_var = tk.BooleanVar(value=(self.db.get_setting(ANALYTICS_ENABLED_SETTING_KEY, "1") == "1"))
        self.show_dock_icon_var = tk.BooleanVar(value=(self.db.get_setting(SHOW_DOCK_ICON_SETTING_KEY, "1") == "1"))
        self.show_timeline_icons_var = tk.BooleanVar(value=(self.db.get_setting(SHOW_TIMELINE_ICONS_SETTING_KEY, "1") == "1"))
        self.show_journal_debug_var = tk.BooleanVar(value=(self.db.get_setting(SHOW_JOURNAL_DEBUG_SETTING_KEY, "0") == "1"))
        self.output_language_var = tk.StringVar(value=self.db.get_setting(OUTPUT_LANGUAGE_SETTING_KEY, "English") or "English")
        self.export_start_var = tk.StringVar(value=(date.today() - timedelta(days=6)).isoformat())
        self.export_end_var = tk.StringVar(value=date.today().isoformat())
        self.journal_debug_var = tk.StringVar(value="")

        self.status_var = tk.StringVar(value="Status: Idle")
        self.last_capture_var = tk.StringVar(value="Last capture: none")
        self.summary_var = tk.StringVar(value="No captures for selected date.")
        self.ai_status_var = tk.StringVar(value="AI: Not generated for selected day.")
        self.dashboard_status_var = tk.StringVar(value="Dashboard: Ask a question about your day.")
        self.journal_status_var = tk.StringVar(value="Journal: Ready.")
        self.settings_storage_status_var = tk.StringVar(value="Status: idle")
        self.settings_storage_last_check_var = tk.StringVar(value="Last check: never")
        self.settings_connection_status_var = tk.StringVar(value="Connection: not tested")

        self.dashboard_question_var = tk.StringVar()
        self._last_dashboard_question = ""
        self._last_dashboard_answer = ""
        self._reminder_sent_for: dict[str, set[str]] = {"morning": set(), "evening": set()}
        self.show_timeline_icons_var.trace_add("write", lambda *_: self._render_timeline_canvas())
        self.show_journal_debug_var.trace_add("write", lambda *_: self._update_journal_debug_panel())

        self._build_shell()
        self._run_storage_status_check()
        self._refresh_all()
        self._append_log("Dayflow Windows started.")
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(250, self._drain_events)
        self.after(30000, self._check_reminders)

    def _load_assets(self) -> None:
        logo = self._read_asset_rgba("logo-icon.png")
        if logo is not None:
            badge = self._fit_image(logo, 34)
            self._image_refs["logo_badge"] = ImageTk.PhotoImage(badge)
            window_icon = self._fit_image(logo, 64)
            self._image_refs["window_icon"] = ImageTk.PhotoImage(window_icon)
            try:
                self.iconphoto(True, self._image_refs["window_icon"])
            except tk.TclError:
                pass

        selected_bg = self._read_asset_rgba("sidebar-selected-bg.png")
        icon_files = {
            "dashboard": "sidebar-dashboard.png",
            "timeline": "sidebar-timeline.png",
            "journal": "sidebar-journal.png",
            "settings": "sidebar-settings.png",
            "reminder": "sidebar-reminder.png",
            "bug": "sidebar-reminder.png",
        }
        for key, filename in icon_files.items():
            icon = self._read_asset_rgba(filename)
            if icon is None:
                continue
            normal = self._compose_sidebar_icon(icon, selected=False, selected_background=selected_bg)
            selected = self._compose_sidebar_icon(icon, selected=True, selected_background=selected_bg)
            self.sidebar_images[(key, False)] = ImageTk.PhotoImage(normal)
            self.sidebar_images[(key, True)] = ImageTk.PhotoImage(selected)

    @staticmethod
    def _read_asset_rgba(filename: str) -> Image.Image | None:
        path = asset_path(filename)
        if not path.exists():
            return None
        try:
            return Image.open(path).convert("RGBA")
        except OSError:
            return None

    @staticmethod
    def _fit_image(image: Image.Image, size: int) -> Image.Image:
        source = image.copy().convert("RGBA")
        source.thumbnail((size, size), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        x = (size - source.width) // 2
        y = (size - source.height) // 2
        canvas.alpha_composite(source, (x, y))
        return canvas

    @staticmethod
    def _compose_sidebar_icon(
        icon: Image.Image,
        selected: bool,
        selected_background: Image.Image | None,
    ) -> Image.Image:
        canvas = Image.new("RGBA", (40, 40), (0, 0, 0, 0))
        if selected:
            if selected_background is not None:
                bg = selected_background.copy().convert("RGBA")
                bg.thumbnail((40, 40), Image.Resampling.LANCZOS)
                bg_canvas = Image.new("RGBA", (40, 40), (0, 0, 0, 0))
                bg_x = (40 - bg.width) // 2
                bg_y = (40 - bg.height) // 2
                bg_canvas.alpha_composite(bg, (bg_x, bg_y))
                canvas.alpha_composite(bg_canvas)
            else:
                fallback = Image.new("RGBA", (40, 40), (252, 239, 220, 255))
                canvas.alpha_composite(fallback)

        glyph = icon.copy().convert("RGBA")
        glyph.thumbnail((18, 18), Image.Resampling.LANCZOS)
        alpha = glyph.split()[-1]
        tint = (249, 110, 0, 255) if selected else (166, 123, 96, 255)
        colored = Image.new("RGBA", glyph.size, tint)
        colored.putalpha(alpha)
        x = (40 - glyph.width) // 2
        y = (40 - glyph.height) // 2
        canvas.alpha_composite(colored, (x, y))
        return canvas

    def _configure_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TFrame", background="#f8d9b9")
        style.configure("TLabel", background="#f8d9b9", foreground="#4e4138")
        style.configure("TCheckbutton", background="#f8d9b9", foreground="#4e4138")
        style.configure("TLabelframe", background="#f8d9b9", bordercolor="#efd8c2")
        style.configure("TLabelframe.Label", background="#f8d9b9", foreground="#6f655d")
        style.configure("TEntry", fieldbackground="#fff6ea", foreground="#4e4138", bordercolor="#ebd8c9")
        style.configure("TCombobox", fieldbackground="#fff6ea", foreground="#4e4138")
        style.configure("TButton", padding=(10, 5))
        style.configure("Title.TLabel", font=("Georgia", 28), foreground="#2f2a27", background="#f8d9b9")
        style.configure("Subtle.TLabel", font=("Segoe UI", 10), foreground="#6f655d", background="#f8d9b9")
        style.configure(
            "Treeview",
            background="#fff7eb",
            fieldbackground="#fff7eb",
            foreground="#4c4038",
            bordercolor="#ecd6bf",
            rowheight=26,
        )
        style.map("Treeview", background=[("selected", "#f8dcc0")], foreground=[("selected", "#2d2723")])
        style.configure("Treeview.Heading", background="#f4e2cf", foreground="#5b4a3f")

    def _build_shell(self) -> None:
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)

        shell = tk.Frame(self, bg="#f7e3cb")
        shell.grid(row=0, column=0, sticky="nsew", padx=16, pady=16)
        shell.columnconfigure(1, weight=1)
        shell.rowconfigure(0, weight=1)

        self.sidebar = tk.Frame(shell, bg="#f7e3cb", width=96)
        self.sidebar.grid(row=0, column=0, sticky="ns")
        self.sidebar.grid_propagate(False)

        content_shell = tk.Frame(
            shell,
            bg="#f9e2c7",
            highlightthickness=1,
            highlightbackground="#efd8c2",
            bd=0,
        )
        content_shell.grid(row=0, column=1, sticky="nsew", padx=(10, 0))
        content_shell.columnconfigure(0, weight=1)
        content_shell.rowconfigure(0, weight=1)

        self.content = tk.Frame(content_shell, bg="#f8d9b9", highlightthickness=0, bd=0)
        self.content.grid(row=0, column=0, sticky="nsew", padx=8, pady=8)
        self.content.columnconfigure(0, weight=1)
        self.content.rowconfigure(0, weight=1)

        self._build_sidebar()
        self._build_views()
        self._show_view("timeline")

    def _build_sidebar(self) -> None:
        logo_shell = tk.Frame(
            self.sidebar,
            bg="#fff7ed",
            highlightthickness=1,
            highlightbackground="#ecd8c6",
            bd=0,
        )
        logo_shell.pack(padx=18, pady=(8, 12))
        if "logo_badge" in self._image_refs:
            tk.Label(logo_shell, image=self._image_refs["logo_badge"], bg="#fff7ed", bd=0).pack(padx=8, pady=8)
        else:
            tk.Label(
                logo_shell,
                text="D",
                bg="#fff7ed",
                fg="#f96e00",
                font=("Georgia", 18, "bold"),
            ).pack(padx=10, pady=8)

        capsule = tk.Frame(
            self.sidebar,
            bg="#fffaf4",
            highlightthickness=1,
            highlightbackground="#ecd8c4",
            bd=0,
        )
        capsule.pack(fill="y", padx=14, pady=(0, 12))

        self.sidebar_buttons: dict[str, tk.Button] = {}
        self.sidebar_button_targets = {
            "dashboard": "dashboard",
            "timeline": "timeline",
            "journal": "journal",
            "settings": "settings",
            "reminder": "",
            "bug": "",
        }

        icon_order = ["dashboard", "timeline", "journal", "settings", "reminder", "bug"]
        fallback_labels = {
            "dashboard": "\u25a6",
            "timeline": "\u2307",
            "journal": "\u25ad",
            "settings": "\u2699",
            "reminder": "\u23f0",
            "bug": "\u26a0",
        }
        for key in icon_order:
            target_view = self.sidebar_button_targets[key]
            if key == "bug":
                command = self._open_bug_report
            elif key == "reminder":
                command = lambda: self._show_view("journal")
            else:
                command = lambda v=target_view: self._show_view(v)
            image = self.sidebar_images.get((key, False))
            btn = tk.Button(
                capsule,
                text="" if image is not None else fallback_labels.get(key, "?"),
                image=image or "",
                font=("Segoe UI Symbol", 11),
                bd=0,
                relief=tk.FLAT,
                bg="#fffaf4",
                activebackground="#fffaf4",
                command=command,
                cursor="hand2",
            )
            btn.pack(pady=(8 if key != "bug" else 4))
            self.sidebar_buttons[key] = btn

        tk.Frame(self.sidebar, bg="#f7e3cb").pack(fill="both", expand=True)
        tk.Label(
            self.sidebar,
            text=f"v{__version__}",
            bg="#f7e3cb",
            fg="#8c7f74",
            font=("Segoe UI", 9),
        ).pack(pady=(0, 12))

    def _build_views(self) -> None:
        self.views: dict[str, tk.Frame] = {}
        self.timeline_view = tk.Frame(self.content, bg="#f8d9b9")
        self.dashboard_view = tk.Frame(self.content, bg="#f8d9b9")
        self.journal_view = tk.Frame(self.content, bg="#f8d9b9")
        self.settings_view = tk.Frame(self.content, bg="#f8d9b9")

        for key, frame in [
            ("timeline", self.timeline_view),
            ("dashboard", self.dashboard_view),
            ("journal", self.journal_view),
            ("settings", self.settings_view),
        ]:
            frame.grid(row=0, column=0, sticky="nsew")
            frame.grid_remove()
            self.views[key] = frame

        self._build_timeline_view()
        self._build_dashboard_view()
        self._build_journal_view()
        self._build_settings_view()

    def _show_view(self, view_key: str) -> None:
        self.selected_view.set(view_key)
        for key, frame in self.views.items():
            if key == view_key:
                frame.grid()
                frame.tkraise()
            else:
                frame.grid_remove()
        self._update_sidebar_styles()
        if view_key == "dashboard":
            self._refresh_dashboard_tiles()
        if view_key == "journal":
            self._load_journal_for_selected_day()
            self._refresh_journal_access_gate()
            self._update_journal_debug_panel()
        if view_key == "settings":
            self._run_storage_status_check()

    def _update_sidebar_styles(self) -> None:
        active = self.selected_view.get()
        for key, btn in self.sidebar_buttons.items():
            target = self.sidebar_button_targets.get(key, "")
            selected = target == active and key != "bug"
            image = self.sidebar_images.get((key, selected))
            if image is not None:
                btn.configure(image=image, bg="#fffaf4", activebackground="#fffaf4")
            else:
                btn.configure(
                    fg="#f96e00" if selected else "#9f7b65",
                    bg="#fffaf4",
                    activebackground="#fffaf4",
                    activeforeground="#f96e00",
                )

    def _open_bug_report(self) -> None:
        try:
            webbrowser.open(BUG_REPORT_URL)
        except Exception as exc:  # noqa: BLE001
            self._append_log(f"Could not open bug report URL: {exc}")

    def _go_prev_day(self) -> None:
        self.date_var.set((self._selected_date() - timedelta(days=1)).isoformat())
        self._refresh_all()

    def _go_next_day(self) -> None:
        candidate = self._selected_date() + timedelta(days=1)
        if candidate <= date.today():
            self.date_var.set(candidate.isoformat())
            self._refresh_all()

    def _build_timeline_view(self) -> None:
        root = self.timeline_view
        root.configure(bg="#f8d9b9")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(4, weight=1)

        header = tk.Frame(root, bg="#f8d9b9")
        header.grid(row=0, column=0, sticky="ew", padx=20, pady=(12, 4))
        header.columnconfigure(0, weight=1)

        tk.Label(
            header,
            text="Timeline",
            bg="#f8d9b9",
            fg="#2f2a27",
            font=("Georgia", 38),
        ).grid(row=0, column=0, sticky="w")

        date_shell = tk.Frame(
            header,
            bg="#fff7ed",
            highlightthickness=1,
            highlightbackground="#edd7c1",
            bd=0,
        )
        date_shell.grid(row=0, column=1, sticky="e")

        def _small_icon_button(parent, text: str, cmd) -> tk.Button:
            return tk.Button(
                parent,
                text=text,
                command=cmd,
                bd=0,
                relief=tk.FLAT,
                bg="#fff7ed",
                fg="#8f7867",
                activebackground="#fff0df",
                activeforeground="#f96e00",
                padx=6,
                pady=4,
                font=("Segoe UI", 10, "bold"),
                cursor="hand2",
            )

        _small_icon_button(date_shell, "<", self._go_prev_day).grid(row=0, column=0, padx=(6, 2), pady=5)

        self.date_entry = tk.Entry(
            date_shell,
            textvariable=self.date_var,
            width=11,
            bd=0,
            relief=tk.FLAT,
            bg="#fff7ed",
            fg="#5b4637",
            font=("Segoe UI Semibold", 10),
            justify="center",
        )
        self.date_entry.grid(row=0, column=1, padx=2, ipady=3)

        _small_icon_button(date_shell, ">", self._go_next_day).grid(row=0, column=2, padx=(2, 6), pady=5)

        controls = tk.Frame(root, bg="#f8d9b9")
        controls.grid(row=1, column=0, sticky="ew", padx=20, pady=(0, 6))

        def _pill_button(parent, text: str, cmd, bg: str = "#f9ead6", fg: str = "#6b4d37") -> tk.Button:
            return tk.Button(
                parent,
                text=text,
                command=cmd,
                bd=0,
                relief=tk.FLAT,
                bg=bg,
                fg=fg,
                activebackground="#fdeedb",
                activeforeground="#f96e00",
                padx=11,
                pady=5,
                font=("Segoe UI Semibold", 9),
                cursor="hand2",
            )

        _pill_button(controls, "Refresh", self._refresh_all).pack(side="left", padx=(0, 6))
        _pill_button(controls, "Generate AI", self._generate_ai_timeline).pack(side="left", padx=(0, 6))
        _pill_button(controls, "Export", self._export_markdown).pack(side="left", padx=(0, 6))
        _pill_button(controls, "Timelapse", self._open_timelapse).pack(side="left", padx=(0, 10))

        tk.Label(controls, text="Every", bg="#f8d9b9", fg="#876753", font=("Segoe UI", 9)).pack(side="left", padx=(0, 3))
        tk.Spinbox(
            controls,
            from_=2,
            to=300,
            increment=1,
            width=4,
            textvariable=self.interval_var,
            bd=0,
            relief=tk.FLAT,
            bg="#fff8ef",
            fg="#5b4637",
            justify="center",
            font=("Segoe UI", 9),
        ).pack(side="left", padx=(0, 3))
        tk.Label(controls, text="sec", bg="#f8d9b9", fg="#876753", font=("Segoe UI", 9)).pack(side="left", padx=(0, 8))

        self.start_button = _pill_button(controls, "Start", self._start_capture, bg="#ffe1c3", fg="#7a4b2c")
        self.start_button.pack(side="left", padx=(0, 4))
        self.stop_button = _pill_button(controls, "Stop", self._stop_capture, bg="#f7dfcf", fg="#7a4b2c")
        self.stop_button.pack(side="left", padx=(0, 4))
        _pill_button(controls, "Capture", self._capture_now).pack(side="left", padx=(0, 4))
        _pill_button(controls, "Folder", self._open_data_folder).pack(side="left", padx=(0, 2))

        info = tk.Frame(root, bg="#f8d9b9")
        info.grid(row=2, column=0, sticky="ew", padx=22, pady=(0, 6))
        tk.Label(info, textvariable=self.status_var, bg="#f8d9b9", fg="#6f655d", font=("Segoe UI", 9)).pack(anchor="w")
        tk.Label(info, textvariable=self.last_capture_var, bg="#f8d9b9", fg="#6f655d", font=("Segoe UI", 9)).pack(anchor="w")
        tk.Label(info, textvariable=self.summary_var, bg="#f8d9b9", fg="#6f655d", font=("Segoe UI", 9)).pack(anchor="w")
        tk.Label(info, textvariable=self.ai_status_var, bg="#f8d9b9", fg="#6f655d", font=("Segoe UI", 9)).pack(anchor="w")

        chips = tk.Frame(root, bg="#f8d9b9")
        chips.grid(row=3, column=0, sticky="ew", padx=22, pady=(0, 8))
        self.timeline_filter_var = tk.StringVar(value="all")
        self.timeline_filter_buttons: dict[str, tk.Button] = {}

        chip_defs = [
            ("all", "\u231b All tasks"),
            ("core", "\U0001f9d1\u200d\U0001f4bb Core tasks"),
            ("personal", "\U0001f440 Personal tasks"),
            ("distractions", "\U0001f614 Distractions"),
            ("idle", "\U0001f634 Idle time"),
        ]
        for key, label in chip_defs:
            btn = tk.Button(
                chips,
                text=label,
                command=lambda k=key: self._set_timeline_filter(k),
                bd=0,
                relief=tk.FLAT,
                bg="#f1e4d5",
                fg="#6e5f54",
                activebackground="#faecd8",
                activeforeground="#7a4b2c",
                padx=12,
                pady=5,
                font=("Segoe UI Semibold", 10),
                cursor="hand2",
            )
            btn.pack(side="left", padx=(0, 8))
            self.timeline_filter_buttons[key] = btn

        self._update_filter_pills()

        body = tk.Frame(root, bg="#f8d9b9")
        body.grid(row=4, column=0, sticky="nsew", padx=16, pady=(0, 10))
        body.columnconfigure(0, weight=3)
        body.columnconfigure(1, weight=2)
        body.rowconfigure(0, weight=1)

        left_shell = tk.Frame(
            body,
            bg="#f5cfac",
            highlightthickness=1,
            highlightbackground="#efd3b6",
            bd=0,
        )
        left_shell.grid(row=0, column=0, sticky="nsew", padx=(6, 10), pady=(0, 6))
        left_shell.columnconfigure(0, weight=1)
        left_shell.rowconfigure(0, weight=1)

        self.timeline_card_canvas = tk.Canvas(
            left_shell,
            bg="#f5cfac",
            highlightthickness=0,
            bd=0,
            relief=tk.FLAT,
        )
        self.timeline_card_canvas.grid(row=0, column=0, sticky="nsew", padx=(10, 0), pady=10)
        self.timeline_canvas_scroll = tk.Scrollbar(left_shell, orient=tk.VERTICAL, command=self.timeline_card_canvas.yview)
        self.timeline_card_canvas.configure(yscrollcommand=self.timeline_canvas_scroll.set)
        self.timeline_canvas_scroll.grid(row=0, column=1, sticky="ns", padx=(0, 8), pady=10)
        self.timeline_card_canvas.bind("<Configure>", lambda _e: self._render_timeline_canvas())

        right_shell = tk.Frame(
            body,
            bg="#f8d4b4",
            highlightthickness=1,
            highlightbackground="#efd3b6",
            bd=0,
        )
        right_shell.grid(row=0, column=1, sticky="nsew", padx=(0, 8), pady=(0, 6))
        right_shell.columnconfigure(0, weight=1)
        right_shell.rowconfigure(8, weight=1)

        self.preview_title_var = tk.StringVar(value="No activity selected")
        self.preview_time_var = tk.StringVar(value="")
        self.focus_percent_var = tk.StringVar(value="0%")
        self.distraction_percent_var = tk.StringVar(value="0%")

        tk.Label(
            right_shell,
            textvariable=self.preview_title_var,
            bg="#f8d4b4",
            fg="#2f2723",
            font=("Segoe UI Semibold", 14),
            wraplength=360,
            justify="left",
        ).grid(row=0, column=0, sticky="w", padx=12, pady=(12, 2))

        tk.Label(
            right_shell,
            textvariable=self.preview_time_var,
            bg="#f8d4b4",
            fg="#6e6056",
            font=("Segoe UI", 10),
        ).grid(row=1, column=0, sticky="w", padx=12, pady=(0, 8))

        self.preview_image_label = tk.Label(
            right_shell,
            bg="#f0c69f",
            fg="#ffffff",
            text="No screenshots yet",
            font=("Segoe UI", 9),
            anchor="center",
        )
        self.preview_image_label.grid(row=2, column=0, sticky="ew", padx=12)

        tk.Label(
            right_shell,
            text="AI Daily Summary",
            bg="#f8d4b4",
            fg="#7b695d",
            font=("Segoe UI Semibold", 10),
        ).grid(row=3, column=0, sticky="w", padx=12, pady=(10, 4))

        self.ai_summary = ScrolledText(
            right_shell,
            wrap=tk.WORD,
            height=6,
            bd=0,
            relief=tk.FLAT,
            bg="#fde8d3",
            fg="#5a4637",
            font=("Segoe UI", 9),
        )
        self.ai_summary.grid(row=4, column=0, sticky="ew", padx=12)

        meter_row = tk.Frame(right_shell, bg="#f8d4b4")
        meter_row.grid(row=5, column=0, sticky="ew", padx=12, pady=(8, 6))
        meter_row.columnconfigure(0, weight=1)
        meter_row.columnconfigure(1, weight=1)

        focus_box = tk.Frame(meter_row, bg="#f8d4b4")
        focus_box.grid(row=0, column=0, sticky="ew", padx=(0, 8))
        tk.Label(focus_box, text="FOCUS METER", bg="#f8d4b4", fg="#7b695d", font=("Segoe UI", 9, "bold")).pack(anchor="w")
        tk.Label(focus_box, textvariable=self.focus_percent_var, bg="#f8d4b4", fg="#2f2723", font=("Segoe UI", 11, "bold")).pack(anchor="w")
        self.focus_meter_canvas = tk.Canvas(focus_box, height=8, bg="#f8d4b4", bd=0, highlightthickness=0)
        self.focus_meter_canvas.pack(fill="x", pady=(2, 0))

        distraction_box = tk.Frame(meter_row, bg="#f8d4b4")
        distraction_box.grid(row=0, column=1, sticky="ew")
        tk.Label(distraction_box, text="DISTRACTIONS", bg="#f8d4b4", fg="#7b695d", font=("Segoe UI", 9, "bold")).pack(anchor="w")
        tk.Label(distraction_box, textvariable=self.distraction_percent_var, bg="#f8d4b4", fg="#2f2723", font=("Segoe UI", 11, "bold")).pack(anchor="w")
        self.distraction_meter_canvas = tk.Canvas(distraction_box, height=8, bg="#f8d4b4", bd=0, highlightthickness=0)
        self.distraction_meter_canvas.pack(fill="x", pady=(2, 0))

        tk.Label(
            right_shell,
            text="AI Timeline Notes",
            bg="#f8d4b4",
            fg="#7b695d",
            font=("Segoe UI Semibold", 10),
        ).grid(row=6, column=0, sticky="w", padx=12, pady=(4, 4))

        self.ai_cards_text = ScrolledText(
            right_shell,
            wrap=tk.WORD,
            bd=0,
            relief=tk.FLAT,
            bg="#fde8d3",
            fg="#5a4637",
            font=("Segoe UI", 9),
        )
        self.ai_cards_text.grid(row=7, column=0, sticky="nsew", padx=12, pady=(0, 8))

        self.distraction_var = tk.StringVar(value="Distractions: n/a")
        tk.Label(
            right_shell,
            textvariable=self.distraction_var,
            bg="#f8d4b4",
            fg="#7f6d60",
            font=("Segoe UI", 9),
            wraplength=360,
            justify="left",
        ).grid(row=8, column=0, sticky="w", padx=12, pady=(0, 10))

    def _set_timeline_filter(self, filter_key: str) -> None:
        self.timeline_filter_var.set(filter_key)
        self._update_filter_pills()
        self._render_timeline_canvas()

    def _update_filter_pills(self) -> None:
        active = self.timeline_filter_var.get()
        for key, btn in self.timeline_filter_buttons.items():
            if key == active:
                btn.configure(bg="#ffe7cb", fg="#7a4b2c")
            else:
                btn.configure(bg="#f3e5d8", fg="#6e5f54")

    def _render_timeline_canvas(self) -> None:
        if not hasattr(self, "timeline_card_canvas"):
            return

        canvas = self.timeline_card_canvas
        width = max(540, canvas.winfo_width())
        cards = self._timeline_display_cards()

        canvas.delete("all")
        self._draw_timeline_background(canvas, width)

        rail_x = 104
        start_y = 52
        card_x = 128
        card_w = max(360, width - card_x - 30)
        y = start_y

        if not cards:
            canvas.create_text(
                card_x,
                y + 16,
                text="No timeline cards for this date. Start recording or generate AI timeline.",
                fill="#7f6d60",
                font=("Segoe UI", 11),
                anchor="w",
            )
            canvas.configure(scrollregion=(0, 0, width, y + 120))
            self._refresh_preview_panel()
            return

        total_height = start_y + len(cards) * 108 + 70
        canvas.create_line(rail_x, start_y - 8, rail_x, total_height - 34, fill="#2f2723", width=1)

        for entry in cards:
            category = entry["category"]
            fill, outline = _palette_for_category(category)
            dot_color = "#f35a4d" if category == "Distractions" else "#2f2723"
            if category == "Idle":
                dot_color = "#b0a9a3"

            canvas.create_text(
                rail_x - 14,
                y + 18,
                text=_friendly_time(str(entry["time_label"])),
                fill="#5d5047",
                font=("Segoe UI", 10),
                anchor="e",
            )
            canvas.create_oval(rail_x - 4, y + 14, rail_x + 4, y + 22, fill=dot_color, outline="#f5cfac")

            card_h = 86
            card_kwargs = {
                "fill": fill,
                "outline": outline,
                "width": 1.2,
            }
            if category == "Idle":
                card_kwargs["dash"] = (2, 2)
            self._canvas_round_rect(
                canvas,
                card_x,
                y,
                card_x + card_w,
                y + card_h,
                radius=10,
                **card_kwargs,
            )

            icon = _icon_for_category(category)
            title = str(entry["title"])
            subtitle = str(entry["subtitle"])
            icon_prefix = f"{icon}  " if self.show_timeline_icons_var.get() else ""
            canvas.create_text(
                card_x + 14,
                y + 24,
                text=f"{icon_prefix}{title}",
                fill="#231f1c",
                font=("Segoe UI Semibold", 12),
                anchor="w",
            )
            canvas.create_text(
                card_x + 14,
                y + 48,
                text=subtitle,
                fill="#6c5f56",
                font=("Segoe UI", 10),
                anchor="w",
            )
            y += card_h + 16

        canvas.configure(scrollregion=(0, 0, width, max(total_height, y + 24)))
        self._refresh_preview_panel()

    @staticmethod
    def _canvas_round_rect(
        canvas: tk.Canvas,
        x1: float,
        y1: float,
        x2: float,
        y2: float,
        radius: float = 10,
        **kwargs,
    ):
        points = [
            x1 + radius,
            y1,
            x2 - radius,
            y1,
            x2,
            y1,
            x2,
            y1 + radius,
            x2,
            y2 - radius,
            x2,
            y2,
            x2 - radius,
            y2,
            x1 + radius,
            y2,
            x1,
            y2,
            x1,
            y2 - radius,
            x1,
            y1 + radius,
            x1,
            y1,
        ]
        return canvas.create_polygon(points, smooth=True, splinesteps=24, **kwargs)

    def _draw_timeline_background(self, canvas: tk.Canvas, width: int) -> None:
        height = max(540, canvas.winfo_height())
        steps = max(1, height // 5)
        for i in range(steps):
            y1 = int(i * height / steps)
            y2 = int((i + 1) * height / steps)
            color = _mix_hex("#f6dcbf", "#f2c291", i / max(1, steps - 1))
            canvas.create_rectangle(0, y1, width, y2 + 1, fill=color, outline=color)
        glow_top = _mix_hex("#ffffff", "#f8d1af", 0.22)
        canvas.create_rectangle(0, 0, width, 32, fill=glow_top, outline=glow_top)

    def _refresh_preview_panel(self) -> None:
        if not hasattr(self, "preview_title_var"):
            return

        day_rows = getattr(self, "_classic_timeline_rows", [])
        if day_rows:
            latest = day_rows[-1]
            title = latest.window_title.strip() or latest.process_name.strip() or "Captured activity"
            self.preview_title_var.set(title[:68])
            local_time = latest.captured_at.astimezone().strftime("%I:%M %p").lstrip("0")
            self.preview_time_var.set(local_time)
            self._set_preview_image(latest.file_path)
        else:
            self.preview_title_var.set("No activity selected")
            self.preview_time_var.set("")
            self._set_preview_image(None)

        ai_cards = self.db.list_ai_timeline_for_day(self._selected_date().isoformat())
        focus_pct, distraction_pct = self._focus_distraction_percentages(ai_cards)
        if focus_pct == 0 and distraction_pct == 0:
            classic_cards = getattr(self, "_classic_timeline_cards", [])
            focus_seconds = 0.0
            distraction_seconds = 0.0
            for card in classic_cards:
                seconds = (card.end - card.start).total_seconds()
                if seconds <= 0:
                    continue
                category = _infer_category_from_classic(card.process_name, card.window_title)
                if category in {"Core", "Personal"}:
                    focus_seconds += seconds
                elif category == "Distractions":
                    distraction_seconds += seconds
            total = focus_seconds + distraction_seconds
            if total > 0:
                focus_pct = int(round((focus_seconds / total) * 100))
                distraction_pct = max(0, min(100, 100 - focus_pct))
        self.focus_percent_var.set(f"{focus_pct}%")
        self.distraction_percent_var.set(f"{distraction_pct}%")
        self._draw_meter(self.focus_meter_canvas, focus_pct / 100.0, "#f96e00")
        self._draw_meter(self.distraction_meter_canvas, distraction_pct / 100.0, "#ef7a37")

    def _set_preview_image(self, image_path: str | None) -> None:
        if not hasattr(self, "preview_image_label"):
            return
        if not image_path:
            self.preview_image_label.configure(image="", text="No screenshots yet")
            self._preview_photo = None
            return
        path = Path(image_path)
        if not path.exists():
            self.preview_image_label.configure(image="", text="Screenshot unavailable")
            self._preview_photo = None
            return
        try:
            image = Image.open(path).convert("RGB")
        except OSError:
            self.preview_image_label.configure(image="", text="Screenshot unavailable")
            self._preview_photo = None
            return
        image.thumbnail((370, 190), Image.Resampling.LANCZOS)
        self._preview_photo = ImageTk.PhotoImage(image)
        self.preview_image_label.configure(image=self._preview_photo, text="")

    @staticmethod
    def _draw_meter(canvas: tk.Canvas, ratio: float, fill: str) -> None:
        if canvas is None:
            return
        width = max(20, canvas.winfo_width())
        height = max(6, canvas.winfo_height())
        ratio = max(0.0, min(1.0, ratio))
        canvas.delete("all")
        canvas.create_rectangle(0, 0, width, height, fill="#f0d6bf", outline="#f0d6bf")
        if ratio > 0:
            canvas.create_rectangle(0, 0, int(width * ratio), height, fill=fill, outline=fill)

    @staticmethod
    def _focus_distraction_percentages(cards: list[AITimelineCard]) -> tuple[int, int]:
        if not cards:
            return (0, 0)
        focus_minutes = 0
        distraction_minutes = 0
        for card in cards:
            minutes = _duration_minutes(card.start, card.end)
            category = _normalize_category(card.category)
            if category in {"Core", "Personal"}:
                focus_minutes += minutes
            elif category == "Distractions":
                distraction_minutes += minutes
        total = focus_minutes + distraction_minutes
        if total <= 0:
            return (0, 0)
        focus_pct = int(round((focus_minutes / total) * 100))
        distraction_pct = max(0, min(100, 100 - focus_pct))
        return (focus_pct, distraction_pct)

    def _timeline_display_cards(self) -> list[dict[str, str]]:
        day = self._selected_date().isoformat()
        ai_cards = self.db.list_ai_timeline_for_day(day)
        display: list[dict[str, str]] = []
        selected_filter = self.timeline_filter_var.get() if hasattr(self, "timeline_filter_var") else "all"

        if ai_cards:
            for card in ai_cards:
                category = _normalize_category(card.category)
                if not _filter_matches(selected_filter, category):
                    continue
                display.append(
                    {
                        "time_label": card.start,
                        "title": card.title,
                        "subtitle": f"{card.start} - {card.end}  |  {card.summary or category}",
                        "category": category,
                    }
                )
            return display

        classic_cards = getattr(self, "_classic_timeline_cards", [])
        for card in classic_cards:
            category = _infer_category_from_classic(card.process_name, card.window_title)
            if not _filter_matches(selected_filter, category):
                continue
            start_s = _fmt_time(card.start)
            end_s = _fmt_time(card.end)
            display.append(
                {
                    "time_label": start_s,
                    "title": card.window_title[:84] or card.process_name,
                    "subtitle": f"{start_s} - {end_s}  |  {card.process_name}",
                    "category": category,
                }
            )
        return display

    def _build_dashboard_view(self) -> None:
        root = self.dashboard_view
        root.configure(bg="#f8d9b9")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(4, weight=1)

        header = ttk.Frame(root, padding=14)
        header.grid(row=0, column=0, sticky="ew")
        ttk.Label(header, text="Dashboard", style="Title.TLabel").pack(side="left")
        ttk.Label(header, text="  Ask a question about your selected day").pack(side="left")
        self.dashboard_entry = ttk.Entry(header, textvariable=self.dashboard_question_var, width=50)
        self.dashboard_entry.pack(side="left", padx=8)
        self.dashboard_entry.bind("<Return>", lambda _e: self._ask_dashboard_question())
        ttk.Button(header, text="Ask AI", command=self._ask_dashboard_question).pack(side="left", padx=(0, 4))
        ttk.Button(header, text="Save Tile", command=self._save_dashboard_tile).pack(side="left", padx=(0, 4))
        ttk.Button(header, text="Clear Tiles", command=self._clear_dashboard_tiles).pack(side="left")

        ttk.Label(root, textvariable=self.dashboard_status_var, padding=(14, 0, 14, 8)).grid(row=1, column=0, sticky="w")

        suggestions = tk.Frame(root, bg="#f8d9b9")
        suggestions.grid(row=2, column=0, sticky="ew", padx=14, pady=(0, 8))
        ttk.Label(suggestions, text="Suggestions:").pack(side="left", padx=(0, 8))
        prompt_defs = [
            "Generate standup notes for yesterday",
            "What did I get done last week?",
            "What distracted me the most this week?",
        ]
        for prompt in prompt_defs:
            btn = tk.Button(
                suggestions,
                text=prompt,
                bd=0,
                relief=tk.FLAT,
                bg="#fff4e7",
                fg="#a35f2d",
                activebackground="#ffe9cf",
                activeforeground="#8d4b1f",
                padx=10,
                pady=4,
                font=("Segoe UI", 9),
                cursor="hand2",
                command=lambda p=prompt: self._set_dashboard_prompt(p),
            )
            btn.pack(side="left", padx=(0, 6))

        self.dashboard_answer = ScrolledText(root, wrap=tk.WORD, height=9, state="disabled")
        self.dashboard_answer.grid(row=3, column=0, sticky="ew", padx=14, pady=(0, 8))

        tiles_frame = ttk.Frame(root, padding=(14, 0, 14, 12))
        tiles_frame.grid(row=4, column=0, sticky="nsew")
        tiles_frame.columnconfigure(0, weight=1)
        tiles_frame.rowconfigure(0, weight=1)

        self.dashboard_tree = ttk.Treeview(
            tiles_frame,
            columns=("created", "question", "answer"),
            show="headings",
        )
        self.dashboard_tree.heading("created", text="Created")
        self.dashboard_tree.heading("question", text="Question")
        self.dashboard_tree.heading("answer", text="Answer")
        self.dashboard_tree.column("created", width=170, anchor="w")
        self.dashboard_tree.column("question", width=320, anchor="w")
        self.dashboard_tree.column("answer", width=860, anchor="w")
        self.dashboard_tree.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(tiles_frame, orient=tk.VERTICAL, command=self.dashboard_tree.yview)
        self.dashboard_tree.configure(yscrollcommand=scroll.set)
        scroll.grid(row=0, column=1, sticky="ns")

    def _build_journal_view(self) -> None:
        root = self.journal_view
        root.configure(bg="#f8d9b9")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(2, weight=1)

        header = ttk.Frame(root, padding=14)
        header.grid(row=0, column=0, sticky="ew")
        ttk.Label(header, text="Dayflow Journal", style="Title.TLabel").pack(side="left")

        period_shell = tk.Frame(header, bg="#f8d9b9")
        period_shell.pack(side="left", padx=(12, 12))
        self.journal_period_var = tk.StringVar(value="day")
        for key, label in [("day", "Day"), ("week", "Week")]:
            btn = tk.Button(
                period_shell,
                text=label,
                bd=0,
                relief=tk.FLAT,
                bg="#fff2e3" if key == "day" else "#f1e5d8",
                fg="#6f5e52",
                padx=12,
                pady=4,
                font=("Segoe UI", 9),
                command=lambda v=key: self.journal_period_var.set(v),
                cursor="hand2",
            )
            btn.pack(side="left", padx=(0, 4))

        ttk.Label(header, text="Date").pack(side="left", padx=(4, 2))
        ttk.Entry(header, textvariable=self.date_var, width=12).pack(side="left", padx=(0, 6))
        ttk.Button(header, text="Load", command=self._load_journal_for_selected_day).pack(side="left", padx=(0, 6))
        ttk.Button(header, text="Save Entry", command=self._save_journal_entry).pack(side="left", padx=(0, 6))
        ttk.Button(header, text="Generate AI Summary", command=self._generate_journal_summary).pack(side="left")

        ttk.Checkbutton(
            header,
            text="Reminders",
            variable=self.reminders_enabled_var,
            command=self._save_settings_only,
        ).pack(side="left", padx=(12, 6))
        ttk.Label(header, text="Morning").pack(side="left", padx=(0, 2))
        ttk.Entry(header, textvariable=self.morning_reminder_var, width=6).pack(side="left", padx=(0, 6))
        ttk.Label(header, text="Evening").pack(side="left", padx=(0, 2))
        ttk.Entry(header, textvariable=self.evening_reminder_var, width=6).pack(side="left")

        ttk.Label(root, textvariable=self.journal_status_var, padding=(14, 0, 14, 8)).grid(row=1, column=0, sticky="w")

        split = ttk.Panedwindow(root, orient=tk.HORIZONTAL)
        split.grid(row=2, column=0, sticky="nsew", padx=14, pady=(0, 10))

        left = ttk.Frame(split, padding=8)
        right = ttk.Frame(split, padding=8)
        split.add(left, weight=3)
        split.add(right, weight=2)
        left.columnconfigure(0, weight=1)
        left.rowconfigure(1, weight=1)
        left.rowconfigure(3, weight=1)
        left.rowconfigure(5, weight=1)

        ttk.Label(left, text="Morning Intentions").grid(row=0, column=0, sticky="w")
        self.journal_intentions = ScrolledText(left, wrap=tk.WORD, height=7, bd=0, relief=tk.FLAT, bg="#fff7ed", fg="#4e4138")
        self.journal_intentions.grid(row=1, column=0, sticky="nsew", pady=(2, 8))

        ttk.Label(left, text="Evening Reflections").grid(row=2, column=0, sticky="w")
        self.journal_reflections = ScrolledText(left, wrap=tk.WORD, height=7, bd=0, relief=tk.FLAT, bg="#fff7ed", fg="#4e4138")
        self.journal_reflections.grid(row=3, column=0, sticky="nsew", pady=(2, 8))

        ttk.Label(left, text="Notes").grid(row=4, column=0, sticky="w")
        self.journal_notes = ScrolledText(left, wrap=tk.WORD, height=6, bd=0, relief=tk.FLAT, bg="#fff7ed", fg="#4e4138")
        self.journal_notes.grid(row=5, column=0, sticky="nsew", pady=(2, 8))

        right.columnconfigure(0, weight=1)
        right.rowconfigure(1, weight=1)
        right.rowconfigure(3, weight=1)
        ttk.Label(right, text="AI Journal Summary").grid(row=0, column=0, sticky="w")
        self.journal_summary = ScrolledText(right, wrap=tk.WORD, height=10, bd=0, relief=tk.FLAT, bg="#fff7ed", fg="#4e4138")
        self.journal_summary.grid(row=1, column=0, sticky="nsew", pady=(2, 8))

        ttk.Label(right, text="Weekly Entries").grid(row=2, column=0, sticky="w")
        self.journal_weekly_tree = ttk.Treeview(
            right,
            columns=("day", "intentions", "summary"),
            show="headings",
            height=12,
        )
        self.journal_weekly_tree.heading("day", text="Day")
        self.journal_weekly_tree.heading("intentions", text="Intentions")
        self.journal_weekly_tree.heading("summary", text="Summary")
        self.journal_weekly_tree.column("day", width=100, anchor="w")
        self.journal_weekly_tree.column("intentions", width=260, anchor="w")
        self.journal_weekly_tree.column("summary", width=360, anchor="w")
        self.journal_weekly_tree.grid(row=3, column=0, sticky="nsew")

        self.journal_debug_frame = tk.Frame(
            right,
            bg="#fff7ed",
            highlightthickness=1,
            highlightbackground="#ecd8c6",
            bd=0,
        )
        self.journal_debug_frame.grid(row=4, column=0, sticky="ew", pady=(10, 0))
        tk.Label(
            self.journal_debug_frame,
            text="Journal debug",
            bg="#fff7ed",
            fg="#675b52",
            font=("Segoe UI Semibold", 10),
        ).grid(row=0, column=0, sticky="w", padx=10, pady=(8, 2))
        tk.Label(
            self.journal_debug_frame,
            textvariable=self.journal_debug_var,
            bg="#fff7ed",
            fg="#6e6056",
            font=("Consolas", 9),
            justify="left",
            anchor="w",
        ).grid(row=1, column=0, sticky="ew", padx=10, pady=(0, 8))
        self._update_journal_debug_panel()

        self.journal_gate_overlay = tk.Frame(root, bg="#f8dfc5")
        self.journal_gate_overlay.place(relx=0, rely=0, relwidth=1, relheight=1)

        gate_center = tk.Frame(self.journal_gate_overlay, bg="#f8dfc5")
        gate_center.place(relx=0.5, rely=0.5, anchor="center")

        self.journal_lock_card = tk.Frame(
            gate_center,
            bg="#fff7ed",
            highlightthickness=1,
            highlightbackground="#edd7c1",
            bd=0,
        )
        self.journal_lock_card.grid(row=0, column=0, padx=20, pady=8)

        tk.Label(
            self.journal_lock_card,
            text="Dayflow Journal",
            bg="#fff7ed",
            fg="#593d2a",
            font=("Georgia", 28, "italic"),
        ).pack(padx=36, pady=(22, 8))
        tk.Label(
            self.journal_lock_card,
            text="BETA",
            bg="#f98d3d",
            fg="#ffffff",
            font=("Segoe UI Semibold", 10),
            padx=10,
            pady=3,
        ).pack()
        tk.Label(
            self.journal_lock_card,
            text="We're rolling this out gradually. Enter your access code to unlock Journal beta.",
            bg="#fff7ed",
            fg="#6c5748",
            font=("Segoe UI", 11),
            wraplength=430,
            justify="center",
        ).pack(padx=28, pady=(10, 14))

        self.journal_code_entry = tk.Entry(
            self.journal_lock_card,
            textvariable=self.journal_access_code_var,
            bd=0,
            relief=tk.FLAT,
            bg="#ffffff",
            fg="#3a2b22",
            width=30,
            justify="center",
            font=("Segoe UI", 12),
        )
        self.journal_code_entry.pack(ipady=9, padx=46)
        self.journal_code_entry.bind("<Return>", lambda _e: self._attempt_journal_unlock())

        tk.Button(
            self.journal_lock_card,
            text="Get early access",
            command=self._attempt_journal_unlock,
            bd=0,
            relief=tk.FLAT,
            bg="#ffe2c0",
            fg="#5b3925",
            activebackground="#ffd2a8",
            activeforeground="#4a2d1f",
            padx=20,
            pady=8,
            font=("Segoe UI Semibold", 11),
            cursor="hand2",
        ).pack(pady=(16, 20))

        self.journal_onboarding_card = tk.Frame(
            gate_center,
            bg="#fff7ed",
            highlightthickness=1,
            highlightbackground="#edd7c1",
            bd=0,
        )
        self.journal_onboarding_card.grid(row=0, column=0, padx=20, pady=8)

        tk.Label(
            self.journal_onboarding_card,
            text="Set your intentions today",
            bg="#fff7ed",
            fg="#653f28",
            font=("Georgia", 28),
        ).pack(padx=36, pady=(22, 10))
        tk.Label(
            self.journal_onboarding_card,
            text="Dayflow Journal helps you track daily goals, reflect, and generate narrative summaries.",
            bg="#fff7ed",
            fg="#6c5748",
            font=("Segoe UI", 11),
            wraplength=440,
            justify="center",
        ).pack(padx=28, pady=(0, 16))

        tk.Button(
            self.journal_onboarding_card,
            text="Start onboarding",
            command=self._complete_journal_onboarding,
            bd=0,
            relief=tk.FLAT,
            bg="#ffe2c0",
            fg="#5b3925",
            activebackground="#ffd2a8",
            activeforeground="#4a2d1f",
            padx=20,
            pady=8,
            font=("Segoe UI Semibold", 11),
            cursor="hand2",
        ).pack(pady=(0, 20))

        self._refresh_journal_access_gate()

    def _build_settings_view(self) -> None:
        root = self.settings_view
        root.configure(bg="#f8d9b9")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(2, weight=1)

        header = ttk.Frame(root, padding=14)
        header.grid(row=0, column=0, sticky="ew")
        ttk.Label(header, text="Settings", style="Title.TLabel").pack(anchor="w")
        ttk.Label(header, text="Storage, providers, and app preferences.", style="Subtle.TLabel").pack(anchor="w", pady=(2, 0))

        body = tk.Frame(root, bg="#f8d9b9")
        body.grid(row=1, column=0, sticky="nsew", padx=14, pady=(0, 10))
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=1)

        sidebar = tk.Frame(body, bg="#f8d9b9", width=210)
        sidebar.grid(row=0, column=0, sticky="ns")
        sidebar.grid_propagate(False)

        content = tk.Frame(body, bg="#f8d9b9")
        content.grid(row=0, column=1, sticky="nsew", padx=(12, 0))
        content.columnconfigure(0, weight=1)
        content.rowconfigure(0, weight=1)

        self.settings_tab_var = tk.StringVar(value="storage")
        self.settings_tab_buttons: dict[str, tk.Button] = {}
        tab_defs = [
            ("storage", "Storage", "Recording status and disk usage"),
            ("providers", "Providers", "Model and endpoint configuration"),
            ("other", "Other", "Preferences, export, and support"),
        ]
        for key, title, subtitle in tab_defs:
            btn = tk.Button(
                sidebar,
                text=f"{title}\n{subtitle}",
                justify="left",
                anchor="w",
                bd=0,
                relief=tk.FLAT,
                bg="#f4e6d8",
                fg="#54473f",
                activebackground="#fff2e2",
                activeforeground="#2f2723",
                padx=12,
                pady=10,
                font=("Segoe UI", 10),
                cursor="hand2",
                command=lambda v=key: self._show_settings_tab(v),
            )
            btn.pack(fill="x", pady=(0, 8))
            self.settings_tab_buttons[key] = btn

        self.settings_tabs: dict[str, tk.Frame] = {}
        for key in ["storage", "providers", "other"]:
            frame = tk.Frame(content, bg="#f8d9b9")
            frame.grid(row=0, column=0, sticky="nsew")
            frame.grid_remove()
            self.settings_tabs[key] = frame

        self._build_settings_storage_tab(self.settings_tabs["storage"])
        self._build_settings_providers_tab(self.settings_tabs["providers"])
        self._build_settings_other_tab(self.settings_tabs["other"])
        self._show_settings_tab(self.settings_tab_var.get())

        logs = ttk.LabelFrame(root, text="Activity Log", padding=12)
        logs.grid(row=2, column=0, sticky="nsew", padx=14, pady=(0, 12))
        logs.columnconfigure(0, weight=1)
        logs.rowconfigure(0, weight=1)
        self.log_output = ScrolledText(logs, wrap=tk.WORD, height=12, state="disabled")
        self.log_output.grid(row=0, column=0, sticky="nsew")

    def _build_settings_storage_tab(self, root: tk.Frame) -> None:
        root.columnconfigure(0, weight=1)

        card = tk.Frame(root, bg="#fff7ed", highlightthickness=1, highlightbackground="#ecd8c6", bd=0)
        card.grid(row=0, column=0, sticky="ew", pady=(0, 10))

        tk.Label(card, text="Recording status", bg="#fff7ed", fg="#3e332d", font=("Segoe UI Semibold", 12)).grid(row=0, column=0, sticky="w", padx=12, pady=(10, 2))
        tk.Label(card, textvariable=self.settings_storage_status_var, bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", padx=12)
        tk.Label(card, textvariable=self.settings_storage_last_check_var, bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=2, column=0, sticky="w", padx=12, pady=(0, 10))

        row = tk.Frame(card, bg="#fff7ed")
        row.grid(row=3, column=0, sticky="w", padx=12, pady=(0, 10))
        tk.Button(row, text="Run status check", bd=0, relief=tk.FLAT, bg="#ffe4c6", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._run_storage_status_check, cursor="hand2").pack(side="left", padx=(0, 6))
        tk.Button(row, text="Open screenshots", bd=0, relief=tk.FLAT, bg="#f1e4d5", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._open_screenshots_folder, cursor="hand2").pack(side="left", padx=(0, 6))
        tk.Button(row, text="Open data folder", bd=0, relief=tk.FLAT, bg="#f1e4d5", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._open_data_folder, cursor="hand2").pack(side="left")

        disk = tk.Frame(root, bg="#fff7ed", highlightthickness=1, highlightbackground="#ecd8c6", bd=0)
        disk.grid(row=1, column=0, sticky="ew", pady=(0, 8))

        tk.Label(disk, text="Disk usage", bg="#fff7ed", fg="#3e332d", font=("Segoe UI Semibold", 12)).grid(row=0, column=0, columnspan=2, sticky="w", padx=12, pady=(10, 6))
        tk.Label(disk, text="Capture interval (s)", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", padx=12, pady=3)
        ttk.Entry(disk, textvariable=self.interval_var, width=10).grid(row=1, column=1, sticky="w", padx=(0, 12), pady=3)
        tk.Label(disk, text="Storage limit (GB)", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=2, column=0, sticky="w", padx=12, pady=3)
        ttk.Entry(disk, textvariable=self.storage_limit_gb_var, width=10).grid(row=2, column=1, sticky="w", padx=(0, 12), pady=3)
        ttk.Checkbutton(disk, text="Enable automatic storage cleanup", variable=self.auto_cleanup_var).grid(row=3, column=0, columnspan=2, sticky="w", padx=12, pady=4)

        actions = tk.Frame(disk, bg="#fff7ed")
        actions.grid(row=4, column=0, columnspan=2, sticky="w", padx=12, pady=(4, 10))
        tk.Button(actions, text="Save storage settings", bd=0, relief=tk.FLAT, bg="#ffe4c6", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._save_settings_only, cursor="hand2").pack(side="left", padx=(0, 6))
        tk.Button(actions, text="Run cleanup now", bd=0, relief=tk.FLAT, bg="#f1e4d5", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._cleanup_now, cursor="hand2").pack(side="left")

    def _build_settings_providers_tab(self, root: tk.Frame) -> None:
        root.columnconfigure(0, weight=1)
        card = tk.Frame(root, bg="#fff7ed", highlightthickness=1, highlightbackground="#ecd8c6", bd=0)
        card.grid(row=0, column=0, sticky="ew", pady=(0, 8))

        tk.Label(card, text="Provider configuration", bg="#fff7ed", fg="#3e332d", font=("Segoe UI Semibold", 12)).grid(row=0, column=0, columnspan=2, sticky="w", padx=12, pady=(10, 8))
        tk.Label(card, text="AI Provider", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", padx=12, pady=3)
        ttk.Combobox(card, textvariable=self.ai_provider_var, values=["gemini", "openai", "local"], state="readonly", width=18).grid(row=1, column=1, sticky="w", padx=(0, 12), pady=3)
        tk.Label(card, text="Model", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=2, column=0, sticky="w", padx=12, pady=3)
        ttk.Entry(card, textvariable=self.ai_model_var, width=36).grid(row=2, column=1, sticky="w", padx=(0, 12), pady=3)
        tk.Label(card, text="API Key", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=3, column=0, sticky="w", padx=12, pady=3)
        ttk.Entry(card, textvariable=self.ai_api_key_var, width=44, show="*").grid(row=3, column=1, sticky="w", padx=(0, 12), pady=3)
        tk.Label(card, text="Endpoint", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=4, column=0, sticky="w", padx=12, pady=3)
        ttk.Entry(card, textvariable=self.ai_endpoint_var, width=44).grid(row=4, column=1, sticky="w", padx=(0, 12), pady=3)

        tk.Label(card, textvariable=self.settings_connection_status_var, bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=5, column=0, columnspan=2, sticky="w", padx=12, pady=(4, 8))

        actions = tk.Frame(card, bg="#fff7ed")
        actions.grid(row=6, column=0, columnspan=2, sticky="w", padx=12, pady=(0, 10))
        tk.Button(actions, text="Save provider settings", bd=0, relief=tk.FLAT, bg="#ffe4c6", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._save_settings_only, cursor="hand2").pack(side="left", padx=(0, 6))
        tk.Button(actions, text="Test connection", bd=0, relief=tk.FLAT, bg="#f1e4d5", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._test_provider_connection, cursor="hand2").pack(side="left")

    def _build_settings_other_tab(self, root: tk.Frame) -> None:
        root.columnconfigure(0, weight=1)

        card = tk.Frame(root, bg="#fff7ed", highlightthickness=1, highlightbackground="#ecd8c6", bd=0)
        card.grid(row=0, column=0, sticky="ew", pady=(0, 10))

        tk.Label(card, text="App preferences", bg="#fff7ed", fg="#3e332d", font=("Segoe UI Semibold", 12)).grid(row=0, column=0, sticky="w", padx=12, pady=(10, 8))
        ttk.Checkbutton(card, text="Launch Dayflow at login", variable=self.launch_at_login_var).grid(row=1, column=0, sticky="w", padx=12, pady=2)
        ttk.Checkbutton(card, text="Share crash reports and usage data", variable=self.analytics_enabled_var).grid(row=2, column=0, sticky="w", padx=12, pady=2)
        ttk.Checkbutton(card, text="Show Dock icon", variable=self.show_dock_icon_var).grid(row=3, column=0, sticky="w", padx=12, pady=2)
        ttk.Checkbutton(card, text="Show app/website icons in timeline", variable=self.show_timeline_icons_var).grid(row=4, column=0, sticky="w", padx=12, pady=2)
        ttk.Checkbutton(card, text="Show Journal debug panel", variable=self.show_journal_debug_var).grid(row=5, column=0, sticky="w", padx=12, pady=2)

        lang_row = tk.Frame(card, bg="#fff7ed")
        lang_row.grid(row=6, column=0, sticky="w", padx=12, pady=(8, 10))
        tk.Label(lang_row, text="Output language", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).pack(side="left", padx=(0, 6))
        ttk.Entry(lang_row, textvariable=self.output_language_var, width=18).pack(side="left", padx=(0, 6))
        tk.Button(lang_row, text="Save", bd=0, relief=tk.FLAT, bg="#ffe4c6", fg="#5c3d2a", padx=10, pady=5, font=("Segoe UI Semibold", 9), command=self._save_output_language_override, cursor="hand2").pack(side="left", padx=(0, 4))
        tk.Button(lang_row, text="Reset", bd=0, relief=tk.FLAT, bg="#f1e4d5", fg="#5c3d2a", padx=10, pady=5, font=("Segoe UI Semibold", 9), command=self._reset_output_language_override, cursor="hand2").pack(side="left")

        export_card = tk.Frame(root, bg="#fff7ed", highlightthickness=1, highlightbackground="#ecd8c6", bd=0)
        export_card.grid(row=1, column=0, sticky="ew", pady=(0, 8))
        tk.Label(export_card, text="Export timeline", bg="#fff7ed", fg="#3e332d", font=("Segoe UI Semibold", 12)).grid(row=0, column=0, columnspan=4, sticky="w", padx=12, pady=(10, 6))
        tk.Label(export_card, text="Start", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=1, column=0, sticky="w", padx=(12, 4), pady=(0, 8))
        ttk.Entry(export_card, textvariable=self.export_start_var, width=12).grid(row=1, column=1, sticky="w", pady=(0, 8))
        tk.Label(export_card, text="End", bg="#fff7ed", fg="#6e6056", font=("Segoe UI", 10)).grid(row=1, column=2, sticky="w", padx=(12, 4), pady=(0, 8))
        ttk.Entry(export_card, textvariable=self.export_end_var, width=12).grid(row=1, column=3, sticky="w", pady=(0, 8))

        actions = tk.Frame(export_card, bg="#fff7ed")
        actions.grid(row=2, column=0, columnspan=4, sticky="w", padx=12, pady=(0, 10))
        tk.Button(actions, text="Export Markdown range", bd=0, relief=tk.FLAT, bg="#ffe4c6", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._export_timeline_range, cursor="hand2").pack(side="left", padx=(0, 6))
        tk.Button(actions, text="Save preferences", bd=0, relief=tk.FLAT, bg="#f1e4d5", fg="#5c3d2a", padx=12, pady=6, font=("Segoe UI Semibold", 10), command=self._save_settings_only, cursor="hand2").pack(side="left")

    def _show_settings_tab(self, tab_key: str) -> None:
        self.settings_tab_var.set(tab_key)
        for key, frame in self.settings_tabs.items():
            if key == tab_key:
                frame.grid()
                frame.tkraise()
            else:
                frame.grid_remove()
        for key, btn in self.settings_tab_buttons.items():
            if key == tab_key:
                btn.configure(bg="#fff3e4", fg="#2f2723")
            else:
                btn.configure(bg="#f4e6d8", fg="#54473f")

    def _run_storage_status_check(self) -> None:
        capture_state = "active" if self.capture_service.is_running else "idle"
        total_bytes = self.db.total_screenshot_bytes()
        total_mb = total_bytes / (1024 * 1024)
        self.settings_storage_status_var.set(
            f"Recorder {capture_state} | Screenshots storage {total_mb:.1f} MB"
        )
        self.settings_storage_last_check_var.set(
            f"Last check: {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S')}"
        )

    def _open_screenshots_folder(self) -> None:
        subprocess.Popen(["explorer", str(screenshots_directory())])

    def _test_provider_connection(self) -> None:
        provider, model, api_key, endpoint = self._ai_settings()
        self.settings_connection_status_var.set("Connection: testing...")

        def _worker() -> None:
            try:
                answer = self.ai_generator.answer_dashboard_question(
                    provider=provider,
                    api_key=api_key,
                    model=model,
                    endpoint=endpoint,
                    day=date.today(),
                    question="Reply with OK if configuration works.",
                    timeline_cards=[],
                    daily_summary="",
                    captured_timeline=["Config test request from Settings"],
                    range_label=date.today().isoformat(),
                )
                self.events.put(("provider_test_done", str(answer).strip()[:120]))
            except Exception as exc:  # noqa: BLE001
                self.events.put(("provider_test_error", exc))

        threading.Thread(target=_worker, name="dayflow-provider-test", daemon=True).start()

    def _save_output_language_override(self) -> None:
        self.db.set_setting(OUTPUT_LANGUAGE_SETTING_KEY, self.output_language_var.get().strip() or "English")
        self._append_log("Output language override saved.")

    def _reset_output_language_override(self) -> None:
        self.output_language_var.set("English")
        self.db.set_setting(OUTPUT_LANGUAGE_SETTING_KEY, "English")
        self._append_log("Output language override reset to English.")

    def _export_timeline_range(self) -> None:
        start_day = _parse_iso_date(self.export_start_var.get().strip())
        end_day = _parse_iso_date(self.export_end_var.get().strip())
        if start_day is None or end_day is None:
            messagebox.showerror("Export timeline", "Use YYYY-MM-DD format for start and end dates.")
            return
        if end_day < start_day:
            messagebox.showerror("Export timeline", "Start date must be before or equal to end date.")
            return

        target = filedialog.asksaveasfilename(
            title="Export Dayflow Timeline Range",
            defaultextension=".md",
            initialfile=f"dayflow-{start_day.isoformat()}-to-{end_day.isoformat()}.md",
            filetypes=[("Markdown", "*.md"), ("All files", "*.*")],
        )
        if not target:
            return

        lines: list[str] = [f"# Dayflow Timeline Export ({start_day.isoformat()} to {end_day.isoformat()})", ""]
        cursor = start_day
        fallback_interval = self._current_interval()
        while cursor <= end_day:
            day_iso = cursor.isoformat()
            lines.extend([f"## {day_iso}", ""])
            ai_summary = self.db.get_ai_daily_summary(day_iso).strip()
            if ai_summary:
                lines.extend(["### AI Daily Summary", ai_summary, ""])

            ai_cards = self.db.list_ai_timeline_for_day(day_iso)
            if ai_cards:
                lines.append("### AI Timeline Cards")
                for card in ai_cards:
                    lines.append(f"- **{card.start}-{card.end}** [{card.category}] {card.title}")
                    if card.summary.strip():
                        lines.append(f"  - {card.summary.strip()}")
                lines.append("")
            else:
                rows = self.db.list_screenshots_for_date(cursor)
                classic_cards = build_timeline_cards(rows, fallback_interval_seconds=fallback_interval)
                if classic_cards:
                    lines.append("### Captured Timeline")
                    for card in classic_cards:
                        lines.append(
                            f"- **{_fmt_time(card.start)}-{_fmt_time(card.end)}** {card.process_name} - {card.window_title}"
                        )
                    lines.append("")
                else:
                    lines.extend(["No timeline data.", ""])
            cursor += timedelta(days=1)

        Path(target).write_text("\n".join(lines), encoding="utf-8")
        self._append_log(f"Exported timeline range: {target}")

    def _refresh_all(self) -> None:
        self._refresh_timeline()
        self._refresh_ai_timeline()
        self._refresh_dashboard_tiles()
        self._load_journal_for_selected_day()

    def _start_capture(self) -> None:
        interval = self._current_interval()
        self.db.set_setting(INTERVAL_SETTING_KEY, f"{interval}")
        started = self.capture_service.start(
            interval_seconds=interval,
            on_sample=self._on_capture_sample,
            on_error=self._on_capture_error,
        )
        if started:
            self.status_var.set(f"Status: Capturing every {interval:g}s")
            self._append_log(f"Capture started (interval={interval:g}s).")
        else:
            self._append_log("Capture already running.")
        self._update_button_state()

    def _stop_capture(self) -> None:
        self.capture_service.stop()
        self.status_var.set("Status: Idle")
        self._append_log("Capture stopped.")
        self._update_button_state()

    def _capture_now(self) -> None:
        self._append_log("Manual capture requested.")

        def _worker() -> None:
            try:
                sample = self.capture_service.capture_once()
                self.events.put(("sample", sample))
            except Exception as exc:  # noqa: BLE001
                self.events.put(("error", exc))

        threading.Thread(target=_worker, name="dayflow-manual-capture", daemon=True).start()

    def _refresh_timeline(self) -> None:
        day = self._selected_date()
        rows = self.db.list_screenshots_for_date(day)
        cards = build_timeline_cards(rows, fallback_interval_seconds=self._current_interval())
        self._classic_timeline_rows = rows
        self._classic_timeline_cards = cards
        self._render_timeline_canvas()
        self.summary_var.set(
            f"{len(rows)} screenshots, {len(cards)} timeline cards for {day.isoformat()}"
        )

    def _refresh_ai_timeline(self) -> None:
        day = self._selected_date().isoformat()
        cards = self.db.list_ai_timeline_for_day(day)
        summary = self.db.get_ai_daily_summary(day)
        card_lines: list[str] = []
        for card in cards:
            card_lines.append(f"{card.start}-{card.end} [{card.category}] {card.title}")
            if card.summary.strip():
                card_lines.append(f"  {card.summary.strip()}")
            card_lines.append("")
        self._set_text(self.ai_summary, summary or "No AI summary generated for selected day.")
        self._set_text(self.ai_cards_text, "\n".join(card_lines).strip() or "No AI cards yet.")
        if cards:
            self.ai_status_var.set(f"AI: Loaded {len(cards)} cards for {day}.")
        else:
            self.ai_status_var.set("AI: Not generated for selected day.")
        self.distraction_var.set(self._compute_distraction_highlights(cards))
        self._render_timeline_canvas()

    def _compute_distraction_highlights(self, cards: list[AITimelineCard]) -> str:
        categories = {"Browsing", "Communication", "Other"}
        total_minutes = 0
        top: list[str] = []
        for card in cards:
            if card.category not in categories:
                continue
            total_minutes += _duration_minutes(card.start, card.end)
            if len(top) < 3 and card.title:
                top.append(card.title)
        if total_minutes <= 0:
            return "Distractions: no major distraction blocks detected."
        return f"Distractions: {total_minutes} min ({'; '.join(top) if top else 'various'})"

    def _generate_ai_timeline(self) -> None:
        provider, model, api_key, endpoint = self._ai_settings()
        day = self._selected_date()
        screenshots = self.db.list_screenshots_for_date(day)
        if not screenshots:
            self.ai_status_var.set("AI: No screenshots for selected day.")
            self._append_log("No screenshots found for selected date.")
            return

        self.ai_status_var.set("AI: Generating timeline...")
        self._append_log(
            f"Generating AI timeline with provider={provider}, model={model}, screenshots={len(screenshots)}."
        )

        def _worker() -> None:
            try:
                result = self.ai_generator.generate(
                    provider=provider,
                    api_key=api_key,
                    model=model,
                    endpoint=endpoint,
                    day=day,
                    screenshots=screenshots,
                )
                self.db.replace_ai_timeline_for_day(day.isoformat(), result.cards, result.daily_summary)
                self.events.put(("ai_done", result.model_used))
            except Exception as exc:  # noqa: BLE001
                self.events.put(("ai_error", exc))

        threading.Thread(target=_worker, name="dayflow-ai-timeline", daemon=True).start()

    def _ask_dashboard_question(self) -> None:
        question = self.dashboard_question_var.get().strip()
        if not question:
            self.dashboard_status_var.set("Dashboard: Enter a question first.")
            return
        provider, model, api_key, endpoint = self._ai_settings()
        day = self._selected_date()
        range_label, cards, daily_summary, captured_timeline = self._dashboard_context_payload(question, day)
        if not cards and not captured_timeline:
            self.dashboard_status_var.set("Dashboard: No captures found for selected question range.")
            return
        self.dashboard_status_var.set("Dashboard: Asking AI...")
        self._append_log(
            "Dashboard question submitted: "
            f"{question} (range={range_label}, ai_cards={len(cards)}, captured_items={len(captured_timeline)})"
        )

        def _worker() -> None:
            try:
                answer = self.ai_generator.answer_dashboard_question(
                    provider=provider,
                    api_key=api_key,
                    model=model,
                    endpoint=endpoint,
                    day=day,
                    question=question,
                    timeline_cards=cards,
                    daily_summary=daily_summary,
                    captured_timeline=captured_timeline,
                    range_label=range_label,
                )
                self.events.put(("dashboard_done", {"question": question, "answer": answer}))
            except Exception as exc:  # noqa: BLE001
                self.events.put(("dashboard_error", exc))

        threading.Thread(target=_worker, name="dayflow-dashboard", daemon=True).start()

    def _set_dashboard_prompt(self, prompt: str) -> None:
        self.dashboard_question_var.set(prompt.strip())
        self._ask_dashboard_question()

    def _dashboard_context_payload(
        self,
        question: str,
        selected_day: date,
    ) -> tuple[str, list[AITimelineCard], str, list[str]]:
        days = self._dashboard_query_days(question, selected_day)
        range_label = (
            days[0].isoformat()
            if len(days) == 1
            else f"{days[0].isoformat()} to {days[-1].isoformat()}"
        )
        ai_cards: list[AITimelineCard] = []
        summary_parts: list[str] = []
        captured_items: list[str] = []
        fallback_interval = self._current_interval()

        for day in days:
            day_iso = day.isoformat()
            day_cards = self.db.list_ai_timeline_for_day(day_iso)
            ai_cards.extend(day_cards)

            day_summary = self.db.get_ai_daily_summary(day_iso).strip()
            if day_summary:
                summary_parts.append(f"{day_iso}: {day_summary}")

            rows = self.db.list_screenshots_for_date(day)
            classic_cards = build_timeline_cards(rows, fallback_interval_seconds=fallback_interval)
            for card in classic_cards[:18]:
                captured_items.append(self._dashboard_captured_line(day_iso, card))
                if len(captured_items) >= 120:
                    break
            if len(captured_items) >= 120:
                break

        return (range_label, ai_cards[:160], "\n".join(summary_parts), captured_items)

    @staticmethod
    def _dashboard_query_days(question: str, selected_day: date) -> list[date]:
        text = question.strip().lower()
        if "yesterday" in text:
            return [selected_day - timedelta(days=1)]
        week_tokens = ("last week", "past week", "this week", "week ")
        if any(token in text for token in week_tokens) or text.endswith("week"):
            return [selected_day - timedelta(days=offset) for offset in range(6, -1, -1)]
        return [selected_day]

    @staticmethod
    def _dashboard_captured_line(day_iso: str, card) -> str:
        start = _friendly_time(_fmt_time(card.start))
        end = _friendly_time(_fmt_time(card.end))
        app_name = (card.process_name or "unknown").strip()[:40]
        title = (card.window_title or "").strip().replace("\n", " ")[:120]
        return f"{day_iso} {start}-{end} [{app_name}] {title}"

    def _save_dashboard_tile(self) -> None:
        if not self._last_dashboard_question or not self._last_dashboard_answer:
            self.dashboard_status_var.set("Dashboard: Ask AI first, then save tile.")
            return
        day = self._selected_date().isoformat()
        self.db.insert_dashboard_tile(day, self._last_dashboard_question, self._last_dashboard_answer)
        self.dashboard_status_var.set("Dashboard: Tile saved.")
        self._refresh_dashboard_tiles()

    def _clear_dashboard_tiles(self) -> None:
        day = self._selected_date().isoformat()
        self.db.clear_dashboard_tiles(day)
        self.dashboard_status_var.set("Dashboard: Tiles cleared.")
        self._refresh_dashboard_tiles()

    def _refresh_dashboard_tiles(self) -> None:
        day = self._selected_date().isoformat()
        tiles = self.db.list_dashboard_tiles(day)
        for item in self.dashboard_tree.get_children():
            self.dashboard_tree.delete(item)
        for tile in tiles:
            self.dashboard_tree.insert(
                "",
                "end",
                values=(tile.created_at[:19].replace("T", " "), tile.question[:120], tile.answer[:250]),
            )

    def _load_journal_for_selected_day(self) -> None:
        entry = self.db.get_journal_entry(self._selected_date().isoformat())
        self._set_text(self.journal_intentions, entry.intentions)
        self._set_text(self.journal_reflections, entry.reflections)
        self._set_text(self.journal_notes, entry.notes)
        self._set_text(self.journal_summary, entry.summary)
        self._refresh_journal_weekly()
        self._update_journal_debug_panel()

    def _save_journal_entry(self) -> None:
        day = self._selected_date().isoformat()
        intentions = self._get_text(self.journal_intentions)
        reflections = self._get_text(self.journal_reflections)
        notes = self._get_text(self.journal_notes)
        summary = self._get_text(self.journal_summary)
        self.db.upsert_journal_entry(day, intentions, reflections, notes, summary)
        self.journal_status_var.set(f"Journal: Entry saved for {day}.")
        self._refresh_journal_weekly()

    def _generate_journal_summary(self) -> None:
        provider, model, api_key, endpoint = self._ai_settings()
        day = self._selected_date()
        intentions = self._get_text(self.journal_intentions)
        reflections = self._get_text(self.journal_reflections)
        cards = self.db.list_ai_timeline_for_day(day.isoformat())
        daily_summary = self.db.get_ai_daily_summary(day.isoformat())
        self.journal_status_var.set("Journal: Generating AI summary...")

        def _worker() -> None:
            try:
                summary = self.ai_generator.generate_journal_summary(
                    provider=provider,
                    api_key=api_key,
                    model=model,
                    endpoint=endpoint,
                    day=day,
                    intentions=intentions,
                    reflections=reflections,
                    timeline_cards=cards,
                    daily_summary=daily_summary,
                )
                self.events.put(("journal_summary_done", summary))
            except Exception as exc:  # noqa: BLE001
                self.events.put(("journal_summary_error", exc))

        threading.Thread(target=_worker, name="dayflow-journal", daemon=True).start()

    def _refresh_journal_weekly(self) -> None:
        entries = self.db.list_recent_journal_entries(limit=7)
        for item in self.journal_weekly_tree.get_children():
            self.journal_weekly_tree.delete(item)
        for entry in entries:
            self.journal_weekly_tree.insert(
                "",
                "end",
                values=(entry.day, entry.intentions[:90], entry.summary[:130]),
            )

    def _refresh_journal_access_gate(self) -> None:
        if not hasattr(self, "journal_gate_overlay"):
            return
        if not self.journal_unlocked_var.get():
            self.journal_gate_overlay.place(relx=0, rely=0, relwidth=1, relheight=1)
            self.journal_gate_overlay.lift()
            self.journal_lock_card.grid()
            self.journal_onboarding_card.grid_remove()
            return
        if not self.journal_onboarded_var.get():
            self.journal_gate_overlay.place(relx=0, rely=0, relwidth=1, relheight=1)
            self.journal_gate_overlay.lift()
            self.journal_lock_card.grid_remove()
            self.journal_onboarding_card.grid()
            return
        self.journal_gate_overlay.place_forget()
        self._update_journal_debug_panel()

    def _update_journal_debug_panel(self) -> None:
        if not hasattr(self, "journal_debug_frame"):
            return
        if not self.show_journal_debug_var.get():
            self.journal_debug_frame.grid_remove()
            return
        self.journal_debug_frame.grid()
        selected_day = self._selected_date().isoformat()
        text = (
            f"day={selected_day}\n"
            f"unlocked={int(self.journal_unlocked_var.get())} onboarded={int(self.journal_onboarded_var.get())}\n"
            f"reminders={int(self.reminders_enabled_var.get())} morning={self.morning_reminder_var.get()} evening={self.evening_reminder_var.get()}\n"
            f"provider={self.ai_provider_var.get().strip()} model={self.ai_model_var.get().strip()}"
        )
        self.journal_debug_var.set(text)

    def _attempt_journal_unlock(self) -> None:
        raw = self.journal_access_code_var.get().strip().lower()
        if not raw:
            self.journal_status_var.set("Journal: Enter your access code.")
            return
        digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
        if digest == JOURNAL_ACCESS_HASH:
            self.journal_unlocked_var.set(True)
            self.db.set_setting(JOURNAL_UNLOCKED_SETTING_KEY, "1")
            self.journal_status_var.set("Journal: Access granted.")
            self.journal_access_code_var.set("")
            self._refresh_journal_access_gate()
        else:
            self.journal_status_var.set("Journal: Invalid access code.")
            self.journal_access_code_var.set("")

    def _complete_journal_onboarding(self) -> None:
        self.journal_onboarded_var.set(True)
        self.db.set_setting(JOURNAL_ONBOARDED_SETTING_KEY, "1")
        self.journal_status_var.set("Journal: Onboarding complete.")
        self._refresh_journal_access_gate()

    def _export_markdown(self) -> None:
        day = self._selected_date()
        ai_cards = self.db.list_ai_timeline_for_day(day.isoformat())
        ai_summary = self.db.get_ai_daily_summary(day.isoformat())
        classic = self.db.list_screenshots_for_date(day)
        classic_cards = build_timeline_cards(classic, fallback_interval_seconds=self._current_interval())

        target = filedialog.asksaveasfilename(
            title="Export Dayflow Timeline as Markdown",
            defaultextension=".md",
            initialfile=f"dayflow-{day.isoformat()}.md",
            filetypes=[("Markdown", "*.md"), ("All files", "*.*")],
        )
        if not target:
            return

        lines: list[str] = [f"# Dayflow Timeline - {day.isoformat()}", ""]
        if ai_summary.strip():
            lines.extend(["## AI Daily Summary", "", ai_summary.strip(), ""])
        if ai_cards:
            lines.extend(["## AI Timeline Cards", ""])
            for card in ai_cards:
                lines.append(f"- **{card.start}-{card.end}** [{card.category}] {card.title}")
                if card.summary.strip():
                    lines.append(f"  - {card.summary.strip()}")
            lines.append("")
        else:
            lines.extend(["## Captured Timeline", ""])
            for card in classic_cards:
                lines.append(
                    f"- **{_fmt_time(card.start)}-{_fmt_time(card.end)}** {card.process_name} - {card.window_title}"
                )
            lines.append("")

        Path(target).write_text("\n".join(lines), encoding="utf-8")
        self._append_log(f"Exported Markdown: {target}")

    def _open_timelapse(self) -> None:
        paths = self.db.list_screenshot_paths_for_day(self._selected_date())
        if not paths:
            self._append_log("Timelapse unavailable: no screenshots for selected date.")
            return
        TimelapseWindow(self, paths)

    def _cleanup_now(self) -> None:
        limit_bytes = self._storage_limit_bytes()
        removed_count, removed_bytes = self.db.enforce_storage_limit(limit_bytes)
        self._append_log(
            f"Storage cleanup removed {removed_count} files ({removed_bytes / (1024 * 1024):.1f} MB)."
        )
        self._refresh_timeline()

    def _save_settings_only(self) -> None:
        self.db.set_setting(INTERVAL_SETTING_KEY, f"{self._current_interval()}")
        self.db.set_setting(AI_PROVIDER_SETTING_KEY, self.ai_provider_var.get().strip())
        self.db.set_setting(AI_MODEL_SETTING_KEY, self.ai_model_var.get().strip())
        self.db.set_setting(AI_API_KEY_SETTING_KEY, self.ai_api_key_var.get().strip())
        self.db.set_setting(AI_ENDPOINT_SETTING_KEY, self.ai_endpoint_var.get().strip())
        self.db.set_setting(STORAGE_LIMIT_GB_SETTING_KEY, self.storage_limit_gb_var.get().strip() or "0")
        self.db.set_setting(AUTO_CLEANUP_SETTING_KEY, "1" if self.auto_cleanup_var.get() else "0")
        self.db.set_setting(REMINDERS_ENABLED_SETTING_KEY, "1" if self.reminders_enabled_var.get() else "0")
        self.db.set_setting(MORNING_REMINDER_TIME_SETTING_KEY, self.morning_reminder_var.get().strip())
        self.db.set_setting(EVENING_REMINDER_TIME_SETTING_KEY, self.evening_reminder_var.get().strip())
        self.db.set_setting(LAUNCH_AT_LOGIN_SETTING_KEY, "1" if self.launch_at_login_var.get() else "0")
        self.db.set_setting(ANALYTICS_ENABLED_SETTING_KEY, "1" if self.analytics_enabled_var.get() else "0")
        self.db.set_setting(SHOW_DOCK_ICON_SETTING_KEY, "1" if self.show_dock_icon_var.get() else "0")
        self.db.set_setting(SHOW_TIMELINE_ICONS_SETTING_KEY, "1" if self.show_timeline_icons_var.get() else "0")
        self.db.set_setting(SHOW_JOURNAL_DEBUG_SETTING_KEY, "1" if self.show_journal_debug_var.get() else "0")
        self.db.set_setting(OUTPUT_LANGUAGE_SETTING_KEY, self.output_language_var.get().strip() or "English")
        self.db.set_setting(JOURNAL_UNLOCKED_SETTING_KEY, "1" if self.journal_unlocked_var.get() else "0")
        self.db.set_setting(JOURNAL_ONBOARDED_SETTING_KEY, "1" if self.journal_onboarded_var.get() else "0")
        self._append_log("Settings saved.")

    def _on_capture_sample(self, sample: CaptureResult) -> None:
        self.events.put(("sample", sample))

    def _on_capture_error(self, error: Exception) -> None:
        self.events.put(("error", error))

    def _drain_events(self) -> None:
        while True:
            try:
                kind, payload = self.events.get_nowait()
            except queue.Empty:
                break

            if kind == "sample":
                if not isinstance(payload, CaptureResult):
                    continue
                sample = payload
                self.last_capture_var.set(
                    "Last capture: "
                    f"{sample.captured_at.astimezone().strftime('%Y-%m-%d %H:%M:%S')} | "
                    f"{sample.process_name} | {sample.window_title[:80]}"
                )
                self._append_log(f"Captured screenshot #{sample.id} ({sample.process_name}) {sample.file_path}")
                if self.auto_cleanup_var.get():
                    self._maybe_cleanup_storage()
                if self._selected_date() == date.today():
                    self._refresh_timeline()
            elif kind == "error":
                self._append_log(f"Capture error: {payload}")
            elif kind == "ai_done":
                self._append_log(f"AI timeline generated successfully (model={payload}).")
                self._refresh_ai_timeline()
            elif kind == "ai_error":
                self._append_log(f"AI generation failed: {payload}")
                self.ai_status_var.set("AI: Generation failed. Check settings/API keys.")
            elif kind == "dashboard_done":
                if isinstance(payload, dict):
                    q = str(payload.get("question", ""))
                    a = str(payload.get("answer", ""))
                    self._last_dashboard_question = q
                    self._last_dashboard_answer = a
                    self._set_text(self.dashboard_answer, a)
                    self.dashboard_status_var.set("Dashboard: Answer generated.")
            elif kind == "dashboard_error":
                self._append_log(f"Dashboard error: {payload}")
                self.dashboard_status_var.set("Dashboard: failed. Check provider settings.")
            elif kind == "journal_summary_done":
                self._set_text(self.journal_summary, str(payload))
                self.journal_status_var.set("Journal: AI summary generated.")
            elif kind == "journal_summary_error":
                self._append_log(f"Journal summary generation failed: {payload}")
                self.journal_status_var.set("Journal: AI summary failed.")
            elif kind == "provider_test_done":
                result = str(payload).strip() or "OK"
                self.settings_connection_status_var.set(f"Connection: success ({result})")
                self._append_log("Provider connection test succeeded.")
            elif kind == "provider_test_error":
                self.settings_connection_status_var.set("Connection: failed")
                self._append_log(f"Provider connection test failed: {payload}")

        self._update_button_state()
        self.after(250, self._drain_events)

    def _maybe_cleanup_storage(self) -> None:
        limit_bytes = self._storage_limit_bytes()
        if limit_bytes <= 0:
            return
        removed_count, removed_bytes = self.db.enforce_storage_limit(limit_bytes)
        if removed_count > 0:
            self._append_log(
                f"Auto-cleanup removed {removed_count} files ({removed_bytes / (1024 * 1024):.1f} MB)."
            )

    def _check_reminders(self) -> None:
        try:
            if self.reminders_enabled_var.get():
                now = datetime.now().astimezone()
                today = now.date().isoformat()
                hhmm = now.strftime("%H:%M")
                morning = self.morning_reminder_var.get().strip()
                evening = self.evening_reminder_var.get().strip()
                if hhmm == morning and today not in self._reminder_sent_for["morning"]:
                    self._reminder_sent_for["morning"].add(today)
                    messagebox.showinfo("Dayflow Journal", "Set your intentions for today.")
                if hhmm == evening and today not in self._reminder_sent_for["evening"]:
                    self._reminder_sent_for["evening"].add(today)
                    messagebox.showinfo("Dayflow Journal", "Time for evening reflections.")
        finally:
            self.after(30000, self._check_reminders)

    def _storage_limit_bytes(self) -> int:
        try:
            gb = float(self.storage_limit_gb_var.get().strip())
        except ValueError:
            gb = 0.0
        if gb <= 0:
            return 0
        return int(gb * 1024 * 1024 * 1024)

    def _ai_settings(self) -> tuple[str, str, str, str]:
        provider = self.ai_provider_var.get().strip().lower() or "gemini"
        model = self.ai_model_var.get().strip()
        api_key = self.ai_api_key_var.get().strip()
        endpoint = self.ai_endpoint_var.get().strip()
        self._save_settings_only()
        return provider, model, api_key, endpoint

    def _update_button_state(self) -> None:
        if self.capture_service.is_running:
            self.start_button.configure(state=tk.DISABLED)
            self.stop_button.configure(state=tk.NORMAL)
        else:
            self.start_button.configure(state=tk.NORMAL)
            self.stop_button.configure(state=tk.DISABLED)

    def _open_data_folder(self) -> None:
        subprocess.Popen(["explorer", str(data_directory())])

    def _on_close(self) -> None:
        self.capture_service.stop()
        self.destroy()

    def _append_log(self, message: str) -> None:
        self.log_output.configure(state="normal")
        self.log_output.insert("end", f"[{_now_stamp()}] {message}\n")
        self.log_output.see("end")
        self.log_output.configure(state="disabled")

    def _selected_date(self) -> date:
        raw = self.date_var.get().strip()
        try:
            return date.fromisoformat(raw)
        except ValueError:
            today = date.today()
            self.date_var.set(today.isoformat())
            return today

    def _current_interval(self) -> float:
        try:
            value = float(self.interval_var.get().strip())
        except ValueError:
            value = self.db.get_setting_float(INTERVAL_SETTING_KEY, 10.0)
            value = max(2.0, min(300.0, value))
            self.interval_var.set(f"{value:g}")
            return value
        value = max(2.0, min(300.0, value))
        self.interval_var.set(f"{value:g}")
        return value

    @staticmethod
    def _set_text(widget: ScrolledText, value: str) -> None:
        original_state = str(widget.cget("state"))
        widget.configure(state="normal")
        widget.delete("1.0", "end")
        widget.insert("end", value or "")
        if original_state in {"disabled", "normal"}:
            widget.configure(state=original_state)

    @staticmethod
    def _get_text(widget: ScrolledText) -> str:
        return widget.get("1.0", "end").strip()


def _normalize_category(raw: str) -> str:
    text = (raw or "").strip().lower()
    if text in {"coding", "research", "writing", "design"}:
        return "Core"
    if text in {"communication", "meeting"}:
        return "Personal"
    if text in {"browsing", "other", "distractions"}:
        return "Distractions"
    if text in {"idle"}:
        return "Idle"
    return "Core"


def _filter_matches(filter_key: str, category: str) -> bool:
    if filter_key == "all":
        return True
    if filter_key == "core":
        return category == "Core"
    if filter_key == "personal":
        return category == "Personal"
    if filter_key == "distractions":
        return category == "Distractions"
    if filter_key == "idle":
        return category == "Idle"
    return True


def _infer_category_from_classic(process_name: str, window_title: str) -> str:
    p = (process_name or "").lower()
    w = (window_title or "").lower()
    if "idle" in p or "idle" in w:
        return "Idle"
    if any(k in w for k in ["twitter", "x.com", "instagram", "youtube", "reddit", "doomscroll"]):
        return "Distractions"
    if any(k in p for k in ["chrome", "msedge", "firefox", "safari"]):
        return "Distractions"
    if any(k in w for k in ["meet", "zoom", "slack", "discord", "teams", "call"]):
        return "Personal"
    if any(k in p for k in ["code", "pycharm", "idea", "notion", "figma", "terminal"]):
        return "Core"
    return "Core"


def _palette_for_category(category: str) -> tuple[str, str]:
    if category == "Distractions":
        return ("#ffe4dd", "#f3b2a7")
    if category == "Personal":
        return ("#d6eefc", "#afd5ee")
    if category == "Idle":
        return ("#f5c29b", "#ddb08f")
    return ("#f5e3c3", "#e2cfaa")


def _icon_for_category(category: str) -> str:
    if category == "Distractions":
        return "\u2715"
    if category == "Personal":
        return "\U0001f46b"
    if category == "Idle":
        return "\U0001f634"
    return "\U0001f4bc"


def _mix_hex(start_hex: str, end_hex: str, ratio: float) -> str:
    ratio = max(0.0, min(1.0, float(ratio)))
    s = _hex_to_rgb(start_hex)
    e = _hex_to_rgb(end_hex)
    mixed = (
        int(s[0] + (e[0] - s[0]) * ratio),
        int(s[1] + (e[1] - s[1]) * ratio),
        int(s[2] + (e[2] - s[2]) * ratio),
    )
    return f"#{mixed[0]:02x}{mixed[1]:02x}{mixed[2]:02x}"


def _hex_to_rgb(value: str) -> tuple[int, int, int]:
    h = value.strip().lstrip("#")
    if len(h) != 6:
        return (0, 0, 0)
    try:
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    except ValueError:
        return (0, 0, 0)


def _fmt_time(timestamp) -> str:
    if timestamp.tzinfo is None:
        return timestamp.strftime("%H:%M:%S")
    return timestamp.astimezone().strftime("%H:%M:%S")


def _friendly_time(value: str) -> str:
    text = (value or "").strip()
    for fmt in ("%H:%M:%S", "%H:%M", "%I:%M %p", "%I:%M%p"):
        try:
            dt = datetime.strptime(text, fmt)
            return dt.strftime("%I:%M %p").lstrip("0")
        except ValueError:
            continue
    return text


def _duration_minutes(start_hhmm: str, end_hhmm: str) -> int:
    start = _parse_clock_minutes(start_hhmm)
    end = _parse_clock_minutes(end_hhmm)
    if start is None or end is None:
        return 0
    if end < start:
        return 0
    return end - start


def _parse_clock_minutes(value: str | None) -> int | None:
    text = (value or "").strip()
    if not text:
        return None
    for fmt in ("%H:%M", "%H:%M:%S", "%I:%M %p", "%I:%M%p"):
        try:
            parsed = datetime.strptime(text, fmt)
            return parsed.hour * 60 + parsed.minute
        except ValueError:
            continue
    return None


def _parse_iso_date(value: str | None) -> date | None:
    text = (value or "").strip()
    if not text:
        return None
    try:
        return date.fromisoformat(text)
    except ValueError:
        return None


def _now_stamp() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S")


def _capture_once_cli() -> int:
    ensure_directories()
    db = DayflowWindowsDatabase(database_path())
    service = ScreenCaptureService(db)
    sample = service.capture_once()
    print(
        f"captured={sample.id} process={sample.process_name} "
        f"window={sample.window_title} file={sample.file_path}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dayflow_windows")
    parser.add_argument("--capture-once", action="store_true", help="Capture one screenshot and exit")
    parser.add_argument("--version", action="store_true", help="Print app version and exit")
    args = parser.parse_args(argv)
    if args.version:
        print(__version__)
        return 0
    if args.capture_once:
        return _capture_once_cli()
    app = DayflowWindowsApp()
    app.mainloop()
    return 0




