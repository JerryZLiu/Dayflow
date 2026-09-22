import AVFoundation
import SwiftUI

/// Plays Flow's environment loop, with the still image shown until video is ready.
struct FlowWaitlistBackgroundView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  @State private var player: AVQueuePlayer?
  @State private var looper: AVPlayerLooper?
  @State private var isVideoReady = false

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Image("FlowWaitlistBackground")
          .resizable()
          .scaledToFill()

        if let player {
          WhiteBGVideoPlayer(
            player: player,
            videoGravity: .resizeAspectFill,
            backgroundColor: .clear,
            onReadyForDisplay: { ready in
              DispatchQueue.main.async { isVideoReady = ready }
            }
          )
          .opacity(isVideoReady && !reduceMotion ? 1 : 0)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear(perform: updatePlayback)
    .onChange(of: reduceMotion) { updatePlayback() }
    .onChange(of: scenePhase) { updatePlayback() }
    .onDisappear {
      player?.pause()
      looper?.disableLooping()
      player?.removeAllItems()
      looper = nil
      player = nil
      isVideoReady = false
    }
  }

  private func updatePlayback() {
    guard !reduceMotion, scenePhase == .active else {
      player?.pause()
      return
    }

    if player == nil,
      let url = Bundle.main.url(forResource: "FlowWaitlistBackground", withExtension: "mp4")
    {
      let queue = AVQueuePlayer()
      queue.isMuted = true
      looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
      player = queue
    }
    player?.play()
  }
}
