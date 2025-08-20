//
//  DayflowApp.swift
//  Dayflow
//
//  Created by Jerry Liu on 4/20/25.
//

import SwiftUI
import Sparkle

// MARK: - Root View with Transparent UI
struct AppRootView: View {
    var body: some View {
        MainView()
            .environmentObject(AppState.shared)
    }
}

@main
struct DayflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("didOnboard") private var didOnboard = false
    @AppStorage("useBlankUI") private var useBlankUI = false
    @State private var showVideoLaunch = true
    
    init() {
        // Comment out for production - only use for testing onboarding
        // UserDefaults.standard.set(false, forKey: "didOnboard")
    }
    
    // Sparkle updater - disabled for now
    // private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Always render the next view underneath
                if didOnboard {
                    // Show UI after onboarding
                    AppRootView()
                } else {
                    OnboardingFlow()
                        .environmentObject(AppState.shared)
                }
                
                // Video overlay on top
                if showVideoLaunch {
                    VideoLaunchView()
                        .onVideoComplete {
                            // Small delay before fade for smoother feel
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation(.easeInOut(duration: 2.0)) {
                                    showVideoLaunch = false
                                }
                            }
                        }
                        .transition(.opacity)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Remove the "New Window" command if you want a single window app
            CommandGroup(replacing: .newItem) { }
            
            // Add custom menu items after the app info section
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Reset Onboarding") {
                    // Reset the onboarding flag
                    UserDefaults.standard.set(false, forKey: "didOnboard")
                    // Force quit and restart the app to show onboarding
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
            }
            
            // Add Sparkle's update menu item - disabled for now
            // CommandGroup(after: .appInfo) {
            //     Button("Check for Updates...") {
            //         updaterController.updater.checkForUpdates()
            //     }
            // }
        }
        .defaultSize(width: 1200, height: 800)
    }
}