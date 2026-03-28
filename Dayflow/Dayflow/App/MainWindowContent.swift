import SwiftUI

@MainActor
struct MainWindowContent: View {
    @EnvironmentObject private var categoryStore: CategoryStore
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var showVideoLaunch = true
    @State private var contentOpacity = 0.0
    @State private var contentScale = 0.98
    private let updaterManager = UpdaterManager.shared

    var body: some View {
        ZStack {
            Group {
                if didOnboard {
                    AppRootView()
                        .environmentObject(categoryStore)
                        .environmentObject(updaterManager)
                } else {
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

            if showVideoLaunch {
                VideoLaunchView()
                    .onVideoComplete {
                        withAnimation(.easeOut(duration: 0.25)) {
                            contentOpacity = 1.0
                            contentScale = 1.0
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeIn(duration: 0.2)) {
                                showVideoLaunch = false
                            }
                        }
                    }
                    .opacity(showVideoLaunch ? 1 : 0)
                    .scaleEffect(showVideoLaunch ? 1 : 1.02)
                    .animation(.easeIn(duration: 0.2), value: showVideoLaunch)
            }
        }
        .background {
            if didOnboard {
                Image("MainUIBackground")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
    }
}
