//
//  DayflowApp.swift
//  Dayflow
//

import Sparkle
import SwiftUI

struct AppRootView: View {
  @EnvironmentObject private var categoryStore: CategoryStore
  @Binding var isShowingGitHubStarPrompt: Bool
  @State private var whatsNewNote: ReleaseNote? = nil
  @State private var activeWhatsNewVersion: String? = nil
  @State private var shouldMarkWhatsNewSeen = false
  @State private var goalFlowPresentation: DayGoalFlowPresentation? = nil

  var body: some View {
    ZStack {
      MainView(goalFlowPresentation: $goalFlowPresentation)
        .environmentObject(AppState.shared)
        .environmentObject(categoryStore)

      goalFlowOverlay
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      guard whatsNewNote == nil else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if let note = WhatsNewConfiguration.pendingReleaseForCurrentBuild() {
          whatsNewNote = note
          activeWhatsNewVersion = note.version
          shouldMarkWhatsNewSeen = true
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        showGitHubStarPromptIfEligible(source: "launch")
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
      guard let release = WhatsNewConfiguration.latestRelease() else { return }
      whatsNewNote = release
      activeWhatsNewVersion = release.version
      shouldMarkWhatsNewSeen = release.version == currentAppVersion

      // Analytics: track manual view
      AnalyticsService.shared.capture(
        "whats_new_viewed_manual",
        [
          "version": release.version
        ])
    }
    .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { _ in
      showGitHubStarPromptIfEligible(source: "first_card")
    }
    .onChange(of: whatsNewNote == nil) { _, isDismissed in
      if isDismissed {
        showGitHubStarPromptIfEligible(source: "launch")
      }
    }
    .sheet(item: $whatsNewNote, onDismiss: handleWhatsNewDismissed) { note in
      ZStack {
        // Backdrop
        Color.black.opacity(0.4)
          .ignoresSafeArea()

        WhatsNewView(releaseNote: note) {
          closeWhatsNew()
        }
      }
      .resolveDayflowTheme()
    }
  }

  @ViewBuilder
  private var goalFlowOverlay: some View {
    if let goalFlowPresentation {
      DayGoalFlowOverlay(
        presentation: goalFlowPresentation,
        onDismiss: {
          withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            self.goalFlowPresentation = nil
          }
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
      .transition(.opacity.combined(with: .scale(scale: 0.985)))
      .zIndex(3)
    }
  }

  private func showGitHubStarPromptIfEligible(source: String) {
    guard !isShowingGitHubStarPrompt,
      whatsNewNote == nil,
      goalFlowPresentation == nil,
      !GitHubStarPromptState.hasShown,
      StorageManager.shared.hasAnyTimelineCards()
    else { return }

    GitHubStarPromptState.markShown()
    AnalyticsService.shared.capture("github_star_prompt_shown", ["source": source])
    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
      isShowingGitHubStarPrompt = true
    }
  }

  private func closeWhatsNew() {
    whatsNewNote = nil
  }

  private func handleWhatsNewDismissed() {
    guard let version = activeWhatsNewVersion else { return }
    if shouldMarkWhatsNewSeen {
      WhatsNewConfiguration.markReleaseAsSeen(version: version)
      AnalyticsService.shared.capture(
        "whats_new_viewed",
        [
          "version": version,
          "source": "auto",
        ])
    }
    AnalyticsService.shared.capture(
      "whats_new_viewed",
      [
        "version": version,
        "source": "manual",
      ])
    activeWhatsNewVersion = nil
    shouldMarkWhatsNewSeen = false
    showGitHubStarPromptIfEligible(source: "launch")
  }

  private var currentAppVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }
}

@main
struct DayflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @AppStorage("didOnboard") private var didOnboard = false
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @AppStorage("useBlankUI") private var useBlankUI = false
  @AppStorage("hasCompletedJournalOnboarding") private var hasCompletedJournalOnboarding = false
  @State private var showVideoLaunch = true
  @State private var contentOpacity = 0.0
  @State private var contentScale = 0.98
  @State private var isShowingGitHubStarPrompt = false
  @StateObject private var categoryStore = CategoryStore()
  @StateObject private var journalCoordinator = JournalCoordinator()

  init() {
    // Writing to stdout after its reader has gone away (app launched from a
    // terminal or wrapper that exited) raises SIGPIPE and kills the process.
    // Ignore it so the write simply fails with EPIPE instead.
    signal(SIGPIPE, SIG_IGN)

    // Comment out for production - only use for testing onboarding
    // UserDefaults.standard.set(false, forKey: "didOnboard")
  }

  // Sparkle updater manager
  private let updaterManager = UpdaterManager.shared

  var body: some Scene {
    Window("Dayflow", id: "main") {
      ZStack {
        // Main app UI or onboarding with entrance animation
        Group {
          if didOnboard {
            // Show UI after onboarding
            AppRootView(isShowingGitHubStarPrompt: $isShowingGitHubStarPrompt)
              .environmentObject(categoryStore)
              .environmentObject(updaterManager)
              .environmentObject(journalCoordinator)
          } else if !showVideoLaunch {
            // Onboarding is designed light-only.
            OnboardingFlow()
              .environmentObject(AppState.shared)
              .environmentObject(categoryStore)
              .environmentObject(updaterManager)
              .dayflowTheme(.light)
          }
        }
        .opacity(contentOpacity)
        .scaleEffect(contentScale)
        .animation(.easeOut(duration: 0.3).delay(0.15), value: contentOpacity)
        .animation(.easeOut(duration: 0.3).delay(0.15), value: contentScale)

        // Video overlay on top with scale + opacity exit
        if showVideoLaunch {
          VideoLaunchView()
            .onVideoComplete {
              // Overlapping animations for smooth handoff
              withAnimation(.easeOut(duration: 0.25)) {
                // Start revealing content while video fades
                contentOpacity = 1.0
                contentScale = 1.0
              }

              // Slightly delayed video exit for overlap
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.2)) {
                  showVideoLaunch = false
                }
              }

              dispatchPendingNotificationNavigation(after: 0.3)
            }
            .opacity(showVideoLaunch ? 1 : 0)
            .scaleEffect(showVideoLaunch ? 1 : 1.02)
            .animation(.easeIn(duration: 0.2), value: showVideoLaunch)
            .onAppear {
              // Skip video if opening via notification tap
              if hasPendingNotificationNavigation {
                showVideoLaunch = false
                contentOpacity = 1.0
                contentScale = 1.0
                dispatchPendingNotificationNavigation(after: 0.1)
              }
            }
        }

        // Journal onboarding video (full window coverage, above sidebar)
        if journalCoordinator.showOnboardingVideo {
          JournalOnboardingVideoView(onComplete: {
            withAnimation(.easeOut(duration: 0.3)) {
              journalCoordinator.showOnboardingVideo = false
              hasCompletedJournalOnboarding = true
            }
          })
          .ignoresSafeArea()
          .transition(.opacity)
        }

        if didOnboard && !showVideoLaunch && isShowingGitHubStarPrompt {
          GitHubStarPromptCard(
            onStar: starDayflow,
            onDismiss: dismissGitHubStarPrompt
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .padding(.trailing, 24)
          .padding(.bottom, 24)
          .transition(.move(edge: .trailing).combined(with: .opacity))
          .zIndex(10)
        }

      }
      // Inline background behind the main app UI only
      .background {
        MainWindowRegistrationView()

        if didOnboard {
          DayflowWindowBackground()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      // Onboarding stays light; the main app follows the user's appearance setting.
      .preferredColorScheme(didOnboard ? appearance.preferredColorScheme : .light)
      .resolveDayflowTheme()
      .resolveStylePreview()
      .onAppear {
        if !showVideoLaunch {
          dispatchPendingNotificationNavigation(after: 0.1)
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        if !showVideoLaunch {
          dispatchPendingNotificationNavigation(after: 0.1)
        }
      }
      .frame(minWidth: 900, maxWidth: .infinity, minHeight: 508, maxHeight: .infinity)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 1195, height: 675)

    .commands {
      // Remove the "New Window" command if you want a single window app
      CommandGroup(replacing: .newItem) {}

      // Add custom menu items after the app info section
      CommandGroup(after: .appInfo) {
        Divider()
        Button("Reset Onboarding") {
          // Reset the onboarding flag
          UserDefaults.standard.set(false, forKey: "didOnboard")
          // Reset the saved onboarding step to start from beginning
          UserDefaults.standard.set(0, forKey: "onboardingStep")
          UserDefaults.standard.removeObject(forKey: "onboardingHasPaidAI")
          UserDefaults.standard.removeObject(forKey: CategoryStore.StoreKeys.onboardingSelectedRole)
          UserDefaults.standard.removeObject(
            forKey: CategoryStore.StoreKeys.onboardingAppliedCategoryPreset)
          UserDefaults.standard.removeObject(
            forKey: CategoryStore.StoreKeys.onboardingCategoriesCustomized)
          UserDefaults.standard.removeObject(forKey: "onboardingSelectedProviderID")
          // Force quit and restart the app to show onboarding
          Task { @MainActor in
            AppDelegate.allowTermination = true
            NSApp.terminate(nil)
          }
        }
        .keyboardShortcut("R", modifiers: [.command, .shift])
      }

      // Add Sparkle's update menu item
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          updaterManager.checkForUpdates(showUI: true)
        }

        Button("View Release Notes") {
          // Activate the app and bring to foreground
          NSApp.activate(ignoringOtherApps: true)

          // Post notification to show What's New modal
          NotificationCenter.default.post(name: .showWhatsNew, object: nil)
        }
        .keyboardShortcut("N", modifiers: [.command, .shift])
      }

      CommandGroup(after: .appInfo) {
        Divider()
        Button("Flow: Simulate Distraction") {
          FlowSessionMirror.shared.simulateDistraction()
        }
        .keyboardShortcut("D", modifiers: [.command, .shift])
      }
    }
    .defaultSize(width: 1200, height: 800)

  }

  private func starDayflow() async {
    AnalyticsService.shared.capture("github_star_prompt_clicked")
    let starred = await GitHubStarService.starDayflow()
    if starred {
      AnalyticsService.shared.capture("github_star_completed", ["method": "gh"])
    } else {
      AnalyticsService.shared.capture("github_star_browser_fallback")
      NSWorkspace.shared.open(GitHubStarPromptState.repositoryURL)
    }
    hideGitHubStarPrompt()
  }

  private func dismissGitHubStarPrompt() {
    AnalyticsService.shared.capture("github_star_prompt_dismissed")
    hideGitHubStarPrompt()
  }

  private func hideGitHubStarPrompt() {
    withAnimation(.easeOut(duration: 0.2)) {
      isShowingGitHubStarPrompt = false
    }
  }

  private var hasPendingNotificationNavigation: Bool {
    AppDelegate.pendingNotificationNavigationDestination != nil
  }

  private func dispatchPendingNotificationNavigation(after delay: TimeInterval) {
    guard hasPendingNotificationNavigation else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      guard let destination = AppDelegate.pendingNotificationNavigationDestination else { return }
      AppDelegate.pendingNotificationNavigationDestination = nil

      switch destination {
      case .daily(let day) where day?.isEmpty == false:
        NotificationCenter.default.post(
          name: .navigateToDaily,
          object: nil,
          userInfo: ["day": day]
        )
      case .daily:
        NotificationCenter.default.post(name: .navigateToDaily, object: nil)
      case .weekly:
        NotificationCenter.default.post(name: .navigateToWeekly, object: nil)
      case .journal:
        NotificationCenter.default.post(name: .navigateToJournal, object: nil)
      }
    }
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let analyticsPreferenceChanged = Notification.Name("analyticsPreferenceChanged")
  static let showWhatsNew = Notification.Name("showWhatsNew")
  static let navigateToJournal = Notification.Name("navigateToJournal")
  static let navigateToDaily = Notification.Name("navigateToDaily")
  static let navigateToWeekly = Notification.Name("navigateToWeekly")
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  static let showTimelineFailureToast = Notification.Name("showTimelineFailureToast")
  static let showScreenRecordingPermissionNotice = Notification.Name(
    "showScreenRecordingPermissionNotice")
  static let openProvidersSettings = Notification.Name("openProvidersSettings")
  static let openAccountSettings = Notification.Name("openAccountSettings")
  static let navigateToFlow = Notification.Name("navigateToFlow")
}

@MainActor
final class MainWindowController {
  static let shared = MainWindowController()

  private var openWindowAction: OpenWindowAction?
  private var hasPendingOpenRequest = false

  func register(_ openWindowAction: OpenWindowAction) {
    self.openWindowAction = openWindowAction

    if hasPendingOpenRequest {
      hasPendingOpenRequest = false
      openWindowAction(id: "main")
    }
  }

  func showMainWindow() {
    guard let openWindowAction else {
      hasPendingOpenRequest = true
      return
    }

    openWindowAction(id: "main")
  }
}

/// Full-window gradient behind the main app (Figma: dark linear / light radial).
private struct DayflowWindowBackground: View {
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    GeometryReader { proxy in
      if theme.isDark {
        Image("DarkWindowBackground")
          .resizable()
          .interpolation(.high)
          .scaledToFill()
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
      } else {
        LightWindowGradient()
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
  }
}

private struct MainWindowRegistrationView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        MainWindowController.shared.register(openWindow)
      }
  }
}
