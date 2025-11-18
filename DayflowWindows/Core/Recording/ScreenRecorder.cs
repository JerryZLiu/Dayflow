using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Windows.Graphics.Capture;
using Windows.Graphics;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;
using SharpDX.Direct3D11;
using SharpDX.DXGI;

namespace Dayflow.Core.Recording
{
    /// <summary>
    /// Screen recorder using Windows Graphics Capture API
    /// Captures screen at 1 FPS in 15-second chunks, similar to macOS ScreenCaptureKit
    /// </summary>
    public class ScreenRecorder : IDisposable
    {
        private readonly StorageManager _storage;
        private GraphicsCaptureSession? _captureSession;
        private Direct3D11CaptureFramePool? _framePool;
        private GraphicsCaptureItem? _captureItem;
        private CancellationTokenSource? _cancellationTokenSource;
        private bool _isRecording;
        private readonly object _lock = new();

        public event EventHandler<RecordingStateChangedEventArgs>? StateChanged;
        public event EventHandler<RecordingErrorEventArgs>? ErrorOccurred;

        public bool IsRecording
        {
            get { lock (_lock) return _isRecording; }
            private set
            {
                lock (_lock)
                {
                    if (_isRecording != value)
                    {
                        _isRecording = value;
                        StateChanged?.Invoke(this, new RecordingStateChangedEventArgs(_isRecording));
                    }
                }
            }
        }

        public ScreenRecorder(StorageManager storage)
        {
            _storage = storage;
        }

        /// <summary>
        /// Starts screen recording
        /// </summary>
        public async Task StartRecording()
        {
            if (IsRecording)
                return;

            try
            {
                // Check if Graphics Capture is supported
                if (!GraphicsCaptureSession.IsSupported())
                {
                    throw new NotSupportedException("Graphics Capture is not supported on this system. Requires Windows 10 1803 or later.");
                }

                _cancellationTokenSource = new CancellationTokenSource();
                IsRecording = true;

                // Start the recording loop (1 FPS, 15-second chunks)
                await RecordingLoop(_cancellationTokenSource.Token);
            }
            catch (Exception ex)
            {
                IsRecording = false;
                ErrorOccurred?.Invoke(this, new RecordingErrorEventArgs(ex));
                Sentry.SentrySdk.CaptureException(ex);
                throw;
            }
        }

        /// <summary>
        /// Stops screen recording
        /// </summary>
        public void StopRecording()
        {
            if (!IsRecording)
                return;

            _cancellationTokenSource?.Cancel();
            CleanupCaptureSession();
            IsRecording = false;
        }

        private async Task RecordingLoop(CancellationToken cancellationToken)
        {
            var frameInterval = TimeSpan.FromSeconds(1); // 1 FPS
            var chunkDuration = TimeSpan.FromSeconds(15); // 15-second chunks

            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    await CaptureChunk(chunkDuration, frameInterval, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    // Handle retryable errors (similar to macOS implementation)
                    if (IsRetryableError(ex))
                    {
                        await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
                        continue;
                    }

                    ErrorOccurred?.Invoke(this, new RecordingErrorEventArgs(ex));
                    Sentry.SentrySdk.CaptureException(ex);
                    break;
                }
            }
        }

        private async Task CaptureChunk(TimeSpan duration, TimeSpan frameInterval, CancellationToken cancellationToken)
        {
            var startTime = DateTime.UtcNow;
            var chunkPath = _storage.GetChunkPath(startTime);

            // Initialize capture session if needed
            if (_captureSession == null)
            {
                await InitializeCaptureSession();
            }

            var frames = new System.Collections.Generic.List<byte[]>();

            while (DateTime.UtcNow - startTime < duration && !cancellationToken.IsCancellationRequested)
            {
                var frame = await CaptureFrame();
                if (frame != null)
                {
                    frames.Add(frame);
                }

                await Task.Delay(frameInterval, cancellationToken);
            }

            // Encode frames to video file
            if (frames.Count > 0)
            {
                await EncodeFramesToVideo(frames, chunkPath);
                await _storage.SaveChunkMetadata(chunkPath, startTime, frames.Count);
            }
        }

        private async Task InitializeCaptureSession()
        {
            // Get the primary display
            var item = await GetPrimaryDisplayCaptureItem();
            if (item == null)
            {
                throw new InvalidOperationException("Failed to get display for capture");
            }

            _captureItem = item;

            // Create frame pool
            var device = Direct3D11Helpers.CreateDevice();
            _framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                device,
                Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
                2, // Number of buffers
                item.Size);

            _captureSession = _framePool.CreateCaptureSession(item);
            _captureSession.StartCapture();
        }

        private async Task<GraphicsCaptureItem?> GetPrimaryDisplayCaptureItem()
        {
            // For Windows, we need to use GraphicsCapturePicker for user consent
            // In production, you'd show UI for the user to select a display
            var picker = new Windows.Graphics.Capture.GraphicsCapturePicker();
            return await picker.PickSingleItemAsync();
        }

        private async Task<byte[]?> CaptureFrame()
        {
            if (_framePool == null)
                return null;

            try
            {
                using var frame = _framePool.TryGetNextFrame();
                if (frame == null)
                    return null;

                // Convert frame to byte array
                // Implementation depends on your video encoding needs
                // This is a simplified version
                return await ConvertFrameToBytes(frame);
            }
            catch
            {
                return null;
            }
        }

        private async Task<byte[]> ConvertFrameToBytes(Direct3D11CaptureFrame frame)
        {
            // Convert Direct3D11 surface to byte array
            // This is a placeholder - actual implementation would use SharpDX or similar
            return await Task.FromResult(Array.Empty<byte>());
        }

        private async Task EncodeFramesToVideo(System.Collections.Generic.List<byte[]> frames, string outputPath)
        {
            // Use Windows MediaFoundation or FFmpeg to encode frames to H.264 video
            // Similar to AVAssetWriter on macOS
            // This is a simplified placeholder
            Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
            await Task.CompletedTask;
        }

        private bool IsRetryableError(Exception ex)
        {
            // Similar to macOS CoreGraphics retryable errors
            return ex is COMException comEx && (
                comEx.HResult == unchecked((int)0x88980406) || // DXGI_ERROR_DEVICE_HUNG
                comEx.HResult == unchecked((int)0x88980405)    // DXGI_ERROR_DEVICE_REMOVED
            );
        }

        private void CleanupCaptureSession()
        {
            _captureSession?.Dispose();
            _framePool?.Dispose();
            _captureSession = null;
            _framePool = null;
        }

        public void Dispose()
        {
            StopRecording();
            _cancellationTokenSource?.Dispose();
        }
    }

    public class RecordingStateChangedEventArgs : EventArgs
    {
        public bool IsRecording { get; }
        public RecordingStateChangedEventArgs(bool isRecording) => IsRecording = isRecording;
    }

    public class RecordingErrorEventArgs : EventArgs
    {
        public Exception Error { get; }
        public RecordingErrorEventArgs(Exception error) => Error = error;
    }

    // Helper class for Direct3D11 device creation
    internal static class Direct3D11Helpers
    {
        public static IDirect3DDevice CreateDevice()
        {
            var d3dDevice = new SharpDX.Direct3D11.Device(
                SharpDX.Direct3D.DriverType.Hardware,
                DeviceCreationFlags.BgraSupport);

            using var dxgiDevice = d3dDevice.QueryInterface<IDXGIDevice>();
            var hr = CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice, out var device);
            if (hr != 0)
            {
                throw new Exception($"Failed to create Direct3D11 device. HRESULT: {hr:X8}");
            }

            return device;
        }

        [System.Runtime.InteropServices.DllImport(
            "d3d11.dll",
            EntryPoint = "CreateDirect3D11DeviceFromDXGIDevice",
            SetLastError = true,
            CharSet = System.Runtime.InteropServices.CharSet.Unicode,
            ExactSpelling = true,
            CallingConvention = System.Runtime.InteropServices.CallingConvention.StdCall)]
        private static extern uint CreateDirect3D11DeviceFromDXGIDevice(
            IntPtr dxgiDevice,
            out IDirect3DDevice graphicsDevice);

        private static uint CreateDirect3D11DeviceFromDXGIDevice(
            IDXGIDevice dxgiDevice,
            out IDirect3DDevice device)
        {
            return CreateDirect3D11DeviceFromDXGIDevice(
                System.Runtime.InteropServices.Marshal.GetIUnknownForObject(dxgiDevice),
                out device);
        }
    }
}
