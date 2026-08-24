//
//  FlowOverlayView.swift
//  Dayflow
//
//  SwiftUI content for the Flow desktop overlay panel, built to the Figma
//  overlay mocks (node 503:34747): the creature peeks in over the screen's
//  right edge, speaks through a gray bubble with a tail, and offers a stack
//  of translucent pill actions. The panel window sits flush against the
//  screen's right edge, so the creature's offscreen half clips naturally.
//

import SwiftUI

struct FlowOverlayView: View {
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @State private var showSnoozeOptions = false

  /// Design canvas: mock coordinates were authored in a 281pt-wide region;
  /// everything below uses that space shifted 19pt right into a 300pt root.
  private let rootSize = CGSize(width: 300, height: 250)

  var body: some View {
    ZStack(alignment: .topLeading) {
      switch mirror.overlay {
      case .hidden:
        EmptyView()
      case .toast(let message):
        creature
        speechBubble(message)
      case .nudge(let message):
        creature
        speechBubble(message)
        nudgePills
      case .onBreak:
        creature
        breakBubble
      case .sessionEnded:
        creature
        speechBubble("Time's up! Great work.")
        sessionEndedPills
      }
    }
    .frame(width: rootSize.width, height: rootSize.height, alignment: .topLeading)
    .frame(width: 360, height: 320, alignment: .bottomTrailing)
    .animation(.spring(duration: 0.3), value: mirror.overlay)
    .onChange(of: mirror.overlay) { showSnoozeOptions = false }
  }

  // MARK: - Creature

  /// The pixel-art creature, rotated so just its face peeks in over the
  /// screen edge (the rest hangs offscreen past the window bounds).
  private var creature: some View {
    Image("FlowCreature")
      .resizable()
      .scaledToFit()
      .frame(width: 131, height: 111)
      .rotationEffect(.degrees(-43.27))
      // Mock: rotated art centered at (~307, ~61) in this canvas — most of the
      // body hangs past the trailing edge, offscreen.
      .offset(x: 241, y: 6)
  }

  // MARK: - Speech bubble

  private func speechBubble(_ text: String) -> some View {
    bubbleShell {
      Text(text)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var breakBubble: some View {
    bubbleShell {
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

  private func bubbleShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
      .offset(x: 85, y: 41)
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
    .offset(x: 38, y: 98)
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
    .offset(x: 38, y: 98)
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
