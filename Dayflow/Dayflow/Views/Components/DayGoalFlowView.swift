import SwiftUI

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
