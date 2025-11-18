using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Dayflow.System
{
    /// <summary>
    /// Monitors user inactivity to support idle reset feature
    /// Equivalent to macOS InactivityMonitor using NSEvent
    /// </summary>
    public class InactivityMonitor : IDisposable
    {
        private readonly TimeSpan _inactivityThreshold;
        private CancellationTokenSource? _cancellationTokenSource;
        private DateTime _lastActivityTime;

        public event EventHandler? InactivityDetected;
        public event EventHandler? ActivityResumed;

        public bool IsIdle { get; private set; }

        public InactivityMonitor(TimeSpan? threshold = null)
        {
            _inactivityThreshold = threshold ?? TimeSpan.FromMinutes(15);
            _lastActivityTime = DateTime.Now;
        }

        public void Start()
        {
            if (_cancellationTokenSource != null)
                return;

            _cancellationTokenSource = new CancellationTokenSource();
            Task.Run(() => MonitorLoop(_cancellationTokenSource.Token));
        }

        public void Stop()
        {
            _cancellationTokenSource?.Cancel();
            _cancellationTokenSource = null;
        }

        private async Task MonitorLoop(CancellationToken cancellationToken)
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    var idleTime = GetIdleTime();
                    var wasIdle = IsIdle;

                    IsIdle = idleTime >= _inactivityThreshold;

                    if (IsIdle && !wasIdle)
                    {
                        InactivityDetected?.Invoke(this, EventArgs.Empty);
                    }
                    else if (!IsIdle && wasIdle)
                    {
                        ActivityResumed?.Invoke(this, EventArgs.Empty);
                    }

                    await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    Sentry.SentrySdk.CaptureException(ex);
                }
            }
        }

        private TimeSpan GetIdleTime()
        {
            var lastInput = new LASTINPUTINFO();
            lastInput.cbSize = (uint)Marshal.SizeOf(lastInput);

            if (GetLastInputInfo(ref lastInput))
            {
                var idleTicks = Environment.TickCount - lastInput.dwTime;
                return TimeSpan.FromMilliseconds(idleTicks);
            }

            return TimeSpan.Zero;
        }

        public void Dispose()
        {
            Stop();
        }

        #region Windows API

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO
        {
            public uint cbSize;
            public uint dwTime;
        }

        #endregion
    }
}
