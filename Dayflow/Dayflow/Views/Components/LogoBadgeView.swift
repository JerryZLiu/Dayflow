//
//  LogoBadgeView.swift
//  Dayflow
//
//  A single-asset (PNG) premium animation: subtle breathing,
//  slow rim shimmer, and an occasional gloss sweep. No SVG.
//

import SwiftUI

struct LogoBadgeView: View {
  let imageName: String
  var size: CGFloat = 100
  var rimWidth: CGFloat = 6
  var action: (() -> Void)? = nil  // optional tap action
  // Fine-tuning to match PNG edges/rim placement
  // After cropping transparency, these can be very small.
  var rimInsetFraction: CGFloat = 0.015  // portion of size to inset rim from outer edge
  var glossMaskInsetFraction: CGFloat = 0.01  // mask inset so gloss doesn't spill over edge

  @State private var rimAngle: Double = 0
  @State private var microScale: CGFloat = 1.0
  @State private var isPressed = false
  @State private var pressFlashOpacity: Double = 0
  @State private var glossX: CGFloat = -0.6  // start near edge so gloss is visible immediately
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let currentScale = microScale * (isPressed ? 0.97 : 1.0)

    ZStack {
      Image(imageName)
        .resizable()
        .interpolation(.high)
        .scaledToFit()  // image now tightly cropped; fit preserves circle
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)

      // Rim shimmer (conic highlight)
      let rimInset = size * rimInsetFraction
      Circle()
        .inset(by: rimInset)
        .strokeBorder(
          AngularGradient(
            gradient: Gradient(colors: [
              .clear,
              Color.white.opacity(0.35),
              .clear,
            ]),
            center: .center
          ),
          lineWidth: rimWidth
        )
        .blendMode(.screen)
        .rotationEffect(.degrees(rimAngle))
        .allowsHitTesting(false)

      // Passing gloss band (masked to the disc)
      GlossBand(progressX: glossX)
        .frame(width: size * 1.8, height: size * 1.8)
        .rotationEffect(.degrees(35))
        .mask(
          Circle()
            .inset(by: size * glossMaskInsetFraction)
            .frame(width: size, height: size)
        )
        .blendMode(.screen)
        .opacity(reduceMotion ? 0 : 1)
        .allowsHitTesting(false)

      // Brief rim flash on press release
      Circle()
        .inset(by: rimInset)
        .stroke(Color.white.opacity(0.22), lineWidth: rimWidth * 0.75)
        .blendMode(.screen)
        .opacity(pressFlashOpacity)
        .allowsHitTesting(false)
    }
    .frame(width: size, height: size)
    .scaleEffect(currentScale)
    .onAppear { runMicroAnimation() }
    .accessibilityHidden(true)  // decorative
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          if !isPressed {
            withAnimation(.easeOut(duration: 0.12)) { isPressed = true }
          }
        }
        .onEnded { _ in
          withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { isPressed = false }
          // flash the rim subtly
          pressFlashOpacity = 1
          withAnimation(.easeOut(duration: 0.35)) { pressFlashOpacity = 0 }
          runMicroAnimation()
          action?()
        }
    )
    // Ensure blend modes render correctly
    .compositingGroup()
  }

  // One-shot, 1–2 second micro animation combining rim sweep, gloss pass, and pulse
  private func runMicroAnimation() {
    if reduceMotion { return }

    // Reset starting states (start near edge so it's visible immediately)
    glossX = -0.6
    // Pulse scale (quick settle < 0.5s)
    microScale = 0.985
    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
      microScale = 1.0
    }

    // Rim rotates ~160° over ~2.0s (slower, premium) and gloss band sweeps immediately
    withAnimation(.easeInOut(duration: 2.0)) {
      rimAngle += 160
    }

    // Gloss band sweeps across immediately in ~1.8s (2× slower)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.0) {
      withAnimation(.easeInOut(duration: 1.8)) {
        glossX = 1.2
      }
    }
  }
}

private struct GlossBand: View {
  // progressX: -1.2 (far left) ... 1.2 (far right)
  var progressX: CGFloat

  var body: some View {
    LinearGradient(
      colors: [
        .clear,
        Color.white.opacity(0.28),
        .clear,
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
    .offset(x: progressX * 120)  // tuned for a soft, brief sweep
  }
}

// (No petal-specific mask; shimmer stays on the disc to keep it classy.)
