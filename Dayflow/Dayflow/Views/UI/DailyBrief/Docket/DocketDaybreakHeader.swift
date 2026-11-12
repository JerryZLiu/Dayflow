//
//  DocketDaybreakHeader.swift
//  Dayflow
//
//  The top of the brief page ("Daybreak · Sun"): a warm glow coming down from the top
//  centre, a pink bloom near each top corner, the date, and "Take these off your plate".
//  On open the sky passes from periwinkle through lilac and clears while the sun comes
//  down into place. While a prompt is open everything here dims and slides up.
//

import SwiftUI

struct DocketDaybreakHeader: View {
  let date: Date
  /// False when there's no docket, so the heading under the date is left out.
  var showsIntro = true
  /// Only the date: the reading-first layout moves the heading down to the deck, and
  /// the full height would leave an empty band under the date.
  var isCompact = false

  @ObservedObject private var ui = DocketUIState.shared
  @State private var appearedAt = Date()
  @State private var isEntranceDone = false

  /// Height of the header area: the deck starts at 203.2.
  static let height: CGFloat = 203.2
  /// The date ends at about 82; this leaves the same gap below it as above the heading.
  static let compactHeight: CGFloat = 112

  private static let sunCurve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.45, y: 0), endControlPoint: UnitPoint(x: 0.25, y: 1))

  var body: some View {
    TimelineView(.animation(paused: isEntranceDone)) { context in
      let t = isEntranceDone ? 10 : context.date.timeIntervalSince(appearedAt)
      ZStack(alignment: .top) {
        sky(t: t)
          .frame(height: 142)
          .frame(maxHeight: .infinity, alignment: .top)
        sun(t: t)
        sideHaze(t: t)
        texts(t: t)
      }
    }
    .frame(height: isCompact ? Self.compactHeight : Self.height, alignment: .top)
    .onAppear { appearedAt = Date() }
    .task {
      try? await Task.sleep(for: .seconds(3.3))
      isEntranceDone = true
    }
  }

  // MARK: Sky and light

  /// Periwinkle at the top, then lilac and rose, then clear. Invisible at rest.
  private func sky(t: Double) -> some View {
    let (top, low) = Self.skyColors(t: t)
    return LinearGradient(
      stops: [
        .init(color: top, location: 0), .init(color: low, location: 0.6),
        .init(color: .clear, location: 1),
      ],
      startPoint: .top, endPoint: .bottom)
  }

  private static func skyColors(t: Double) -> (Color, Color) {
    let p = t / 2.8
    // (red, green, blue, alpha) at 20%, 62% and 100%.
    let top: [(Double, Double, Double, Double)] = [
      (209, 219, 244, 0.64), (222, 212, 248, 0.4), (222, 212, 248, 0),
    ]
    let low: [(Double, Double, Double, Double)] = [
      (226, 230, 246, 0.5), (250, 214, 224, 0.3), (250, 214, 224, 0),
    ]
    func blend(_ stops: [(Double, Double, Double, Double)]) -> Color {
      let a: (Double, Double, Double, Double)
      let b: (Double, Double, Double, Double)
      let local: Double
      if p <= 0.2 {
        return color(stops[0])
      } else if p <= 0.62 {
        (a, b, local) = (stops[0], stops[1], (p - 0.2) / 0.42)
      } else {
        (a, b, local) = (stops[1], stops[2], min((p - 0.62) / 0.38, 1))
      }
      let e = UnitCurve.easeInOut.value(at: local)
      return color(
        (
          DocketMotion.mix(a.0, b.0, e), DocketMotion.mix(a.1, b.1, e),
          DocketMotion.mix(a.2, b.2, e), DocketMotion.mix(a.3, b.3, e)
        ))
    }
    return (blend(top), blend(low))
  }

  private static func color(_ rgba: (Double, Double, Double, Double)) -> Color {
    Color(red: rgba.0 / 255, green: rgba.1 / 255, blue: rgba.2 / 255).opacity(rgba.3)
  }

  /// A large, heavily blurred peach ellipse; only its lower part shows.
  private func sun(t: Double) -> some View {
    let p = DocketMotion.progress(t, start: 0.79, duration: 2.1, curve: Self.sunCurve)
    // The image's top moves from -715 to -489.56; the ellipse centre is 450 below it.
    let centreY = DocketMotion.mix(-715, -489.56, p) + 450
    let entranceOpacity = DocketMotion.mix(0.6, 1, p) * (t < 0.79 ? 0 : 1)
    return Ellipse()
      .fill(
        LinearGradient(
          stops: [
            .init(color: Color(hex: "FFE4DD"), location: 0.62),
            .init(color: Color(hex: "FFF0D2"), location: 0.798),
            .init(color: .white, location: 1),
          ], startPoint: .top, endPoint: .bottom)
      )
      .frame(width: 810, height: 348)
      // Room for the blur to spread, then bake it into one bitmap so scrolling doesn't
      // redo a 75pt blur every frame.
      .padding(170)
      .blur(radius: 75)
      .drawingGroup()
      .position(x: 0, y: centreY)
      .frame(width: 0, height: 0)
      .frame(maxWidth: .infinity, maxHeight: 380, alignment: .top)
      .clipped()
      .opacity(entranceOpacity * (ui.isPromptOpen ? 0.35 : 1))
      .animation(.easeOut(duration: 0.26), value: ui.isPromptOpen)
      .allowsHitTesting(false)
  }

  /// Two blurred pink ellipses, 412pt either side of centre.
  private func sideHaze(t: Double) -> some View {
    let p = t / 2.8
    let fade = p <= 0.4 ? 0 : UnitCurve.easeInOut.value(at: min((p - 0.4) / 0.6, 1))
    return ZStack {
      hazeEllipse.offset(x: -412.22)
      hazeEllipse.offset(x: 412.22)
    }
    .frame(height: 0)
    .offset(y: -224.74 + 165.69)
    .frame(maxWidth: .infinity, maxHeight: 230, alignment: .top)
    .clipped()
    .opacity(fade * (ui.isPromptOpen ? 0.35 : 1))
    .animation(.easeOut(duration: 0.26), value: ui.isPromptOpen)
    .allowsHitTesting(false)
  }

  private var hazeEllipse: some View {
    Ellipse()
      .fill(
        LinearGradient(
          stops: [
            .init(color: Color(hex: "F4C8D0"), location: 0.62),
            .init(color: Color(hex: "E8F6FF"), location: 0.798),
            .init(color: .white, location: 1),
          ], startPoint: .top, endPoint: .bottom)
      )
      .frame(width: 263.4, height: 211.4)
      .padding(70)
      .blur(radius: 30)
      .drawingGroup()
  }

  // MARK: Texts

  private func texts(t: Double) -> some View {
    let isOpen = ui.isPromptOpen
    return VStack(spacing: 0) {
      Text(DailyBriefDates.longTitle(date))
        .font(DailyBriefFonts.serif(36))
        .foregroundStyle(DocketColors.ink)
        .frame(height: 36.8)
        .modifier(DocketHeaderRise(t: t, start: 0.2))
        .opacity(isOpen ? 0 : 1)
        .offset(y: isOpen ? -36 : 0)
        .padding(.top, 45.13)

      if showsIntro {
        VStack(spacing: 4) {
          Text("Take these off your plate")
            .font(DailyBriefFonts.serif(24))
            .foregroundStyle(Color(hex: "474747"))
            .frame(height: 28.8)
            .modifier(DocketHeaderRise(t: t, start: 0.35))
          Text("Let your agents complete these tasks for you.")
            .font(DailyBriefFonts.sans(14))
            .foregroundStyle(Color(hex: "8A8A8A"))
            .frame(height: 16)
            .modifier(DocketHeaderRise(t: t, start: 0.5))
        }
        .opacity(isOpen ? 0 : 1)
        .offset(y: isOpen ? -64 : 0)
        .padding(.top, 111.5 - 45.13 - 36.8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
    // Opening fades fast and slides with the card; closing waits a beat, like the prototype.
    .animation(isOpen ? DocketMotion.ease(0.46) : DocketMotion.ease(0.5).delay(0.06), value: isOpen)
    .allowsHitTesting(!isOpen)
  }
}

/// "Take these off your plate", drawn right above the card stack instead of in the
/// header, for the half of the layout test that puts the reading sections on top.
/// It dims and slides up with the header's copy while a prompt is open.
struct DocketDeckHeading: View {
  @ObservedObject private var ui = DocketUIState.shared

  var body: some View {
    let isOpen = ui.isPromptOpen
    return VStack(spacing: 4) {
      Text("Take these off your plate")
        .font(DailyBriefFonts.serif(24))
        .foregroundStyle(Color(hex: "474747"))
        .frame(height: 28.8)
      Text("Let your agents complete these tasks for you.")
        .font(DailyBriefFonts.sans(14))
        .foregroundStyle(Color(hex: "8A8A8A"))
        .frame(height: 16)
    }
    .frame(maxWidth: .infinity)
    // The gap the header leaves between this copy and the deck.
    .padding(.bottom, 43)
    .opacity(isOpen ? 0 : 1)
    .offset(y: isOpen ? -64 : 0)
    .animation(isOpen ? DocketMotion.ease(0.46) : DocketMotion.ease(0.5).delay(0.06), value: isOpen)
    .allowsHitTesting(!isOpen)
  }
}

/// Fades in from 12pt above over 0.9s, starting `start` seconds after the page appeared.
private struct DocketHeaderRise: ViewModifier {
  let t: Double
  let start: Double

  func body(content: Content) -> some View {
    let p = DocketMotion.progress(t, start: start, duration: 0.9, curve: DocketMotion.enterCurve)
    content
      .opacity(p)
      .offset(y: -12 * (1 - p))
  }
}

/// The content panel's twilight wash during the entrance: periwinkle at the top and
/// rose by 745pt, held for the first 20% of 3.2s, then cleared.
struct DocketTwilightWash: View {
  @State private var appearedAt = Date()
  @State private var isDone = false

  private static let curve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.45, y: 0), endControlPoint: UnitPoint(x: 0.4, y: 1))

  var body: some View {
    TimelineView(.animation(paused: isDone)) { context in
      let raw = isDone ? 1 : context.date.timeIntervalSince(appearedAt) / 3.2
      let strength = raw <= 0.2 ? 1 : 1 - Self.curve.value(at: min((raw - 0.2) / 0.8, 1))
      LinearGradient(
        colors: [
          Color(red: 218 / 255, green: 225 / 255, blue: 243 / 255).opacity(0.5 * strength),
          Color(red: 241 / 255, green: 232 / 255, blue: 235 / 255).opacity(0.5 * strength),
        ], startPoint: .top, endPoint: .bottom
      )
      .frame(height: 745)
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .allowsHitTesting(false)
    .onAppear { appearedAt = Date() }
    .task {
      try? await Task.sleep(for: .seconds(3.3))
      isDone = true
    }
  }
}
