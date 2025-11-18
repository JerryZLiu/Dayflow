using System;
using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;
using Dayflow.Core.Recording;

namespace Dayflow.System
{
    /// <summary>
    /// Manages the system tray icon and menu
    /// Equivalent to macOS StatusBarController
    /// </summary>
    public class SystemTrayController : IDisposable
    {
        private TaskbarIcon? _notifyIcon;
        private readonly ScreenRecorder _recorder;
        private readonly StorageManager _storage;
        private MainWindow? _mainWindow;

        public SystemTrayController(ScreenRecorder recorder, StorageManager storage)
        {
            _recorder = recorder;
            _storage = storage;
        }

        public void Initialize()
        {
            _notifyIcon = new TaskbarIcon
            {
                Icon = new System.Drawing.Icon("Assets/AppIcon.ico"),
                ToolTipText = "Dayflow - Timeline of your day",
                ContextMenu = CreateContextMenu()
            };

            _notifyIcon.TrayLeftMouseDown += (s, e) => ShowMainWindow();

            // Update icon based on recording state
            _recorder.StateChanged += (s, e) => UpdateIcon(e.IsRecording);
        }

        private ContextMenu CreateContextMenu()
        {
            var menu = new ContextMenu();

            // Start/Stop Recording
            var recordingItem = new MenuItem { Header = "Start Recording" };
            recordingItem.Click += (s, e) => ToggleRecording();
            menu.Items.Add(recordingItem);

            menu.Items.Add(new Separator());

            // Show Window
            var showItem = new MenuItem { Header = "Show Dayflow" };
            showItem.Click += (s, e) => ShowMainWindow();
            menu.Items.Add(showItem);

            // Open Recordings Folder
            var recordingsItem = new MenuItem { Header = "Open Recordings..." };
            recordingsItem.Click += (s, e) => OpenRecordingsFolder();
            menu.Items.Add(recordingsItem);

            menu.Items.Add(new Separator());

            // Settings
            var settingsItem = new MenuItem { Header = "Settings..." };
            settingsItem.Click += (s, e) => ShowSettings();
            menu.Items.Add(settingsItem);

            // Check for Updates
            var updateItem = new MenuItem { Header = "Check for Updates..." };
            updateItem.Click += (s, e) => CheckForUpdates();
            menu.Items.Add(updateItem);

            menu.Items.Add(new Separator());

            // Quit
            var quitItem = new MenuItem { Header = "Quit Dayflow" };
            quitItem.Click += (s, e) => QuitApplication();
            menu.Items.Add(quitItem);

            return menu;
        }

        private void ToggleRecording()
        {
            if (_recorder.IsRecording)
            {
                _recorder.StopRecording();
            }
            else
            {
                _ = _recorder.StartRecording();
            }
        }

        private void UpdateIcon(bool isRecording)
        {
            if (_notifyIcon?.ContextMenu?.Items[0] is MenuItem item)
            {
                item.Header = isRecording ? "Stop Recording" : "Start Recording";
            }

            // Optionally change icon to show recording state
            _notifyIcon!.ToolTipText = isRecording
                ? "Dayflow - Recording active"
                : "Dayflow - Paused";
        }

        private void ShowMainWindow()
        {
            if (Application.Current.MainWindow == null)
                return;

            _mainWindow = (MainWindow)Application.Current.MainWindow;
            _mainWindow.Show();
            _mainWindow.WindowState = WindowState.Normal;
            _mainWindow.Activate();
        }

        private void OpenRecordingsFolder()
        {
            try
            {
                System.Diagnostics.Process.Start("explorer.exe", _storage.RecordingsPath);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to open recordings folder: {ex.Message}",
                    "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void ShowSettings()
        {
            ShowMainWindow();
            // Navigate to settings page
            // Implementation depends on your navigation setup
        }

        private void CheckForUpdates()
        {
            var updater = App.Services.GetService(typeof(UpdaterManager)) as UpdaterManager;
            updater?.CheckForUpdates();
        }

        private void QuitApplication()
        {
            Application.Current.Shutdown();
        }

        public void Dispose()
        {
            _notifyIcon?.Dispose();
        }
    }
}
