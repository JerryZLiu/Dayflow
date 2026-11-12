//
//  DocketSummaryCard.swift
//  Dayflow
//
//  Shown in place of the stack once every task is dismissed or handed off: a peach to
//  lavender card with a tilted sky-blue tile that reads "N Tasks Reviewed", and a
//  1 to 5 star rating of how good the day's tasks were.
//

import SwiftUI

struct DocketSummaryCard: View {
  static let height: CGFloat = 470

  let count: Int

  @ObservedObject private var store = DailyBriefStore.shared

  @State private var appearedAt: Date?
  @State private var isFloating = false
  @State private var isEntranceDone = false

  private static let tileCurve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.3, y: 0.6), endControlPoint: UnitPoint(x: 0.4, y: 1))
  private static let riseCurve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.2, y: 0.7), endControlPoint: UnitPoint(x: 0.2, y: 1))

  var body: some View {
    TimelineView(.animation(paused: isEntranceDone)) { context in
      let t = isEntranceDone ? 10 : appearedAt.map { context.date.timeIntervalSince($0) } ?? 0
      content(t: t)
    }
    .frame(width: 676, height: Self.height)
    .background(
      EllipticalGradient(
        colors: [Color(hex: "FFE6D6"), Color(hex: "E8EEFF")],
        center: UnitPoint(x: 0.49, y: 1.02), startRadiusFraction: 0, endRadiusFraction: 1.02)
    )
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.06), radius: 5, y: 2)
    .onAppear {
      appearedAt = Date()
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
          isFloating = true
        }
      }
    }
    .task {
      try? await Task.sleep(for: .seconds(2.3))
      isEntranceDone = true
    }
  }

  private func content(t: Double) -> some View {
    ZStack(alignment: .topLeading) {
      halo(t: t)
        .frame(width: 513.1, height: 505)
        .offset(x: 76.6, y: -14)

      VStack(spacing: 6) {
        Text("You’ve swiped through all the tasks for the day")
          .font(DailyBriefFonts.sans(18, weight: .semibold))
          .foregroundStyle(DocketColors.ink)
          .modifier(DocketRise(t: t, start: 0.28, duration: 0.9, distance: 10))
        Text(
          "Check in on the status of each task in the list view.\nCome back tomorrow to see what else Dayflow can complete for you."
        )
        .font(DailyBriefFonts.sans(14))
        .foregroundStyle(DocketColors.countHover)
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .modifier(DocketRise(t: t, start: 0.4, duration: 0.9, distance: 10))
      }
      .frame(width: 499)
      .offset(x: 87.5, y: 33)

      tile(t: t)
        .offset(x: 242, y: 135.68)

      DocketStarRating(rating: store.brief?.userState.docketRating) { stars in
        store.rateDocket(stars)
      }
      .frame(width: 676)
      .offset(y: 380)
      .modifier(DocketRise(t: t, start: 1.4, duration: 0.6, distance: 8))
      .allowsHitTesting(t >= 1.4)
    }
    .frame(width: 676, height: Self.height, alignment: .topLeading)
  }

  private func halo(t: Double) -> some View {
    let p = DocketMotion.progress(
      t, start: 0.1, duration: 1.4,
      curve: .bezier(
        startControlPoint: UnitPoint(x: 0.22, y: 0.61), endControlPoint: UnitPoint(x: 0.36, y: 1)))
    return EllipticalGradient(
      stops: [
        .init(color: .white.opacity(0.93), location: 0),
        .init(color: .white.opacity(0.93), location: 0.28),
        .init(color: .white.opacity(0.8), location: 0.46),
        .init(color: .white.opacity(0.46), location: 0.64),
        .init(color: .white.opacity(0.12), location: 0.82),
        .init(color: .white.opacity(0), location: 1),
      ], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5
    )
    .opacity(p)
    .scaleEffect(DocketMotion.mix(0.7, 1, p))
  }

  // MARK: Tile

  private func tile(t: Double) -> some View {
    let entrance = tileEntrance(t: t)
    let floatRotation = isFloating ? -0.4 : 0
    let floatY: CGFloat = isFloating ? -4 : 0

    return ZStack(alignment: .top) {
      LinearGradient(
        stops: [
          .init(color: Color(hex: "9FD2FF"), location: 0),
          .init(color: Color(hex: "CDE8FF"), location: 0.72),
          .init(color: Color(hex: "EEF7FF"), location: 0.88),
          .init(color: Color(hex: "FFFEFC"), location: 1),
        ], startPoint: .top, endPoint: .bottom)

      dome(t: t)
        .frame(width: 340, height: 288)
        .offset(x: 0, y: -101)
        .frame(width: 190, alignment: .center)

      tally(t: t)
        .padding(.top, 47.36)
    }
    .frame(width: 190, height: 210)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.12), radius: 5, y: 4)
    .opacity(entrance.opacity)
    .scaleEffect(entrance.scale)
    .rotationEffect(.degrees(entrance.rotation + floatRotation))
    .offset(y: entrance.y + floatY)
  }

  /// The tile's hand-keyed entrance: drops in, overshoots its tilt, settles at 3°.
  private func tileEntrance(t: Double) -> (
    opacity: Double, scale: Double, rotation: Double, y: Double
  ) {
    let local = (t - 0.5) / 0.9
    if local <= 0 { return (0, 0.94, 1, -30) }
    if local < 0.55 {
      let p = Self.tileCurve.value(at: local / 0.55)
      return (
        p, DocketMotion.mix(0.94, 1, p), DocketMotion.mix(1, 3.6, p), DocketMotion.mix(-30, 4, p)
      )
    }
    if local < 0.8 {
      let p = UnitCurve.easeInOut.value(at: (local - 0.55) / 0.25)
      return (1, 1, DocketMotion.mix(3.6, 2.8, p), DocketMotion.mix(4, -1, p))
    }
    let p = UnitCurve.easeInOut.value(at: min((local - 0.8) / 0.2, 1))
    return (1, 1, DocketMotion.mix(2.8, 3, p), DocketMotion.mix(-1, 0, p))
  }

  private func dome(t: Double) -> some View {
    let p = DocketMotion.progress(
      t, start: 0.65, duration: 1.1,
      curve: .bezier(
        startControlPoint: UnitPoint(x: 0.25, y: 0.7), endControlPoint: UnitPoint(x: 0.2, y: 1)))
    return Ellipse()
      .fill(
        EllipticalGradient(
          stops: [
            .init(color: Color(hex: "448CE9"), location: 0),
            .init(color: Color(hex: "61A7FF"), location: 0.6),
            .init(color: Color(hex: "8DC7FF"), location: 0.88),
            .init(color: Color(hex: "E4F3FF"), location: 0.96),
            .init(color: Color(hex: "FFF8ED"), location: 1),
          ], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
      )
      .shadow(color: .white, radius: 12)
      .shadow(color: Color(red: 1, green: 228 / 255, blue: 189 / 255).opacity(0.7), radius: 5)
      .blur(radius: 2)
      .opacity(DocketMotion.mix(0.5, 1, p))
      .offset(y: DocketMotion.mix(-70, 0, p))
  }

  private func tally(t: Double) -> some View {
    let countProgress = min(max((t - 1.0) / 0.7, 0), 1)
    let shown = Int((Double(count) * (1 - pow(1 - countProgress, 3))).rounded())
    return VStack(spacing: 0) {
      Text("\(shown)")
        .font(DailyBriefFonts.sans(48, weight: .semibold))
        .frame(height: 34)
        .modifier(DocketRise(t: t, start: 1.0, duration: 0.5, distance: 10, curve: Self.riseCurve))
      Text(count == 1 ? "Task" : "Tasks")
        .font(DailyBriefFonts.sans(18, weight: .semibold))
        .opacity(0.9)
        .padding(.top, 14)
        .modifier(DocketRise(t: t, start: 1.1, duration: 0.5, distance: 8, curve: Self.riseCurve))
      Text("Reviewed")
        .font(DailyBriefFonts.sans(18, weight: .medium))
        .opacity(0.9)
        .padding(.top, 2)
        .modifier(DocketRise(t: t, start: 1.2, duration: 0.5, distance: 8, curve: Self.riseCurve))
    }
    .foregroundStyle(.white)
    .frame(width: 190)
  }
}

/// "How good were today's tasks?" over five stars. Hovering previews a rating;
/// clicking saves it, and it can be changed by clicking again.
private struct DocketStarRating: View {
  let rating: Int?
  let onRate: (Int) -> Void

  @State private var hovered: Int?

  private var shown: Int { hovered ?? rating ?? 0 }

  var body: some View {
    VStack(spacing: 8) {
      Text(rating == nil ? "How good were today’s tasks?" : "Thanks for rating today’s tasks")
        .font(DailyBriefFonts.sans(13, weight: .medium))
        .foregroundStyle(DocketColors.countHover)

      HStack(spacing: 0) {
        ForEach(1...5, id: \.self) { star in
          Button {
            onRate(star)
          } label: {
            Image(systemName: star <= shown ? "star.fill" : "star")
              .font(.system(size: 22, weight: .medium))
              .foregroundStyle(star <= shown ? Color(hex: "FF9F6F") : DocketColors.count)
              .frame(width: 36, height: 32)
              .contentShape(Rectangle())
          }
          .buttonStyle(DayflowPressScaleButtonStyle())
          .onHover { isHovering in
            if isHovering {
              hovered = star
            } else if hovered == star {
              hovered = nil
            }
          }
          .accessibilityLabel(star == 1 ? "1 star" : "\(star) stars")
        }
      }
      .pointingHandCursor()
      .animation(.easeOut(duration: 0.12), value: shown)
    }
  }
}

/// Fades up from `distance` points below, starting `start` seconds in.
private struct DocketRise: ViewModifier {
  let t: Double
  let start: Double
  let duration: Double
  let distance: CGFloat
  var curve: UnitCurve = DocketMotion.enterCurve

  func body(content: Content) -> some View {
    let p = DocketMotion.progress(t, start: start, duration: duration, curve: curve)
    content
      .opacity(p)
      .offset(y: distance * (1 - p))
  }
}
