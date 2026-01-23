//
//  ScreenshotPlayerModal.swift
//  Dayflow
//
//  Modal player for screenshot-based timelapses.
//

import AppKit
import SwiftUI

private let screenshotPlayerTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
}()

struct ScreenshotPlayerModal: View {
    var title: String? = nil
    var startTime: Date? = nil
    var endTime: Date? = nil
    var containerSize: CGSize? = nil

    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel = ScreenshotSequencePlayerModel()
    @State private var keyMonitor: Any?
    @State private var isHoveringVideo = false
    @State private var didStartPlay = false

    var body: some View {
        VStack(spacing: 0) {
            if title != nil || (startTime != nil && endTime != nil) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title {
                            Text(title)
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        if let startTime, let endTime {
                            Text("\(screenshotPlayerTimeFormatter.string(from: startTime)) to \(screenshotPlayerTimeFormatter.string(from: endTime))")
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

            GeometryReader { geo in
                let a = max(0.1, viewModel.aspectRatio)
                let h = geo.size.height
                let wFitHeight = h * a
                let fitsWidth = wFitHeight <= geo.size.width
                let vw = fitsWidth ? wFitHeight : geo.size.width
                let vh = fitsWidth ? h : (geo.size.width / a)

                ZStack {
                    Color.white
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        screenshotPlayerView(width: vw, height: vh)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.togglePlayPause() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                ScreenshotScrubberView(
                    screenshots: viewModel.screenshots,
                    duration: max(0.001, viewModel.duration),
                    currentTime: viewModel.currentTime,
                    onSeek: { t in viewModel.seek(to: t) },
                    onScrubStateChange: { dragging in viewModel.isDragging = dragging },
                    absoluteStart: startTime,
                    absoluteEnd: endTime
                )
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .background(Color.white)
        }
        .frame(
            width: (containerSize?.width ?? 800) * 0.9,
            height: (containerSize?.height ?? 600) * 0.9
        )
        .onAppear {
            AnalyticsService.shared.capture("video_modal_opened", [
                "source": title != nil ? "activity_card" : "unknown",
                "duration_bucket": AnalyticsService.shared.secondsBucket(max(0.0, viewModel.duration))
            ])
            viewModel.loadScreenshots(startTime: startTime, endTime: endTime)
            setupKeyMonitor()
        }
        .onDisappear {
            viewModel.cleanup()
            removeKeyMonitor()
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
            } else if didStartPlay {
                AnalyticsService.shared.capture("video_paused")
            }
        }
        .onChange(of: viewModel.playbackSpeed) { _, _ in
            if didStartPlay {
                AnalyticsService.shared.capture("video_playback_speed_changed", ["speed": String(format: "%.1fx", viewModel.playbackSpeed)])
            }
        }
    }

    @ViewBuilder
    private func screenshotPlayerView(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let frame = viewModel.currentFrame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            } else if viewModel.isEmpty {
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
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isPlaying)
        .onAppear {
            viewModel.setTargetSize(CGSize(width: width, height: height))
        }
        .onChange(of: width) { _, _ in
            viewModel.setTargetSize(CGSize(width: width, height: height))
        }
        .onChange(of: height) { _, _ in
            viewModel.setTargetSize(CGSize(width: width, height: height))
        }
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = NSApp.keyWindow?.firstResponder {
                if responder is NSTextField || responder is NSTextView || responder is NSText {
                    return event
                }
                let className = NSStringFromClass(type(of: responder))
                if className.contains("TextField") || className.contains("TextEditor") || className.contains("TextInput") {
                    return event
                }
            }

            if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                viewModel.togglePlayPause()
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

}
