//
//  FlowOverlayView.swift
//  Dayflow
//
//  SwiftUI content for the Flow desktop overlay panel. The creature is a
//  video (HEVC with alpha, see FlowCreatureView) whose 1280×768 canvas bakes
//  in the screen position: it peeks in over the right edge to wave or breathe
//  fire, and drags out a tub for breaks. The speech bubble and action pills
//  are laid over the video; the panel window sits flush against the screen's
//  bottom-right corner so the offscreen half of the creature clips naturally.
//

import SwiftUI

struct FlowOverlayView: View {
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @State private var showSnoozeOptions = false

  /// The 1280×768 clip canvas rendered at half size, plus a little headroom
  /// so bubbles can float above it.
  private static let videoSize = CGSize(width: 640, height: 384)
  private static let rootSize = CGSize(width: 680, height: 440)

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Always mounted: exit clips play while the overlay state is already
      // .hidden, just before the panel fades out.
      FlowCreatureVideoView()
        .frame(width: Self.videoSize.width, height: Self.videoSize.height)
        .offset(
          x: Self.rootSize.width - Self.videoSize.width,
          y: Self.rootSize.height - Self.videoSize.height)

      switch mirror.overlay {
      case .hidden:
        EmptyView()
      case .toast(let message):
        speechBubble(message, layout: .edge)
      case .nudge(let message, let escalated):
        speechBubble(message, layout: escalated ? .scene : .edge)
        nudgePills
      case .onBreak:
        breakBubble
      case .sessionEnded:
        speechBubble("Time's up! Great work.", layout: .edge)
        sessionEndedPills
      }
    }
    .frame(width: Self.rootSize.width, height: Self.rootSize.height, alignment: .topLeading)
    .animation(.spring(duration: 0.3), value: mirror.overlay)
    .onChange(of: mirror.overlay) { oldValue, newValue in
      showSnoozeOptions = false
      updateCreature(from: oldValue, to: newValue)
    }
    .onAppear {
      updateCreature(from: .hidden, to: mirror.overlay)
    }
  }

  // MARK: - Creature clip selection

  private func updateCreature(from old: FlowOverlayPresentation, to new: FlowOverlayPresentation) {
    let player = FlowCreaturePlayer.shared
    switch new {
    case .hidden:
      break  // Exit clips are driven by FlowOverlayController before hiding.
    case .nudge(_, true):
      player.play(.fireBegin, thenLoop: .fireLoop)
    case .toast, .sessionEnded, .nudge:
      if old == .hidden {
        player.play(.entrance, thenLoop: .waveLoop)
      } else {
        player.ensureLoop(.waveLoop)
      }
    case .onBreak:
      player.play(.bathBegin, thenLoop: .bathLoop)
    }
  }

  // MARK: - Speech bubble

  /// Where the bubble sits: `edge` next to the creature peeking at the right
  /// edge, `scene` higher up and further left, clear of the fire/tub clips.
  private enum BubbleLayout {
    case edge, scene

    var offset: CGPoint {
      switch self {
      case .edge: return CGPoint(x: 430, y: 190)
      case .scene: return CGPoint(x: 310, y: 84)
      }
    }
  }

  private func speechBubble(_ text: String, layout: BubbleLayout) -> some View {
    bubbleShell(layout: layout) {
      Text(text)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var breakBubble: some View {
    bubbleShell(layout: .scene) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Break time!")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(.black)
        if let endsAt = mirror.snapshot.breakEndsAt {
          CountdownText(until: Date(timeIntervalSince1970: TimeInterval(endsAt)))
            .font(.custom("Figtree", size: 13).monospacedDigit())
            .foregroundColor(.black.opacity(0.6))
        }
      }
    }
  }

  private func bubbleShell<Content: View>(
    layout: BubbleLayout, @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .frame(width: 147, alignment: .leading)
      .frame(minHeight: 49)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(hex: "D9D9D9"))
      )
      .background(alignment: .trailing) {
        // Tail pointing right, toward the creature.
        BubbleTail()
          .fill(Color(hex: "D9D9D9"))
          .frame(width: 30, height: 16)
          .offset(x: 19)
      }
      .offset(x: layout.offset.x, y: layout.offset.y)
  }

  // MARK: - Nudge pills

  private var nudgePills: some View {
    VStack(alignment: .leading, spacing: 7) {
      pill(background: .white.opacity(0.5)) {
        showSnoozeOptions = false
        mirror.respondBackToWork()
      } label: {
        HStack(spacing: 4) {
          pillText("Whoops! I'll get back to work.")
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.black.opacity(0.7))
        }
      }

      pill(background: .white.opacity(showSnoozeOptions ? 0.8 : 0.5)) {
        showSnoozeOptions.toggle()
      } label: {
        pillText("Just a few more minutes!")
      }

      if showSnoozeOptions {
        HStack(spacing: 5) {
          ForEach([5, 10, 15], id: \.self) { minutes in
            pill(background: .white.opacity(0.75)) {
              showSnoozeOptions = false
              mirror.snooze(minutes: minutes)
            } label: {
              pillText("\(minutes) min")
            }
          }
        }
      }

      pill(background: .white.opacity(0.5)) {
        showSnoozeOptions = false
        mirror.correctMistake()
      } label: {
        pillText("Correct Flow's mistake")
      }
    }
    .offset(x: 388, y: 262)
  }

  private var sessionEndedPills: some View {
    VStack(alignment: .leading, spacing: 7) {
      pill(background: .white.opacity(0.5)) {
        mirror.openFlowTab()
      } label: {
        pillText("Start a new session")
      }
      pill(background: .white.opacity(0.5)) {
        mirror.dismissOverlay()
      } label: {
        pillText("Done")
      }
    }
    .offset(x: 388, y: 262)
  }

  private func pillText(_ title: String) -> some View {
    Text(title)
      .font(.custom("Figtree", size: 14))
      .foregroundColor(.black)
  }

  private func pill<Label: View>(
    background: Color,
    action: @escaping () -> Void,
    @ViewBuilder label: () -> Label
  ) -> some View {
    Button(action: action) {
      label()
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
    }
    .buttonStyle(.plain)
  }
}

/// The speech bubble's tail: a small curved point aimed right at the creature.
private struct BubbleTail: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.midY),
      control: CGPoint(x: rect.maxX * 0.7, y: rect.minY)
    )
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY),
      control: CGPoint(x: rect.maxX * 0.7, y: rect.maxY)
    )
    path.closeSubpath()
    return path
  }
}

/// Self-updating "mm:ss" countdown to a fixed deadline.
private struct CountdownText: View {
  let until: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text(formatted(remaining: until.timeIntervalSince(context.date)))
    }
  }

  private func formatted(remaining: TimeInterval) -> String {
    let total = max(0, Int(remaining))
    return String(format: "%d:%02d left", total / 60, total % 60)
  }
}
