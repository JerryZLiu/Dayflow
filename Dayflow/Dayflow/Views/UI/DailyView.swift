import AppKit
import Foundation
import SwiftUI
import UserNotifications

struct DailyView: View {
  @AppStorage("isDailyUnlocked") var isUnlocked: Bool = false
  @Binding var selectedDate: Date
  @EnvironmentObject var categoryStore: CategoryStore

  @State var accessFlowStep: DailyAccessFlowStep = .intro
  @State var lockScreenConfettiTrigger: Int = 0
  @State var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
  @State var isCheckingNotificationAuthorization: Bool = false
  @State var isRequestingNotificationPermission: Bool = false
  @State var workflowRows: [DailyWorkflowGridRow] = []
  @State var workflowTotals: [DailyWorkflowTotalItem] = []
  @State var workflowStats: [DailyWorkflowStatChip] = DailyWorkflowStatChip.placeholder
  @State var workflowWindow: DailyWorkflowTimelineWindow = .placeholder
  @State var workflowDistractionMarkers: [DailyWorkflowDistractionMarker] = []
  @State var workflowHasDistractionCategory: Bool = false
  @State var workflowHoveredCellKey: String? = nil
  @State var workflowHoveredDistractionId: String? = nil
  @State var workflowLoadTask: Task<Void, Never>? = nil
  @State var standupDraft: DailyStandupDraft = .default
  @State var standupSourceDay: DailyStandupDayInfo? = nil
  @State var loadedStandupDraftDay: String? = nil
  @State var loadedStandupFallbackSourceDay: String? = nil
  @State var standupDraftSaveTask: Task<Void, Never>? = nil
  @State var standupCopyState: DailyStandupCopyState = .idle
  @State var standupCopyResetTask: Task<Void, Never>? = nil
  @State var standupRegenerateState: DailyStandupRegenerateState = .idle
  @State var standupRegenerateTask: Task<Void, Never>? = nil
  @State var standupRegenerateResetTask: Task<Void, Never>? = nil
  @State var standupRegeneratingDotsPhase: Int = 1
  @State var hasPersistedStandupEntry: Bool = false
  @State var dailyRecapProvider: DailyRecapProvider = DailyRecapProvider.load()
  @State var isShowingProviderPicker: Bool = false
  @State var isRefreshingProviderAvailability: Bool = false
  @State var providerAvailabilityTask: Task<Void, Never>? = nil
  @State var providerAvailability: [DailyRecapProvider: DailyRecapProviderAvailability] =
    [:]

  let betaNoticeCopy =
    "Daily is a new way to visualize your day and turn it into a standup update fast."
  let priorStandupHistoryLimit = 3
  static let maxDateTitleWidth: CGFloat = {
    let referenceText = "Wednesday, September 30"
    let font = NSFont(name: "InstrumentSerif-Regular", size: 26) ?? NSFont.systemFont(ofSize: 26)
    let width = referenceText.size(withAttributes: [.font: font]).width
    return ceil(width) + 6
  }()

  var body: some View {
    ZStack {
      if isUnlocked {
        unlockedContent
          .transition(.opacity)
      } else {
        lockScreen
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .environment(\.colorScheme, .light)
    .onAppear {
      dailyRecapProvider = DailyRecapGenerator.shared.selectedProvider()
      refreshProviderAvailability()
      checkNotificationAuthorizationForUnlock()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      checkNotificationAuthorizationForUnlock()
    }
    .onChange(of: isUnlocked) { _, newValue in
      guard !newValue else { return }
      accessFlowStep = .intro
      checkNotificationAuthorizationForUnlock()
    }
  }

}

struct DailyView_Previews: PreviewProvider {
  static var previews: some View {
    DailyView(selectedDate: .constant(Date()))
      .environmentObject(CategoryStore.shared)
      .frame(width: 1180, height: 760)
  }
}
