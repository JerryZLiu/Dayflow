//
//  DayflowApp.swift
//  Dayflow
//

import Sparkle
import SwiftUI

struct AppRootView: View {
  @EnvironmentObject private var categoryStore: CategoryStore
  @State private var whatsNewNote: ReleaseNote? = nil
  @State private var activeWhatsNewVersion: String? = nil
  @State private var shouldMarkWhatsNewSeen = false

  var body: some View {
    MainView()
      .environmentObject(AppState.shared)
      .environmentObject(categoryStore)
      .onAppear {
        guard whatsNewNote == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          if let note = WhatsNewConfiguration.pendingReleaseForCurrentBuild() {
            whatsNewNote = note
            activeWhatsNewVersion = note.version
            shouldMarkWhatsNewSeen = true
          }
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
      .sheet(item: $whatsNewNote, onDismiss: handleWhatsNewDismissed) { note in
        ZStack {
          // Backdrop
          Color.black.opacity(0.4)
            .ignoresSafeArea()

          WhatsNewView(releaseNote: note) {
            closeWhatsNew()
          }
        }
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
  }

  private var currentAppVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }
}

@main
struct DayflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @AppStorage("didOnboard") private var didOnboard = false
  @AppStorage("useBlankUI") private var useBlankUI = false
  @AppStorage("hasCompletedJournalOnboarding") private var hasCompletedJournalOnboarding = false
  @State private var showVideoLaunch = true
  @State private var contentOpacity = 0.0
  @State private var contentScale = 0.98
  @StateObject private var categoryStore = CategoryStore()
  @StateObject private var journalCoordinator = JournalCoordinator()

  init() {
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
            AppRootView()
              .environmentObject(categoryStore)
              .environmentObject(updaterManager)
              .environmentObject(journalCoordinator)
          } else if !showVideoLaunch {
            OnboardingFlow()
              .environmentObject(AppState.shared)
              .environmentObject(categoryStore)
              .environmentObject(updaterManager)
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
      }
      // Inline background behind the main app UI only
      .background {
        MainWindowRegistrationView()

        if didOnboard {
          Image("MainUIBackground")
            .resizable()
            .scaledToFill()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
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
          // Reset the selected LLM provider to default
          UserDefaults.standard.set("gemini", forKey: "selectedLLMProvider")
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
    }
    .defaultSize(width: 1200, height: 800)
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
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  static let showTimelineFailureToast = Notification.Name("showTimelineFailureToast")
  static let openProvidersSettings = Notification.Name("openProvidersSettings")
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
