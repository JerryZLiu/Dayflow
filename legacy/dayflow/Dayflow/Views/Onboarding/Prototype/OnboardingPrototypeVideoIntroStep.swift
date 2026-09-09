//
//  OnboardingPrototypeVideoIntroStep.swift
//  Dayflow
//

import AVFoundation
import SwiftUI

struct OnboardingPrototypeVideoIntroStep: View {
  let videoName: String
  let onPlaybackStarted: () -> Void
  let onPlaybackCompleted: (String) -> Void

  @State private var player: AVPlayer?
  @State private var hasStartedPlayback = false
  @State private var hasCompletedPlayback = false
  @State private var isDoubleSpeed = false
  @State private var playbackTimer: Timer?
  @State private var timeObserverToken: Any?
  @State private var endObserverToken: NSObjectProtocol?
  @State private var statusObservation: NSKeyValueObservation?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let player = player {
        AVPlayerControllerRepresented(player: player)
          .ignoresSafeArea()
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if player != nil && !hasCompletedPlayback {
        speedToggleButton
          .padding(.trailing, 24)
          .padding(.bottom, 24)
      }
    }
    .onAppear {
      setupVideo()
    }
    .onDisappear {
      cleanup()
    }
  }

  private var speedToggleButton: some View {
    Button(action: toggleSpeed) {
      Text("2x")
        .font(.custom("Figtree", size: 13))
        .fontWeight(.semibold)
        .foregroundColor(isDoubleSpeed ? Color(red: 0.25, green: 0.17, blue: 0) : .white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
          Capsule()
            .fill(isDoubleSpeed ? Color.white.opacity(0.92) : Color.black.opacity(0.35))
        )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .accessibilityLabel(isDoubleSpeed ? "Play at normal speed" : "Play at double speed")
  }

  private var currentRate: Float {
    isDoubleSpeed ? 2.0 : 1.0
  }

  private func toggleSpeed() {
    isDoubleSpeed.toggle()
    guard !hasCompletedPlayback else { return }
    player?.rate = currentRate
  }

  private func setupVideo() {
    guard let videoURL = resolveVideoURL() else {
      finishPlayback(reason: "missing_asset")
      return
    }

    let playerItem = AVPlayerItem(url: videoURL)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = true
    player?.volume = 0
    player?.automaticallyWaitsToMinimizeStalling = false
    player?.actionAtItemEnd = .none

    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      time in
      guard let duration = self.player?.currentItem?.duration,
        duration.isValid && duration.isNumeric
      else { return }

      let currentSeconds = time.seconds
      let totalSeconds = duration.seconds

      guard totalSeconds > 0 else { return }

      if currentSeconds >= totalSeconds - 0.3 && currentSeconds < totalSeconds {
        self.finishPlayback(reason: "ended")
      }
    }

    endObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { _ in
      finishPlayback(reason: "ended")
    }

    statusObservation = playerItem.observe(\.status) { item, _ in
      guard item.status == .failed else { return }
      DispatchQueue.main.async {
        finishPlayback(reason: "playback_failed")
      }
    }

    player?.play()
    markPlaybackStartedIfNeeded()

    playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      guard !self.hasCompletedPlayback else { return }
      if self.player?.rate == 0 {
        self.player?.play()
      }
    }
  }

  private func resolveVideoURL() -> URL? {
    Bundle.main.url(forResource: videoName, withExtension: "mp4")
      ?? Bundle.main.url(forResource: videoName, withExtension: "mp4", subdirectory: "Videos")
      ?? Bundle.main.url(forResource: videoName, withExtension: "mov")
      ?? Bundle.main.url(forResource: videoName, withExtension: "mov", subdirectory: "Videos")
  }

  private func markPlaybackStartedIfNeeded() {
    guard !hasStartedPlayback else { return }
    hasStartedPlayback = true
    onPlaybackStarted()
  }

  private func finishPlayback(reason: String) {
    guard !hasCompletedPlayback else { return }
    hasCompletedPlayback = true

    playbackTimer?.invalidate()
    playbackTimer = nil

    player?.pause()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      onPlaybackCompleted(reason)
    }
  }

  private func cleanup() {
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
      timeObserverToken = nil
    }
    if let token = endObserverToken {
      NotificationCenter.default.removeObserver(token)
      endObserverToken = nil
    }
    statusObservation = nil
    playbackTimer?.invalidate()
    playbackTimer = nil
    player?.pause()
    player = nil
  }
}
