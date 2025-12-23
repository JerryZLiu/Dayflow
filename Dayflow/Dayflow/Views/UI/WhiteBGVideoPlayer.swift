//
//  WhiteBGVideoPlayer.swift
//  Dayflow
//
//  SwiftUI wrapper for AVPlayerView with a white background to avoid
//  default black letterboxing.
//

import SwiftUI
import AVKit
import AppKit

// AVPlayerLayer-backed view to avoid AVPlayerView overlays (e.g., Live Text button)
final class PlayerLayerView: NSView {
    private var _player: AVPlayer?
    var player: AVPlayer? {
        get { _player }
        set {
            guard newValue != _player else { return }
            _player = newValue
            playerLayer.player = newValue
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
}

struct WhiteBGVideoPlayer: NSViewRepresentable {
    var player: AVPlayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var backgroundColor: NSColor = .white

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
        nsView.playerLayer.backgroundColor = backgroundColor.cgColor
        nsView.playerLayer.videoGravity = videoGravity
    }
}
