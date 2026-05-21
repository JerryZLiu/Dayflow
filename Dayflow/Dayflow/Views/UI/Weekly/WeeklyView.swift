import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct WeeklyView: View {
  @EnvironmentObject private var categoryStore: CategoryStore
  @Environment(\.scenePhase) private var scenePhase

  @AppStorage("weeklyAccessManuallyLocked") private var isManuallyLocked = false

  @State private var weekRange: WeeklyDateRange
  @State private var dashboardSnapshot: WeeklyDashboardSnapshot
  @State private var isLoading = true
  @State private var selectedWeekRecordedMinutes: Int?
  @State private var weeklyAccessProgress: WeeklyAccessProgressSnapshot
  @State private var notificationState: WeeklyAccessNotificationState = .idle

  init() {
    let initialWeekRange = WeeklyDateRange.containing(Date())
    let initialAccessProgress = WeeklyAccessProgressSnapshot(
      completedBatchCount: StorageManager.shared.countCompletedAnalysisBatchesForWeeklyAccess()
    )

    _weekRange = State(initialValue: initialWeekRange)
    _dashboardSnapshot = State(
      initialValue: WeeklyDashboardBuilder.build(
        cards: [],
        previousWeekCards: [],
        categories: [],
        weekRange: initialWeekRange
      )
    )
    _weeklyAccessProgress = State(initialValue: initialAccessProgress)
  }

  var body: some View {
    Group {
      if isWeeklyAccessUnlocked {
        weeklyDashboard
          .transition(.opacity)
          .task(id: weekRange) {
            await loadWeeklyData(for: weekRange, categories: categoryStore.categories)
          }
          .onChange(of: categoryStore.categories) { _, categories in
            Task {
              await loadWeeklyData(for: weekRange, categories: categories)
            }
          }
          .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
              await loadWeeklyData(for: weekRange, categories: categoryStore.categories)
            }
          }
      } else {
        WeeklyAccessLockedView(
          accessProgress: weeklyAccessProgress,
          notificationState: notificationState,
          onNotify: handleWeeklyNotifyAction
        )
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color(hex: "FBF6EF"))
    .environment(\.colorScheme, .light)
    .animation(.easeInOut(duration: 0.22), value: isWeeklyAccessUnlocked)
    .onAppear {
      refreshWeeklyAccessState()
      selectDefaultWeekOnEntry()
    }
    .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
      refreshWeeklyAccessState()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      refreshWeeklyAccessState()
    }
  }

  private var weeklyDashboard: some View {
    GeometryReader { geometry in
      let layout = WeeklyAdaptiveLayout(panelWidth: geometry.size.width)

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 0) {
          WeeklyHeader(
            title: weekRange.title,
            canNavigateForward: weekRange.canNavigateForward,
            onPrevious: showPreviousWeek,
            onNext: showNextWeek
          )
          .padding(.bottom, layout.headerBottomPadding)

          VStack(spacing: layout.sectionSpacing) {
            if shouldShowWeeklyDataGate {
              WeeklyDataRequirementView(
                recordedMinutes: selectedWeekRecordedMinutes ?? 0,
                targetMinutes: Self.weeklyDataRequirementMinutes
              )
              .frame(width: layout.contentWidth, height: WeeklyAdaptiveLayout.dataGateHeight)
            } else {
              topSummarySection(layout: layout)

              WeeklyExportableGraphic(
                layout: layout,
                title: "Weekly workflow",
                fileName: exportFileName("weekly-workflow"),
                displayHeight: WeeklyAdaptiveLayout.workflowHeight,
                exportHeight: WeeklyAdaptiveLayout.workflowHeight,
                watermarkPlacement: .bottomTrailing
              ) { width in
                WeeklyWorkflowSection(snapshot: dashboardSnapshot.workflow, width: width)
              }

              WeeklyExportableGraphic(
                layout: layout,
                title: "Focus heatmap",
                fileName: exportFileName("focus-heatmap"),
                displayHeight: WeeklyAdaptiveLayout.heatmapHeight,
                exportHeight: WeeklyAdaptiveLayout.heatmapHeight,
                watermarkPlacement: .bottomTrailing
              ) { width in
                WeeklyFocusHeatmapSection(snapshot: dashboardSnapshot.heatmap, width: width)
              }

              WeeklyExportableGraphic(
                layout: layout,
                title: "Focus breakdown",
                fileName: exportFileName("focus-breakdown"),
                displayHeight: WeeklyAdaptiveLayout.treemapHeight,
                exportHeight: WeeklyAdaptiveLayout.treemapHeight,
                watermarkPlacement: .bottomTrailing
              ) { width in
                WeeklyTreemapSection(snapshot: dashboardSnapshot.treemap, width: width)
              }

              WeeklyExportableGraphic(
                layout: layout,
                title: "Weekly breakdown",
                fileName: exportFileName("weekly-breakdown"),
                displayHeight: layout.sankeyHeight,
                exportHeight: WeeklyAdaptiveLayout.designSankeyHeight,
                watermarkPlacement: .bottomLeading
              ) { width in
                WeeklySankeySection(
                  snapshot: dashboardSnapshot.sankey,
                  showsControls: false,
                  width: width
                )
              }
            }
          }
          .frame(width: layout.contentWidth, alignment: .top)
        }
        .padding(.top, layout.topPadding)
        .padding(.bottom, layout.bottomPadding)
        .padding(.horizontal, layout.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private func topSummarySection(layout: WeeklyAdaptiveLayout) -> some View {
    if layout.usesTopRowColumns {
      HStack(alignment: .top, spacing: WeeklyAdaptiveLayout.topRowSpacing) {
        weeklyDistributionCard(layout: layout, width: layout.donutCardWidth)
        weeklyContextChartCard(layout: layout, width: layout.contextCardWidth)
      }
      .frame(width: layout.contentWidth, alignment: .topLeading)
    } else {
      VStack(spacing: layout.compactTopRowSpacing) {
        weeklyDistributionCard(layout: layout, width: layout.contentWidth)
        weeklyContextChartCard(layout: layout, width: layout.contentWidth)
      }
      .frame(width: layout.contentWidth, alignment: .topLeading)
    }
  }

  private func weeklyDistributionCard(
    layout: WeeklyAdaptiveLayout,
    width: CGFloat
  ) -> some View {
    WeeklyExportableFixedGraphic(
      availableWidth: width,
      title: "Weekly distribution",
      fileName: exportFileName("weekly-distribution"),
      designWidth: WeeklyAdaptiveLayout.donutCardWidth,
      designHeight: WeeklyAdaptiveLayout.topRowHeight,
      watermarkPlacement: .bottomTrailing
    ) { cardWidth in
      WeeklyDonutSection(
        snapshot: dashboardSnapshot.donut,
        isLoading: isLoading,
        width: cardWidth
      )
    }
  }

  private func weeklyContextChartCard(
    layout: WeeklyAdaptiveLayout,
    width: CGFloat
  ) -> some View {
    WeeklyExportableFixedGraphic(
      availableWidth: width,
      title: "Context charts",
      fileName: exportFileName("context-charts"),
      designWidth: WeeklyAdaptiveLayout.designContentWidth,
      designHeight: WeeklyAdaptiveLayout.topRowHeight,
      watermarkPlacement: .bottomTrailing
    ) { cardWidth in
      WeeklyContextChartsSection(
        snapshot: dashboardSnapshot.contextCharts,
        width: cardWidth
      )
    }
  }

  private static let weeklyDataRequirementMinutes = 15 * 60
  private static let defaultWeekSearchLimit = 52

  private var shouldShowWeeklyDataGate: Bool {
    guard let selectedWeekRecordedMinutes else { return false }
    return selectedWeekRecordedMinutes < Self.weeklyDataRequirementMinutes
  }

  private var isWeeklyAccessUnlocked: Bool {
    weeklyAccessProgress.isComplete && !isManuallyLocked
  }

  private func refreshWeeklyAccessState() {
    weeklyAccessProgress = WeeklyAccessProgressSnapshot(
      completedBatchCount: StorageManager.shared.countCompletedAnalysisBatchesForWeeklyAccess()
    )

    guard weeklyAccessProgress.isComplete, !isManuallyLocked else { return }

    NotificationService.shared.cancelWeeklyUnlockNotification()
  }

  private func selectDefaultWeekOnEntry() {
    guard isWeeklyAccessUnlocked else { return }

    let defaultRange = defaultWeekRangeOnEntry()
    guard defaultRange != weekRange else { return }

    weekRange = defaultRange
  }

  private func defaultWeekRangeOnEntry() -> WeeklyDateRange {
    var fallbackRangeWithData: WeeklyDateRange?
    var range = WeeklyDateRange.containing(Date())

    for _ in 0..<Self.defaultWeekSearchLimit {
      let recordedMinutes = Int(
        StorageManager.shared.fetchTotalMinutesTracked(
          from: range.weekStart,
          to: range.weekEnd
        ).rounded(.down)
      )

      if recordedMinutes >= Self.weeklyDataRequirementMinutes {
        return range
      }

      if fallbackRangeWithData == nil, recordedMinutes > 0 {
        fallbackRangeWithData = range
      }

      range = range.shifted(byWeeks: -1)
    }

    return fallbackRangeWithData ?? WeeklyDateRange.containing(Date())
  }

  private func handleWeeklyNotifyAction() {
    if weeklyAccessProgress.isComplete {
      NotificationService.shared.cancelWeeklyUnlockNotification()
      notificationState = .idle
      withAnimation(.easeInOut(duration: 0.22)) {
        isManuallyLocked = false
      }
      return
    }

    if notificationState == .denied {
      openNotificationSettings()
      return
    }

    guard notificationState != .requesting else { return }

    notificationState = .requesting

    Task {
      let result = await NotificationService.shared.scheduleWeeklyUnlockNotification(
        at: weeklyAccessProgress.estimatedUnlockDate(from: Date())
      )

      await MainActor.run {
        switch result {
        case .scheduled:
          notificationState = .scheduled
        case .denied:
          notificationState = .denied
        case .failed:
          notificationState = .failed
        }
      }
    }
  }

  private func openNotificationSettings() {
    let bundleID = Bundle.main.bundleIdentifier ?? "ai.dayflow.Dayflow"
    let settingsURLString =
      "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)"

    if let settingsURL = URL(string: settingsURLString) {
      _ = NSWorkspace.shared.open(settingsURL)
      return
    }

    if let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
    {
      _ = NSWorkspace.shared.open(fallbackURL)
    }
  }

  private func lockWeeklyAccess() {
    NotificationService.shared.cancelWeeklyUnlockNotification()
    notificationState = .idle
    weeklyAccessProgress = WeeklyAccessProgressSnapshot(
      completedBatchCount: StorageManager.shared.countCompletedAnalysisBatchesForWeeklyAccess()
    )

    withAnimation(.easeInOut(duration: 0.22)) {
      isManuallyLocked = true
    }
  }

  private func exportFileName(_ graphicSlug: String) -> String {
    let weekSlug = weekRange.title
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")

    return "dayflow-weekly-\(weekSlug)-\(graphicSlug).png"
  }

  private func showPreviousWeek() {
    weekRange = weekRange.shifted(byWeeks: -1)
  }

  private func showNextWeek() {
    guard weekRange.canNavigateForward else { return }
    weekRange = weekRange.shifted(byWeeks: 1)
  }

  @MainActor
  private func loadWeeklyData(
    for range: WeeklyDateRange,
    categories: [TimelineCategory]
  ) async {
    isLoading = true
    selectedWeekRecordedMinutes = nil

    let previousRange = range.shifted(byWeeks: -1)
    let cards = StorageManager.shared.fetchTimelineCardsByTimeRange(
      from: range.weekStart,
      to: range.weekEnd
    )
    let previousCards = StorageManager.shared.fetchTimelineCardsByTimeRange(
      from: previousRange.weekStart,
      to: previousRange.weekEnd
    )
    let snapshot = WeeklyDashboardBuilder.build(
      cards: cards,
      previousWeekCards: previousCards,
      categories: categories,
      weekRange: range
    )

    guard range == weekRange else { return }
    dashboardSnapshot = snapshot
    selectedWeekRecordedMinutes = snapshot.donut.totalMinutes
    isLoading = false
  }
}

private struct WeeklyDataRequirementView: View {
  let recordedMinutes: Int
  let targetMinutes: Int

  private var progress: Double {
    guard targetMinutes > 0 else { return 1 }
    return min(max(Double(recordedMinutes) / Double(targetMinutes), 0), 1)
  }

  private var recordedTimeText: String {
    "\(durationText(recordedMinutes)) / \(durationText(targetMinutes))"
  }

  private var remainingText: String {
    let remainingMinutes = max(targetMinutes - recordedMinutes, 0)
    return "\(durationText(remainingMinutes)) more to unlock this week"
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(hex: "FFF7EF"))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white, lineWidth: 1)
        )
        .shadow(color: Color(hex: "80450D").opacity(0.12), radius: 12, x: 0, y: 2)

      VStack(spacing: 18) {
        VStack(spacing: 5) {
          Text("Keep recording to unlock this week")
            .font(.custom("InstrumentSerif-Regular", size: 24))
            .foregroundStyle(Color(hex: "333333"))

          Text("Weekly insights need at least 15 hours of recorded activity for the selected week.")
            .font(.custom("Figtree-Regular", size: 14))
            .foregroundStyle(Color(hex: "796E64"))
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }

        WeeklyDataRequirementPill(text: recordedTimeText)

        WeeklyDataRequirementProgressBar(progress: progress)

        Text(remainingText)
          .font(.custom("Figtree-Medium", size: 13))
          .foregroundStyle(Color(hex: "8A7768"))
      }
      .padding(.horizontal, 28)
      .frame(maxWidth: 540)
    }
  }

  private func durationText(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if minutes <= 0 {
      return "0h"
    }

    if hours == 0 {
      return "\(remainingMinutes)m"
    }

    if remainingMinutes == 0 {
      return "\(hours)h"
    }

    return "\(hours)h \(remainingMinutes)m"
  }
}

private struct WeeklyDataRequirementPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.custom("InstrumentSerif-Regular", size: 22))
      .foregroundStyle(Color(hex: "FF7856"))
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .padding(.horizontal, 24)
      .frame(height: 58)
      .background(
        Capsule(style: .continuous)
          .fill(Color(hex: "FFEBD6"))
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(Color(hex: "FF8904").opacity(0.5), lineWidth: 1)
      )
      .shadow(color: Color(hex: "FDE7D1"), radius: 8, x: 0, y: 2)
  }
}

private struct WeeklyDataRequirementProgressBar: View {
  let progress: Double

  var body: some View {
    GeometryReader { geometry in
      let clampedProgress = min(max(progress, 0), 1)
      let filledWidth = geometry.size.width * clampedProgress

      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(Color(hex: "EAE0DD"))

        LinearGradient(
          colors: [Color(hex: "C6D9FF"), Color(hex: "FF9A78")],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: filledWidth)
        .clipShape(Capsule(style: .continuous))

        Circle()
          .fill(Color(hex: "FF6E00"))
          .frame(width: 24, height: 24)
          .overlay(
            Image("DayflowLogo")
              .renderingMode(.template)
              .resizable()
              .scaledToFit()
              .foregroundStyle(Color.white)
              .frame(width: 13.5, height: 13.5)
          )
          .shadow(color: Color(hex: "FF6E00").opacity(0.18), radius: 5, x: 0, y: 2)
          .offset(x: max(0, min(geometry.size.width - 24, filledWidth - 12)))
      }
    }
    .frame(width: 420, height: 24)
  }
}

private struct WeeklyAdaptiveLayout {
  static let designContentWidth: CGFloat = 958
  static let donutCardWidth: CGFloat = 461
  static let topRowHeight: CGFloat = 300
  static let topRowSpacing: CGFloat = 27
  static let workflowHeight: CGFloat = 292
  static let suggestionsHeight: CGFloat = 328
  static let treemapHeight: CGFloat = 549
  static let heatmapHeight: CGFloat = 238
  static let dataGateHeight: CGFloat = 360
  static let designSankeyHeight: CGFloat = designContentWidth * 933 / 1748
  static let maximumContentWidth: CGFloat = 1500

  let panelWidth: CGFloat

  var horizontalPadding: CGFloat {
    min(56, max(24, panelWidth * 0.03))
  }

  private var rawContentWidth: CGFloat {
    max(1, panelWidth - horizontalPadding * 2)
  }

  var contentWidth: CGFloat {
    min(Self.maximumContentWidth, rawContentWidth)
  }

  var donutCardWidth: CGFloat {
    let idealWidth = floor((contentWidth - Self.topRowSpacing) * 0.44)
    return min(620, max(Self.donutCardWidth, idealWidth))
  }

  var contextCardWidth: CGFloat {
    max(1, contentWidth - Self.topRowSpacing - donutCardWidth)
  }

  var sankeyHeight: CGFloat {
    contentWidth * 933 / 1748
  }

  var sectionSpacing: CGFloat {
    24
  }

  var compactTopRowSpacing: CGFloat {
    18
  }

  var headerBottomPadding: CGFloat {
    16
  }

  var topPadding: CGFloat {
    28
  }

  var bottomPadding: CGFloat {
    48
  }

  var usesTopRowColumns: Bool {
    rawContentWidth >= Self.designContentWidth
  }
}

private struct WeeklyExportableGraphic<Content: View>: View {
  let layout: WeeklyAdaptiveLayout
  let title: String
  let fileName: String
  let displayHeight: CGFloat
  let exportHeight: CGFloat
  let watermarkPlacement: WeeklyExportWatermarkPlacement
  let content: (CGFloat) -> Content

  init(
    layout: WeeklyAdaptiveLayout,
    title: String,
    fileName: String,
    displayHeight: CGFloat,
    exportHeight: CGFloat,
    watermarkPlacement: WeeklyExportWatermarkPlacement,
    @ViewBuilder content: @escaping (CGFloat) -> Content
  ) {
    self.layout = layout
    self.title = title
    self.fileName = fileName
    self.displayHeight = displayHeight
    self.exportHeight = exportHeight
    self.watermarkPlacement = watermarkPlacement
    self.content = content
  }

  var body: some View {
    content(layout.contentWidth)
      .frame(
        width: layout.contentWidth,
        height: displayHeight,
        alignment: .topLeading
      )
      .frame(
        width: layout.contentWidth,
        height: displayHeight,
        alignment: .topLeading
      )
  }
}

private struct WeeklyExportableFixedGraphic<Content: View>: View {
  let availableWidth: CGFloat
  let title: String
  let fileName: String
  let designWidth: CGFloat
  let designHeight: CGFloat
  let watermarkPlacement: WeeklyExportWatermarkPlacement
  let content: (CGFloat) -> Content

  init(
    availableWidth: CGFloat,
    title: String,
    fileName: String,
    designWidth: CGFloat,
    designHeight: CGFloat,
    watermarkPlacement: WeeklyExportWatermarkPlacement,
    @ViewBuilder content: @escaping (CGFloat) -> Content
  ) {
    self.availableWidth = availableWidth
    self.title = title
    self.fileName = fileName
    self.designWidth = designWidth
    self.designHeight = designHeight
    self.watermarkPlacement = watermarkPlacement
    self.content = content
  }

  var body: some View {
    content(availableWidth)
      .frame(width: availableWidth, height: designHeight, alignment: .topLeading)
      .frame(
        width: availableWidth,
        height: designHeight,
        alignment: .topLeading
      )
  }
}

private struct WeeklyGraphicDownloadButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "arrow.down.circle")
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(Color(hex: "B46531"))
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Download \(title) as a full-resolution PNG")
    .hoverScaleEffect(scale: 1.03)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }
}

@MainActor
private enum WeeklyGraphicExporter {
  private static let targetPixelWidth: CGFloat = 1080

  static func savePNG<Content: View>(
    fileName: String,
    size: CGSize,
    watermarkPlacement: WeeklyExportWatermarkPlacement,
    @ViewBuilder content: () -> Content
  ) {
    let exportView = content()
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      .background(Color(hex: "FBF6EF"))
      .overlay(alignment: watermarkPlacement.alignment) {
        WeeklyExportWatermark()
          .padding(watermarkPlacement.padding)
      }
      .environment(\.colorScheme, .light)

    let renderer = ImageRenderer(content: exportView)
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = targetPixelWidth / size.width

    guard let image = renderer.cgImage else {
      NSSound.beep()
      return
    }

    let savePanel = NSSavePanel()
    savePanel.title = "Download graphic"
    savePanel.prompt = "Download"
    savePanel.nameFieldStringValue = fileName
    savePanel.allowedContentTypes = [.png]
    savePanel.canCreateDirectories = true

    guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      NSSound.beep()
      return
    }

    CGImageDestinationAddImage(destination, image, nil)

    if !CGImageDestinationFinalize(destination) {
      NSSound.beep()
    }
  }
}

private enum WeeklyExportWatermarkPlacement {
  case topLeading
  case topTrailing
  case bottomLeading
  case bottomTrailing

  var alignment: Alignment {
    switch self {
    case .topLeading:
      return .topLeading
    case .topTrailing:
      return .topTrailing
    case .bottomLeading:
      return .bottomLeading
    case .bottomTrailing:
      return .bottomTrailing
    }
  }

  var padding: EdgeInsets {
    switch self {
    case .topLeading:
      return EdgeInsets(top: 14, leading: 14, bottom: 0, trailing: 0)
    case .topTrailing:
      return EdgeInsets(top: 14, leading: 0, bottom: 0, trailing: 14)
    case .bottomLeading:
      return EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 0)
    case .bottomTrailing:
      return EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 14)
    }
  }
}

private struct WeeklyExportWatermark: View {
  var body: some View {
    HStack(spacing: 6) {
      Image("DayflowLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 16, height: 16)

      WeeklyGeneratedWithDayflowText()
    }
    .padding(.leading, 7)
    .padding(.trailing, 9)
    .frame(height: 26)
    .background(
      Capsule(style: .continuous)
        .fill(Color.white.opacity(0.94))
    )
    .overlay(
      Capsule(style: .continuous)
        .stroke(Color(hex: "EBE6E3"), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)
  }
}

private struct WeeklyGeneratedWithDayflowText: View {
  var body: some View {
    HStack(spacing: 3) {
      Text("Generated with")
        .font(.custom("Figtree-SemiBold", size: 10))
        .foregroundStyle(Color(hex: "786A61"))

      Text("Dayflow")
        .font(.custom("Figtree-Bold", size: 10))
        .foregroundStyle(Color(hex: "B46531"))
    }
  }
}

#Preview("Weekly View", traits: .fixedLayout(width: 1119, height: 920)) {
  WeeklyView()
    .environmentObject(CategoryStore.shared)
}
