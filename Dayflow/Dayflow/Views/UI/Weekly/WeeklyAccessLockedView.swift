import SwiftUI

enum WeeklyAccessNotificationState: Equatable {
  case idle
  case requesting
  case scheduled
  case denied
  case failed

  var buttonTitle: String {
    switch self {
    case .idle:
      return "Notify me when ready"
    case .requesting:
      return "Setting reminder..."
    case .scheduled:
      return "We'll notify you"
    case .denied:
      return "Open notification settings"
    case .failed:
      return "Try again"
    }
  }

  var isButtonDisabled: Bool {
    switch self {
    case .requesting, .scheduled:
      return true
    case .idle, .denied, .failed:
      return false
    }
  }
}

struct WeeklyAccessProgressSnapshot: Equatable {
  static let batchDurationMinutes = 15
  static let batchesPerRecordedHour = 4
  static let recordedHourTarget = 30
  static let completedBatchTarget = recordedHourTarget * batchesPerRecordedHour

  let completedBatchCount: Int

  var progress: Double {
    Double(cappedCompletedBatchCount) / Double(Self.completedBatchTarget)
  }

  var isComplete: Bool {
    completedBatchCount >= Self.completedBatchTarget
  }

  var remainingBatchCount: Int {
    max(Self.completedBatchTarget - completedBatchCount, 0)
  }

  var recordedTimeText: String {
    let minutes = cappedCompletedBatchCount * Self.batchDurationMinutes
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if minutes == 0 {
      return "0h / 30h"
    }

    if hours == 0 {
      return "\(remainingMinutes)m / 30h"
    }

    if remainingMinutes == 0 {
      return "\(hours)h / 30h"
    }

    return "\(hours)h \(remainingMinutes)m / 30h"
  }

  func estimatedUnlockDate(from date: Date) -> Date {
    date.addingTimeInterval(TimeInterval(remainingBatchCount * Self.batchDurationMinutes * 60))
  }

  private var cappedCompletedBatchCount: Int {
    min(max(completedBatchCount, 0), Self.completedBatchTarget)
  }
}

struct WeeklyAccessLockedView: View {
  let accessProgress: WeeklyAccessProgressSnapshot
  let notificationState: WeeklyAccessNotificationState
  let onNotify: () -> Void

  private var clampedProgress: Double {
    min(max(accessProgress.progress, 0), 1)
  }

  var body: some View {
    GeometryReader { geometry in
      let cardScale = cardScale(for: geometry.size)

      ZStack {
        WeeklyAccessPreviewBackground()
        WeeklyAccessLockedBackground()

        lockCard
          .frame(width: 485, height: 276)
          .scaleEffect(cardScale, anchor: .center)
          .frame(width: 485 * cardScale, height: 276 * cardScale)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
  }

  private var lockCard: some View {
    WeeklyAccessLockCard(
      recordedTimeText: accessProgress.recordedTimeText,
      isReady: accessProgress.isComplete,
      progress: clampedProgress,
      notificationState: notificationState,
      onNotify: onNotify
    )
  }

  private func cardScale(for size: CGSize) -> CGFloat {
    let availableWidth = max(1, size.width - 64)
    let availableHeight = max(1, size.height - 64)
    return min(1, max(0.66, min(availableWidth / 485, availableHeight / 276)))
  }

}

private struct WeeklyAccessLockCard: View {
  let recordedTimeText: String
  let isReady: Bool
  let progress: Double
  let notificationState: WeeklyAccessNotificationState
  let onNotify: () -> Void

  private var buttonTitle: String {
    isReady ? "View Weekly" : notificationState.buttonTitle
  }

  private var isButtonDisabled: Bool {
    !isReady && notificationState.isButtonDisabled
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      WeeklyAccessCardBackground()

      VStack(spacing: 4) {
        Text("Unlock Weekly")
          .font(.custom("InstrumentSerif-Regular", size: 22))
          .foregroundStyle(Color(hex: "333333"))
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .minimumScaleFactor(0.76)
          .frame(width: 333, height: 26.4)

        Text("Weekly unlocks after 30 hours of recorded timeline data")
          .font(.custom("Figtree-Regular", size: 14))
          .foregroundStyle(Color(hex: "796E64"))
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .minimumScaleFactor(0.76)
          .frame(width: 333, height: 16.8)
      }
      .frame(width: 333, height: 47.2)
      .position(x: 241.5, y: 48.9)

      WeeklyAccessCountdownPill(text: recordedTimeText)
        .frame(width: 166, height: 60)
        .position(x: 244.39, y: 120.49)

      WeeklyAccessProgressBar(progress: progress)
        .position(x: 246.82, y: 171.6)

      Button(action: onNotify) {
        Text(buttonTitle)
          .font(.custom("Figtree-Medium", size: 14))
          .foregroundStyle(Color.white)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .frame(width: 140)
      }
      .frame(width: 188, height: 36)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color(hex: "402B00").opacity(isButtonDisabled ? 0.62 : 1))
      )
      .buttonStyle(.plain)
      .disabled(isButtonDisabled)
      .pointingHandCursorOnHover(enabled: !isButtonDisabled)
      .position(x: 247.94, y: 229)
    }
    .frame(width: 485, height: 276)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.white, lineWidth: 1)
    )
    .shadow(color: Color(hex: "80450D").opacity(0.2), radius: 12, x: 0, y: 2)
  }
}

private struct WeeklyAccessCardBackground: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(hex: "FFF7EF"))

      WeeklyAccessGlowCircle(size: 287, colors: [Color(hex: "FFE6A3"), Color(hex: "FF8A1E")])
        .position(x: 185.4, y: -160.4)

      WeeklyAccessGlowCircle(size: 127, colors: [Color(hex: "FFF2BD"), Color(hex: "FF9F2F")])
        .position(x: 286.1, y: -219.2)

      WeeklyAccessGlowCircle(size: 115, colors: [Color(hex: "FFF4C9"), Color(hex: "FF7A00")])
        .position(x: 318.7, y: -172.7)

      WeeklyAccessGlowCircle(size: 112, colors: [Color(hex: "FFE3B3"), Color(hex: "FF7D2D")])
        .position(x: 265.6, y: 437.1)

      WeeklyAccessGlowCircle(size: 73, colors: [Color(hex: "FFF6D0"), Color(hex: "FF7A00")])
        .position(x: 96.1, y: 415.5)
    }
  }
}

private struct WeeklyAccessGlowCircle: View {
  let size: CGFloat
  let colors: [Color]

  var body: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [
            colors.first?.opacity(0.44) ?? Color.white.opacity(0.44),
            colors.last?.opacity(0.22) ?? Color.orange.opacity(0.22),
            Color.clear,
          ],
          center: .center,
          startRadius: 0,
          endRadius: size / 2
        )
      )
      .frame(width: size, height: size)
      .rotationEffect(.degrees(105))
      .blur(radius: 1.5)
  }
}

private struct WeeklyAccessCountdownPill: View {
  let text: String

  var body: some View {
    ZStack {
      Capsule(style: .continuous)
        .fill(Color(hex: "FFEBD6"))
        .overlay(
          Capsule(style: .continuous)
            .stroke(Color(hex: "FF8904").opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Color(hex: "FDE7D1"), radius: 8, x: 0, y: 2)

      Ellipse()
        .fill(
          RadialGradient(
            colors: [
              Color.white.opacity(0.34),
              Color.white.opacity(0.11),
              Color.clear,
            ],
            center: .center,
            startRadius: 0,
            endRadius: 72
          )
        )
        .frame(width: 134, height: 39)

      Capsule(style: .continuous)
        .fill(Color.white.opacity(0.06))

      Text(text)
        .font(.custom("InstrumentSerif-Regular", size: 20.5))
        .foregroundStyle(Color(hex: "FF7856"))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(width: 142, height: 27, alignment: .center)
        .offset(y: -0.8)
    }
  }
}

private struct WeeklyAccessProgressBar: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var logoRotation = 0.0

  let progress: Double

  private let barWidth: CGFloat = 413.35
  private let barHeight: CGFloat = 8
  private let knobSize: CGFloat = 24

  var body: some View {
    let clampedProgress = min(max(progress, 0), 1)
    let knobOffset = barWidth * clampedProgress

    ZStack(alignment: .leading) {
      Capsule(style: .continuous)
        .fill(Color(hex: "EAE0DD"))
        .frame(width: barWidth, height: barHeight)
        .offset(x: knobSize / 2)

      LinearGradient(
        colors: [Color(hex: "C6D9FF"), Color(hex: "FF9A78")],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: max(0, knobOffset), height: barHeight)
      .clipShape(Capsule(style: .continuous))
      .offset(x: knobSize / 2)

      Circle()
        .fill(Color(hex: "FF6E00"))
        .frame(width: knobSize, height: knobSize)
        .overlay(
          Image("DayflowLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.white)
            .frame(width: 13.5, height: 13.5)
            .rotationEffect(.degrees(reduceMotion ? 0 : logoRotation))
        )
        .shadow(color: Color(hex: "FF6E00").opacity(0.18), radius: 5, x: 0, y: 2)
        .offset(x: knobOffset)
    }
    .frame(width: barWidth + knobSize, height: knobSize, alignment: .leading)
    .onAppear {
      startLogoRotationIfNeeded()
    }
    .onChange(of: reduceMotion) { _, shouldReduceMotion in
      if shouldReduceMotion {
        logoRotation = 0
      } else {
        startLogoRotationIfNeeded()
      }
    }
  }

  private func startLogoRotationIfNeeded() {
    guard !reduceMotion, logoRotation == 0 else { return }

    withAnimation(.linear(duration: 22).repeatForever(autoreverses: false)) {
      logoRotation = 360
    }
  }
}

private struct WeeklyAccessLockedBackground: View {
  var body: some View {
    ZStack {
      Color(hex: "FFF8F0").opacity(0.28)

      LinearGradient(
        colors: [
          Color.white.opacity(0.68),
          Color(hex: "FDF3EA").opacity(0.42),
          Color(hex: "FFE2C4").opacity(0.22),
        ],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
      )
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct WeeklyAccessPreviewBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isScrolledDown = false

  private static let designWidth: CGFloat = 958
  private static let sectionSpacing: CGFloat = 24
  private static let verticalPadding: CGFloat = 26
  private static let contentHeight: CGFloat =
    verticalPadding * 2
    + 300
    + sectionSpacing
    + 339
    + sectionSpacing
    + 328
    + sectionSpacing
    + 549
    + sectionSpacing
    + 548
    + sectionSpacing
    + 238
    + sectionSpacing
    + 427

  var body: some View {
    GeometryReader { geometry in
      let scale = previewScale(for: geometry.size)
      let scaledHeight = Self.contentHeight * scale
      let travel = scrollTravel(contentHeight: scaledHeight, viewportHeight: geometry.size.height)
      let yOffset =
        reduceMotion
        ? -travel * 0.32
        : (isScrolledDown ? -travel : geometry.size.height * 0.08)

      previewContent
        .frame(width: Self.designWidth, height: Self.contentHeight, alignment: .top)
        .scaleEffect(scale, anchor: .top)
        .frame(width: Self.designWidth * scale, height: scaledHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .center)
        .offset(y: yOffset)
        .opacity(0.46)
        .blur(radius: 2.2)
        .saturation(1.04)
        .allowsHitTesting(false)
        .onAppear {
          startScrollingIfNeeded()
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
          if shouldReduceMotion {
            isScrolledDown = false
          } else {
            startScrollingIfNeeded()
          }
        }
    }
    .clipped()
    .allowsHitTesting(false)
  }

  private var previewContent: some View {
    VStack(spacing: Self.sectionSpacing) {
      WeeklyDonutSection(snapshot: .figmaPreview, isLoading: false, width: Self.designWidth)
        .frame(width: Self.designWidth, height: 300, alignment: .topLeading)

      WeeklyOverviewSection(snapshot: .figmaPreview)
        .frame(width: Self.designWidth, height: 339, alignment: .topLeading)
        .clipped()

      WeeklyTreemapSection(snapshot: .figmaPreview)

      WeeklySankeySection(snapshot: .weeklyAccessPreview, showsControls: false)
        .frame(width: Self.designWidth, height: 548, alignment: .topLeading)
        .clipped()

      WeeklyFocusHeatmapSection(snapshot: .figmaPreview)

      WeeklyContextChartsSection(snapshot: .figmaPreview)
        .frame(width: Self.designWidth, height: 427, alignment: .topLeading)
    }
    .padding(.vertical, Self.verticalPadding)
  }

  private func previewScale(for size: CGSize) -> CGFloat {
    let availableWidth = max(320, size.width - 96)
    return min(0.95, max(0.58, availableWidth / Self.designWidth))
  }

  private func scrollTravel(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
    let availableTravel = contentHeight - viewportHeight + 180
    return max(96, min(availableTravel, 860))
  }

  private func startScrollingIfNeeded() {
    guard !reduceMotion, !isScrolledDown else { return }

    withAnimation(.linear(duration: 26).repeatForever(autoreverses: true)) {
      isScrolledDown = true
    }
  }
}

extension WeeklySankeySnapshot {
  fileprivate static let weeklyAccessPreview = WeeklySankeySnapshot(
    id: "weekly-access-preview",
    seedLabel: "Weekly preview",
    sourceName: "Weekly",
    categories: [
      .init(id: "research", name: "Research", minutes: 430, colorHex: "93BCFF"),
      .init(id: "communication", name: "Communication", minutes: 360, colorHex: "6CDACD"),
      .init(id: "design", name: "Design", minutes: 720, colorHex: "DE9DFC"),
      .init(id: "testing", name: "Testing", minutes: 240, colorHex: "FFA189"),
      .init(id: "distractions", name: "Distractions", minutes: 150, colorHex: "FF5950"),
      .init(id: "personal", name: "Personal", minutes: 180, colorHex: "FFC6B7"),
    ],
    apps: [
      .init(id: "chatgpt", name: "ChatGPT", minutes: 320, colorHex: "333333"),
      .init(id: "claude", name: "Claude", minutes: 250, colorHex: "D97757"),
      .init(id: "figma", name: "Figma", minutes: 720, colorHex: "FF7262"),
      .init(id: "slack", name: "Slack", minutes: 260, colorHex: "36C5F0"),
      .init(id: "zoom", name: "Zoom", minutes: 100, colorHex: "4085FD"),
      .init(id: "clickup", name: "ClickUp", minutes: 100, colorHex: "FD1BB9"),
      .init(id: "youtube", name: "YouTube", minutes: 110, colorHex: "FF0000"),
      .init(id: "other", name: "Other", minutes: 220, colorHex: "D9D9D9"),
    ],
    links: [
      .init(id: "research-chatgpt", from: "research", to: "chatgpt", minutes: 180),
      .init(id: "research-claude", from: "research", to: "claude", minutes: 150),
      .init(id: "research-figma", from: "research", to: "figma", minutes: 100),
      .init(id: "communication-slack", from: "communication", to: "slack", minutes: 260),
      .init(id: "communication-zoom", from: "communication", to: "zoom", minutes: 100),
      .init(id: "design-figma", from: "design", to: "figma", minutes: 520),
      .init(id: "design-claude", from: "design", to: "claude", minutes: 100),
      .init(id: "design-chatgpt", from: "design", to: "chatgpt", minutes: 100),
      .init(id: "testing-clickup", from: "testing", to: "clickup", minutes: 100),
      .init(id: "testing-figma", from: "testing", to: "figma", minutes: 100),
      .init(id: "testing-chatgpt", from: "testing", to: "chatgpt", minutes: 40),
      .init(id: "distractions-youtube", from: "distractions", to: "youtube", minutes: 110),
      .init(id: "distractions-other", from: "distractions", to: "other", minutes: 40),
      .init(id: "personal-other", from: "personal", to: "other", minutes: 180),
    ]
  )
}

#Preview("Weekly Access Locked", traits: .fixedLayout(width: 1024, height: 604)) {
  WeeklyAccessLockedView(
    accessProgress: WeeklyAccessProgressSnapshot(completedBatchCount: 34),
    notificationState: .idle,
    onNotify: {}
  )
}
