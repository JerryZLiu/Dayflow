import SwiftUI

struct WeeklyView: View {
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var categoryStore: CategoryStore

  @State private var weekRange = WeeklyDateRange.containing(Date())
  @State private var donutSnapshot = WeeklyDonutSnapshot.empty
  @State private var isLoadingDonut = false
  @State private var donutLoadTask: Task<Void, Never>?

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

        WeeklyDonutSection(
          snapshot: donutSnapshot,
          isLoading: isLoadingDonut
        )
        .frame(maxWidth: .infinity, alignment: .leading)

        WeeklySankeyDistributionSection()
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
      loadDonutSnapshot()
    }
    .onDisappear {
      donutLoadTask?.cancel()
      donutLoadTask = nil
    }
    .onChange(of: weekRange) {
      loadDonutSnapshot()
    }
    .onChange(of: categoryStore.categories) {
      loadDonutSnapshot()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      loadDonutSnapshot()
    }
  }

  private func loadDonutSnapshot() {
    donutLoadTask?.cancel()
    isLoadingDonut = true

    let categories = categoryStore.categories
    let weekRange = weekRange

    donutLoadTask = Task.detached(priority: .userInitiated) {
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
        self.donutSnapshot = snapshot
        self.isLoadingDonut = false
      }
    }
  }
}

#Preview("Weekly View", traits: .fixedLayout(width: 1050, height: 920)) {
  WeeklyView()
    .environmentObject(CategoryStore.shared)
}
