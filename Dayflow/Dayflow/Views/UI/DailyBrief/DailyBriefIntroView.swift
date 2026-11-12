//
//  DailyBriefIntroView.swift
//  Dayflow
//
//  The "Introducing Dayflow Daily Briefs" walkthrough: four steps, then an envelope whose
//  seal opens the first brief (Figma › Daily: 563:10268, 563:28112, 563:28687 + 563:31262,
//  563:32024). It's a bundled web page, DailyBriefIntro.html, because its animations were
//  built in HTML; edit them in scripts/daily_brief_intro/src and run build.py.
//
//  The page talks back through the "dailyBriefIntro" message handler:
//    {command: "ready"}, {command: "step", index}, {command: "finish"}, {command: "skip", step}
//

import SwiftUI
import WebKit

/// The dimmed backdrop and the 730 × 422 intro modal, centered over the brief.
struct DailyBriefIntroLayer: View {
  @ObservedObject private var store = DailyBriefStore.shared

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color.black.opacity(0.46), Color.black.opacity(0.58)],
        startPoint: .top, endPoint: .bottom
      )
      // Clicks on the backdrop don't close the intro or reach the brief underneath.
      .contentShape(Rectangle())
      .onTapGesture {}

      if let url = DailyBriefIntroWebView.pageURL {
        DailyBriefIntroWebView(url: url) { command in
          handle(command)
        }
        .frame(width: 730, height: 422)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
      }
    }
    .onAppear {
      // Without the page there's nothing to show, so go straight to the brief.
      if DailyBriefIntroWebView.pageURL == nil {
        store.finishIntro("missing", step: 0)
      }
    }
  }

  private func handle(_ command: DailyBriefIntroWebView.Command) {
    switch command {
    case .step(let index):
      store.introStep = index
      AnalyticsService.shared.capture("daily_brief_intro_step", ["step": index + 1])
    case .finish:
      store.finishIntro("finished", step: store.introStep)
    case .skip:
      store.finishIntro("skipped", step: store.introStep)
    }
  }
}

/// Hosts DailyBriefIntro.html. The page is local and never navigates anywhere else.
struct DailyBriefIntroWebView: NSViewRepresentable {
  enum Command {
    case step(Int)
    case finish
    case skip
  }

  static let messageHandlerName = "dailyBriefIntro"

  static var pageURL: URL? {
    Bundle.main.url(forResource: "DailyBriefIntro", withExtension: "html")
  }

  let url: URL
  let onCommand: (Command) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(pageURL: url, onCommand: onCommand)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: Self.messageHandlerName)

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    webView.allowsMagnification = false
    webView.allowsBackForwardNavigationGestures = false
    #if DEBUG
      webView.isInspectable = true
    #endif
    webView.loadFileURL(url, allowingReadAccessTo: url)
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.onCommand = onCommand
  }

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    nsView.configuration.userContentController.removeScriptMessageHandler(
      forName: messageHandlerName)
    nsView.navigationDelegate = nil
  }

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let pageURL: URL
    var onCommand: (Command) -> Void

    init(pageURL: URL, onCommand: @escaping (Command) -> Void) {
      self.pageURL = pageURL
      self.onCommand = onCommand
    }

    // MARK: Page → app

    nonisolated func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      // WebKit delivers script messages on the main thread.
      MainActor.assumeIsolated {
        self.receive(message)
      }
    }

    private func receive(_ message: WKScriptMessage) {
      guard message.frameInfo.isMainFrame,
        let body = message.body as? [String: Any],
        let name = body["command"] as? String
      else { return }

      switch name {
      case "step": onCommand(.step(body["index"] as? Int ?? 0))
      case "finish": onCommand(.finish)
      case "skip": onCommand(.skip)
      default: break  // "ready" needs nothing
      }
    }

    // MARK: Navigation

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      // Only the bundled page itself loads.
      let isPage = navigationAction.request.url?.standardizedFileURL == pageURL.standardizedFileURL
      decisionHandler(isPage ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      // So the arrow keys move between steps without clicking the page first.
      webView.window?.makeFirstResponder(webView)
    }
  }
}
