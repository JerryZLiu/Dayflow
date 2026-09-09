//
//  FlowCreatureView.swift
//  Dayflow
//
//  Plays the creature's HEVC-with-alpha animation clips (Videos/Flow/*.mov)
//  in the desktop overlay. One shared player so the overlay controller can
//  finish with an exit clip before the panel fades out.
//
//  Clips are authored on a 1280×768 transparent canvas with the creature's
//  screen position baked in (peeking at the right edge, tub near the middle),
//  so the view just renders the whole canvas and the panel hugs the screen's
//  bottom-right corner.
//

import AVFoundation
import AppKit
import SwiftUI

enum FlowCreatureClip: String {
  case entrance = "flow_entrance"
  case waveLoop = "flow_wave_loop"
  case sideToFull = "flow_side_to_full"
  case exitWave1 = "flow_exit_wave1"
  case exitWave2 = "flow_exit_wave2"
  case exitMove1 = "flow_exit_move1"
  case exitMove2 = "flow_exit_move2"
  case exitPlane = "flow_exit_plane"
  case fireBegin = "flow_fire_begin"
  case fireLoop = "flow_fire_loop"
  case fireEnd = "flow_fire_end"
  case bathBegin = "flow_bath_begin"
  case bathLoop = "flow_bath_loop"
  case bathEnd = "flow_bath_end"

  var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "mov") }

  static var randomExit: FlowCreatureClip {
    [.exitWave1, .exitWave2, .exitMove1, .exitMove2].randomElement() ?? .exitWave1
  }
}

@MainActor
final class FlowCreaturePlayer {
  static let shared = FlowCreaturePlayer()

  let player = AVPlayer()

  private var currentClip: FlowCreatureClip?
  private var loopClip: FlowCreatureClip?
  private var onceCompletion: (() -> Void)?
  /// Bumped per play request so a stale timeout can't fire a completion.
  private var playGeneration = 0

  private init() {
    player.actionAtItemEnd = .none
    NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        self?.itemEnded(note)
      }
    }
  }

  /// Play `clip` once, then keep looping `loop` (pass the same clip to loop
  /// it from the start).
  func play(_ clip: FlowCreatureClip, thenLoop loop: FlowCreatureClip?) {
    playGeneration += 1
    onceCompletion = nil
    loopClip = loop
    setItem(clip)
  }

  /// If `loop` is already what's playing (or queued to loop), leave it alone;
  /// otherwise switch to it. Keeps the wave loop from restarting every time
  /// the overlay content changes.
  func ensureLoop(_ loop: FlowCreatureClip) {
    if currentClip == loop || loopClip == loop { return }
    play(loop, thenLoop: loop)
  }

  /// Play a one-shot clip (exit animations); calls `completion` when it ends,
  /// or after a safety timeout if playback stalls.
  func playOnce(_ clip: FlowCreatureClip, completion: @escaping () -> Void) {
    playGeneration += 1
    let gen = playGeneration
    loopClip = nil
    onceCompletion = completion
    setItem(clip)

    // Longest exit clip is ~7s; anything past 10s means playback stalled.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      guard gen == self.playGeneration, let pending = self.onceCompletion else { return }
      self.onceCompletion = nil
      pending()
    }
  }

  private func setItem(_ clip: FlowCreatureClip) {
    guard let url = clip.url else {
      // Missing resource: fail soft, run any pending completion.
      let pending = onceCompletion
      onceCompletion = nil
      currentClip = nil
      pending?()
      return
    }
    currentClip = clip
    player.replaceCurrentItem(with: AVPlayerItem(url: url))
    player.play()
  }

  private func itemEnded(_ note: Notification) {
    guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }

    if let pending = onceCompletion {
      onceCompletion = nil
      pending()
      return
    }
    guard let loopClip else { return }
    if currentClip == loopClip {
      player.seek(to: .zero)
      player.play()
    } else {
      setItem(loopClip)
    }
  }
}

/// Hosts the shared player's AVPlayerLayer with a transparent background.
struct FlowCreatureVideoView: NSViewRepresentable {
  func makeNSView(context: Context) -> FlowCreatureLayerView {
    FlowCreatureLayerView(player: FlowCreaturePlayer.shared.player)
  }

  func updateNSView(_ nsView: FlowCreatureLayerView, context: Context) {}
}

final class FlowCreatureLayerView: NSView {
  private let playerLayer = AVPlayerLayer()

  init(player: AVPlayer) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = .clear
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = .clear
    layer?.addSublayer(playerLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    playerLayer.frame = bounds
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
