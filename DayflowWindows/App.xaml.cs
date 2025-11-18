using System;
using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using Dayflow.Core.Recording;
using Dayflow.Core.Storage;
using Dayflow.Core.Security;
using Dayflow.Core.AI;
using Dayflow.System;
using Dayflow.ViewModels;

namespace Dayflow
{
    /// <summary>
    /// Dayflow Windows Application
    /// A timeline of your day, automatically.
    /// </summary>
    public partial class App : Application
    {
        private readonly IServiceProvider _serviceProvider;
        private SystemTrayController? _systemTray;

        public App()
        {
            var services = new ServiceCollection();
            ConfigureServices(services);
            _serviceProvider = services.BuildServiceProvider();
        }

        private void ConfigureServices(IServiceCollection services)
        {
            // Core Services
            services.AddSingleton<StorageManager>();
            services.AddSingleton<ScreenRecorder>();
            services.AddSingleton<CredentialManager>();
            services.AddSingleton<AnalyticsService>();
            services.AddSingleton<UpdaterManager>();
            services.AddSingleton<SystemTrayController>();
            services.AddSingleton<InactivityMonitor>();

            // AI Providers
            services.AddTransient<GeminiProvider>();
            services.AddTransient<LocalProvider>();

            // View Models
            services.AddTransient<MainViewModel>();
            services.AddTransient<SettingsViewModel>();
            services.AddTransient<TimelineViewModel>();

            // Windows
            services.AddTransient<MainWindow>();
        }

        protected override async void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            try
            {
                // Initialize Sentry for error tracking
                Sentry.SentrySdk.Init(options =>
                {
                    options.Dsn = ""; // Configure in release
                    options.AutoSessionTracking = true;
                    options.IsGlobalModeEnabled = true;
                });

                // Initialize storage
                var storage = _serviceProvider.GetRequiredService<StorageManager>();
                await storage.InitializeAsync();

                // Initialize analytics
                var analytics = _serviceProvider.GetRequiredService<AnalyticsService>();
                analytics.Initialize();

                // Start system tray
                _systemTray = _serviceProvider.GetRequiredService<SystemTrayController>();
                _systemTray.Initialize();

                // Initialize updater
                var updater = _serviceProvider.GetRequiredService<UpdaterManager>();
                updater.Initialize();

                // Start inactivity monitoring
                var inactivityMonitor = _serviceProvider.GetRequiredService<InactivityMonitor>();
                inactivityMonitor.Start();

                // Show main window (initially hidden, shown via tray)
                var mainWindow = _serviceProvider.GetRequiredService<MainWindow>();
                MainWindow = mainWindow;

                // Handle deep links
                HandleCommandLineArgs(e.Args);
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
                MessageBox.Show($"Failed to start Dayflow: {ex.Message}", "Startup Error",
                    MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(1);
            }
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _systemTray?.Dispose();
            Sentry.SentrySdk.Close();
            base.OnExit(e);
        }

        private void HandleCommandLineArgs(string[] args)
        {
            if (args.Length > 0)
            {
                var recorder = _serviceProvider.GetRequiredService<ScreenRecorder>();

                foreach (var arg in args)
                {
                    if (arg.StartsWith("dayflow://", StringComparison.OrdinalIgnoreCase))
                    {
                        HandleDeepLink(arg);
                    }
                }
            }
        }

        private void HandleDeepLink(string url)
        {
            var recorder = _serviceProvider.GetRequiredService<ScreenRecorder>();
            var analytics = _serviceProvider.GetRequiredService<AnalyticsService>();

            if (url.Contains("start-recording", StringComparison.OrdinalIgnoreCase))
            {
                recorder.StartRecording();
                analytics.TrackEvent("recording_started", new { reason = "deeplink" });
            }
            else if (url.Contains("stop-recording", StringComparison.OrdinalIgnoreCase))
            {
                recorder.StopRecording();
                analytics.TrackEvent("recording_stopped", new { reason = "deeplink" });
            }
        }

        public static IServiceProvider Services => ((App)Current)._serviceProvider;
    }
}
