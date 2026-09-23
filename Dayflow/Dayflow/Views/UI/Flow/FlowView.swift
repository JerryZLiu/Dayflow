//
//  FlowView.swift
//  Dayflow
//
//  Flow tab: hosts the remote Flow web app for accounts with Flow access
//  (the web app talks to the backend with the user's session token). Everyone
//  else, signed in or not, sees the waitlist.
//

import SwiftUI

struct FlowView: View {
  @Environment(\.dayflowTheme) private var theme
  @ObservedObject private var authManager = DayflowAuthManager.shared

  @State private var loadState: LoadState = .loading
  /// Bumped to tear down and recreate the webview on retry.
  @State private var reloadToken = 0

  private enum LoadState {
    case loading
    case loaded
    case failed(String)
  }

  var body: some View {
    ZStack {
      if authManager.flowEnabled {
        webContent
      } else {
        FlowWaitlistView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var webContent: some View {
    ZStack {
      FlowWebView(url: FlowWebConfiguration.url) { event in
        switch event {
        case .loaded:
          loadState = .loaded
        case .failed(let error):
          loadState = .failed(error.localizedDescription)
        }
      }
      .id(reloadToken)
      .opacity(isLoaded ? 1 : 0)

      switch loadState {
      case .loading:
        ProgressView()
      case .failed(let message):
        errorView(message: message)
      case .loaded:
        EmptyView()
      }
    }
  }

  private var isLoaded: Bool {
    if case .loaded = loadState { return true }
    return false
  }

  private func errorView(message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "wifi.slash")
        .font(.system(size: 40))
        .foregroundColor(theme.textMuted)
      Text("Couldn't load Flow")
        .font(.custom("Figtree", size: 20).weight(.semibold))
        .foregroundColor(theme.textPrimary)
      Text(message)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(theme.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      Button("Retry") {
        loadState = .loading
        reloadToken += 1
      }
      .buttonStyle(.borderedProminent)
      .tint(theme.accent)
    }
  }
}
