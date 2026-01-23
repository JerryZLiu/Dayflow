//
//  VideoPlayerModal.swift
//  Dayflow
//
//  Custom video timeline player with activity segments
//

import SwiftUI
import AVKit
import AppKit

private let videoPlayerTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
}()

// MARK: - Hero Animation State (Emil Kowalski: shared element transitions)

/// Manages the hero animation state for video thumbnail-to-modal expansion
final class VideoExpansionState: ObservableObject {
    @Published var isExpanded: Bool = false
    @Published var videoURL: String = ""
    @Published var title: String? = nil
    @Published var startTime: Date? = nil
    @Published var endTime: Date? = nil
    @Published var thumbnailFrame: CGRect = .zero
    @Published var containerSize: CGSize = .zero
    @Published var isHoveringVideo: Bool = false
    @Published var usesScreenshots: Bool = false
    @Published var heroId: String = ""

    // Animation phase tracking for choreographed entrance
    @Published var animationPhase: AnimationPhase = .collapsed

    enum AnimationPhase {
        case collapsed      // Thumbnail at rest
        case lifting        // Thumbnail lifts (scale up, shadow)
        case flying         // Moving to center, expanding
        case expanded       // Fully open
        case collapsing     // Reverse animation
    }

    func expand(
        videoURL: String,
        title: String?,
        startTime: Date?,
        endTime: Date?,
        thumbnailFrame: CGRect,
        containerSize: CGSize
    ) {
        self.videoURL = videoURL
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.thumbnailFrame = thumbnailFrame
        self.containerSize = containerSize
        self.usesScreenshots = false
        self.heroId = "heroVideo_\(videoURL)"

        // Immediate expansion with spring animation - no delays
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            self.isExpanded = true
            self.animationPhase = .expanded
        }
    }

    func collapse() {
        // Instant close - no animation per user preference
        self.animationPhase = .collapsed
        self.isExpanded = false
        self.videoURL = ""
        self.title = nil
        self.startTime = nil
        self.endTime = nil
        self.usesScreenshots = false
        self.heroId = ""
    }

    func expandScreenshots(
        sourceId: String,
        title: String?,
        startTime: Date?,
        endTime: Date?,
        thumbnailFrame: CGRect,
        containerSize: CGSize
    ) {
        self.videoURL = ""
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.thumbnailFrame = thumbnailFrame
        self.containerSize = containerSize
        self.usesScreenshots = true
        self.heroId = "heroScreenshot_\(sourceId)"

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            self.isExpanded = true
            self.animationPhase = .expanded
        }
    }
}

// MARK: - Video Expansion Overlay (Hero Animation Modal)

struct VideoExpansionOverlay: View {
    @ObservedObject var expansionState: VideoExpansionState
    let namespace: Namespace.ID
    @StateObject private var viewModel = VideoPlayerViewModel()
    @StateObject private var screenshotModel = ScreenshotSequencePlayerModel()
    @State private var keyMonitor: Any?
    @State private var didStartPlay = false

    private var isVisible: Bool {
        expansionState.isExpanded || expansionState.animationPhase == .collapsing
    }

    var body: some View {
        if isVisible {
            ZStack {
                // Scrim/backdrop
                Color.black
                    .opacity(scrimOpacity)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeModal()
                    }

                // Modal content
                modalContent
            }
            .onAppear {
                setupPlayback()
                setupKeyMonitor()
                AnalyticsService.shared.capture("video_modal_opened", [
                    "source": expansionState.title != nil ? "hero_animation" : "unknown",
                    "animation_type": "hero"
                ])
            }
            .onDisappear {
                cleanupPlayback()
                removeKeyMonitor()
            }
        }
    }

    private var scrimOpacity: Double {
        switch expansionState.animationPhase {
        case .collapsed: return 0
        case .lifting: return 0.1
        case .flying: return 0.5
        case .expanded: return 0.7
        case .collapsing: return 0
        }
    }

    @ViewBuilder
    private var modalContent: some View {
        let targetWidth = (expansionState.containerSize.width) * 0.9
        let targetHeight = (expansionState.containerSize.height) * 0.9
        let matchedId = expansionState.heroId.isEmpty ? "heroVideo_\(expansionState.videoURL)" : expansionState.heroId

        VStack(spacing: 0) {
            // Header (fades in during expansion)
            if expansionState.title != nil || (expansionState.startTime != nil && expansionState.endTime != nil) {
                headerView
                    .opacity(headerOpacity)
                    .offset(y: headerOffset)
            }

            // Video area with matched geometry
            GeometryReader { geo in
                let a = max(0.1, activeAspectRatio)
                let h = geo.size.height
                let wFitHeight = h * a
                let fitsWidth = wFitHeight <= geo.size.width
                let vw = fitsWidth ? wFitHeight : geo.size.width
                let vh = fitsWidth ? h : (geo.size.width / a)

                ZStack {
                    Color.white
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if expansionState.usesScreenshots {
                            screenshotPlayerView(width: vw, height: vh)
                        } else {
                            videoPlayerView(width: vw, height: vh)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlayback() }
                }
            }
            .matchedGeometryEffect(id: matchedId, in: namespace)

            // Scrubber (slides up during expansion)
            scrubberView
                .opacity(scrubberOpacity)
                .offset(y: scrubberOffset)
        }
        .frame(width: targetWidth, height: targetHeight)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 10)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                if let title = expansionState.title {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                if let startTime = expansionState.startTime, let endTime = expansionState.endTime {
                    Text("\(videoPlayerTimeFormatter.string(from: startTime)) to \(videoPlayerTimeFormatter.string(from: endTime))")
                        .font(.caption)
                        .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                }
            }
            Spacer()
            Button(action: { closeModal() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color.black.opacity(0.5))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white)
        .overlay(
            Rectangle().stroke(Color.gray.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func videoPlayerView(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if viewModel.player != nil {
                WhiteBGVideoPlayer(player: viewModel.player)
                    .disabled(true)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .gray))
            }

            // Play button overlay
            if !viewModel.isPlaying {
                Button(action: { viewModel.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                        Image(systemName: "play.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 24, weight: .bold))
                    }
                }
                .buttonStyle(ScaleButtonStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) {
            // Playback speed chip (20x, 40x, 60x)
            if expansionState.isHoveringVideo {
                Button(action: { viewModel.cycleSpeed() }) {
                    Text("\(Int(viewModel.playbackSpeed * 20))x")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(4)
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(12)
                .accessibilityLabel("Playback speed")
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: expansionState.isHoveringVideo)
        .onHover { hovering in expansionState.isHoveringVideo = hovering }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isPlaying)
    }

    private func screenshotPlayerView(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let frame = screenshotModel.currentFrame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .background(Color.white)
            } else if screenshotModel.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.gray.opacity(0.6))
                    Text("No screenshots")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .frame(width: width, height: height)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                    .frame(width: width, height: height)
            }

            if !screenshotModel.isPlaying {
                Button(action: { screenshotModel.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                        Image(systemName: "play.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 24, weight: .bold))
                    }
                }
                .buttonStyle(ScaleButtonStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) {
            if expansionState.isHoveringVideo {
                Button(action: { screenshotModel.cycleSpeed() }) {
                    Text("\(Int(screenshotModel.playbackSpeed * 20))x")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(4)
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(12)
                .accessibilityLabel("Playback speed")
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: expansionState.isHoveringVideo)
        .onHover { hovering in expansionState.isHoveringVideo = hovering }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: screenshotModel.isPlaying)
        .onAppear {
            screenshotModel.setTargetSize(CGSize(width: width, height: height))
        }
        .onChange(of: width) { _, _ in
            screenshotModel.setTargetSize(CGSize(width: width, height: height))
        }
        .onChange(of: height) { _, _ in
            screenshotModel.setTargetSize(CGSize(width: width, height: height))
        }
    }

    @ViewBuilder
    private var scrubberView: some View {
        VStack(spacing: 12) {
            if expansionState.usesScreenshots {
                ScreenshotScrubberView(
                    screenshots: screenshotModel.screenshots,
                    duration: max(0.001, screenshotModel.duration),
                    currentTime: screenshotModel.currentTime,
                    onSeek: { t in screenshotModel.seek(to: t) },
                    onScrubStateChange: { dragging in screenshotModel.isDragging = dragging },
                    absoluteStart: expansionState.startTime,
                    absoluteEnd: expansionState.endTime
                )
                .padding(.horizontal)
                .padding(.bottom, 12)
            } else if let url = scrubberURL {
                ScrubberView(
                    url: url,
                    duration: max(0.001, viewModel.duration),
                    currentTime: viewModel.currentTime,
                    onSeek: { t in viewModel.seek(to: t) },
                    onScrubStateChange: { dragging in viewModel.isDragging = dragging },
                    absoluteStart: expansionState.startTime,
                    absoluteEnd: expansionState.endTime
                )
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
        .background(Color.white)
    }

    // Animation helpers
    private var headerOpacity: Double {
        switch expansionState.animationPhase {
        case .collapsed, .lifting, .collapsing: return 0
        case .flying: return 0.5
        case .expanded: return 1
        }
    }

    private var headerOffset: CGFloat {
        switch expansionState.animationPhase {
        case .collapsed, .lifting, .collapsing: return -10
        case .flying: return -5
        case .expanded: return 0
        }
    }

    private var scrubberOpacity: Double {
        switch expansionState.animationPhase {
        case .collapsed, .lifting, .collapsing: return 0
        case .flying: return 0.3
        case .expanded: return 1
        }
    }

    private var scrubberOffset: CGFloat {
        switch expansionState.animationPhase {
        case .collapsed, .lifting, .collapsing: return 20
        case .flying: return 10
        case .expanded: return 0
        }
    }

    // Player setup
    private var activeAspectRatio: CGFloat {
        expansionState.usesScreenshots ? screenshotModel.aspectRatio : viewModel.videoAspect
    }

    private var scrubberURL: URL? {
        let processedURL = expansionState.videoURL.hasPrefix("file://") ? expansionState.videoURL : "file://" + expansionState.videoURL
        return URL(string: processedURL)
    }

    private func setupPlayback() {
        if expansionState.usesScreenshots {
            screenshotModel.loadScreenshots(startTime: expansionState.startTime, endTime: expansionState.endTime)
        } else {
            let processedURL = expansionState.videoURL.hasPrefix("file://") ? expansionState.videoURL : "file://" + expansionState.videoURL
            guard let url = URL(string: processedURL) else { return }
            if url.isFileURL {
                let path = url.path
                guard FileManager.default.fileExists(atPath: path) else { return }
            }
            viewModel.setupPlayer(url: url)
        }
    }

    private func cleanupPlayback() {
        viewModel.cleanup()
        screenshotModel.cleanup()
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = NSApp.keyWindow?.firstResponder {
                if responder is NSTextField || responder is NSTextView || responder is NSText {
                    return event
                }
            }

            // Space to toggle play/pause
            if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                togglePlayback()
                return nil
            }

            // Escape to close
            if event.keyCode == 53 {
                closeModal()
                return nil
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func closeModal() {
        expansionState.collapse()
    }

    private func togglePlayback() {
        if expansionState.usesScreenshots {
            screenshotModel.togglePlayPause()
        } else {
            viewModel.togglePlayPause()
        }
    }

}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            // Spring animation for more natural button feel (Emil Kowalski principle)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct VideoSegment: Identifiable {
    let id = UUID()
    let title: String
    let startTime: Double // in seconds
    let endTime: Double
    let color: Color
    let activityType: ActivityType
    
    var duration: Double {
        endTime - startTime
    }
    
    var durationString: String {
        let minutes = Int(duration / 60)
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes) min" : "\(seconds) sec"
    }
}

enum ActivityType {
    case brainstorming
    case browsing
    case coding
    case email
    case meeting
    case breaks
    case other(String)
    
    var color: Color {
        switch self {
        case .brainstorming, .coding:
            return Color.orange
        case .browsing:
            return Color.red
        case .email, .meeting:
            return Color.blue
        case .breaks:
            return Color.yellow
        case .other:
            return Color.gray
        }
    }
}

class VideoPlayerViewModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var isPlaying: Bool = false
    @Published var playbackSpeed: Float = 1.0
    @Published var currentSegment: VideoSegment?
    @Published var segments: [VideoSegment] = []
    @Published var isDragging: Bool = false
    @Published var hoverTime: Double? = nil
    @Published var timelineOffset: CGFloat = 0
    @Published var videoAspect: CGFloat = 16.0/9.0

    // Playback speed options shown in the chip (mapped to 20x, 40x, 60x labels)
    let speedOptions: [Float] = [1.0, 2.0, 3.0]
    
    var player: AVPlayer?
    private var timeObserver: Any?
    
    func setupPlayer(url: URL) {
        player = AVPlayer(url: url)

        // Get video duration and aspect
        guard let asset = player?.currentItem?.asset else { return }
        Task {
            do {
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)

                var aspect: CGFloat = 16.0 / 9.0  // Default aspect ratio
                if let track = tracks.first {
                    let natural = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let transformed = natural.applying(transform)
                    let w = abs(transformed.width) > 0 ? abs(transformed.width) : max(1, natural.width)
                    let h = abs(transformed.height) > 0 ? abs(transformed.height) : max(1, natural.height)
                    aspect = max(0.1, CGFloat(w / h))
                }

                // Shadow mutable var with let before crossing async boundary
                let finalAspect = aspect

                await MainActor.run {
                    self.duration = CMTimeGetSeconds(duration)
                    self.videoAspect = finalAspect
                    self.loadSegments()
                }
            } catch {
                await MainActor.run {
                    self.loadSegments()
                }
            }
        }

        // Observe playback time
        let interval = CMTime(seconds: 1.0/60.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isDragging else { return }
            self.currentTime = CMTimeGetSeconds(time)
            self.updateCurrentSegment()
        }
    }
    
    func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player?.pause()
        player = nil
    }
    
    func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
            player?.rate = playbackSpeed
        }
        isPlaying.toggle()
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateCurrentSegment()
    }
    
    func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying {
            player?.rate = speed
        }
    }

    func cycleSpeed() {
        guard let idx = speedOptions.firstIndex(of: playbackSpeed) else {
            setPlaybackSpeed(speedOptions.first ?? 1.0)
            return
        }
        let next = speedOptions[(idx + 1) % speedOptions.count]
        setPlaybackSpeed(next)
    }
    
    private func updateCurrentSegment() {
        currentSegment = segments.first { segment in
            currentTime >= segment.startTime && currentTime < segment.endTime
        }
    }
    
    private func loadSegments() {
        // Dummy data for now
        segments = [
            VideoSegment(title: "Brainstorming with Chat GPT", startTime: 0, endTime: 420, color: .orange, activityType: .brainstorming),
            VideoSegment(title: "Browsing TripAdvisor", startTime: 420, endTime: 660, color: .red, activityType: .browsing),
            VideoSegment(title: "Comparing flights", startTime: 660, endTime: 780, color: .blue, activityType: .other("travel")),
            VideoSegment(title: "Break", startTime: 780, endTime: 840, color: .yellow, activityType: .breaks),
            VideoSegment(title: "Email responses", startTime: 840, endTime: 1020, color: .blue, activityType: .email),
            VideoSegment(title: "Coding session", startTime: 1020, endTime: 1680, color: .orange, activityType: .coding),
            VideoSegment(title: "Research", startTime: 1680, endTime: 1980, color: .orange, activityType: .brainstorming),
            VideoSegment(title: "Planning", startTime: 1980, endTime: duration, color: .blue, activityType: .other("planning"))
        ]
    }
}

struct VideoPlayerModal: View {
    let videoURL: String
    var title: String? = nil
    var startTime: Date? = nil
    var endTime: Date? = nil
    var containerSize: CGSize? = nil
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var keyMonitor: Any?
    @State private var isHoveringVideo = false
    @State private var didStartPlay = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            if title != nil || (startTime != nil && endTime != nil) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title = title {
                            Text(title)
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        if let startTime = startTime, let endTime = endTime {
                            Text("\(videoPlayerTimeFormatter.string(from: startTime)) to \(videoPlayerTimeFormatter.string(from: endTime))")
                                .font(.caption)
                                .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                        }
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Color.black.opacity(0.5))
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white)
                .overlay(
                    Rectangle().stroke(Color.gray.opacity(0.25), lineWidth: 1)
                )
            }

            // Video area + overlays sized by aspect (fill available height)
            GeometryReader { geo in
                let a = max(0.1, viewModel.videoAspect)
                let h = geo.size.height
                let wFitHeight = h * a
                let fitsWidth = wFitHeight <= geo.size.width
                let vw = fitsWidth ? wFitHeight : geo.size.width
                let vh = fitsWidth ? h : (geo.size.width / a)

                ZStack {
                    Color.white
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ZStack {
                            if let _ = viewModel.player {
                                WhiteBGVideoPlayer(player: viewModel.player)
                                    .disabled(true)
                            } else {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                            }

                            // Center play/pause overlay with animated entrance (Emil Kowalski: purposeful transitions)
                            if !viewModel.isPlaying {
                                Button(action: { viewModel.togglePlayPause() }) {
                                    ZStack {
                                        Circle()
                                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                                            .frame(width: 64, height: 64)
                                            .background(Circle().fill(Color.black.opacity(0.35)))
                                        Image(systemName: "play.fill")
                                            .foregroundColor(.white)
                                            .font(.system(size: 24, weight: .bold))
                                    }
                                }
                                .buttonStyle(ScaleButtonStyle())
                                .transition(
                                    .asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                                        removal: .opacity.combined(with: .scale(scale: 1.1))
                                    )
                                )
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isPlaying)
                        .frame(width: vw, height: vh)
                        .overlay(alignment: .bottomTrailing) {
                            // Playback speed chip with animated appearance (Emil Kowalski: purposeful reveal)
                            if isHoveringVideo {
                                Button(action: { viewModel.cycleSpeed() }) {
                                    Text("\(Int(viewModel.playbackSpeed * 20))x")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.85))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(ScaleButtonStyle())
                                .padding(12)
                                .accessibilityLabel("Playback speed")
                                .transition(
                                    .asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)),
                                        removal: .opacity
                                    )
                                )
                            }
                        }
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHoveringVideo)
                        .onHover { hovering in isHoveringVideo = hovering }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.togglePlayPause() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Scrubber
            VStack(spacing: 12) {
                if let url = scrubberURL {
                    ScrubberView(
                        url: url,
                        duration: max(0.001, viewModel.duration),
                        currentTime: viewModel.currentTime,
                        onSeek: { t in
                            let from = viewModel.currentTime
                            AnalyticsService.shared.throttled("seek_event", minInterval: 0.5) {
                                AnalyticsService.shared.capture("seek_performed", [
                                    "from_s_bucket": AnalyticsService.shared.secondsBucket(from),
                                    "to_s_bucket": AnalyticsService.shared.secondsBucket(t)
                                ])
                            }
                            viewModel.seek(to: t)
                        },
                        onScrubStateChange: { dragging in viewModel.isDragging = dragging },
                        absoluteStart: startTime,
                        absoluteEnd: endTime
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
            .background(Color.white) // underneath video area edge
        }
        // Size modal to 90% of the presenting window if available
        .frame(
            width: (containerSize?.width ?? 800) * 0.9,
            height: (containerSize?.height ?? 600) * 0.9
        )
        .onAppear {
            // Modal opened
            AnalyticsService.shared.capture("video_modal_opened", [
                "source": title != nil ? "activity_card" : "unknown",
                "duration_bucket": AnalyticsService.shared.secondsBucket(max(0.0, viewModel.duration))
            ])
            setupPlayer()
            startControlsTimer()
            // Capture spacebar to toggle play/pause while the modal is active
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Check if any text input field is focused (AppKit or SwiftUI)
                if let responder = NSApp.keyWindow?.firstResponder {
                    // Check for AppKit text fields
                    if responder is NSTextField || responder is NSTextView || responder is NSText {
                        return event
                    }
                    // Check for SwiftUI text fields (use class name string matching)
                    let className = NSStringFromClass(type(of: responder))
                    if className.contains("TextField") || className.contains("TextEditor") || className.contains("TextInput") {
                        return event
                    }
                }

                // 49 is the keyCode for Space on macOS
                if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    viewModel.togglePlayPause()
                    return nil // swallow the event when not editing text
                }
                return event
            }
        }
        .onDisappear {
            viewModel.cleanup()
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
            // Completion (approximate)
            let pct = viewModel.duration > 0 ? (viewModel.currentTime / viewModel.duration) : 0
            AnalyticsService.shared.capture("video_completed", [
                "watch_time_bucket": AnalyticsService.shared.secondsBucket(viewModel.currentTime),
                "completion_pct_bucket": AnalyticsService.shared.pctBucket(pct)
            ])
        }
        .onChange(of: viewModel.isPlaying) { _, playing in
            if playing {
                if didStartPlay {
                    AnalyticsService.shared.capture("video_resumed")
                } else {
                    AnalyticsService.shared.capture("video_play_started", [
                        "speed": String(format: "%.1fx", viewModel.playbackSpeed)
                    ])
                    didStartPlay = true
                }
            } else {
                if didStartPlay {
                    AnalyticsService.shared.capture("video_paused")
                }
            }
        }
        .onChange(of: viewModel.playbackSpeed) {
            if didStartPlay {
                AnalyticsService.shared.capture("video_playback_speed_changed", ["speed": String(format: "%.1fx", viewModel.playbackSpeed)])
            }
        }
    }
    
    private func setupPlayer() {
        let processedURL = videoURL.hasPrefix("file://") ? videoURL : "file://" + videoURL
        guard let url = URL(string: processedURL) else { return }
        if url.isFileURL {
            let path = url.path
            guard FileManager.default.fileExists(atPath: path) else { return }
        }
        viewModel.setupPlayer(url: url)
    }

    private var scrubberURL: URL? {
        let processedURL = videoURL.hasPrefix("file://") ? videoURL : "file://" + videoURL
        guard let url = URL(string: processedURL) else { return nil }
        return url
    }
    
    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            if viewModel.isPlaying && !viewModel.isDragging {
                showControls = false
            }
        }
    }
    
    private func showControlsTemporarily() {
        showControls = true
        startControlsTimer()
    }
}

extension VideoPlayerModal {
}
