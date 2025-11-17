# Screen Recording Migration Strategy: macOS → Windows

**Component**: Core screen recording functionality
**Priority**: P0 - CRITICAL PATH
**Complexity**: HIGH

---

## Current macOS Implementation

### Technology Stack
- **Framework**: ScreenCaptureKit (macOS 12.3+)
- **File**: `/home/user/Dayflow/Dayflow/Dayflow/Core/Recording/ScreenRecorder.swift`
- **Video Encoding**: AVFoundation (H.264, 1 FPS)
- **Chunk Duration**: 15 seconds per file
- **Resolution**: 1080p target height, scaled proportionally

### Key Features
1. **Display Selection**: Captures primary display by default
2. **State Machine**: Idle → Starting → Recording → Finishing → Paused
3. **Error Handling**:
   - Transient errors (display disconnect, system sleep) → auto-retry
   - User-initiated stop → no retry
4. **Power Management**: Auto-pause on sleep, resume on wake
5. **Multi-display Support**: Tracks active display, adapts to changes
6. **Permissions**: Screen Recording permission via macOS Privacy & Security

### Technical Implementation Details

```swift
// From ScreenRecorder.swift
private enum C {
    static let targetHeight = 1080               // Target ~1080p resolution
    static let chunk  : TimeInterval = 15        // seconds per file
    static let fps    : Int32        = 1         // keep @ 1 fps
}

// Screen capture stream setup
let filter = SCContentFilter(display: targetDisplay, excludeWindows: [])
let config = SCStreamConfiguration()
config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(C.fps))
config.width = calculatedWidth
config.height = C.targetHeight

let stream = SCStream(filter: filter, configuration: config, delegate: self)
stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
try await stream.startCapture()
```

### Error Codes Handled
- `-3807`: Display disconnected (transient)
- `-3808`: User stopped via system UI
- `-3815`: Display not ready after wake/unlock
- `-3817`: User declined
- `-3805`: Connection invalid
- `-3802`: Stream already stopping
- `-3821`: System stopped (disk space)

---

## Windows Implementation Options

### Option 1: Windows.Graphics.Capture API (Recommended)

#### Overview
- **Namespace**: `Windows.Graphics.Capture`
- **Introduced**: Windows 10 version 1803 (April 2018)
- **Modern WinRT API**, works with WinUI 3

#### Advantages
✅ Modern, officially supported API
✅ Works with DirectX, good performance
✅ Integrates well with WinUI 3 / UWP apps
✅ Per-monitor DPI aware
✅ Supports window and monitor capture

#### Disadvantages
❌ Requires user permission **per session** (no persistent permission)
❌ Yellow border around captured window/screen (by design)
❌ Cannot capture protected content (DRM)
❌ More complex setup than ScreenCaptureKit

#### Sample Code Structure

```csharp
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

public class ScreenRecorder
{
    private GraphicsCaptureSession _captureSession;
    private Direct3D11CaptureFramePool _framePool;
    private GraphicsCaptureItem _captureItem;

    public async Task StartCaptureAsync()
    {
        // User must select what to capture
        var picker = new GraphicsCapturePicker();
        _captureItem = await picker.PickSingleItemAsync();

        if (_captureItem == null) return; // User cancelled

        // Create Direct3D device
        var d3dDevice = Direct3D11Helpers.CreateDevice();

        // Create frame pool
        _framePool = Direct3D11CaptureFramePool.Create(
            d3dDevice,
            DirectXPixelFormat.B8G8R8A8UIntNormalized,
            2, // Number of buffers
            _captureItem.Size);

        // Set up frame arrival handler
        _framePool.FrameArrived += OnFrameArrived;

        // Start capture session
        _captureSession = _framePool.CreateCaptureSession(_captureItem);
        _captureSession.IsBorderRequired = false; // May not work on all systems
        _captureSession.StartCapture();
    }

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        using var frame = sender.TryGetNextFrame();
        if (frame == null) return;

        // Process frame (encode to video)
        ProcessFrame(frame);
    }
}
```

#### Implementation Plan

1. **Capture Session Management**
   - [ ] Request user to select screen/window on first launch
   - [ ] Store preference for auto-capture on subsequent launches
   - [ ] Handle picker cancellation gracefully
   - [ ] Re-prompt if selected display/window closes

2. **Frame Rate Control**
   - [ ] Capture frames at system refresh rate
   - [ ] Filter to 1 FPS in processing pipeline
   - [ ] Use `Stopwatch` for precise timing

3. **Video Encoding**
   - See separate encoding strategy below

4. **Multi-Monitor Support**
   - [ ] Allow user to select which monitor
   - [ ] Handle monitor connect/disconnect
   - [ ] Re-initialize capture on display changes

5. **Permissions & UI**
   - [ ] Show picker dialog with instructions
   - [ ] Explain yellow border (cannot be fully removed)
   - [ ] Provide retry mechanism if user cancels

---

### Option 2: DXGI Desktop Duplication API

#### Overview
- **Namespace**: `SharpDX.DXGI` (or P/Invoke)
- **Introduced**: Windows 8
- **Low-level DirectX API**

#### Advantages
✅ No user prompt required (runs silently)
✅ No yellow border
✅ Very fast, low latency
✅ Fine-grained control

#### Disadvantages
❌ More complex implementation
❌ Requires significant DirectX knowledge
❌ Per-adapter enumeration needed
❌ Doesn't handle multi-GPU scenarios well
❌ Can fail if desktop is not composited

#### Use Case
Best for **background monitoring** where user interaction is undesirable.

#### Sample Code Structure

```csharp
using SharpDX.DXGI;
using SharpDX.Direct3D11;

public class DXGIScreenRecorder
{
    private Device _device;
    private OutputDuplication _outputDuplication;

    public void Initialize(int adapterIndex, int outputIndex)
    {
        var factory = new Factory1();
        var adapter = factory.GetAdapter1(adapterIndex);
        _device = new Device(adapter);

        var output = adapter.GetOutput(outputIndex);
        var output1 = output.QueryInterface<Output1>();

        _outputDuplication = output1.DuplicateOutput(_device);
    }

    public bool TryGetFrame(out Texture2D texture)
    {
        OutputDuplicateFrameInformation frameInfo;
        SharpDX.DXGI.Resource screenResource;

        var result = _outputDuplication.TryAcquireNextFrame(
            100, // timeout ms
            out frameInfo,
            out screenResource);

        if (result.Failure)
        {
            texture = null;
            return false;
        }

        texture = screenResource.QueryInterface<Texture2D>();
        _outputDuplication.ReleaseFrame();
        return true;
    }
}
```

---

### Option 3: Hybrid Approach (Fallback Strategy)

#### Strategy
1. **Primary**: Use Windows.Graphics.Capture (modern, supported)
2. **Fallback**: DXGI Desktop Duplication if capture picker is disabled/blocked

#### Implementation
```csharp
public interface IScreenCaptureProvider
{
    Task<bool> InitializeAsync();
    event EventHandler<FrameCapturedEventArgs> FrameCaptured;
    void Start();
    void Stop();
}

public class HybridScreenRecorder
{
    private IScreenCaptureProvider _provider;

    public async Task InitializeAsync()
    {
        // Try Windows.Graphics.Capture first
        _provider = new GraphicsCaptureProvider();
        if (await _provider.InitializeAsync())
        {
            return;
        }

        // Fall back to DXGI
        _provider = new DXGIScreenCaptureProvider();
        await _provider.InitializeAsync();
    }
}
```

---

## Video Encoding Strategy

### Option A: Media Foundation (Native Windows)

#### Overview
- **Native Windows API** for media encoding
- **Namespace**: `Windows.Media.MediaProperties`, `Windows.Media.Transcoding`

#### Advantages
✅ Native to Windows
✅ Hardware acceleration support (Intel Quick Sync, NVENC)
✅ No external dependencies

#### Disadvantages
❌ Complex API
❌ Limited documentation compared to FFmpeg
❌ Requires COM interop knowledge

#### Sample Code
```csharp
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;

public async Task EncodeVideoAsync(IList<Bitmap> frames, string outputPath)
{
    var transcoder = new MediaTranscoder();
    var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
    profile.Video.Bitrate = 2_000_000; // 2 Mbps
    profile.Video.FrameRate.Numerator = 1;
    profile.Video.FrameRate.Denominator = 1;

    // Create MediaStreamSource from frames
    var source = CreateMediaStreamSourceFromFrames(frames);

    var outputFile = await StorageFile.GetFileFromPathAsync(outputPath);
    var prepareOp = await transcoder.PrepareMediaStreamSourceTranscodeAsync(
        source,
        outputFile.OpenAsync(FileAccessMode.ReadWrite),
        profile);

    if (prepareOp.CanTranscode)
    {
        await prepareOp.TranscodeAsync();
    }
}
```

---

### Option B: FFmpeg (via FFmpeg.AutoGen or CLI)

#### Overview
- **Cross-platform** media framework
- Can be embedded via P/Invoke or called as CLI

#### Advantages
✅ Battle-tested, very mature
✅ Excellent documentation and community
✅ Portable (same code could work on Linux)
✅ Precise control over encoding parameters

#### Disadvantages
❌ External dependency (~50MB binaries)
❌ License considerations (LGPL/GPL depending on build)
❌ Requires packaging FFmpeg binaries with app

#### Sample Code (CLI Approach)
```csharp
public async Task EncodeWithFFmpegAsync(string inputPattern, string outputPath)
{
    var ffmpegPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ffmpeg.exe");

    var args = $"-framerate 1 -i \"{inputPattern}\" -c:v libx264 -preset fast " +
               $"-crf 23 -pix_fmt yuv420p \"{outputPath}\"";

    var process = Process.Start(new ProcessStartInfo
    {
        FileName = ffmpegPath,
        Arguments = args,
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true
    });

    await process.WaitForExitAsync();
}
```

---

## Recommended Implementation

### Phase 1: Proof of Concept
**Goal**: Validate Windows.Graphics.Capture can meet requirements

1. Create minimal WinUI 3 app
2. Implement `GraphicsCapturePicker` flow
3. Capture frames to memory
4. Verify 1 FPS can be achieved
5. Test multi-monitor scenarios

**Success Criteria**:
- Can capture at 1080p @ 1 FPS
- Handles display changes gracefully
- Memory usage acceptable (<200MB for 15-second chunks)

### Phase 2: Video Encoding
**Goal**: Implement H.264 encoding matching macOS output

**Recommendation**: Start with FFmpeg CLI
- Faster to prototype
- Can switch to Media Foundation later if needed
- Known quantity (matches macOS quality)

1. Capture frames as PNGs to temp folder
2. Every 15 seconds, invoke FFmpeg to encode chunk
3. Delete source PNGs after encoding
4. Store video file with timestamp

### Phase 3: State Machine & Error Handling
**Goal**: Match macOS robustness

1. Implement state machine (Idle/Starting/Recording/Finishing/Paused)
2. Handle display disconnect → retry logic
3. Handle system sleep/wake → pause/resume
4. Handle user cancellation → graceful shutdown

### Phase 4: Optimization
**Goal**: Reduce overhead and improve reliability

1. Switch from PNG frames to in-memory frame queue
2. Implement streaming encode (don't wait for 15-second chunk)
3. Optimize memory allocation (object pooling for bitmaps)
4. Add telemetry for failure rates

---

## Migration Checklist

### Core Functionality
- [ ] Select primary display (or user-selected display)
- [ ] Capture at 1 FPS
- [ ] Encode to H.264 video chunks (15 seconds each)
- [ ] Target 1080p resolution (or scale proportionally)
- [ ] Handle multi-monitor setups
- [ ] Auto-pause on system sleep
- [ ] Auto-resume on system wake
- [ ] Clean up old recordings after 3 days

### Error Handling
- [ ] Display disconnect → retry
- [ ] User cancels picker → show instructions to re-enable
- [ ] Disk space low → stop recording and notify user
- [ ] Encoding failure → log error, continue to next chunk
- [ ] Permission revoked → show re-authorization flow

### Performance
- [ ] Memory usage under 200MB during recording
- [ ] CPU usage under 5% on modern hardware
- [ ] Disk I/O optimized (batch writes)
- [ ] No dropped frames at 1 FPS

### Testing
- [ ] Single monitor scenario
- [ ] Dual monitor scenario
- [ ] Monitor disconnect during recording
- [ ] Monitor reconnect during recording
- [ ] Sleep/wake cycle during recording
- [ ] Low disk space handling
- [ ] High DPI displays (125%, 150%, 200%)

---

## Open Questions

1. **Permission Persistence**: Can we avoid showing the picker every time?
   - **Research**: Check if `AppCapability` allows persistent capture
   - **Fallback**: Store user preference, re-prompt on app start

2. **Yellow Border**: Can it be fully disabled?
   - **Research**: `IsBorderRequired = false` may not work on all systems
   - **Documentation**: Clearly explain this behavior to users

3. **Protected Content**: What happens when DRM content is on screen?
   - **Research**: Does capture fail or just black out that region?
   - **Testing**: Test with Netflix, Spotify, etc.

4. **Performance on Older Hardware**: How does it perform on non-GPU systems?
   - **Testing**: Test on Intel HD Graphics, AMD APU, etc.

---

## References

- [Windows.Graphics.Capture API Docs](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture)
- [Simple Screen Recorder Sample (Microsoft)](https://github.com/microsoft/Windows-universal-samples/tree/main/Samples/SimpleScreenRecorder)
- [DXGI Desktop Duplication API](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api)
- [FFmpeg Documentation](https://ffmpeg.org/ffmpeg.html)
- [Media Foundation Programming Guide](https://learn.microsoft.com/en-us/windows/win32/medfound/microsoft-media-foundation-sdk)

---

**Created**: 2025-11-17
**Last Updated**: 2025-11-17
