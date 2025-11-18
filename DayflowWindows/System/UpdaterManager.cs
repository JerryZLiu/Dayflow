using System;
using System.Threading.Tasks;
using System.Windows;
using Squirrel;

namespace Dayflow.System
{
    /// <summary>
    /// Manages automatic updates using Squirrel.Windows
    /// Equivalent to macOS Sparkle updater
    /// </summary>
    public class UpdaterManager : IDisposable
    {
        private UpdateManager? _updateManager;
        private readonly string _updateUrl;
        private bool _isInitialized;

        public UpdaterManager()
        {
            // Configure your update server URL
            _updateUrl = "https://dayflow.so/releases/windows";
        }

        public async void Initialize()
        {
            try
            {
                _updateManager = await UpdateManager.GitHubUpdateManager(
                    "https://github.com/JerryZLiu/Dayflow",
                    prerelease: false);

                _isInitialized = true;

                // Check for updates on startup (silent)
                await CheckForUpdatesAsync(silent: true);

                // Schedule daily update checks
                ScheduleDailyChecks();
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
            }
        }

        public async void CheckForUpdates(bool silent = false)
        {
            await CheckForUpdatesAsync(silent);
        }

        private async Task CheckForUpdatesAsync(bool silent = false)
        {
            if (!_isInitialized || _updateManager == null)
                return;

            try
            {
                var updateInfo = await _updateManager.CheckForUpdate();

                if (updateInfo.ReleasesToApply.Count > 0)
                {
                    if (!silent)
                    {
                        var result = MessageBox.Show(
                            $"A new version of Dayflow is available ({updateInfo.FutureReleaseEntry.Version}). Would you like to update now?",
                            "Update Available",
                            MessageBoxButton.YesNo,
                            MessageBoxImage.Information);

                        if (result != MessageBoxResult.Yes)
                            return;
                    }

                    // Download and apply updates
                    await _updateManager.UpdateApp();

                    if (!silent)
                    {
                        var restartResult = MessageBox.Show(
                            "Update installed successfully. Restart Dayflow to apply the update?",
                            "Update Complete",
                            MessageBoxButton.YesNo,
                            MessageBoxImage.Information);

                        if (restartResult == MessageBoxResult.Yes)
                        {
                            UpdateManager.RestartApp();
                        }
                    }
                }
                else if (!silent)
                {
                    MessageBox.Show(
                        "You're running the latest version of Dayflow.",
                        "No Updates Available",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
                if (!silent)
                {
                    MessageBox.Show(
                        $"Failed to check for updates: {ex.Message}",
                        "Update Error",
                        MessageBoxButton.OK,
                        MessageBoxImage.Error);
                }
            }
        }

        private void ScheduleDailyChecks()
        {
            var timer = new System.Threading.Timer(
                async _ => await CheckForUpdatesAsync(silent: true),
                null,
                TimeSpan.FromHours(1), // First check after 1 hour
                TimeSpan.FromHours(24)); // Then daily
        }

        public void Dispose()
        {
            _updateManager?.Dispose();
        }
    }
}
