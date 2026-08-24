//
//  FlowView.swift
//  Dayflow
//
//  Flow tab: hosts the remote Flow web app. Requires being signed in (the web
//  app talks to the backend with the user's session token) and online.
//

import SwiftUI

struct FlowView: View {
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
      if authManager.user == nil {
        signedOutView
      } else {
        webContent
      }
      #if DEBUG
        FlowAgentLogPanel()
      #endif
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

  private var signedOutView: some View {
    VStack(spacing: 16) {
      Image(systemName: "water.waves")
        .font(.system(size: 40))
        .foregroundColor(Color(hex: "F96E00"))
      Text("Sign in to use Flow")
        .font(.custom("Figtree", size: 20).weight(.semibold))
        .foregroundColor(.black)
      Text("Flow sessions sync with your Dayflow account.")
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black.opacity(0.6))
      Button("Sign in") {
        NotificationCenter.default.post(name: .openAccountSettings, object: nil)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color(hex: "F96E00"))
    }
  }

  #if DEBUG
    /// Debug-only transcript of the distraction agent: every reply the Codex
    /// CLI produced during the session, nothing else.
    private struct FlowAgentLogPanel: View {
      @ObservedObject private var agent = FlowDistractionAgent.shared
      @State private var isOpen = false

      var body: some View {
        VStack(alignment: .leading, spacing: 8) {
          Spacer()
          if isOpen {
            logList
          }
          Button(isOpen ? "Hide agent log" : "Agent log (\(agent.transcript.count))") {
            isOpen.toggle()
          }
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Capsule().fill(Color.black.opacity(0.6)))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(true)
      }

      private var logList: some View {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              if agent.transcript.isEmpty {
                Text("No agent output yet.")
                  .font(.system(size: 11))
                  .foregroundColor(.white.opacity(0.6))
              }
              ForEach(agent.transcript) { entry in
                VStack(alignment: .leading, spacing: 2) {
                  Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                  Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .id(entry.id)
              }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(width: 420, height: 260)
          .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
          .onChange(of: agent.transcript) {
            if let last = agent.transcript.last {
              proxy.scrollTo(last.id, anchor: .bottom)
            }
          }
          .onAppear {
            if let last = agent.transcript.last {
              proxy.scrollTo(last.id, anchor: .bottom)
            }
          }
        }
      }
    }
  #endif

  private func errorView(message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "wifi.slash")
        .font(.system(size: 40))
        .foregroundColor(.black.opacity(0.4))
      Text("Couldn't load Flow")
        .font(.custom("Figtree", size: 20).weight(.semibold))
        .foregroundColor(.black)
      Text(message)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(.black.opacity(0.6))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      Button("Retry") {
        loadState = .loading
        reloadToken += 1
      }
      .buttonStyle(.borderedProminent)
      .tint(Color(hex: "F96E00"))
    }
  }
}
