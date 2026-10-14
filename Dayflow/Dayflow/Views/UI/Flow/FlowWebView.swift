//
//  FlowWebView.swift
//  Dayflow
//
//  Hosts the remote Flow web app and bridges it to native. The web app owns
//  all Flow data (via the Dayflow backend); native supplies the auth token,
//  mirrors session state for the desktop overlay, and opens external links.
//
//  Bridge protocol (v1):
//    JS → native:  window.webkit.messageHandlers.flow.postMessage(
//                      {id?, command, payload?})
//    native → JS:  window.__dayflowFlow.receive(
//                      {id, ok, payload|error}         // reply to a command
//                      | {event, payload})             // unsolicited event
//
//  Commands: ready, getToken, state, simulateDistraction, getTimeline,
//            getWeeklyFocus, getPlan, startCheckout, startTrial,
//            openExternal, openSupport.
//  Events:   nativeState, overlayAction, supportUnread.
//
//  The bridge hands out the session token and numbers derived from the
//  user's timeline, so it only talks to the Flow page itself: messages are
//  dropped unless they come from the top frame on the Flow origin, and the
//  web view is never allowed to navigate anywhere else.
//

import SwiftUI
import WebKit

enum FlowWebConfiguration {
  static let bridgeVersion = 1
  static let urlOverrideDefaultsKey = "flowWebURLOverride"

  static var url: URL {
    // Pointing Flow at another host hands that host the bridge, so the
    // override exists in debug builds only.
    #if DEBUG
      if let override = UserDefaults.standard.string(forKey: urlOverrideDefaultsKey),
        let url = URL(string: override)
      {
        return url
      }
    #endif
    return URL(string: "https://www.dayflow.so/flow/")!
  }

  /// True for the origin the bridge trusts: the Flow URL's scheme, host and port.
  static func isFlowOrigin(scheme: String?, host: String?, port: Int?) -> Bool {
    let flow = url
    guard let scheme = scheme?.lowercased(), scheme == flow.scheme?.lowercased(),
      let host = host?.lowercased(), host == flow.host?.lowercased()
    else { return false }
    // WKSecurityOrigin reports 0 for a scheme's default port; URL reports nil.
    return (port ?? 0) == (flow.port ?? 0)
  }

  static func isFlowOrigin(_ url: URL?) -> Bool {
    guard let url else { return false }
    return isFlowOrigin(scheme: url.scheme, host: url.host, port: url.port)
  }
}

struct FlowWebView: NSViewRepresentable {
  enum Event {
    case loaded
    case failed(Error)
    /// The page's Support button was pressed.
    case supportRequested
  }

  let url: URL
  let onEvent: (Event) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onEvent: onEvent)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "flow")

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    #if DEBUG
      webView.isInspectable = true
    #endif

    context.coordinator.webView = webView
    FlowSessionMirror.shared.webBridge = context.coordinator
    if FlowSessionMirror.shared.pendingStartSession {
      FlowSessionMirror.shared.pendingStartSession = false
      context.coordinator.sendEvent("sessionControl", payload: ["action": "start"])
    }
    if LocalOnlyNetworking.allows(url) {
      webView.load(URLRequest(url: url))
    } else {
      webView.loadHTMLString(LocalOnlyNetworking.blockedPageHTML, baseURL: nil)
    }
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    nsView.configuration.userContentController.removeScriptMessageHandler(forName: "flow")
    nsView.navigationDelegate = nil
    nsView.uiDelegate = nil
    if FlowSessionMirror.shared.webBridge === coordinator {
      FlowSessionMirror.shared.hideDemo()
      FlowSessionMirror.shared.webBridge = nil
    }
  }

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate,
    FlowBridgeForwarding
  {
    private let onEvent: (Event) -> Void
    weak var webView: WKWebView?
    /// Events raised before the page said "ready" are held and flushed after.
    private var pageIsReady = false
    private var pendingEvents: [[String: Any]] = []

    init(onEvent: @escaping (Event) -> Void) {
      self.onEvent = onEvent
    }

    // MARK: JS → native

    nonisolated func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      let origin = message.frameInfo.securityOrigin
      guard message.name == "flow",
        message.frameInfo.isMainFrame,
        FlowWebConfiguration.isFlowOrigin(
          scheme: origin.protocol, host: origin.host, port: origin.port),
        let body = message.body as? [String: Any],
        let command = body["command"] as? String
      else { return }
      let id = body["id"] as? String
      let payload = body["payload"] as? [String: Any] ?? [:]

      Task { @MainActor in
        self.handle(command: command, id: id, payload: payload)
      }
    }

    private func handle(command: String, id: String?, payload: [String: Any]) {
      switch command {
      case "ready":
        // A reload mid-onboarding must not leave the demo creature on screen.
        FlowSessionMirror.shared.hideDemo()
        pageIsReady = true
        SupportChatSession.startFlowSupportMonitoring()
        onEvent(.loaded)
        reply(id: id, payload: handshakePayload())
        flushPendingEvents()

      case "getToken":
        reply(id: id, payload: ["token": DayflowAuthManager.storedSessionToken() as Any])

      case "state":
        // The web app is authoritative; it pushes a snapshot after every change.
        if let snapshot = FlowNativeSnapshot(bridgePayload: payload) {
          FlowSessionMirror.shared.apply(snapshot)
          reply(id: id, payload: [:])
        } else {
          reply(id: id, error: "invalid state payload")
        }

      case "simulateDistraction":
        FlowSessionMirror.shared.simulateDistraction()
        reply(id: id, payload: [:])

      case "getTimeline":
        // The session summary wants the agent's activity timeline: hand over
        // whatever the last update produced, right away (no model turn, no
        // waiting on an in-flight tick).
        let timeline = FlowSessionTimeline.shared
        timeline.finish()
        reply(
          id: id,
          payload: [
            "activities": timeline.bridgePayload,
            "file": timeline.fileURL.path,
          ])

      case "getWeeklyFocus":
        // The paywall shows last week's focus heat map. The page draws it
        // from scores alone; card text never crosses the bridge.
        let categories = CategoryStore.shared.categories
        Task { [weak self] in
          let focus = await Task.detached(priority: .userInitiated) {
            let range = WeeklyDateRange.containing(Date()).shifted(byWeeks: -1)
            let cards = StorageManager.shared.fetchTimelineCardsByTimeRange(
              from: range.weekStart, to: range.weekEnd)
            return WeeklyDashboardBuilder.buildFlowFocus(
              cards: cards, categories: categories, weekRange: range)
          }.value
          self?.reply(id: id, payload: focus.bridgePayload)
        }

      case "getCategoryWeek":
        // The session-complete radar opens on how the last seven days split
        // across the user's categories. Only names, colours and minute
        // totals cross; idle and system time is left out.
        let categories = CategoryStore.shared.categories
          .filter { !$0.isIdle && !$0.isSystem }
          .sorted { $0.order < $1.order }
        Task { [weak self] in
          let minutes = await Task.detached(priority: .userInitiated) { () -> [String: Double] in
            let now = Date()
            let start = now.addingTimeInterval(-7 * 24 * 60 * 60)
            var totals: [String: Double] = [:]
            for card in StorageManager.shared.fetchTimelineCardsByTimeRange(from: start, to: now) {
              guard let from = WeeklyDashboardBuilder.parseCardMinute(card.startTimestamp),
                let to = WeeklyDashboardBuilder.parseCardMinute(card.endTimestamp)
              else { continue }
              let range = WeeklyDashboardBuilder.normalizedMinuteRange(start: from, end: to)
              let key = card.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
              totals[key, default: 0] += max(0, range.end - range.start)
            }
            return totals
          }.value
          let rows: [[String: Any]] = categories.map { category in
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
              "name": String(name.prefix(60)),
              "color": category.colorHex,
              "minutes": (minutes[name.lowercased()] ?? 0).rounded(),
            ]
          }
          self?.reply(id: id, payload: ["categories": rows])
        }

      case "getDayTimeline":
        // Voice planning can answer "what did I do yesterday?". Only what the
        // timeline shows as a card's heading crosses: times, title, category.
        // Summaries, app and site lists and screenshots stay in the app, and
        // the page can only ask about the last seven days.
        let daysAgo = min(6, max(0, payload["daysAgo"] as? Int ?? 0))
        Task { [weak self] in
          let cards = await Task.detached(priority: .userInitiated) { () -> [[String: Any]] in
            // A Dayflow day runs from 4 AM to 4 AM.
            let calendar = Calendar.current
            let shifted = calendar.date(byAdding: .hour, value: -4, to: Date()) ?? Date()
            guard
              let day = calendar.date(
                byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: shifted)),
              let start = calendar.date(byAdding: .hour, value: 4, to: day),
              let end = calendar.date(byAdding: .day, value: 1, to: start)
            else { return [] }
            return StorageManager.shared.fetchTimelineCardsByTimeRange(from: start, to: end)
              .prefix(80)
              .map { card in
                [
                  "start": card.startTimestamp,
                  "end": card.endTimestamp,
                  "title": String(card.title.prefix(120)),
                  "category": String(card.category.prefix(40)),
                ]
              }
          }.value
          self?.reply(id: id, payload: ["daysAgo": daysAgo, "cards": cards])
        }

      case "getPlan":
        Task { @MainActor [weak self] in
          await DayflowAuthManager.shared.refreshIfAwaitingCheckout()
          self?.reply(id: id, payload: self?.planPayload() ?? [:])
        }

      case "startCheckout":
        // Same path as the Settings upgrade button, but for Dayflow Plus: the
        // backend makes the Stripe Checkout link for the signed-in account at
        // the price it was offered, and it opens in the browser. The page then asks getPlan until the subscription lands.
        let interval =
          DayflowBillingInterval(rawValue: payload["interval"] as? String ?? "") ?? .yearly
        Task { @MainActor [weak self] in
          let auth = DayflowAuthManager.shared
          await auth.openBillingCheckout(interval: interval, plan: "plus")
          self?.reply(id: id, payload: self?.planPayload(error: auth.errorText) ?? [:])
        }

      case "startTrial":
        Task { @MainActor [weak self] in
          let auth = DayflowAuthManager.shared
          await auth.startPlusTrial()
          self?.reply(id: id, payload: self?.planPayload(error: auth.errorText) ?? [:])
        }

      case "onboardingAlert":
        // Onboarding's pop-in beats use the real overlay at the screen edge.
        // The text comes from the Flow page, so cap what it can put up.
        if let message = payload["message"] as? String, let answer = payload["reply"] as? String,
          !message.isEmpty, !answer.isEmpty
        {
          FlowSessionMirror.shared.showDemo(
            message: String(message.prefix(200)), reply: String(answer.prefix(40)),
            feisty: payload["style"] as? String == "feisty")
        } else {
          FlowSessionMirror.shared.hideDemo()
        }
        reply(id: id, payload: ["shown": FlowSessionMirror.shared.overlay.isDemo])

      case "openExternal":
        if let urlString = payload["url"] as? String, let url = URL(string: urlString),
          url.scheme == "https" || url.scheme == "http"
        {
          NSWorkspace.shared.open(url)
          reply(id: id, payload: [:])
        } else {
          reply(id: id, error: "invalid url")
        }

      case "openSupport":
        onEvent(.supportRequested)
        reply(id: id, payload: [:])

      default:
        reply(id: id, error: "unknown command: \(command)")
      }
    }

    private func handshakePayload() -> [String: Any] {
      var payload: [String: Any] = [
        "bridgeVersion": FlowWebConfiguration.bridgeVersion,
        "nativeState": FlowSessionMirror.shared.snapshot.bridgePayload,
        "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
      ]
      // Commands newer than the first bridge, so the page knows what it can ask for.
      payload["capabilities"] = ["dayTimeline", "supportChat"]
      payload["supportUnread"] = SupportChatSession.flowSupportUnreadCount
      payload["token"] = DayflowAuthManager.storedSessionToken()
      payload["backendURL"] = DayflowBackendConfiguration.endpoint()
      // Lets the web app's own analytics report as the same PostHog person
      // as the app (distinctId is nil when the app's analytics is off; Flow
      // then identifies by the signed-in user instead).
      var analytics: [String: Any] = ["optedIn": AnalyticsService.shared.isOptedIn]
      analytics["distinctId"] = AnalyticsService.shared.currentDistinctId()
      payload["analytics"] = analytics
      return payload
    }

    // MARK: native → JS

    func sendEvent(_ event: String, payload: [String: Any]) {
      deliver(["event": event, "payload": payload])
    }

    private func planPayload(error: String? = nil) -> [String: Any] {
      let entitlements = DayflowAuthManager.shared.entitlements
      var payload: [String: Any] = [
        // Flow comes with Dayflow Plus and with Dayflow Pro.
        "active": entitlements.status == "active"
          && (entitlements.plan == "plus" || entitlements.plan == "pro"),
        "plan": entitlements.plan,
        "source": entitlements.source ?? "",
      ]
      if let error { payload["error"] = error }
      return payload
    }

    private func reply(id: String?, payload: [String: Any]) {
      guard let id else { return }
      deliver(["id": id, "ok": true, "payload": payload])
    }

    private func reply(id: String?, error: String) {
      guard let id else { return }
      deliver(["id": id, "ok": false, "error": error])
    }

    private func deliver(_ message: [String: Any]) {
      let isReply = message["id"] != nil
      guard pageIsReady || isReply else {
        pendingEvents.append(message)
        return
      }
      guard let webView,
        let data = try? JSONSerialization.data(withJSONObject: message),
        let json = String(data: data, encoding: .utf8)
      else { return }
      webView.evaluateJavaScript(
        "window.__dayflowFlow && window.__dayflowFlow.receive(\(json))", completionHandler: nil)
    }

    private func flushPendingEvents() {
      let queued = pendingEvents
      pendingEvents = []
      queued.forEach(deliver)
    }

    // MARK: Navigation

    nonisolated func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      // The top frame never leaves the Flow origin, however the navigation
      // started (link, script, redirect), so nothing else can sit where the
      // bridge listens. Links the user clicked open in the browser instead
      // (new windows go to createWebViewWith below, which does the same and
      // never loads them here). Frames inside the page are left alone; the
      // bridge ignores them.
      let isTopFrame = navigationAction.targetFrame?.isMainFrame == true
      if isTopFrame, !FlowWebConfiguration.isFlowOrigin(navigationAction.request.url) {
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated,
          let url = navigationAction.request.url,
          url.scheme == "https" || url.scheme == "http"
        {
          DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
          }
        }
        return
      }
      decisionHandler(.allow)
    }

    nonisolated func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http" {
        DispatchQueue.main.async {
          NSWorkspace.shared.open(url)
        }
      }
      return nil
    }

    // "Add more to my plan" talks to Flow over the microphone. Grant the
    // Flow origin's capture request straight through; the system's own
    // microphone consent (NSMicrophoneUsageDescription) still applies.
    nonisolated func webView(
      _ webView: WKWebView,
      requestMediaCapturePermissionFor origin: WKSecurityOrigin,
      initiatedByFrame frame: WKFrameInfo,
      type: WKMediaCaptureType,
      decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
      let allowed =
        type == .microphone && frame.isMainFrame
        && FlowWebConfiguration.isFlowOrigin(
          scheme: origin.protocol, host: origin.host, port: origin.port)
      decisionHandler(allowed ? .grant : .deny)
    }

    nonisolated func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      Task { @MainActor in
        self.onEvent(.failed(error))
      }
    }

    nonisolated func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      Task { @MainActor in
        self.onEvent(.failed(error))
      }
    }
  }
}
