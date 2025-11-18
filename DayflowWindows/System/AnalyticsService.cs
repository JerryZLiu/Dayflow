using System;
using System.Collections.Generic;

namespace Dayflow.System
{
    /// <summary>
    /// Analytics service using PostHog (or similar)
    /// Equivalent to macOS AnalyticsService
    /// </summary>
    public class AnalyticsService
    {
        private bool _isEnabled;
        private string? _userId;

        public void Initialize()
        {
            // Load consent from settings
            _isEnabled = Properties.Settings.Default.AnalyticsEnabled;

            if (_isEnabled)
            {
                // Initialize PostHog or your analytics provider
                _userId = GetOrCreateUserId();
            }
        }

        public void TrackEvent(string eventName, object? properties = null)
        {
            if (!_isEnabled)
                return;

            try
            {
                // Send event to PostHog or your analytics backend
                var eventData = new
                {
                    distinct_id = _userId,
                    @event = eventName,
                    properties = properties ?? new { },
                    timestamp = DateTime.UtcNow
                };

                // PostHog.Capture(eventName, properties);
                System.Diagnostics.Debug.WriteLine($"Analytics: {eventName}");
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
            }
        }

        public void SetAnalyticsEnabled(bool enabled)
        {
            _isEnabled = enabled;
            Properties.Settings.Default.AnalyticsEnabled = enabled;
            Properties.Settings.Default.Save();

            if (enabled && _userId == null)
            {
                _userId = GetOrCreateUserId();
            }
        }

        private string GetOrCreateUserId()
        {
            var userId = Properties.Settings.Default.UserId;
            if (string.IsNullOrEmpty(userId))
            {
                userId = Guid.NewGuid().ToString();
                Properties.Settings.Default.UserId = userId;
                Properties.Settings.Default.Save();
            }
            return userId;
        }
    }
}
