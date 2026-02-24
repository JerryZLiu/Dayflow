//
//  VideoLaunchView.swift
//  Dayflow
//
//  Video launch screen that plays before onboarding or main app
//

import AVFoundation
import AVKit
import SwiftUI

struct VideoLaunchView: View {
  @State private var player: AVPlayer?
  @State private var hasCompleted = false
  @State private var playbackTimer: Timer?
  @State private var timeObserverToken: Any?
  @State private var endObserverToken: NSObjectProtocol?
  @State private var rateObserverToken: NSObjectProtocol?
  @State private var statusObservation: NSKeyValueObservation?
  private var onComplete: (() -> Void)?

  func onVideoComplete(_ completion: @escaping () -> Void) -> VideoLaunchView {
    var view = self
    view.onComplete = completion
    return view
  }

  var body: some View {
    ZStack {
      if let player = player {
        // Custom AVPlayer view without controls
        AVPlayerControllerRepresented(player: player)
          .ignoresSafeArea()
      }
    }
    .onAppear {
      setupVideo()
      // Focus the window
      NSApp.activate(ignoringOtherApps: true)
    }
    .onDisappear {
      cleanup()
    }
  }

  private func setupVideo() {
    // Play directly from bundle - no need to write to temp file
    guard let videoURL = Bundle.main.url(forResource: "DayflowAnimation", withExtension: "mp4")
    else {
      print("Failed to find video in bundle")
      completeVideo()
      return
    }

    let playerItem = AVPlayerItem(url: videoURL)
    player = AVPlayer(playerItem: playerItem)

    // Silence audio to prevent interrupting user's music
    player?.isMuted = true
    player?.volume = 0

    // Prevent system-level pause/interruptions
    player?.automaticallyWaitsToMinimizeStalling = false
    player?.actionAtItemEnd = .none

    // Monitor when we're near the end to start fade early
    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      time in
      guard let duration = self.player?.currentItem?.duration,
        duration.isValid && duration.isNumeric
      else { return }

      let currentSeconds = time.seconds
      let totalSeconds = duration.seconds

      // Start transition 0.3 seconds before the end for smoother handoff
      if currentSeconds >= totalSeconds - 0.3 && currentSeconds < totalSeconds {
        self.completeVideo()
      }
    }

    // Also monitor actual completion as fallback
    endObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { _ in
      completeVideo()
    }

    // Monitor for any pause events and force resume
    rateObserverToken = NotificationCenter.default.addObserver(
      forName: Notification.Name("AVPlayerRateDidChangeNotification"),
      object: player,
      queue: .main
    ) { _ in
      if self.player?.rate == 0 && !self.hasCompleted {
        // Force resume if paused
        self.player?.play()
      }
    }

    // Start playing
    player?.play()

    // Start a timer to continuously check and force playback
    playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      if self.player?.rate == 0 && !self.hasCompleted {
        self.player?.play()
      }
    }

    // Add observer for errors
    statusObservation = playerItem.observe(\.status) { item, _ in
      if item.status == .failed {
        print("Video failed to load: \(item.error?.localizedDescription ?? "Unknown error")")
        DispatchQueue.main.async {
          self.completeVideo()
        }
      }
    }
  }

  private func completeVideo() {
    guard !hasCompleted else { return }
    hasCompleted = true

    // Clean up timer
    playbackTimer?.invalidate()
    playbackTimer = nil

    // Pause but KEEP the last frame visible while the parent fades us out.
    // Actual teardown happens onDisappear to avoid a jarring cut.
    player?.pause()
    onComplete?()
  }

  private func cleanup() {
    // Remove periodic time observer if present
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
      timeObserverToken = nil
    }
    // Remove NotificationCenter observers if present
    if let token = endObserverToken {
      NotificationCenter.default.removeObserver(token)
      endObserverToken = nil
    }
    if let token = rateObserverToken {
      NotificationCenter.default.removeObserver(token)
      rateObserverToken = nil
    }
    // Release KVO observation
    statusObservation = nil

    // Stop playback and release player
    player?.pause()
    player = nil
  }
}

// Custom AVPlayer view without controls
struct AVPlayerControllerRepresented: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> NonInteractiveAVPlayerView {
    let view = NonInteractiveAVPlayerView()
    view.player = player
    view.controlsStyle = .none
    view.videoGravity = .resizeAspectFill  // Fill the screen
    view.showsFullScreenToggleButton = false
    view.allowsPictureInPicturePlayback = false

    // Disable all user interactions
    view.isHidden = false
    view.wantsLayer = true

    return view
  }

  func updateNSView(_ nsView: NonInteractiveAVPlayerView, context: Context) {}
}

// Custom AVPlayerView that prevents all user interactions
class NonInteractiveAVPlayerView: AVPlayerView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    // Prevent all mouse interactions
    return nil
  }

  override func keyDown(with event: NSEvent) {
    // Ignore all keyboard events (including spacebar)
    // Don't call super to prevent default behavior
  }

  override func mouseDown(with event: NSEvent) {
    // Ignore mouse clicks
    // Don't call super to prevent default behavior
  }

  override func rightMouseDown(with event: NSEvent) {
    // Ignore right clicks
    // Don't call super to prevent default behavior
  }

  override var acceptsFirstResponder: Bool {
    // Don't accept keyboard focus
    return false
  }
}

// Preview for development
struct VideoLaunchView_Previews: PreviewProvider {
  static var previews: some View {
    VideoLaunchView()
      .onVideoComplete {
        print("Video completed")
      }
  }
}
