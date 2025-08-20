//
//  VideoPlayerModal.swift
//  Dayflow
//
//  Custom video timeline player with activity segments
//

import SwiftUI
import AVKit

// MARK: - Custom Button Style
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Data Models
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

// MARK: - View Model
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
    
    var player: AVPlayer?
    private var timeObserver: Any?
    
    func setupPlayer(url: URL) {
        player = AVPlayer(url: url)
        
        // Get video duration
        player?.currentItem?.asset.loadValuesAsynchronously(forKeys: ["duration"]) { [weak self] in
            guard let duration = self?.player?.currentItem?.asset.duration else { return }
            DispatchQueue.main.async {
                self?.duration = CMTimeGetSeconds(duration)
                self?.loadSegments()
            }
        }
        
        // Observe playback time
        let interval = CMTime(seconds: 0.03, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
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

// MARK: - Main Player View
struct VideoPlayerModal: View {
    let videoURL: String
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    
    var body: some View {
        ZStack {
            Color.black
            
            VStack(spacing: 0) {
                // Video player area
                ZStack {
                    if let player = viewModel.player {
                        VideoPlayer(player: player)
                            .disabled(true) // Disable default controls
                            .onTapGesture {
                                viewModel.togglePlayPause()
                            }
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    
                    // Close button overlay
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: { dismiss() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white.opacity(0.8))
                                    .background(Circle().fill(Color.black.opacity(0.3)))
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding()
                        }
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Timeline and controls at bottom
                VStack(spacing: 0) {
                    VideoTimelineView(viewModel: viewModel)
                        .frame(height: 80)
                        .background(Color.black.opacity(0.95))
                    
                    PlayerControlsView(viewModel: viewModel)
                        .padding()
                        .background(Color.black)
                }
                .opacity(showControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showControls)
            }
        }
        .frame(width: 800, height: 600)
        .onAppear {
            setupPlayer()
            startControlsTimer()
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .onHover { isHovering in
            if isHovering {
                showControlsTemporarily()
            }
        }
    }
    
    private func setupPlayer() {
        let processedURL = videoURL.hasPrefix("file://") ? videoURL : "file://" + videoURL
        guard let url = URL(string: processedURL) else { return }
        viewModel.setupPlayer(url: url)
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

// MARK: - Timeline View
struct VideoTimelineView: View {
    @ObservedObject var viewModel: VideoPlayerViewModel
    @State private var isDraggingTimeline = false
    
    private let segmentHeight: CGFloat = 45
    private let timeRulerHeight: CGFloat = 20
    
    var body: some View {
        VStack(spacing: 0) {
            // Time ruler
            GeometryReader { geometry in
                TimeRulerView(duration: viewModel.duration, width: geometry.size.width)
            }
            .frame(height: timeRulerHeight)
            
            // Timeline with segments
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    // Dark background track
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                        .frame(height: segmentHeight)
                    
                    // Segments laid out horizontally
                    HStack(spacing: 0) {
                        ForEach(viewModel.segments) { segment in
                            SegmentView(
                                segment: segment,
                                totalDuration: viewModel.duration,
                                totalWidth: geometry.size.width,
                                isActive: viewModel.currentSegment?.id == segment.id,
                                onTap: {
                                    viewModel.seek(to: segment.startTime)
                                }
                            )
                        }
                    }
                    .frame(height: segmentHeight)
                    
                    // Playhead
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: segmentHeight + 10)
                        .offset(x: playheadOffset(in: geometry.size.width) - 1, y: -5)
                        .allowsHitTesting(false)
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            viewModel.isDragging = true
                            let percentage = value.location.x / geometry.size.width
                            let time = max(0, min(viewModel.duration, percentage * viewModel.duration))
                            viewModel.seek(to: time)
                        }
                        .onEnded { _ in
                            viewModel.isDragging = false
                        }
                )
            }
            .frame(height: segmentHeight)
        }
    }
    
    private func playheadOffset(in width: CGFloat) -> CGFloat {
        guard viewModel.duration > 0 else { return 0 }
        return (viewModel.currentTime / viewModel.duration) * width
    }
}

// MARK: - Segment View
struct SegmentView: View {
    let segment: VideoSegment
    let totalDuration: Double
    let totalWidth: CGFloat
    let isActive: Bool
    let onTap: () -> Void
    
    @State private var isPressed = false
    
    private var segmentWidth: CGFloat {
        guard totalDuration > 0 else { return 0 }
        return (segment.duration / totalDuration) * totalWidth
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(segment.color.opacity(isActive ? 1.0 : 0.85))
                .frame(width: segmentWidth, height: 45)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Text(segment.durationString)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: segmentWidth, height: 45)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isPressed)
        .onTapGesture {
            onTap()
        }
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .infinity,
            pressing: { pressing in
                isPressed = pressing
            },
            perform: {}
        )
    }
}


// MARK: - Time Ruler View
struct TimeRulerView: View {
    let duration: Double
    let width: CGFloat
    
    private var timeMarkers: [Double] {
        guard duration > 0 else { return [] }
        
        let interval: Double
        if duration < 300 { // < 5 minutes
            interval = 30 // 30 second intervals
        } else if duration < 1800 { // < 30 minutes
            interval = 60 // 1 minute intervals
        } else {
            interval = 300 // 5 minute intervals
        }
        
        var markers: [Double] = []
        var time: Double = 0
        while time <= duration {
            markers.append(time)
            time += interval
        }
        return markers
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(timeMarkers, id: \.self) { time in
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 1, height: 8)
                        
                        Text(formatTime(time))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .offset(x: (time / duration) * geometry.size.width - 15)
                }
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Player Controls View
struct PlayerControlsView: View {
    @ObservedObject var viewModel: VideoPlayerViewModel
    
    var body: some View {
        HStack(spacing: 20) {
            // Play/Pause
            Button(action: { viewModel.togglePlayPause() }) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
            }
            .buttonStyle(ScaleButtonStyle())
            
            // Time display
            Text("\(formatTime(viewModel.currentTime)) / \(formatTime(viewModel.duration))")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white)
            
            Spacer()
            
            // Current segment
            if let segment = viewModel.currentSegment {
                HStack(spacing: 8) {
                    Circle()
                        .fill(segment.color)
                        .frame(width: 8, height: 8)
                    Text(segment.title)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            
            Spacer()
            
            // Speed control
            Menu {
                Button("0.5x") { viewModel.setPlaybackSpeed(0.5) }
                Button("0.75x") { viewModel.setPlaybackSpeed(0.75) }
                Button("1x") { viewModel.setPlaybackSpeed(1.0) }
                Button("1.5x") { viewModel.setPlaybackSpeed(1.5) }
                Button("2x") { viewModel.setPlaybackSpeed(2.0) }
            } label: {
                Text("\(String(format: "%.1fx", viewModel.playbackSpeed))")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(6)
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}