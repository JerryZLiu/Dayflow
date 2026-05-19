import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DayGoalFlowInitialScreen: String {
  case review
  case setup
}

struct DayGoalSetupReferenceStats: Equatable, Sendable {
  enum Period: Sendable {
    case yesterday
    case lastWeekAverage
  }

  var yesterdayByCategoryID: [String: TimeInterval]
  var yesterdayByCategoryName: [String: TimeInterval]
  var lastWeekAverageByCategoryID: [String: TimeInterval]
  var lastWeekAverageByCategoryName: [String: TimeInterval]

  static let empty = DayGoalSetupReferenceStats(
    yesterdayByCategoryID: [:],
    yesterdayByCategoryName: [:],
    lastWeekAverageByCategoryID: [:],
    lastWeekAverageByCategoryName: [:]
  )

  func minutes(for snapshots: [DayGoalCategorySnapshot], period: Period) -> Int {
    let duration: TimeInterval
    switch period {
    case .yesterday:
      duration = totalDuration(
        for: snapshots,
        byID: yesterdayByCategoryID,
        byName: yesterdayByCategoryName
      )
    case .lastWeekAverage:
      duration = totalDuration(
        for: snapshots,
        byID: lastWeekAverageByCategoryID,
        byName: lastWeekAverageByCategoryName
      )
    }
    return max(0, Int(duration / 60))
  }

  private func totalDuration(
    for snapshots: [DayGoalCategorySnapshot],
    byID: [String: TimeInterval],
    byName: [String: TimeInterval]
  ) -> TimeInterval {
    snapshots.reduce(0) { total, snapshot in
      let duration =
        byID[snapshot.categoryID]
        ?? byName[Self.normalized(snapshot.name), default: 0]
      return total + duration
    }
  }

  private static func normalized(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

struct DayGoalFlowPresentation: Identifiable {
  let id = UUID()
  let review: DayGoalReviewSnapshot
  let plan: DayGoalPlan
  let categories: [TimelineCategory]
  let setupReferenceStats: DayGoalSetupReferenceStats
  let initialScreen: DayGoalFlowInitialScreen
  var onSkip: () -> Void
  var onConfirm: (DayGoalPlan) -> Void
  var onSetupStarted: () -> Void
  var onCategoryToggled: (DayGoalCategoryKind, String, DayGoalPlan) -> Void
}

private struct GoalSetupStatPair {
  let yesterdayMinutes: Int
  let lastWeekAverageMinutes: Int

  var scaleMaxMinutes: Int {
    max(yesterdayMinutes, lastWeekAverageMinutes)
  }
}

struct DayGoalFlowOverlay: View {
  let presentation: DayGoalFlowPresentation
  var onDismiss: () -> Void

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color(hex: "DB420B").opacity(0.10)
          .ignoresSafeArea()

        DayGoalFlowView(
          review: presentation.review,
          plan: presentation.plan,
          categories: presentation.categories,
          setupReferenceStats: presentation.setupReferenceStats,
          initialScreen: presentation.initialScreen,
          onSkip: {
            presentation.onSkip()
            onDismiss()
          },
          onConfirm: { plan in
            presentation.onConfirm(plan)
            onDismiss()
          },
          onSetupStarted: presentation.onSetupStarted,
          onCategoryToggled: presentation.onCategoryToggled
        )
        .frame(width: proxy.size.width, height: proxy.size.height)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .contentShape(Rectangle())
      .ignoresSafeArea()
    }
    .ignoresSafeArea()
  }
}

struct DayGoalFlowView: View {
  let review: DayGoalReviewSnapshot
  let categories: [TimelineCategory]
  let setupReferenceStats: DayGoalSetupReferenceStats
  let initialScreen: DayGoalFlowInitialScreen
  var onSkip: () -> Void
  var onConfirm: (DayGoalPlan) -> Void
  var onSetupStarted: () -> Void
  var onCategoryToggled: (DayGoalCategoryKind, String, DayGoalPlan) -> Void

  @State private var screen: DayGoalFlowInitialScreen
  @State private var draft: DayGoalPlan

  init(
    review: DayGoalReviewSnapshot,
    plan: DayGoalPlan,
    categories: [TimelineCategory],
    setupReferenceStats: DayGoalSetupReferenceStats = .empty,
    initialScreen: DayGoalFlowInitialScreen = .review,
    onSkip: @escaping () -> Void,
    onConfirm: @escaping (DayGoalPlan) -> Void,
    onSetupStarted: @escaping () -> Void,
    onCategoryToggled: @escaping (DayGoalCategoryKind, String, DayGoalPlan) -> Void
  ) {
    self.review = review
    self.categories = categories
    self.setupReferenceStats = setupReferenceStats
    self.initialScreen = initialScreen
    self.onSkip = onSkip
    self.onConfirm = onConfirm
    self.onSetupStarted = onSetupStarted
    self.onCategoryToggled = onCategoryToggled
    _screen = State(initialValue: initialScreen)
    _draft = State(initialValue: plan)
  }

  private enum Design {
    static let canvasSize = CGSize(width: 1200, height: 680)
    static let backgroundTop = Color(hex: "FFF3EC")
    static let backgroundBottom = Color(hex: "FF8046").opacity(0.78)
    static let orange = Color(hex: "FF8046")
    static let mutedOrange = Color(hex: "FFEDE4")
    static let mutedBorder = Color(hex: "B1A8A1")
    static let text = Color(hex: "333333")
    static let focus = Color(hex: "628CFF")
    static let distraction = Color(hex: "FA8282")
  }

  var body: some View {
    GeometryReader { geometry in
      let scale = canvasScale(for: geometry.size)

      ZStack {
        switch screen {
        case .review:
          reviewScreen
        case .setup:
          setupScreen
        }
      }
      .frame(width: Design.canvasSize.width, height: Design.canvasSize.height)
      .scaleEffect(scale)
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
    }
  }

  private func canvasScale(for size: CGSize) -> CGFloat {
    let margin: CGFloat = 24
    let availableWidth = max(1, size.width - (margin * 2))
    let availableHeight = max(1, size.height - (margin * 2))
    return min(
      1,
      availableWidth / Design.canvasSize.width,
      availableHeight / Design.canvasSize.height
    )
  }

  private var reviewScreen: some View {
    ZStack(alignment: .topLeading) {
      Text("Yesterday’s review")
        .font(.custom("Instrument Serif", size: 36))
        .foregroundColor(Design.text)
        .tracking(-1.08)
        .multilineTextAlignment(.center)
        .frame(width: 346, height: 44)
        .position(x: 592.4, y: 125)

      GoalReviewCard(
        kind: .focus,
        title: "Focus target: \(formatDuration(review.plan.focusTargetDuration))",
        subtitle: "Time spent: \(formatDuration(review.focusDuration))",
        targetDuration: review.plan.focusTargetDuration,
        actualDuration: review.focusDuration,
        categories: review.focusCategories
      )
      .frame(width: 388, height: 236)
      .position(x: 600, y: 297)

      GoalReviewCard(
        kind: .distraction,
        title: "Distraction limit: \(formatDuration(review.plan.distractionLimitDuration))",
        subtitle: "Time spent distracted: \(formatDuration(review.distractedDuration))",
        targetDuration: review.plan.distractionLimitDuration,
        actualDuration: review.distractedDuration,
        categories: []
      )
      .frame(width: 388, height: 123)
      .position(x: 600, y: 491.5)

      primaryButton("Set today’s goals") {
        onSetupStarted()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
          screen = .setup
        }
      }
      .position(x: 597.35, y: 615)
    }
  }

  private var setupScreen: some View {
    let focusStats = setupStats(for: .focus)
    let distractionStats = setupStats(for: .distraction)

    return ZStack(alignment: .topLeading) {
      Text("Where do you want to spend your time today?")
        .font(.custom("Instrument Serif", size: 24))
        .foregroundColor(.black)
        .multilineTextAlignment(.center)
        .frame(width: 620, height: 30)
        .position(x: 602, y: 64)

      GoalCategoryPool(
        categories: unassignedCategories,
        focusIDs: Set(draft.focusCategories.map(\.categoryID)),
        distractionIDs: Set(draft.distractionCategories.map(\.categoryID)),
        onCycle: cycleCategoryAssignment
      )
      .frame(width: 804, height: 87)
      .position(x: 601.86, y: 171.5)

      GoalSetupPanel(
        kind: .focus,
        title: "Focus goal",
        durationMinutes: $draft.focusTargetMinutes,
        leadingStatTitle: "Yesterday’s focus",
        leadingStatMinutes: focusStats.yesterdayMinutes,
        trailingStatTitle: "Last week’s Focus average",
        trailingStatMinutes: focusStats.lastWeekAverageMinutes,
        statScaleMaxMinutes: focusStats.scaleMaxMinutes,
        selectedCategories: resolvedSnapshots(for: .focus),
        onRemoveCategory: { removeCategoryFromPanel($0, from: .focus) },
        onDropCategory: { moveCategoryFromDrop($0, to: .focus) }
      )
      .frame(width: 396, height: 321)
      .position(x: 397.86, y: 384.5)

      GoalSetupPanel(
        kind: .distraction,
        title: "Distraction limit",
        durationMinutes: $draft.distractionLimitMinutes,
        leadingStatTitle: "Yesterday’s Distractions",
        leadingStatMinutes: distractionStats.yesterdayMinutes,
        trailingStatTitle: "Last week’s Distraction average",
        trailingStatMinutes: distractionStats.lastWeekAverageMinutes,
        statScaleMaxMinutes: distractionStats.scaleMaxMinutes,
        selectedCategories: resolvedSnapshots(for: .distraction),
        onRemoveCategory: { removeCategoryFromPanel($0, from: .distraction) },
        onDropCategory: { moveCategoryFromDrop($0, to: .distraction) }
      )
      .frame(width: 400.28, height: 323)
      .position(x: 804, y: 385.5)

      HStack(spacing: 10) {
        secondaryButton("Skip today", action: onSkip)

        primaryButton("Confirm") {
          var plan = draft
          plan.isSkipped = false
          let now = Int(Date().timeIntervalSince1970)
          if plan.createdAt <= 0 {
            plan.createdAt = now
          }
          plan.updatedAt = now
          onConfirm(plan)
        }
      }
      .position(x: 607.45, y: 617)
    }
  }

  private var selectableCategories: [TimelineCategory] {
    categories
      .filter { $0.isSystem == false && $0.isIdle == false }
      .sorted { $0.order < $1.order }
  }

  private var unassignedCategories: [TimelineCategory] {
    let assignedSnapshots = draft.focusCategories + draft.distractionCategories
    let assignedIDs = Set(assignedSnapshots.map(\.categoryID))
    let assignedNames = Set(assignedSnapshots.map { normalizedCategoryName($0.name) })
    return selectableCategories.filter { category in
      assignedIDs.contains(category.id.uuidString) == false
        && assignedNames.contains(normalizedCategoryName(category.name)) == false
    }
  }

  private func resolvedSnapshots(for kind: DayGoalCategoryKind) -> [DayGoalCategorySnapshot] {
    draft.categorySnapshots(for: kind)
      .map(resolveSnapshot)
      .sorted { $0.sortOrder < $1.sortOrder }
  }

  private func setupStats(for kind: DayGoalCategoryKind) -> GoalSetupStatPair {
    let snapshots = resolvedSnapshots(for: kind)
    return GoalSetupStatPair(
      yesterdayMinutes: setupReferenceStats.minutes(for: snapshots, period: .yesterday),
      lastWeekAverageMinutes: setupReferenceStats.minutes(
        for: snapshots,
        period: .lastWeekAverage
      )
    )
  }

  private func resolveSnapshot(_ snapshot: DayGoalCategorySnapshot) -> DayGoalCategorySnapshot {
    guard let current = currentCategory(for: snapshot)
    else {
      return snapshot
    }
    return DayGoalCategorySnapshot(
      categoryID: current.id.uuidString,
      name: current.name,
      colorHex: current.colorHex,
      sortOrder: snapshot.sortOrder
    )
  }

  private func currentCategory(for snapshot: DayGoalCategorySnapshot) -> TimelineCategory? {
    selectableCategories.first(where: { $0.id.uuidString == snapshot.categoryID })
      ?? selectableCategories.first {
        normalizedCategoryName($0.name) == normalizedCategoryName(snapshot.name)
      }
  }

  private func normalizedCategoryName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func cycleCategoryAssignment(_ category: TimelineCategory) {
    let id = category.id.uuidString
    let focusIDs = Set(draft.focusCategories.map(\.categoryID))
    let distractionIDs = Set(draft.distractionCategories.map(\.categoryID))

    if focusIDs.contains(id) {
      removeCategory(id, from: .focus)
      addCategory(category, to: .distraction)
      onCategoryToggled(.distraction, "moved_to_distraction", draft)
    } else if distractionIDs.contains(id) {
      removeCategory(id, from: .distraction)
      onCategoryToggled(.distraction, "removed", draft)
    } else {
      addCategory(category, to: .focus)
      onCategoryToggled(.focus, "added", draft)
    }
  }

  private func addCategory(_ category: TimelineCategory, to kind: DayGoalCategoryKind) {
    removeCategory(category.id.uuidString, from: .focus)
    removeCategory(category.id.uuidString, from: .distraction)

    switch kind {
    case .focus:
      draft.focusCategories.append(
        DayGoalCategorySnapshot(category: category, sortOrder: draft.focusCategories.count)
      )
    case .distraction:
      draft.distractionCategories.append(
        DayGoalCategorySnapshot(category: category, sortOrder: draft.distractionCategories.count)
      )
    }
    normalizeSortOrders()
  }

  private func moveCategory(_ categoryID: String, to kind: DayGoalCategoryKind) {
    let draggedSnapshot = (draft.focusCategories + draft.distractionCategories)
      .first { $0.categoryID == categoryID }
    let category =
      selectableCategories.first(where: { $0.id.uuidString == categoryID })
      ?? draggedSnapshot.flatMap(currentCategory)
    guard let category
    else {
      return
    }
    addCategory(category, to: kind)
  }

  private func removeCategoryFromPanel(_ categoryID: String, from kind: DayGoalCategoryKind) {
    let before = draft
    removeCategory(categoryID, from: kind)
    guard before != draft else { return }
    onCategoryToggled(kind, "removed", draft)
  }

  private func moveCategoryFromDrop(_ categoryID: String, to kind: DayGoalCategoryKind) {
    let before = draft
    let previousKind = assignmentKind(for: categoryID)
    moveCategory(categoryID, to: kind)
    guard before != draft else { return }
    let action = previousKind == nil ? "dropped" : "moved"
    onCategoryToggled(kind, action, draft)
  }

  private func assignmentKind(for categoryID: String) -> DayGoalCategoryKind? {
    if draft.focusCategories.contains(where: { $0.categoryID == categoryID }) {
      return .focus
    }
    if draft.distractionCategories.contains(where: { $0.categoryID == categoryID }) {
      return .distraction
    }
    return nil
  }

  private func removeCategory(_ categoryID: String, from kind: DayGoalCategoryKind) {
    switch kind {
    case .focus:
      draft.focusCategories.removeAll { $0.categoryID == categoryID }
    case .distraction:
      draft.distractionCategories.removeAll { $0.categoryID == categoryID }
    }
    normalizeSortOrders()
  }

  private func normalizeSortOrders() {
    draft.focusCategories = draft.focusCategories.enumerated().map { index, snapshot in
      DayGoalCategorySnapshot(
        categoryID: snapshot.categoryID,
        name: snapshot.name,
        colorHex: snapshot.colorHex,
        sortOrder: index
      )
    }
    draft.distractionCategories = draft.distractionCategories.enumerated().map { index, snapshot in
      DayGoalCategorySnapshot(
        categoryID: snapshot.categoryID,
        name: snapshot.name,
        colorHex: snapshot.colorHex,
        sortOrder: index
      )
    }
  }

  private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Figtree", size: 13).weight(.medium))
        .foregroundColor(.white)
        .lineLimit(1)
        .frame(width: 120, height: 36)
        .background(Design.orange)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }

  private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Figtree", size: 13).weight(.medium))
        .foregroundColor(Design.mutedBorder)
        .lineLimit(1)
        .frame(width: 120, height: 36)
        .background(Design.mutedOrange)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Design.mutedBorder, lineWidth: 1)
        )
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    let totalMinutes = max(0, Int(duration / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 && minutes > 0 {
      return "\(hours) hours \(minutes) minutes"
    }
    if hours > 0 {
      return hours == 1 ? "1 hour" : "\(hours) hours"
    }
    return "\(minutes) minutes"
  }

}

private struct GoalCategoryPool: View {
  let categories: [TimelineCategory]
  let focusIDs: Set<String>
  let distractionIDs: Set<String>
  var onCycle: (TimelineCategory) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Drag and drop to set the categories you want to track")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color(hex: "5E5E5E"))

      DayGoalFlowLayout(spacing: 8, rowSpacing: 6) {
        ForEach(categories) { category in
          Button {
            onCycle(category)
          } label: {
            GoalCategoryChip(
              title: category.name,
              colorHex: category.colorHex,
              status: status(for: category)
            )
          }
          .buttonStyle(.plain)
          .onDrag {
            NSItemProvider(object: category.id.uuidString as NSString)
          }
          .pointingHandCursor()
          .help(
            "Drag into a goal panel, or click to cycle between Focus, Distraction, and untracked")
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(hex: "FCFCFC").opacity(0.76))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(hex: "E7DFDF"), lineWidth: 1)
    )
  }

  private func status(for category: TimelineCategory) -> GoalCategoryChip.Status {
    let id = category.id.uuidString
    if focusIDs.contains(id) {
      return .focus
    }
    if distractionIDs.contains(id) {
      return .distraction
    }
    return .untracked
  }
}

private struct GoalSetupPanel: View {
  let kind: DayGoalCategoryKind
  let title: String
  @Binding var durationMinutes: Int
  let leadingStatTitle: String
  let leadingStatMinutes: Int
  let trailingStatTitle: String
  let trailingStatMinutes: Int
  let statScaleMaxMinutes: Int
  let selectedCategories: [DayGoalCategorySnapshot]
  var onRemoveCategory: (String) -> Void
  var onDropCategory: (String) -> Void

  private var accent: Color {
    switch kind {
    case .focus:
      return Color(hex: "628CFF")
    case .distraction:
      return Color(hex: "FA8282")
    }
  }

  private var iconName: String {
    switch kind {
    case .focus:
      return "DayGoalFocus"
    case .distraction:
      return "DayGoalDistraction"
    }
  }

  private var panelWidth: CGFloat {
    switch kind {
    case .focus:
      return 396
    case .distraction:
      return 400.28
    }
  }

  private var statColumnWidth: CGFloat {
    (panelWidth - 32 - 18) / 2
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(iconName)
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)

        Text(title)
          .font(.custom("Figtree", size: 14))
          .foregroundColor(.white)

        Spacer()
      }
      .padding(.horizontal, 11)
      .frame(height: 30)
      .background(accent)

      HStack(spacing: 10) {
        categoryBox
          .frame(width: 140, height: 187)

        GoalDurationPicker(minutes: $durationMinutes)
          .frame(width: 192, height: 187)
      }
      .padding(.top, 21)
      .padding(.bottom, 23)
      .padding(.horizontal, 24)
      .frame(maxWidth: .infinity)
      .background(Color.white.opacity(0.8))

      footer
        .frame(height: 59)
    }
    .frame(width: panelWidth)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(hex: "E7DFDF"), lineWidth: 1)
    )
  }

  private var categoryBox: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Categories")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color(hex: "7A7A7A"))

      VStack(alignment: .leading, spacing: 6) {
        ForEach(selectedCategories) { category in
          Button {
            onRemoveCategory(category.categoryID)
          } label: {
            GoalCategoryChip(
              title: category.name,
              colorHex: category.colorHex,
              status: kind == .focus ? .focus : .distraction,
              showsRemove: true
            )
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }
      }
      Spacer(minLength: 0)
    }
    .padding(11)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(hex: "F8F6F5"))
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color(hex: "E6DDD5"), lineWidth: 1)
    )
    .onDrop(of: [.plainText], isTargeted: nil, perform: handleCategoryDrop)
  }

  private func handleCategoryDrop(_ providers: [NSItemProvider]) -> Bool {
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
      })
    else {
      return false
    }

    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
      let categoryID: String?
      if let data = item as? Data {
        categoryID = String(data: data, encoding: .utf8)
      } else if let string = item as? String {
        categoryID = string
      } else if let nsString = item as? NSString {
        categoryID = String(nsString)
      } else {
        categoryID = nil
      }

      guard let categoryID else { return }
      Task { @MainActor in
        onDropCategory(categoryID)
      }
    }
    return true
  }

  private var footer: some View {
    HStack(spacing: 18) {
      goalStat(title: leadingStatTitle, minutes: leadingStatMinutes)
        .frame(width: statColumnWidth, alignment: .leading)
      goalStat(title: trailingStatTitle, minutes: trailingStatMinutes)
        .frame(width: statColumnWidth, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Color(hex: "FCFCFC").opacity(0.7))
  }

  private func goalStat(title: String, minutes: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.custom("Figtree", size: 12))
        .foregroundColor(.black)
        .lineLimit(1)
        .minimumScaleFactor(0.82)

      HStack(spacing: 5) {
        RoundedRectangle(cornerRadius: 20)
          .fill(accent)
          .frame(width: statBarWidth(minutes: minutes), height: 6)

        Text(formatShort(minutes: minutes))
          .font(.custom("Figtree", size: 12))
          .foregroundColor(.black)
          .lineLimit(1)
          .minimumScaleFactor(0.86)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func formatShort(minutes: Int) -> String {
    let hours = minutes / 60
    let mins = minutes % 60
    if hours > 0 && mins == 0 {
      return "\(hours) hours"
    }
    if hours > 0 {
      return "\(hours)h \(mins)m"
    }
    return "\(mins)m"
  }

  private func statBarWidth(minutes: Int) -> CGFloat {
    guard minutes > 0, statScaleMaxMinutes > 0 else { return 0 }
    let ratio = min(max(CGFloat(minutes) / CGFloat(statScaleMaxMinutes), 0), 1)
    return max(12, 86 * ratio)
  }
}

private struct GoalDurationPicker: View {
  @Binding var minutes: Int

  private var hoursBinding: Binding<Int> {
    Binding(
      get: { max(0, minutes / 60) },
      set: { newHours in
        minutes = max(0, min(12 * 60, newHours * 60 + minutes % 60))
      }
    )
  }

  private var minuteBinding: Binding<Int> {
    Binding(
      get: { minutes % 60 },
      set: { newMinutes in
        minutes = max(0, min(12 * 60, (minutes / 60) * 60 + newMinutes))
      }
    )
  }

  var body: some View {
    HStack(spacing: 6) {
      GoalNumberColumn(
        value: hoursBinding,
        range: 0...12,
        label: "Hours",
        step: 1,
        numberStackLeft: 5.25,
        numberStackTop: 12.89,
        labelLeft: 41.5
      )

      GoalNumberColumn(
        value: minuteBinding,
        range: 0...55,
        label: "Mins",
        step: 5,
        numberStackLeft: 5.25,
        numberStackTop: 11.89,
        labelLeft: 47
      )
    }
    .padding(EdgeInsets(top: 7, leading: 9, bottom: 10, trailing: 11))
    .background(Color(hex: "F1F1F1"))
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color(hex: "E6DDD5"), lineWidth: 1)
    )
  }
}

private struct GoalNumberColumn: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @Binding var value: Int
  let range: ClosedRange<Int>
  let label: String
  let step: Int
  let numberStackLeft: CGFloat
  let numberStackTop: CGFloat
  let labelLeft: CGFloat
  @State private var dragStartValue: Int?
  @State private var scrollAccumulator: CGFloat = 0
  @State private var wheelOffset: CGFloat = 0

  private let rowStride: CGFloat = 29

  var body: some View {
    ZStack(alignment: .topLeading) {
      VStack(spacing: 6) {
        wheelRow(offset: -2, size: 21, color: Color(hex: "AAA6A3"))
        wheelRow(offset: -1, size: 23, color: Color(hex: "8A8582"))
        wheelRow(offset: 0, size: 25, color: .black)
        wheelRow(offset: 1, size: 23, color: Color(hex: "8A8582"))
        wheelRow(offset: 2, size: 21, color: Color(hex: "AAA6A3"))
      }
      .frame(width: numberStackWidth)
      .offset(x: numberStackLeft, y: numberStackTop + wheelOffset)

      Text(label)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black)
        .lineLimit(1)
        .frame(width: labelWidth, alignment: .leading)
        .offset(x: labelLeft, y: 72)

      VStack(spacing: 0) {
        Color.clear
          .frame(height: 85)
          .contentShape(Rectangle())
          .onTapGesture {
            stepValue(by: -step)
          }

        Color.clear
          .frame(height: 85)
          .contentShape(Rectangle())
          .onTapGesture {
            stepValue(by: step)
          }
      }
      .frame(width: 83, height: 170)
    }
    .frame(width: 83, height: 170)
    .background(
      LinearGradient(
        colors: [
          Color(hex: "E9E4E2"),
          Color(hex: "FFFDFC"),
          Color(hex: "FFFDFC"),
          Color(hex: "E9E4E2"),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(hex: "E6DDD9"), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .simultaneousGesture(numberDragGesture)
    .background(
      GoalNumberScrollMonitor { deltaY, isPrecise in
        applyScroll(deltaY, isPrecise: isPrecise)
      }
    )
    .help("Drag or scroll to adjust \(label.lowercased())")
  }

  @ViewBuilder
  private func wheelRow(offset: Int, size: CGFloat, color: Color) -> some View {
    if let rowValue = valueAtOffset(offset) {
      wheelText(rowValue, size: size, color: color)
    } else {
      Color.clear
        .frame(width: numberStackWidth, height: size)
    }
  }

  private func valueAtOffset(_ offset: Int) -> Int? {
    let proposedValue = value + offset * step
    guard range.contains(proposedValue) else { return nil }
    return proposedValue
  }

  private func wheelText(_ value: Int, size: CGFloat, color: Color) -> some View {
    Text(formattedValue(value))
      .font(.custom("Figtree", size: size))
      .foregroundColor(color)
      .lineLimit(1)
      .minimumScaleFactor(0.85)
      .allowsTightening(true)
      .monospacedDigit()
      .frame(width: numberStackWidth, height: size, alignment: .center)
  }

  private var numberStackWidth: CGFloat {
    step == 1 ? 34 : 38
  }

  private var labelWidth: CGFloat {
    label == "Hours" ? 40 : 32
  }

  private func formattedValue(_ value: Int) -> String {
    step == 5 ? String(format: "%02d", value) : "\(value)"
  }

  @discardableResult
  private func stepValue(
    by delta: Int,
    resetsAccumulator: Bool = true,
    showsWheelMotion: Bool = true
  ) -> Bool {
    let proposedValue = clamped(value + delta)
    if resetsAccumulator {
      scrollAccumulator = 0
    }

    guard proposedValue != value else {
      settleWheel()
      return false
    }

    let direction = proposedValue > value ? 1 : -1
    value = proposedValue
    if showsWheelMotion {
      startWheelMotion(direction: direction)
    }
    return true
  }

  private var numberDragGesture: some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { gestureValue in
        if dragStartValue == nil {
          dragStartValue = self.value
          scrollAccumulator = 0
        }

        guard let startValue = dragStartValue else { return }
        let rawSteps = Int((-gestureValue.translation.height / rowStride).rounded())
        let nextValue = clamped(startValue + rawSteps * step)
        let appliedSteps = (nextValue - startValue) / step
        let snappedTranslation = -CGFloat(appliedSteps) * rowStride
        let remainingTranslation = gestureValue.translation.height - snappedTranslation

        self.value = nextValue
        self.wheelOffset = rubberBandedOffset(remainingTranslation, at: nextValue)
      }
      .onEnded { gestureValue in
        if let startValue = dragStartValue {
          let rawSteps = Int((-gestureValue.translation.height / rowStride).rounded())
          self.value = clamped(startValue + rawSteps * step)
        }
        dragStartValue = nil
        scrollAccumulator = 0
        settleWheel()
      }
  }

  private func applyScroll(_ deltaY: CGFloat, isPrecise: Bool) {
    guard deltaY != 0 else { return }

    if !isPrecise {
      let direction = deltaY > 0 ? step : -step
      stepValue(by: direction)
      return
    }

    scrollAccumulator += deltaY
    let threshold: CGFloat = 22

    while abs(scrollAccumulator) >= threshold {
      if scrollAccumulator > 0 {
        guard stepValue(by: step, resetsAccumulator: false) else {
          scrollAccumulator = 0
          break
        }
        scrollAccumulator -= threshold
      } else {
        guard stepValue(by: -step, resetsAccumulator: false) else {
          scrollAccumulator = 0
          break
        }
        scrollAccumulator += threshold
      }
    }
  }

  private func startWheelMotion(direction: Int) {
    guard !reduceMotion else {
      wheelOffset = 0
      return
    }

    wheelOffset = direction > 0 ? rowStride : -rowStride
    settleWheel()
  }

  private func settleWheel() {
    guard !reduceMotion else {
      wheelOffset = 0
      return
    }

    withAnimation(.spring(duration: 0.22, bounce: 0)) {
      wheelOffset = 0
    }
  }

  private func rubberBandedOffset(_ offset: CGFloat, at currentValue: Int) -> CGFloat {
    if currentValue == range.lowerBound && offset > 0 {
      return offset * 0.35
    }
    if currentValue == range.upperBound && offset < 0 {
      return offset * 0.35
    }
    return offset
  }

  private func clamped(_ proposedValue: Int) -> Int {
    min(max(proposedValue, range.lowerBound), range.upperBound)
  }

}

private struct GoalNumberScrollMonitor: NSViewRepresentable {
  var onScroll: (CGFloat, Bool) -> Void

  func makeNSView(context: Context) -> ScrollMonitorView {
    let view = ScrollMonitorView()
    view.onScroll = onScroll
    return view
  }

  func updateNSView(_ nsView: ScrollMonitorView, context: Context) {
    nsView.onScroll = onScroll
  }

  static func dismantleNSView(_ nsView: ScrollMonitorView, coordinator: ()) {
    nsView.removeMonitor()
  }

  final class ScrollMonitorView: NSView {
    var onScroll: ((CGFloat, Bool) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        removeMonitor()
      } else {
        installMonitorIfNeeded()
      }
    }

    func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    private func installMonitorIfNeeded() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, self.isEventInside(event) else {
          return event
        }

        self.onScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
        return nil
      }
    }

    private func isEventInside(_ event: NSEvent) -> Bool {
      guard event.window === window else { return false }
      let location = convert(event.locationInWindow, from: nil)
      return bounds.contains(location)
    }
  }
}

private struct GoalReviewCard: View {
  let kind: DayGoalCategoryKind
  let title: String
  let subtitle: String
  let targetDuration: TimeInterval
  let actualDuration: TimeInterval
  let categories: [DayGoalCategoryResult]

  private var accent: Color {
    kind == .focus ? Color(hex: "628CFF") : Color(hex: "FA8282")
  }

  private var iconName: String {
    kind == .focus ? "DayGoalFocus" : "DayGoalDistraction"
  }

  private var succeeded: Bool {
    switch kind {
    case .focus:
      return actualDuration >= targetDuration
    case .distraction:
      return actualDuration <= targetDuration
    }
  }

  private var progressRatio: Double {
    guard targetDuration > 0 else { return 0 }
    return min(max(actualDuration / targetDuration, 0), 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
          Text(subtitle)
        }
        .font(.custom("Figtree", size: 15))
        .foregroundColor(.black)

        Spacer()

        resultBadge
      }

      HStack(spacing: 8) {
        if kind == .focus {
          GoalIconBubble(kind: kind)
        }

        GeometryReader { geometry in
          ZStack(alignment: kind == .focus ? .leading : .trailing) {
            RoundedRectangle(cornerRadius: 4)
              .fill(Color(hex: "E4E4E4"))

            RoundedRectangle(cornerRadius: 6)
              .fill(accent)
              .frame(width: barWidth(availableWidth: geometry.size.width), height: 8)
          }
        }
        .frame(height: 14)

        if kind == .distraction {
          GoalIconBubble(kind: kind)
        }
      }

      if kind == .focus {
        GoalCategoryBreakdown(categories: categories)
          .frame(height: 92)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, kind == .focus ? 18 : 18)
    .frame(width: 388, height: kind == .focus ? 236 : 123, alignment: .topLeading)
    .background(Color.white.opacity(0.8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(kind == .focus ? Color(hex: "CEDBFF") : Color(hex: "FFCDCD"), lineWidth: 1)
    )
    .shadow(
      color: (kind == .focus ? Color(hex: "8BAAFF") : Color(hex: "FA8282")).opacity(0.75),
      radius: 10
    )
  }

  private var resultBadge: some View {
    Text(succeeded ? "NAILED IT" : "MISSED")
      .font(.custom("Figtree", size: 10).weight(.heavy))
      .foregroundColor(succeeded ? Color(hex: "4AB43F") : Color(hex: "FA8282"))
      .padding(.horizontal, 15)
      .frame(height: 30)
      .background(succeeded ? Color(hex: "F1FFE3") : Color(hex: "FFF0F0"))
      .clipShape(Capsule())
      .overlay(Capsule().stroke(Color.white, lineWidth: 0.5))
      .rotationEffect(.degrees(7.5))
  }

  private func barWidth(availableWidth: CGFloat) -> CGFloat {
    let width = availableWidth * progressRatio
    if kind == .distraction {
      return max(0, width)
    }
    return max(0, width)
  }
}

private struct GoalCategoryBreakdown: View {
  let categories: [DayGoalCategoryResult]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if categories.isEmpty {
        Text("No focus categories tracked")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(Color(hex: "777777"))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        ForEach(categories.prefix(4)) { category in
          HStack(spacing: 9) {
            Text(category.name)
              .font(.custom("Figtree", size: 12))
              .foregroundColor(Color(hex: "333333"))
              .lineLimit(1)
              .frame(width: 74, alignment: .leading)

            RoundedRectangle(cornerRadius: 6)
              .fill(category.color)
              .frame(width: barWidth(for: category), height: 6)

            Text(formatDuration(category.duration))
              .font(.custom("Figtree", size: 8))
              .foregroundColor(.black)
              .lineLimit(1)

            Spacer(minLength: 0)
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .background(Color(hex: "F4F4F4"))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  private func barWidth(for category: DayGoalCategoryResult) -> CGFloat {
    guard let maxDuration = categories.map(\.duration).max(), maxDuration > 0 else { return 0 }
    return max(18, CGFloat(category.duration / maxDuration) * 86)
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    let totalMinutes = Int(duration / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 && minutes > 0 {
      return "\(hours)h \(minutes)m"
    }
    if hours > 0 {
      return "\(hours)h"
    }
    return "\(minutes)m"
  }
}

private struct GoalIconBubble: View {
  let kind: DayGoalCategoryKind

  var body: some View {
    ZStack {
      Circle()
        .fill(Color(hex: "E4E4E4"))
        .overlay(Circle().stroke(accent, lineWidth: 1))

      Image(kind == .focus ? "DayGoalFocus" : "DayGoalDistraction")
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
    }
    .frame(width: 36, height: 36)
  }

  private var accent: Color {
    kind == .focus ? Color(hex: "8BAAFF") : Color(hex: "FA8282")
  }
}

private struct GoalCategoryChip: View {
  enum Status {
    case untracked
    case focus
    case distraction
  }

  let title: String
  let colorHex: String
  let status: Status
  var showsRemove = false

  private var color: Color {
    if let nsColor = NSColor(hex: colorHex) {
      return Color(nsColor: nsColor)
    }
    return .gray
  }

  private var background: Color {
    switch status {
    case .focus:
      return color.opacity(0.16)
    case .distraction:
      return Color(hex: "FFEDED")
    case .untracked:
      return color.opacity(0.16)
    }
  }

  var body: some View {
    HStack(spacing: 2) {
      ChipDragHandle(color: color)
        .frame(width: 16, height: 16)

      Text(title)
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color(hex: "333333"))
        .lineLimit(1)
        .minimumScaleFactor(0.8)

      if showsRemove {
        Image(systemName: "xmark")
          .font(.system(size: 7, weight: .semibold))
          .foregroundColor(Color(hex: "777777"))
      }
    }
    .padding(4)
    .background(background)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(color.opacity(status == .untracked ? 0.75 : 1), lineWidth: 0.5)
    )
  }
}

private struct ChipDragHandle: View {
  let color: Color

  var body: some View {
    VStack(spacing: 2) {
      HStack(spacing: 2) {
        Circle().fill(color)
        Circle().fill(color)
      }
      HStack(spacing: 2) {
        Circle().fill(color)
        Circle().fill(color)
      }
    }
    .padding(3)
  }
}

private struct DayGoalFlowLayout: Layout {
  var spacing: CGFloat = 6
  var rowSpacing: CGFloat = 6

  func makeCache(subviews: Subviews) {}

  func updateCache(_ cache: inout (), subviews: Subviews) {}

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maxRowWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
        totalHeight += rowHeight + rowSpacing
        maxRowWidth = max(maxRowWidth, rowWidth)
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
        rowHeight = max(rowHeight, size.height)
      }
    }

    maxRowWidth = max(maxRowWidth, rowWidth)
    totalHeight += rowHeight
    return CGSize(width: maxRowWidth, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var origin = CGPoint(x: bounds.minX, y: bounds.minY)
    var currentRowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += currentRowHeight + rowSpacing
        currentRowHeight = 0
      }

      subview.place(
        at: CGPoint(x: origin.x, y: origin.y),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )

      origin.x += size.width + spacing
      currentRowHeight = max(currentRowHeight, size.height)
    }
  }
}

#Preview("Day Goal Flow") {
  let categories = [
    TimelineCategory(name: "Research", colorHex: "#8BAAFF", order: 0),
    TimelineCategory(name: "Coding", colorHex: "#CF8FFF", order: 1),
    TimelineCategory(name: "Code review", colorHex: "#90DDF0", order: 2),
    TimelineCategory(name: "Debugging", colorHex: "#6E66D4", order: 3),
    TimelineCategory(name: "Distraction", colorHex: "#FF706B", order: 4),
  ]
  let plan = DayGoalPlan.defaultPlan(day: "2026-05-13", categories: categories)
  DayGoalFlowView(
    review: DayGoalReviewSnapshot(
      day: "2026-05-12",
      plan: plan,
      focusDuration: 270 * 60,
      distractedDuration: 85 * 60,
      focusCategories: [
        DayGoalCategoryResult(
          id: "research", name: "Research", colorHex: "#8BAAFF", duration: 74 * 60),
        DayGoalCategoryResult(id: "coding", name: "Coding", colorHex: "#CF8FFF", duration: 74 * 60),
      ]
    ),
    plan: plan,
    categories: categories,
    onSkip: {},
    onConfirm: { _ in },
    onSetupStarted: {},
    onCategoryToggled: { _, _, _ in }
  )
}
