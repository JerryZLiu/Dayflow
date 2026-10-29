//
//  DocketEffects.swift
//  Dayflow
//
//  The front card's light effects from the prototype:
//    Scan    on entrance, the card's text appears from the top down behind a wide, soft,
//            downward-bowing edge of light (2 seconds).
//    Reveal  when the prompt opens, its text appears top to bottom, the newest letters
//            near-white and darkening to grey as the edge passes (1.25 seconds).
//  Both are gradients and masks driven by a TimelineView, so no shaders.
//

import SwiftUI

// MARK: - Scan

/// The Scan entrance on the front card's inside (its fill and content, not its border).
/// Before `start` the inside is hidden; after the 2-second sweep it's fully shown and the
/// timeline stops.
struct DocketScanSurface: ViewModifier {
  /// When the sweep begins. nil means no sweep: the content is simply shown.
  let start: Date?

  static let duration = 2.0
  private static let end = 790.37
  private static let lag = 150.37
  private static let radiusX = 670.0
  private static let radiusY = 470.0
  private static let curve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.2, y: 0.65), endControlPoint: UnitPoint(x: 0.35, y: 1))

  @State private var isFinished = false

  func body(content: Content) -> some View {
    TimelineView(.animation(paused: start == nil || isFinished)) { context in
      let elapsed = start.map { context.date.timeIntervalSince($0) } ?? Self.duration
      let progress = min(max(elapsed / Self.duration, 0), 1)
      let surfY = Self.end * Self.curve.value(at: progress)
      // The light and rays hold until 65% of the sweep, then ease out.
      let fade = progress < 0.65 ? 1 : 1 - UnitCurve.easeIn.value(at: (progress - 0.65) / 0.35)
      let isDone = progress >= 1

      content
        .mask { isDone ? AnyView(Color.black) : AnyView(contentMask(surfY: surfY)) }
        .overlay {
          if !isDone {
            ZStack {
              rays(surfY: surfY, elapsed: elapsed)
              light(surfY: surfY)
            }
            .opacity(fade)
            .allowsHitTesting(false)
          }
        }
    }
    .task(id: start) {
      guard let start else { return }
      isFinished = false
      let remaining = start.timeIntervalSinceNow + Self.duration + 0.05
      if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
      isFinished = true
    }
  }

  /// The ellipse whose lower curve is the moving edge, centred `radiusY` above surfY.
  private func ellipse(_ stops: [Gradient.Stop], surfY: Double, width: Double) -> some View {
    EllipticalGradient(stops: stops, center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
      .frame(width: Self.radiusX * 2, height: Self.radiusY * 2)
      .position(x: width / 2, y: surfY - Self.radiusY)
  }

  /// Hides everything below the lower half of the ellipse: clear above its centre,
  /// opaque from 140pt below it.
  private func lowerHalf(surfY: Double, height: Double) -> LinearGradient {
    LinearGradient(
      colors: [.clear, .black],
      startPoint: UnitPoint(x: 0.5, y: (surfY - 470) / height),
      endPoint: UnitPoint(x: 0.5, y: (surfY - 330) / height))
  }

  private func contentMask(surfY: Double) -> some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack {
        ellipse(
          [
            .init(color: .black.opacity(0.875), location: 0),
            .init(color: .black.opacity(0.55), location: 0.419),
            .init(color: .black.opacity(0.15), location: 0.7925),
            .init(color: .clear, location: 1),
          ], surfY: surfY, width: size.width)
        // A straight edge trailing the curve, so the top of the card is fully shown.
        LinearGradient(
          colors: [.black, .clear],
          startPoint: UnitPoint(x: 0.5, y: (surfY - Self.lag - 160) / size.height),
          endPoint: UnitPoint(x: 0.5, y: (surfY - Self.lag) / size.height))
      }
      .frame(width: size.width, height: size.height)
    }
  }

  private func light(surfY: Double) -> some View {
    GeometryReader { geometry in
      let size = geometry.size
      let wash = Color(hex: "FFFAF5")
      ellipse(
        [
          .init(color: wash.opacity(0.119), location: 0),
          .init(color: wash.opacity(0.12), location: 0.004),
          .init(color: wash.opacity(0.3), location: 0.5435),
          .init(color: .white.opacity(0.2528), location: 0.855),
          .init(color: .white.opacity(0.32), location: 0.971),
          .init(color: .white.opacity(0), location: 1),
        ], surfY: surfY, width: size.width)
      .frame(width: size.width, height: size.height)
      .mask(lowerHalf(surfY: surfY, height: size.height))
      .blur(radius: 12.45)
    }
  }

  /// Soft vertical light rays just inside the edge, sliding 24pt left over the sweep.
  private func rays(surfY: Double, elapsed: Double) -> some View {
    GeometryReader { geometry in
      let size = geometry.size
      let slide = -24 * min(max(elapsed / Self.duration, 0), 1)
      let ray = Color(hex: "FFFDF5")
      Canvas { context, canvasSize in
        var x = -90.0 + slide
        while x < canvasSize.width + 90 {
          for band in [(from: 22.0, peak: 34.0, to: 48.0, alpha: 0.55),
                       (from: 70.0, peak: 78.0, to: 90.0, alpha: 0.4)] {
            let rect = CGRect(x: x + band.from, y: 0, width: band.to - band.from, height: canvasSize.height)
            let peak = (band.peak - band.from) / (band.to - band.from)
            context.fill(
              Path(rect),
              with: .linearGradient(
                Gradient(stops: [
                  .init(color: ray.opacity(0), location: 0),
                  .init(color: ray.opacity(band.alpha), location: peak),
                  .init(color: ray.opacity(0), location: 1),
                ]),
                startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
          }
          x += 90
        }
      }
      .mask {
        ZStack {
          ellipse(
            [
              .init(color: .black.opacity(0.316), location: 0),
              .init(color: .black, location: 0.7095),
              .init(color: .clear, location: 1),
            ], surfY: surfY, width: size.width)
        }
        .frame(width: size.width, height: size.height)
        .mask(lowerHalf(surfY: surfY, height: size.height))
      }
      .blur(radius: 20.75)
    }
  }
}

// MARK: - Prompt reveal

/// Reveals text top to bottom when the prompt opens: a mask edge moves down over 1.25s,
/// and the letters just behind the edge are near-white, darkening to `ink` as it passes.
struct DocketPromptReveal: ViewModifier {
  /// When the reveal began; nil shows the text plainly.
  let start: Date?
  let ink: Color

  static let duration = 1.25
  private static let delay = 0.08
  private static let curve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.25, y: 0.1), endControlPoint: UnitPoint(x: 0.25, y: 1))

  @State private var isFinished = false
  @State private var height: CGFloat = 1

  func body(content: Content) -> some View {
    TimelineView(.animation(paused: start == nil || isFinished)) { context in
      let elapsed = start.map { context.date.timeIntervalSince($0) - Self.delay } ?? Self.duration
      let progress = min(max(elapsed / Self.duration, 0), 1)
      // The edge travels from the top to 120pt past the bottom.
      let edge = (height + 120) * Self.curve.value(at: progress)

      content
        .foregroundStyle(
          progress >= 1 ? AnyShapeStyle(ink) : AnyShapeStyle(letterFill(edge: edge, height: height)))
        .mask {
          if progress >= 1 { Color.black } else { revealMask(edge: edge, height: height) }
        }
    }
    .background(
      GeometryReader { geometry in
        Color.clear
          .onAppear { height = max(geometry.size.height, 1) }
          .onChange(of: geometry.size.height) { _, newHeight in height = max(newHeight, 1) }
      }
    )
    .task(id: start) {
      guard let start else { return }
      isFinished = false
      let remaining = start.timeIntervalSinceNow + Self.delay + Self.duration + 0.05
      if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
      isFinished = true
    }
  }

  /// A gradient laid out in points: `from` and `to` are y positions in the text.
  private func gradient(_ stops: [Gradient.Stop], from: Double, to: Double, height: Double)
    -> LinearGradient
  {
    LinearGradient(
      stops: stops,
      startPoint: UnitPoint(x: 0.5, y: from / height),
      endPoint: UnitPoint(x: 0.5, y: to / height))
  }

  private func revealMask(edge: Double, height: Double) -> LinearGradient {
    gradient(
      [
        .init(color: .black, location: 0),
        .init(color: .black.opacity(0.9), location: 26 / 130),
        .init(color: .black.opacity(0.5), location: 65 / 130),
        .init(color: .black.opacity(0.1), location: 104 / 130),
        .init(color: .clear, location: 1),
      ], from: edge, to: edge + 130, height: height)
  }

  private func letterFill(edge: Double, height: Double) -> LinearGradient {
    gradient(
      [
        .init(color: ink, location: 0),
        .init(color: Color(red: 145 / 255, green: 144 / 255, blue: 144 / 255), location: 0.25),
        .init(color: Color(red: 190 / 255, green: 187 / 255, blue: 186 / 255), location: 0.5),
        .init(color: Color(red: 235 / 255, green: 229 / 255, blue: 227 / 255), location: 0.75),
        .init(color: Color(hex: "FFF8F6"), location: 1),
      ], from: edge - 110, to: edge - 14, height: height)
  }
}
