import SwiftUI

struct WeeklyView: View {
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var categoryStore: CategoryStore

  @State private var weekRange = WeeklyDateRange.containing(Date())
  @State private var weeklyCards: [TimelineCard] = []
  @State private var donutSnapshot = WeeklyDonutSnapshot.empty
  @State private var isLoadingWeekData = false
  @State private var weekLoadTask: Task<Void, Never>?

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(spacing: 32) {
        WeeklyHeader(
          title: weekRange.title,
          canNavigateForward: weekRange.canNavigateForward,
          onPrevious: { weekRange = weekRange.shifted(byWeeks: -1) },
          onNext: {
            guard weekRange.canNavigateForward else { return }
            weekRange = weekRange.shifted(byWeeks: 1)
          }
        )

        WeeklyFocusHeatmapSection(snapshot: .figmaPreview)
          .frame(maxWidth: .infinity, alignment: .leading)

        WeeklyContextShiftComparisonSection(snapshot: .figmaPreview)
          .frame(maxWidth: .infinity, alignment: .leading)

        WeeklyDonutSection(
          snapshot: donutSnapshot,
          isLoading: isLoadingWeekData
        )
        .frame(maxWidth: .infinity, alignment: .leading)

        WeeklySankeyDistributionSection(
          cards: weeklyCards,
          categories: categoryStore.categories,
          weekRange: weekRange
        )
        .frame(maxWidth: .infinity, alignment: .leading)

        WeeklyTreemapSection(snapshot: .figmaPreview)
        WeeklySuggestionsSection(snapshot: .figmaPreview)
      }
      .padding(.top, 54)
      .padding(.horizontal, 48)
      .padding(.bottom, 40)
      .frame(maxWidth: 1060, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.colorScheme, .light)
    .onAppear {
      loadWeekData()
    }
    .onDisappear {
      weekLoadTask?.cancel()
      weekLoadTask = nil
    }
    .onChange(of: weekRange) {
      loadWeekData()
    }
    .onChange(of: categoryStore.categories) {
      loadWeekData()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      loadWeekData()
    }
  }

  private func loadWeekData() {
    weekLoadTask?.cancel()
    isLoadingWeekData = true

    let categories = categoryStore.categories
    let weekRange = weekRange

    weekLoadTask = Task.detached(priority: .userInitiated) {
      let cards = StorageManager.shared.fetchTimelineCardsByTimeRange(
        from: weekRange.weekStart,
        to: weekRange.weekEnd
      )
      let snapshot = WeeklyDonutBuilder.build(
        cards: cards,
        categories: categories,
        weekRange: weekRange
      )
      guard !Task.isCancelled else { return }

      await MainActor.run {
        self.weeklyCards = cards
        self.donutSnapshot = snapshot
        self.isLoadingWeekData = false
      }
    }
  }
}

private struct WeeklySankeyControlsCard: View {
  @Binding var minAppSharePercent: Double
  @Binding var capsVisibleApps: Bool
  @Binding var maxVisibleApps: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Sankey tuning")
          .font(.custom("Nunito-Bold", size: 14))
          .foregroundStyle(Color(hex: "3B2418"))

        Text(
          "These controls only affect the rightmost app rail so you can cut the tiny buckets without changing the category story."
        )
        .font(.custom("Nunito-Regular", size: 12))
        .foregroundStyle(Color(hex: "6E584B"))
      }

      HStack(spacing: 12) {
        Text("Min app share")
          .font(.custom("Nunito-Regular", size: 12))
          .foregroundStyle(Color(hex: "3B2418"))

        Slider(value: $minAppSharePercent, in: 1...10, step: 1)
          .frame(width: 220)

        Text("\(Int(minAppSharePercent.rounded()))%")
          .font(.custom("Nunito-Regular", size: 12))
          .foregroundStyle(Color(hex: "6E584B"))
          .monospacedDigit()
      }

      HStack(spacing: 12) {
        Toggle("Top X right-rail cap", isOn: $capsVisibleApps)
          .toggleStyle(.checkbox)
          .font(.custom("Nunito-Regular", size: 12))
          .foregroundStyle(Color(hex: "3B2418"))

        Stepper(value: $maxVisibleApps, in: 3...10) {
          Text("Show top \(maxVisibleApps)")
            .font(.custom("Nunito-Regular", size: 12))
            .foregroundStyle(Color(hex: "6E584B"))
            .monospacedDigit()
        }
        .disabled(!capsVisibleApps)
        .opacity(capsVisibleApps ? 1 : 0.5)
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color(hex: "EBE6E3"), lineWidth: 1)
    )
  }
}

#Preview("Weekly View", traits: .fixedLayout(width: 1050, height: 920)) {
  WeeklyView()
    .environmentObject(CategoryStore.shared)
}
