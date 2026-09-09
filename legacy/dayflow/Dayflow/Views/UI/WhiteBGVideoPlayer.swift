//
//  WhiteBGVideoPlayer.swift
//  Dayflow
//
//  SwiftUI wrapper for AVPlayerView with a white background to avoid
//  default black letterboxing.
//

import AVKit
import AppKit
import SwiftUI

// AVPlayerLayer-backed view to avoid AVPlayerView overlays (e.g., Live Text button)
final class PlayerLayerView: NSView {
  private var _player: AVPlayer?
  private var readyObservation: NSKeyValueObservation?

  /// Called when `AVPlayerLayer.isReadyForDisplay` changes.
  var onReadyForDisplayChanged: ((Bool) -> Void)?

  var player: AVPlayer? {
    get { _player }
    set {
      guard newValue != _player else { return }
      _player = newValue
      playerLayer.player = newValue
      observeReadyForDisplay()
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = NSColor.white.cgColor
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = NSColor.white.cgColor
  }

  override func makeBackingLayer() -> CALayer {
    return AVPlayerLayer()
  }

  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

  private func observeReadyForDisplay() {
    readyObservation?.invalidate()
    readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new, .initial]) {
      [weak self] layer, _ in
      self?.onReadyForDisplayChanged?(layer.isReadyForDisplay)
    }
  }
}

struct WhiteBGVideoPlayer: NSViewRepresentable {
  var player: AVPlayer?
  var videoGravity: AVLayerVideoGravity = .resizeAspect
  var backgroundColor: NSColor = .white
  var onReadyForDisplay: ((Bool) -> Void)?

  func makeNSView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.onReadyForDisplayChanged = onReadyForDisplay
    view.player = player
    return view
  }

  func updateNSView(_ nsView: PlayerLayerView, context: Context) {
    nsView.onReadyForDisplayChanged = onReadyForDisplay
    nsView.player = player
    nsView.playerLayer.backgroundColor = backgroundColor.cgColor
    nsView.playerLayer.videoGravity = videoGravity
  }
}
