//
//  FlowView.swift
//  Dayflow
//
//  Flow tab: hosts the remote Flow web app (it talks to the backend with the
//  user's session token). Until someone has signed in and tapped "Enter Flow"
//  once, the tab shows the enter screen instead.
//

import SwiftUI

struct FlowView: View {
  @Environment(\.dayflowTheme) private var theme
  @ObservedObject private var authManager = DayflowAuthManager.shared

  @State private var loadState: LoadState = .loading
  /// Bumped to tear down and recreate the webview on retry.
  @State private var reloadToken = 0
  @State private var showingSupport = false
  /// Set the first time someone taps "Enter Flow"; after that the tab opens
  /// straight into the web app.
  @AppStorage("flowHasEntered") private var hasEnteredFlow = false
  /// Read only so a provider change re-renders the gate.
  @AppStorage(LLMProviderRoutingStore.storageKey) private var providerRouting: Data?

  private enum LoadState {
    case loading
    case loaded
    case failed(String)
  }

  var body: some View {
    ZStack {
      if !authManager.hasLoadedStoredSession || authManager.isRestoringStoredSession {
        ProgressView()
      } else if authManager.flowEnabled && hasEnteredFlow && !FlowDistractionAgent.providerCanWatch
      {
        FlowEnterView(providerLimited: true)
      } else if authManager.flowEnabled && hasEnteredFlow {
        webContent
      } else if authManager.hasUnrestoredSession {
        // Signed in, but the account couldn't be fetched.
        errorView(
          title: "Flow needs an internet connection",
          message: String(
            localized: "Dayflow couldn't reach your account. Check your connection and try again.")
        ) {
          Task { await authManager.restoreStoredSession() }
        }
      } else {
        FlowEnterView { hasEnteredFlow = true }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      await authManager.restoreStoredSession()
    }
  }

  private var webContent: some View {
    ZStack {
      FlowWebView(url: FlowWebConfiguration.url) { event in
        switch event {
        case .loaded:
          loadState = .loaded
        case .failed(let error):
          loadState = .failed(error.localizedDescription)
        case .supportRequested:
          showingSupport = true
        }
      }
      .id(reloadToken)
      .opacity(isLoaded ? 1 : 0)

      switch loadState {
      case .loading:
        ProgressView()
      case .failed(let message):
        errorView(title: "Couldn't load Flow", message: message) {
          loadState = .loading
          reloadToken += 1
        }
      case .loaded:
        EmptyView()
      }

      if showingSupport {
        FlowSupportChatView { showingSupport = false }
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.15), value: showingSupport)
  }

  private var isLoaded: Bool {
    if case .loaded = loadState { return true }
    return false
  }

  private func errorView(
    title: LocalizedStringKey,
    message: String,
    onRetry: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "wifi.slash")
        .font(.system(size: 40))
        .foregroundColor(theme.textMuted)
      Text(title)
        .font(.custom("Figtree", size: 20).weight(.semibold))
        .foregroundColor(theme.textPrimary)
      Text(message)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(theme.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      Button("Retry", action: onRetry)
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)
    }
  }
}
