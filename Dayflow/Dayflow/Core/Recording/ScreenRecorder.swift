//
//  ScreenRecorder.swift
//  Dayflow
//
//  Lightweight screen recorder – captures the main display at 1280 × 800
//  and stores 15-second H.264 (.mp4) chunks while `AppState.shared.isRecording` is true.
//
//  Created 5 May 2025.  Last cleaned-up 17 May 2025.
//
//  Notes
//  -----
//  •  The recorder lives entirely on its own serial queue (`q`).
//  •  Recording auto-restarts after errors and after system sleep/wake or
//     lock/unlock events.
//  •  Debug prints are compiled-in **only** for DEBUG builds.
//
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import Combine
import IOKit.pwr_mgt
import AppKit
import CoreGraphics
import CoreText

private enum C {
    static let targetHeight = 1080               // Target ~1080p resolution
    static let chunk  : TimeInterval = 15        // seconds per file
    static let fps    : Int32        = 1         // keep @ 1 fps - NOTE: This is intentionally low!
}

// MARK: - SCStream Error Codes
private enum SCStreamErrorCode: Int {
    case noDisplayOrWindow = -3807          // Transient error, display disconnected
    case userStoppedViaSystemUI = -3808     // User clicked "Stop Sharing" in system UI
    case displayNotReady = -3815            // Failed to find displays/windows after wake/unlock
    case userDeclined = -3817               // Alternative code for user stop
    case connectionInvalid = -3805          // Stream connection became invalid
    case attemptToStopStreamState = -3802   // Stream already stopping
    case stoppedBySystem = -3821            // System stopped stream (usually disk space)
    
    var isUserInitiated: Bool {
        switch self {
        case .userStoppedViaSystemUI, .userDeclined:
            return true
        default:
            return false
        }
    }
    
    var shouldAutoRestart: Bool {
        switch self {
        case .noDisplayOrWindow, .displayNotReady, .stoppedBySystem:
            return true  // Transient errors, should retry
        case .userStoppedViaSystemUI, .userDeclined, .connectionInvalid, .attemptToStopStreamState:
            return false // User action or unrecoverable error
        }
    }
}

#if DEBUG
@inline(__always) func dbg(_ msg: @autoclosure () -> String) { print("[Recorder] \(msg())") }
#else
@inline(__always) func dbg(_: @autoclosure () -> String) {}
#endif

// MARK: - ScreenRecorder
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: lifecycle ----------------------------------------------------
    @MainActor
    init(autoStart: Bool = true) {
        super.init()
        dbg("init – autoStart = \(autoStart)")

        // Observe the app-wide recording flag on the main actor,
        // then hop our work back onto the recorder queue.
        sub = AppState.shared.$isRecording
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] rec in
                self?.q.async {
                    rec ? self?.start() : self?.stop()
                }
            }

        // Honor the current flag once (after subscription exists).
        if autoStart, AppState.shared.isRecording { start() }

        registerForSleepAndLock()
    }

        deinit { sub?.cancel(); dbg("deinit") }

    // MARK: private state ----------------------------------------------
    private let q = DispatchQueue(label: "com.dayflow.recorder", qos: .userInitiated)
    private var stream : SCStream?
    private var writer : AVAssetWriter?
    private var input  : AVAssetWriterInput?
    private var firstPTS : CMTime?
    private var timer  : DispatchSourceTimer?
    private var fileURL: URL?
    private var sub    : AnyCancellable?
    private var frames : Int = 0
    private var isStarting = false            // guards concurrent starts
    private var isFinishing = false           // guards concurrent finishes
    private var resumeAfterPause = false      // remember intent across interruptions
    private var recordingWidth: Int = 1280   // Store recording dimensions
    private var recordingHeight: Int = 800

    // MARK: public control ----------------------------------------------
    func start() {
        q.async { [weak self] in
            guard let self else { return }
            guard self.stream == nil,       // not already running
                  self.isStarting == false  // not already starting
            else { return dbg("start – already starting/running") }

            self.isStarting = true          // ←–––– set once
            Task { await self.makeStream() }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self else { return }
            self.isStarting = false         // ←–––– clear **immediately**

            self.finishSegment(restart: false)
            self.stopStream()               // (stopStream also calls reset())
        }
    }

    private func shouldRetry(_ err: Error) -> Bool {
        let scErr = err as NSError
        guard scErr.domain == SCStreamErrorDomain else { return false }
        
        // Check if it's a known error code
        if let errorCode = SCStreamErrorCode(rawValue: Int(scErr.code)) {
            dbg("SCStream error code: \(scErr.code) (\(errorCode)) - shouldAutoRestart: \(errorCode.shouldAutoRestart)")
            return errorCode.shouldAutoRestart
        }
        
        // Unknown error code - log it and don't retry
        dbg("Unknown SCStream error code: \(scErr.code) - not retrying")
        return false
    }
    
    private func isUserInitiatedStop(_ err: Error) -> Bool {
        let scErr = err as NSError
        guard scErr.domain == SCStreamErrorDomain else { return false }
        
        // Check if it's a known user-initiated error code
        if let errorCode = SCStreamErrorCode(rawValue: Int(scErr.code)) {
            return errorCode.isUserInitiated
        }
        
        // Check userInfo for additional context
        let userInfo = scErr.userInfo
        if let reason = userInfo[NSLocalizedFailureReasonErrorKey] as? String {
            let userStopIndicators = ["user stopped", "stopped by user", "user cancelled", "stop sharing"]
            let lowercasedReason = reason.lowercased()
            if userStopIndicators.contains(where: { lowercasedReason.contains($0) }) {
                dbg("Detected user stop from error reason: \(reason)")
                return true
            }
        }
        
        return false
    }

    // MARK: stream setup -------------------------------------------------
    private func makeStream(attempt: Int = 1, maxAttempts: Int = 4) async {
        do {
            // 1. find a display
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                throw RecorderError.noDisplay
            }

            // 2. filter
            let filter = SCContentFilter(display: display,
                                         excludingApplications: [],
                                         exceptingWindows: [])

            // 3. configuration
            let cfg                 = SCStreamConfiguration()
            
            // Calculate dimensions to maintain aspect ratio at ~1080p
            let displayWidth = display.width
            let displayHeight = display.height
            let aspectRatio = Double(displayWidth) / Double(displayHeight)
            
            // Scale to target height while maintaining aspect ratio
            let targetHeight = C.targetHeight
            let targetWidth = Int(Double(targetHeight) * aspectRatio)
            
            cfg.width               = targetWidth
            cfg.height              = targetHeight
            cfg.capturesAudio       = false
            cfg.pixelFormat         = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: C.fps)
            
            // Store dimensions for later use
            recordingWidth = targetWidth
            recordingHeight = targetHeight
            
            dbg("Recording at \(targetWidth)×\(targetHeight) (display: \(displayWidth)×\(displayHeight), ratio: \(String(format: "%.2f", aspectRatio)):1)")

            // 4. kick-off
            try await startStream(filter: filter, config: cfg)
        }
        catch {
            dbg("makeStream failed [attempt \(attempt)] – \(error.localizedDescription)")

            q.async { self.isStarting = false }

            // Check if this is a user-initiated stop
            if isUserInitiatedStop(error) {
                dbg("User stopped recording during startup - updating app state")
                Task { @MainActor in self.forceStopFlag() }
                return
            }
            
            // Treat `noDisplay` like other transient issues
            let retryable = shouldRetry(error) || (error as? RecorderError) == .noDisplay

            if retryable, attempt < maxAttempts {
                let delay = Double(attempt)        // 1 s, 2 s, 3 s …
                dbg("retrying in \(delay)s")
                q.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
            } else {
                Task { @MainActor in self.forceStopFlag() }
            }
        }
    }

    @MainActor
    private func forceStopFlag() {
        AppState.shared.isRecording = false
    }

    @MainActor
    private func startStream(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
        dbg("stream started")
    }

    private func stopStream() {
        if let s = stream { s.stopCapture()
            do {
              try s.removeStreamOutput(self, type: .screen)
            } catch {
              dbg("removeStreamOutput failed – \(error)")
            }

        }
        
        stream = nil
        isStarting = false
        reset(); dbg("stream stopped")
    }

    // MARK: segment rotation --------------------------------------------
    private func beginSegment() {
        guard writer == nil else { return }
        let url = StorageManager.shared.nextFileURL(); fileURL = url; frames = 0

        StorageManager.shared.registerChunk(url: url)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            
            // Increase bitrate for higher resolution (roughly 2.5 Mbps for 1080p at 1fps)
            let bitrate = 2500000 // 2.5 Mbps
            
            let inp = AVAssetWriterInput(mediaType: .video,
                                         outputSettings: [
                                             AVVideoCodecKey  : AVVideoCodecType.h264,
                                             AVVideoWidthKey  : recordingWidth,
                                             AVVideoHeightKey : recordingHeight,
                                             AVVideoCompressionPropertiesKey: [
                                                 AVVideoAverageBitRateKey: bitrate,
                                                 AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                                                 AVVideoMaxKeyFrameIntervalKey: 30
                                             ]
                                         ])
            inp.expectsMediaDataInRealTime = true
            guard w.canAdd(inp) else { throw RecorderError.badInput }
            w.add(inp); writer = w; input = inp

            // auto-finish after C.chunk seconds
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + C.chunk)
            t.setEventHandler { [weak self] in self?.finishSegment() }
            t.resume(); timer = t
        } catch {
            dbg("writer creation failed – \(error.localizedDescription)")
            StorageManager.shared.markChunkFailed(url: url); reset()
        }
    }

    private func finishSegment(restart: Bool = true) {
        // Guard against concurrent calls
        guard !isFinishing else { return }
        isFinishing = true
        
        // 1. stop the timer that would have closed the file
        timer?.cancel()
        timer = nil

        // 2. make sure we even have something to finish
        guard let w = writer, let inp = input, let url = fileURL else {
            isFinishing = false
            return reset()
        }

        // ── EARLY EXIT ────────────────────────────────────────────────────
        guard frames > 0 else {
            w.cancelWriting()
            StorageManager.shared.markChunkFailed(url: url)
            isFinishing = false
            reset()
            return
        }
        // ─────────────────────────────────────────────────────────────────

        guard w.status == .writing else {
            w.cancelWriting()
            StorageManager.shared.markChunkFailed(url: url)
            isFinishing = false
            reset()
            return
        }

        // 4. normal shutdown path
        inp.markAsFinished()
        w.finishWriting { [weak self] in
            guard let self = self else { return }
            if w.status == .completed {
                StorageManager.shared.markChunkCompleted(url: url)
            } else {
                StorageManager.shared.markChunkFailed(url: url)
            }
            self.reset()
            self.isFinishing = false  // Clear the flag after completion

            guard restart else { return }

            // Hop back to the main actor to read the flag safely.
            Task { @MainActor in
                if AppState.shared.isRecording {
                    self.beginSegment()
                }
            }
        }
    }

    private func reset() {
        timer = nil; writer = nil; input = nil; firstPTS = nil; fileURL = nil; frames = 0
    }

    // MARK: sample-buffer handling ---------------------------------------
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sb) else { return }
        guard isComplete(sb) else { return }
        if let pb = CMSampleBufferGetImageBuffer(sb) {
            // TEMPORARILY DISABLED to test if this causes corruption
            // overlayClock(on: pb)          // ← inject the clock into this frame
        }
        if writer == nil { beginSegment() }
        guard let w = writer, let inp = input else { return }

        if firstPTS == nil {
            firstPTS = sb.presentationTimeStamp
            let started = w.startWriting()
            w.startSession(atSourceTime: firstPTS!)
        }

        if inp.isReadyForMoreMediaData, w.status == .writing {
            if inp.append(sb) { 
                frames += 1
            } else { 
                finishSegment() 
            }
        }
    }

    // MARK: error & sleep / wake ----------------------------------------
    func stream(_ s: SCStream, didStopWithError err: Error) {
        let scErr = err as NSError
        dbg("stream stopped – domain: \(scErr.domain), code: \(scErr.code), description: \(err.localizedDescription)")
        
        // Log userInfo for debugging
        let userInfo = scErr.userInfo
        if !userInfo.isEmpty {
            dbg("Error userInfo: \(userInfo)")
        }
        
        stop()
        
        // Check if this was a user-initiated stop
        if isUserInitiatedStop(err) {
            dbg("User stopped recording through system UI - updating app state")
            Task { @MainActor in
                AppState.shared.isRecording = false
            }
        } else if shouldRetry(err) {
            dbg("Retryable error - will restart if recording flag is set")
            Task { @MainActor in
                if AppState.shared.isRecording { start() }
            }
        } else {
            // Unknown or non-retryable error - update app state to stop
            dbg("Non-retryable error - stopping recording")
            Task { @MainActor in
                AppState.shared.isRecording = false
            }
        }
    }

    private func registerForSleepAndLock() {
        let nc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // -------- system will sleep ----------
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("willSleep – pausing")

            Task { @MainActor in
                self.resumeAfterPause = AppState.shared.isRecording
            }
            self.stop()
        }

        // -------- system did wake ------------
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("didWake – checking flag")

            guard self.resumeAfterPause else { return }
            self.resumeAfterPause = false      // consume the token

            // give ScreenCaptureKit a moment to re-enumerate displays
            self.q.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.start()
            }
        }

        // -------- screen locked ------------
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                        object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("screen locked – pausing")

            Task { @MainActor in
                self.resumeAfterPause = AppState.shared.isRecording
            }
            self.stop()
        }

        // -------- screen unlocked ----------
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                        object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("screen unlocked – checking flag")

            guard self.resumeAfterPause else { return }
            self.resumeAfterPause = false

            self.q.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.start()
            }
        }

        // -------- screensaver started ------
        dnc.addObserver(forName: .init("com.apple.screensaver.didstart"),
                        object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("screensaver started – pausing")

            Task { @MainActor in
                self.resumeAfterPause = AppState.shared.isRecording
            }
            self.stop()
        }

        // -------- screensaver stopped ------
        dnc.addObserver(forName: .init("com.apple.screensaver.didstop"),
                        object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("screensaver stopped – checking flag")

            guard self.resumeAfterPause else { return }
            self.resumeAfterPause = false

            self.q.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.start()
            }
        }
    }

    // MARK: helpers ------------------------------------------------------
    private enum RecorderError: Error { case badInput, noDisplay }

    /// Accept only fully-assembled frames (complete & not dropped).
    private func isComplete(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo : Any]],
              let raw = arr.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    
    private func overlayClock(on pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])  // Lock for read/write access
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)

        guard let ctx = CGContext(data: base,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }

        // ---- draw black box ----
        let padding: CGFloat = 12
        let fontSize: CGFloat = 36

        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        let text = fmt.string(from: Date())

        let attrs: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Menlo" as CFString, fontSize, nil),
            .foregroundColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1) // red
        ]
        let line   = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                                                                         attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        let boxW = bounds.width  + padding * 2
        let boxH = bounds.height + padding * 2
        let originX = CGFloat(w) - boxW
        let originY = CGFloat(h) - boxH

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))           // black
        ctx.fill(CGRect(x: originX, y: originY,
                        width: boxW,  height: boxH))

        ctx.textPosition = CGPoint(x: originX + padding,
                                   y: originY + padding - bounds.minY)
        CTLineDraw(line, ctx)
    }
}
