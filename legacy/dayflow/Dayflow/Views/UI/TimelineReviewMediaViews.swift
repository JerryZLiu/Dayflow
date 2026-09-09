import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

struct TimelineReviewCardMedia: View {
  let previewImage: CGImage?
  @ObservedObject var playbackState: TimelineReviewPlaybackMediaState
  let player: AVPlayer?
  let onTogglePlayback: () -> Void

  @State private var isPlayerReady = false

  private enum Design {
    static let mediaBorderColor = Color.white.opacity(0.2)
  }

  var body: some View {
    ZStack {
      if let player {
        WhiteBGVideoPlayer(
          player: player,
          videoGravity: .resizeAspectFill,
          onReadyForDisplay: { ready in isPlayerReady = ready }
        )
        .allowsHitTesting(false)
        .clipped()
        .opacity(isPlayerReady ? 1 : 0)

        // Show thumbnail until the player layer has rendered its first frame
        if !isPlayerReady, let image = previewImage {
          TimelineReviewLayerBackedImageView(image: image)
            .allowsHitTesting(false)
            .clipped()
        }
      } else if let image = playbackState.currentImage ?? previewImage {
        TimelineReviewLayerBackedImageView(image: image)
          .allowsHitTesting(false)
          .clipped()
      } else {
        LinearGradient(
          colors: [Color.black.opacity(0.25), Color.black.opacity(0.05)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { onTogglePlayback() }
    .pointingHandCursor()
    .overlay(
      Rectangle().stroke(Design.mediaBorderColor, lineWidth: 1)
    )
    .onChange(of: player) {
      isPlayerReady = false
    }
  }
}

final class TimelineReviewImageLayerHostView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = CALayer()
    configureLayer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    layer = CALayer()
    configureLayer()
  }

  override func layout() {
    super.layout()
    layer?.frame = bounds
  }

  func updateImage(_ image: CGImage) {
    guard let layer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = image
    CATransaction.commit()
  }

  private func configureLayer() {
    guard let layer else { return }
    layer.masksToBounds = true
    layer.contentsGravity = .resizeAspectFill
    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    layer.magnificationFilter = .trilinear
    layer.minificationFilter = .trilinear
    layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
  }
}

struct TimelineReviewLayerBackedImageView: NSViewRepresentable {
  let image: CGImage

  func makeNSView(context: Context) -> TimelineReviewImageLayerHostView {
    let view = TimelineReviewImageLayerHostView()
    view.updateImage(image)
    return view
  }

  func updateNSView(_ nsView: TimelineReviewImageLayerHostView, context: Context) {
    nsView.updateImage(image)
  }
}
