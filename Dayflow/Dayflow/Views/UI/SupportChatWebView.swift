//
//  SupportChatWebView.swift
//  Dayflow
//
//  In-app support chat backed by PostHog Support ("conversations"). The Swift
//  PostHog SDK has no conversations API, so we host a small local HTML page in
//  a WKWebView that loads posthog-js and drives `posthog.conversations`
//  directly. The page is identified with the native SDK's distinct ID so every
//  ticket lands on the same PostHog person as the app's analytics.
//
//  Bridge:
//    JS → native:  window.webkit.messageHandlers.support.postMessage({event, ...})
//                  events: ready, unavailable, sent, requestDebugLog, openExternal
//    native → JS:  window.__dayflowSupport.receiveDebugLog(text)
//                  window.__dayflowSupport.applyPalette(palette)
//
//  Tickets are keyed by this install's widget session, so the page asks for an
//  email before the first message so we can still reply if the app is closed.
//
//  Images: PostHog messages are text-only, so pasted or dropped images are
//  uploaded to the Dayflow backend and sent as URLs inside the message text.
//  Any message line that is one of those URLs renders as an image.
//

import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - Palette

/// The handful of colors the chat page needs, as CSS color strings.
struct SupportChatPalette: Equatable {
  let values: [String: String]

  /// Light-mode colors, matching the rest of the app's hard-coded palette.
  static let light = SupportChatPalette(values: [
    "textPrimary": css(Color(hex: "333333")),
    "textSecondary": css(Color(hex: "707070")),
    "textMuted": css(Color(hex: "979797")),
    "accent": css(Color(hex: "F3854B")),
    "userBubbleFill": css(Color(hex: "FFD2B9")),
    "userBubbleBorder": css(Color(hex: "EAD5CD")),
    "userBubbleText": css(Color(hex: "606060")),
    "teamBubbleFill": css(Color.white.opacity(0.9)),
    "teamBubbleBorder": css(Color(hex: "D0D0D0")),
    "inputFill": css(Color.white.opacity(0.9)),
    "inputBorder": css(Color(hex: "E1E1E1")),
    "sendFill": css(Color(hex: "FF9F6F")),
    "sendBorder": css(Color(hex: "F4C8B1")),
    "sendText": css(Color.white),
    "chipFill": css(Color.white.opacity(0.9)),
    "chipBorder": css(Color(hex: "E1E1E1")),
    "chipText": css(Color(hex: "333333")),
    "divider": css(Color(hex: "E7E5E3")),
    "colorScheme": "light",
  ])

  private static func css(_ color: Color) -> String {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "rgba(0,0,0,1)" }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    let a = String(format: "%.3f", rgb.alphaComponent)
    return "rgba(\(r),\(g),\(b),\(a))"
  }
}

enum SupportChatContext: Equatable {
  case support
  case flowWaitlist(email: String, accountID: String? = nil)

  var isFlowWaitlist: Bool {
    if case .flowWaitlist = self { return true }
    return false
  }

  var email: String? {
    guard case .flowWaitlist(let email, _) = self else { return nil }
    return email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  var accountID: String? {
    guard case .flowWaitlist(_, let accountID) = self,
      let normalizedID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !normalizedID.isEmpty
    else { return nil }
    return normalizedID
  }

  var sessionKey: String {
    guard let email else { return "support" }
    guard let accountID else { return "signed-out:\(email)" }
    return "account:\(accountID.utf8.count):\(accountID):\(email)"
  }
}

/// Retains each conversation independently so Flow never shares a support ticket.
@MainActor
final class SupportChatSession {
  static let shared = SupportChatSession(context: .support)
  private static var flowWaitlistSessions: [String: SupportChatSession] = [:]
  private static var activeFlowWaitlistSession: SupportChatSession?
  private static var flowAccountObserver: AnyCancellable?

  static func startFlowWaitlistMonitoring() {
    guard flowAccountObserver == nil else { return }
    // Published properties send before their values change; read the settled
    // account on the next run-loop turn.
    flowAccountObserver = DayflowAuthManager.shared.objectWillChange
      .receive(on: RunLoop.main)
      .sink { refreshFlowWaitlistMonitoring() }
    refreshFlowWaitlistMonitoring()
  }

  static func refreshFlowWaitlistMonitoring() {
    let auth = DayflowAuthManager.shared
    guard auth.hasLoadedStoredSession, !auth.isRestoringStoredSession else { return }
    let registration = FlowWaitlistRegistration()
    let shouldMonitor =
      !auth.flowEnabled
      && registration.belongsTo(userID: auth.user?.id, email: auth.user?.email)
    let nextSession =
      shouldMonitor
      ? flowWaitlist(email: registration.email, accountID: registration.chatContext.accountID) : nil
    guard activeFlowWaitlistSession !== nextSession else { return }
    if activeFlowWaitlistSession != nil || nextSession == nil {
      NotificationService.shared.clearFlowWaitlistReplyNotification()
    }
    if activeFlowWaitlistSession !== flowSupportSession { activeFlowWaitlistSession?.stop() }
    activeFlowWaitlistSession = nextSession
    let unreadCount = nextSession?.replyState.unreadCount ?? 0
    NotificationBadgeManager.shared.setFlowWaitlistUnreadCount(
      unreadCount,
      sessionKey: nextSession?.context.sessionKey
    )
    nextSession?.start()
  }

  // MARK: Flow support

  /// The conversation behind Flow's Support button, watched while Flow is
  /// open so the page can show a dot when a reply is waiting.
  private static var flowSupportSession: SupportChatSession?

  /// Someone who joined the waitlist on this Mac keeps the conversation they
  /// started there; anyone else gets one keyed to their account.
  static func flowSupportContext() -> SupportChatContext {
    let user = DayflowAuthManager.shared.user
    let registration = FlowWaitlistRegistration()
    if registration.belongsTo(userID: user?.id, email: user?.email) {
      return registration.chatContext
    }
    guard let user else { return .support }
    return .flowWaitlist(email: user.email, accountID: user.id)
  }

  static func session(for context: SupportChatContext) -> SupportChatSession {
    switch context {
    case .support: return .shared
    case .flowWaitlist(let email, let accountID):
      return .flowWaitlist(email: email, accountID: accountID)
    }
  }

  static func startFlowSupportMonitoring() {
    let context = flowSupportContext()
    guard context.isFlowWaitlist else { return }
    let next = session(for: context)
    if flowSupportSession !== next, flowSupportSession !== activeFlowWaitlistSession {
      flowSupportSession?.stop()
    }
    flowSupportSession = next
    next.start()
  }

  static var flowSupportUnreadCount: Int {
    flowSupportSession?.replyState.unreadCount ?? 0
  }

  static func flowWaitlist(email: String, accountID: String? = nil) -> SupportChatSession {
    let context = SupportChatContext.flowWaitlist(email: email, accountID: accountID)
    if let session = flowWaitlistSessions[context.sessionKey] { return session }
    let session = SupportChatSession(context: context)
    flowWaitlistSessions[context.sessionKey] = session
    return session
  }

  let context: SupportChatContext
  let websiteDataStore: WKWebsiteDataStore
  lazy var coordinator = SupportChatWebView.Coordinator(session: self, onEvent: { _ in })
  lazy var webView = SupportChatWebView.makeWebView(session: self)
  /// Flow's support overlay and the waitlist screen share one conversation
  /// and page, so each sets its own composer placeholder when it shows.
  func setMessagePlaceholder(_ text: String) {
    guard let data = try? JSONEncoder().encode(text),
      let literal = String(data: data, encoding: .utf8)
    else { return }
    webView.evaluateJavaScript(
      "var t = document.getElementById('text'); if (t) { t.placeholder = \(literal); }")
  }

  private var timer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var chatVisible = false
  private var lastPoll = Date.distantPast
  private(set) var ready = false
  private var failed = false
  private let defaults = UserDefaults.standard

  private init(context: SupportChatContext) {
    self.context = context
    if let email = context.email {
      // PostHog keys conversations by project token, so a separate data store
      // keeps Support and other accounts out of this conversation.
      let key = "flowWaitlistChatDataStores"
      var identifiers = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
      let storedID =
        identifiers[context.sessionKey]
        ?? (context.accountID == nil ? identifiers[email] : nil)
      let identifier = storedID.flatMap(UUID.init(uuidString:)) ?? UUID()
      identifiers[context.sessionKey] = identifier.uuidString
      // Only the signed-out scope may inherit the original anonymous conversation.
      if context.accountID == nil { identifiers.removeValue(forKey: email) }
      UserDefaults.standard.set(identifiers, forKey: key)
      websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
    } else {
      websiteDataStore = .default()
    }
  }

  var pageURL: URL {
    URL(
      string: context.isFlowWaitlist
        ? "https://www.dayflow.so/flow-waitlist-chat" : "https://www.dayflow.so/support-chat"
    )!
  }

  func start() {
    guard timer == nil else { return }
    _ = webView
    if failed { reload() }
    timer = Timer.scheduledTimer(withTimeInterval: Self.readingPollInterval, repeats: true) {
      [weak self] _ in
      Task { @MainActor [weak self] in self?.pollIfDue() }
    }
    guard observers.isEmpty else { return }
    for name in [
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
    ] {
      let observer = NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.chatVisible else { return }
          self.updateReading()
        }
      }
      observers.append(observer)
    }
  }

  func setVisible(_ visible: Bool) {
    chatVisible = visible
    if visible { start() }
    updateReading()
  }

  private func stop() {
    chatVisible = false
    updateReading()
    timer?.invalidate()
    timer = nil
  }

  func didBecomeReady() {
    ready = true
    failed = false
    updateReading()
  }

  func didBecomeUnavailable() {
    ready = false
    failed = true
  }

  private func reload() {
    failed = false
    webView.loadHTMLString(SupportChatPage.html, baseURL: pageURL)
  }

  // Each poll asks the Dayflow backend whether the ticket has anything new;
  // the page only fetches from PostHog when it does.
  private static let readingPollInterval: TimeInterval = 5
  private static let backgroundPollInterval: TimeInterval = 60
  private static let reloadInterval: TimeInterval = 60

  private var isReading: Bool {
    let windowVisible = webView.window.map { $0.isVisible && !$0.isMiniaturized } ?? false
    return chatVisible && NSApp.isActive && windowVisible
  }

  private func pollIfDue() {
    let interval =
      !ready
      ? Self.reloadInterval
      : (isReading ? Self.readingPollInterval : Self.backgroundPollInterval)
    guard Date().timeIntervalSince(lastPoll) >= interval else { return }
    if ready {
      updateReading()
    } else if failed {
      lastPoll = Date()
      reload()
    }
  }

  /// Tells the page whether the chat is on screen, which also checks for new messages.
  private func updateReading() {
    guard ready, timer != nil else { return }
    lastPoll = Date()
    coordinator.send("setReading", isReading)
  }

  private var replyState: ChatReplyState {
    ChatReplyState(
      defaults: defaults,
      keyPrefix: context.isFlowWaitlist ? "flowWaitlist.\(context.sessionKey)" : "support"
    )
  }

  func receiveReplies(_ body: [String: Any]) {
    if Self.flowSupportSession === self, Self.activeFlowWaitlistSession !== self {
      // Flow's own Support button: only the dot on the page, no Dock badge.
      _ = replyState.receive(
        unreadCount: body["unread"] as? Int ?? 0, latestReplyID: body["latestID"] as? String)
      FlowSessionMirror.shared.webBridge?.sendEvent(
        "supportUnread", payload: ["count": replyState.unreadCount])
      return
    }
    guard !context.isFlowWaitlist || Self.activeFlowWaitlistSession === self else { return }
    let shouldNotify = replyState.receive(
      unreadCount: body["unread"] as? Int ?? 0, latestReplyID: body["latestID"] as? String)
    let unread = replyState.unreadCount
    if context.isFlowWaitlist {
      NotificationBadgeManager.shared.setFlowWaitlistUnreadCount(
        unread, sessionKey: context.sessionKey)
      if unread == 0 {
        NotificationService.shared.clearFlowWaitlistReplyNotification()
      } else if shouldNotify {
        NotificationService.shared.notifyFlowWaitlistReply(sessionKey: context.sessionKey)
      }
      return
    }
    NotificationBadgeManager.shared.setSupportUnreadCount(unread)
    if unread == 0 {
      NotificationService.shared.clearSupportReplyNotification()
    } else if shouldNotify {
      NotificationService.shared.notifySupportReply()
    }
  }
}

// MARK: - View

struct SupportChatWebView: NSViewRepresentable {
  enum Event {
    case ready
    case unavailable(reason: String)
  }

  let palette: SupportChatPalette
  let context: SupportChatContext
  let onEvent: (Event) -> Void

  init(
    palette: SupportChatPalette,
    context: SupportChatContext = .support,
    onEvent: @escaping (Event) -> Void
  ) {
    self.palette = palette
    self.context = context
    self.onEvent = onEvent
  }

  private var session: SupportChatSession { .session(for: context) }

  func makeCoordinator() -> Coordinator {
    session.coordinator.onEvent = onEvent
    return session.coordinator
  }

  func makeNSView(context: Context) -> WKWebView {
    let session = session
    if session.ready {
      DispatchQueue.main.async { session.coordinator.onEvent(.ready) }
    }
    return session.webView
  }

  static func makeWebView(session: SupportChatSession) -> WKWebView {
    let coordinator = session.coordinator
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = session.websiteDataStore
    configuration.userContentController.add(coordinator, name: "support")
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.configScript(palette: .light, context: session.context),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    webView.uiDelegate = coordinator
    webView.setValue(false, forKey: "drawsBackground")
    #if DEBUG
      webView.isInspectable = true
    #endif

    coordinator.webView = webView
    coordinator.lastPalette = .light
    webView.loadHTMLString(LocalOnlyNetworking.blockedPageHTML, baseURL: nil)
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    guard context.coordinator.lastPalette != palette else { return }
    context.coordinator.lastPalette = palette
    context.coordinator.send("applyPalette", palette.values)
  }

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    coordinator.onEvent = { _ in }
  }

  /// Everything the page needs before posthog-js loads: keys, distinct ID, and theme.
  private static func configScript(palette: SupportChatPalette, context: SupportChatContext)
    -> String
  {
    let info = Bundle.main.infoDictionary
    var config: [String: Any] = [
      "token": info?["PHPostHogApiKey"] as? String ?? "",
      "apiHost": info?["PHPostHogHost"] as? String ?? "https://us.i.posthog.com",
      "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
      "backendURL": DayflowBackendConfiguration.endpoint() ?? "",
      "palette": palette.values,
      "language": Bundle.main.preferredLocalizations.first ?? "en",
      "flowWaitlist": context.isFlowWaitlist,
      "email": context.email ?? "",
      "strings": [
        "email": String(localized: "Your email"),
        "emailPlaceholder": String(localized: "so we can reply if you close the app"),
        "messagePlaceholder": context.isFlowWaitlist
          ? String(localized: "Who are you, and how would you use Flow?")
          // The image hint is its own string so the original keeps its translations.
          : String(localized: "What's going on? Bugs, ideas, confusion — all welcome.") + " "
            + String(localized: "Paste or drop screenshots here too."),
        "debug": String(localized: "Attach debug logs"),
        "send": String(localized: "Send"),
        "you": String(localized: "You"),
        "greeting": context.isFlowWaitlist
          ? String(
            localized:
              "You're on the Flow waitlist! Tell us a little about yourself and what you'd like to use Flow for. The more detail you share, the sooner we can review your request and get you off the waitlist. Our team will reply here."
          )
          : String(
            localized:
              "Hey there! Found a bug, have an idea, or just confused about something? Drop it here and a real person on the Dayflow team will get back to you in this chat."
          ),
        "emailRequired": String(localized: "Add your email so we can reply."),
        "unavailable": String(localized: "Support is not available right now."),
        "sent": context.isFlowWaitlist
          ? String(localized: "Sent. Our team will reply here.")
          : String(localized: "Sent. Replies show up here and in your inbox."),
        "sendFailed": String(localized: "Couldn't send. Try again."),
        "rateLimited": String(localized: "Slow down a little — try again in a minute."),
        "dropHint": String(localized: "Drop images to attach"),
        "imageUnsupported": String(localized: "That file type isn't supported."),
        "imageTooLarge": String(localized: "Images can be up to 50 MB."),
        "imageFailed": String(localized: "Couldn't upload that image. Try again."),
      ],
    ]
    if let distinctId = AnalyticsService.shared.currentDistinctId() {
      config["distinctId"] = distinctId
    }
    guard let data = try? JSONSerialization.data(withJSONObject: config),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return "window.__dayflowSupportConfig = \(json);"
  }

  // MARK: Coordinator

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    var onEvent: (Event) -> Void
    weak var webView: WKWebView?
    weak var session: SupportChatSession?
    var lastPalette: SupportChatPalette?

    init(session: SupportChatSession, onEvent: @escaping (Event) -> Void) {
      self.session = session
      self.onEvent = onEvent
    }

    // MARK: JS → native

    nonisolated func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == "support",
        let body = message.body as? [String: Any],
        let event = body["event"] as? String
      else { return }

      Task { @MainActor in
        self.handle(event: event, body: body)
      }
    }

    private func handle(event: String, body: [String: Any]) {
      switch event {
      case "ready":
        session?.didBecomeReady()
        onEvent(.ready)

      case "unavailable":
        session?.didBecomeUnavailable()
        let reason = body["reason"] as? String ?? "unknown"
        AnalyticsService.shared.capture(
          session?.context.isFlowWaitlist == true
            ? "flow_waitlist_chat_unavailable" : "support_chat_unavailable",
          ["reason": reason]
        )
        onEvent(.unavailable(reason: reason))

      case "replies":
        session?.receiveReplies(body)

      case "sent":
        Task { await NotificationService.shared.requestPermission() }
        AnalyticsService.shared.capture(
          session?.context.isFlowWaitlist == true
            ? "flow_waitlist_message_sent" : "support_message_sent",
          [
            "has_debug_log": body["hasDebugLog"] as? Bool ?? false,
            "new_ticket": body["newTicket"] as? Bool ?? false,
          ]
        )

      case "requestDebugLog":
        guard session?.context.isFlowWaitlist != true else { return }
        Task.detached(priority: .userInitiated) {
          let snapshot = DebugLogSnapshot.makeCurrent()
          await MainActor.run {
            AnalyticsService.shared.capture(
              "support_debug_log_attached", snapshot.analyticsProperties)
            self.send("receiveDebugLog", snapshot.text)
          }
        }

      case "openExternal":
        if let urlString = body["url"] as? String, let url = URL(string: urlString),
          url.scheme == "https" || url.scheme == "http"
        {
          NSWorkspace.shared.open(url)
        }

      default:
        break
      }
    }

    // MARK: native → JS

    func send(_ function: String, _ argument: Any) {
      guard let webView,
        let data = try? JSONSerialization.data(
          withJSONObject: argument, options: [.fragmentsAllowed]),
        let json = String(data: data, encoding: .utf8)
      else { return }
      webView.evaluateJavaScript(
        "window.__dayflowSupport && window.__dayflowSupport.\(function)(\(json))",
        completionHandler: nil
      )
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      Task { @MainActor in
        self.session?.didBecomeUnavailable()
      }
    }

    // MARK: Navigation

    // Any link inside the page opens in the real browser.
    nonisolated func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url
      {
        decisionHandler(.cancel)
        DispatchQueue.main.async {
          NSWorkspace.shared.open(url)
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
      if let url = navigationAction.request.url {
        DispatchQueue.main.async {
          NSWorkspace.shared.open(url)
        }
      }
      return nil
    }

    nonisolated func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      Task { @MainActor in
        self.session?.didBecomeUnavailable()
        self.onEvent(.unavailable(reason: "load_failed"))
      }
    }

    nonisolated func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      Task { @MainActor in
        self.session?.didBecomeUnavailable()
        self.onEvent(.unavailable(reason: "load_failed"))
      }
    }
  }
}

// MARK: - Page

/// The chat page itself. Kept as one raw string so the JS needs no escaping.
private enum SupportChatPage {
  static let html = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root {
        --text-primary: #333;
        --text-secondary: #707070;
        --text-muted: #979797;
        --accent: #F3854B;
        --user-fill: #FFD2B9;
        --user-border: #EAD5CD;
        --user-text: #606060;
        --team-fill: rgba(255,255,255,0.9);
        --team-border: #D0D0D0;
        --input-fill: rgba(255,255,255,0.9);
        --input-border: #E1E1E1;
        --send-fill: #FF9F6F;
        --send-border: #F4C8B1;
        --send-text: #fff;
        --chip-fill: rgba(255,255,255,0.9);
        --chip-border: #E1E1E1;
        --chip-text: #333;
        --divider: #E7E5E3;
      }
      * { box-sizing: border-box; }
      html, body {
        margin: 0; padding: 0; height: 100%;
        background: transparent;
        font-family: "Figtree", -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        font-size: 14px; line-height: 1.45;
        color: var(--text-primary);
        -webkit-font-smoothing: antialiased;
        -webkit-user-select: none; user-select: none;
      }
      #app { display: flex; flex-direction: column; height: 100%; }

      #messages {
        flex: 1; overflow-y: auto; padding: 18px 18px 8px;
        display: flex; flex-direction: column; gap: 10px;
      }
      .msg {
        max-width: 78%; padding: 10px 14px; border-radius: 16px;
        white-space: pre-wrap; word-wrap: break-word;
        -webkit-user-select: text; user-select: text;
      }
      .msg.team {
        align-self: flex-start;
        background: var(--team-fill); border: 1px solid var(--team-border);
        border-bottom-left-radius: 6px;
      }
      .msg.user {
        align-self: flex-end;
        background: var(--user-fill); border: 1px solid var(--user-border);
        color: var(--user-text); border-bottom-right-radius: 6px;
      }
      .meta { font-size: 11px; color: var(--text-muted); margin: -4px 6px 0; }
      .meta.user { align-self: flex-end; }
      .meta.team { align-self: flex-start; }
      .msg a { color: var(--accent); }
      .msg img {
        display: block; max-width: 100%; max-height: 260px;
        border-radius: 10px; margin-top: 6px;
      }
      .msg img:only-child, .msg a:first-child img { margin-top: 0; }
      .status {
        align-self: center; font-size: 12px; color: var(--text-muted);
        padding: 4px 0;
      }

      #composer {
        border-top: 1px solid var(--divider);
        padding: 12px 16px 14px;
        display: flex; flex-direction: column; gap: 10px;
      }
      #email-row { display: flex; align-items: center; gap: 8px; }
      #email-row label { font-size: 12px; color: var(--text-secondary); white-space: nowrap; }
      input, textarea {
        font: inherit; color: var(--text-primary);
        background: var(--input-fill); border: 1px solid var(--input-border);
        border-radius: 12px; padding: 9px 12px; outline: none;
        -webkit-user-select: text; user-select: text;
      }
      input::placeholder, textarea::placeholder { color: var(--text-muted); }
      input:focus, textarea:focus { border-color: var(--accent); }
      #email { flex: 1; padding: 6px 10px; border-radius: 10px; font-size: 13px; }
      #text { width: 100%; resize: none; min-height: 64px; max-height: 160px; }

      #attachments { display: flex; flex-wrap: wrap; gap: 10px; }
      #attachments:empty { display: none; }
      .attachment {
        position: relative; width: 56px; height: 56px; border-radius: 10px;
        display: flex; align-items: center; justify-content: center;
        color: var(--text-muted);
        background: var(--input-fill) center / cover no-repeat;
        border: 1px solid var(--input-border);
      }
      .attachment button {
        position: absolute; top: -7px; right: -7px; width: 18px; height: 18px;
        padding: 0; border-radius: 50%; cursor: pointer;
        font-size: 12px; line-height: 1; color: var(--text-secondary);
        background: var(--chip-fill); border: 1px solid var(--chip-border);
      }
      /* Covers the whole chat so an image can be dropped anywhere. */
      #drop-overlay {
        position: fixed; inset: 0; z-index: 10; pointer-events: none;
        display: none; align-items: center; justify-content: center;
        font-weight: 600; color: var(--accent);
        background: var(--team-fill);
        border: 2px dashed var(--accent); border-radius: 20px;
      }
      body.dragging #drop-overlay { display: flex; }

      #actions { display: flex; align-items: center; gap: 10px; }
      #debug-toggle {
        display: inline-flex; align-items: center; gap: 7px;
        padding: 5px 11px; border-radius: 999px; cursor: pointer;
        font-size: 12px; color: var(--chip-text);
        background: var(--chip-fill); border: 1px solid var(--chip-border);
      }
      #debug-toggle input { margin: 0; accent-color: var(--accent); }
      .spacer { flex: 1; }
      #send {
        font: inherit; font-weight: 600; font-size: 14px; cursor: pointer;
        padding: 9px 22px; border-radius: 12px;
        color: var(--send-text); background: var(--send-fill);
        border: 1px solid var(--send-border);
        transition: transform 0.12s ease, opacity 0.12s ease;
      }
      #send:hover { transform: translateY(-1px); }
      #send:active { transform: scale(0.98); }
      #send:disabled { opacity: 0.55; cursor: default; transform: none; }
      #error { font-size: 12px; color: #E55A3E; display: none; }
      /* PostHog mounts its own floating chat launcher once the API loads; this page is the UI. */
      #ph-conversations-widget-container { display: none !important; }
    </style>
    </head>
    <body>
    <div id="app">
      <div id="messages"></div>
      <div id="composer">
        <div id="email-row">
          <label for="email">Your email</label>
          <input id="email" type="email" placeholder="so we can reply if you close the app" autocomplete="email">
        </div>
        <textarea id="text" placeholder="What's going on? Bugs, ideas, confusion — all welcome." rows="3"></textarea>
        <div id="attachments"></div>
        <div id="actions">
          <label id="debug-toggle">
            <input id="debug" type="checkbox" checked>
            <span>Attach debug logs</span>
          </label>
          <span class="spacer"></span>
          <span id="error"></span>
          <button id="send" disabled>Send</button>
        </div>
      </div>
    </div>
    <div id="drop-overlay"></div>

    <script>
    (function () {
      var config = window.__dayflowSupportConfig || {};
      var native = function (message) {
        try { window.webkit.messageHandlers.support.postMessage(message); } catch (e) {}
      };

      var el = {
        messages: document.getElementById("messages"),
        email: document.getElementById("email"),
        text: document.getElementById("text"),
        attachments: document.getElementById("attachments"),
        debug: document.getElementById("debug"),
        send: document.getElementById("send"),
        error: document.getElementById("error")
      };

      var strings = config.strings;
      var isFlowWaitlist = config.flowWaitlist === true;
      var FLOW_WAITLIST_PREFIX = "[Flow waitlist]\n\n";
      if (isFlowWaitlist) {
        document.getElementById("email-row").style.display = "none";
        document.getElementById("debug-toggle").style.display = "none";
        el.debug.checked = false;
        el.debug.disabled = true;
      }
      document.documentElement.lang = config.language || "en";
      document.querySelector('label[for="email"]').textContent = strings.email;
      el.email.placeholder = strings.emailPlaceholder;
      el.text.placeholder = strings.messagePlaceholder;
      document.querySelector('#debug-toggle span').textContent = strings.debug;
      el.send.textContent = strings.send;
      document.getElementById("drop-overlay").textContent = strings.dropHint;
      var GREETING = strings.greeting;
      // Logs travel as a PostHog event on the same person, not inside the message,
      // so the ticket thread stays readable. Event properties allow ~1MB; stay well under.
      var DEBUG_LOG_LIMIT = 200000;
      var reading = false;
      var loadingMessages = false;

      var state = {
        available: false,
        sending: false,
        rendered: {},           // message id -> true
        attachments: [],        // { url, node }; url is null while uploading
        pendingDebugLog: null   // resolver waiting on native
      };

      // ---- Theme -------------------------------------------------------------

      var cssVarNames = {
        textPrimary: "--text-primary", textSecondary: "--text-secondary",
        textMuted: "--text-muted", accent: "--accent",
        userBubbleFill: "--user-fill", userBubbleBorder: "--user-border",
        userBubbleText: "--user-text",
        teamBubbleFill: "--team-fill", teamBubbleBorder: "--team-border",
        inputFill: "--input-fill", inputBorder: "--input-border",
        sendFill: "--send-fill", sendBorder: "--send-border", sendText: "--send-text",
        chipFill: "--chip-fill", chipBorder: "--chip-border", chipText: "--chip-text",
        divider: "--divider"
      };

      function applyPalette(palette) {
        if (!palette) return;
        var root = document.documentElement.style;
        Object.keys(cssVarNames).forEach(function (key) {
          if (palette[key]) root.setProperty(cssVarNames[key], palette[key]);
        });
        if (palette.colorScheme) root.setProperty("color-scheme", palette.colorScheme);
      }
      applyPalette(config.palette);

      // ---- Rendering ---------------------------------------------------------

      function escapeHTML(text) {
        return String(text)
          .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
          .replace(/"/g, "&quot;");
      }

      function linkify(escaped) {
        return escaped.replace(/(https?:\/\/[^\s<]+)/g, function (url) {
          return '<a href="' + url + '" target="_blank">' + url + '</a>';
        });
      }

      function formatTime(iso) {
        var date = new Date(iso);
        if (isNaN(date.getTime())) return "";
        return date.toLocaleString(config.language || "en", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
      }

      function appendMessage(message) {
        if (message.id && state.rendered[message.id]) return;
        if (message.id) state.rendered[message.id] = true;

        var isUser = message.author_type === "customer";
        var content = message.content || "";
        if (isFlowWaitlist && isUser && content.indexOf(FLOW_WAITLIST_PREFIX) === 0) {
          content = content.slice(FLOW_WAITLIST_PREFIX.length);
        }

        var images = content.match(IMAGE_URL) || [];
        var bubble = document.createElement("div");
        bubble.className = "msg " + (isUser ? "user" : "team");
        bubble.innerHTML = linkify(escapeHTML(content.replace(IMAGE_URL, "").trim()));
        images.forEach(function (url) {
          var link = document.createElement("a");
          link.href = url;
          link.target = "_blank";
          var image = document.createElement("img");
          image.src = url;
          image.onload = scrollToBottom;
          link.appendChild(image);
          bubble.appendChild(link);
        });
        el.messages.appendChild(bubble);

        var meta = document.createElement("div");
        meta.className = "meta " + (isUser ? "user" : "team");
        var who = isUser ? strings.you : (message.author_name || "Dayflow");
        var when = message.created_at ? formatTime(message.created_at) : "";
        meta.textContent = when ? who + " · " + when : who;
        el.messages.appendChild(meta);

        scrollToBottom();
      }

      function showStatus(text) {
        var node = document.createElement("div");
        node.className = "status";
        node.textContent = text;
        el.messages.appendChild(node);
        scrollToBottom();
      }

      function scrollToBottom() {
        el.messages.scrollTop = el.messages.scrollHeight;
      }

      function showError(text) {
        el.error.textContent = text;
        el.error.style.display = text ? "inline" : "none";
      }

      function updateSendEnabled() {
        var uploading = state.attachments.some(function (a) { return !a.url; });
        var empty = el.text.value.trim().length === 0 && state.attachments.length === 0;
        el.send.disabled = !state.available || state.sending || uploading || empty;
      }

      // ---- Images --------------------------------------------------------------

      var backendURL = (config.backendURL || "").replace(/\/+$/, "");
      var IMAGE_URL = /https:\/\/[^\s<>|]+\/v1\/support\/images\/[\w-]+\.(?:jpg|png|gif|webp)/g;
      var IMAGE_MAX_BYTES = 50 * 1024 * 1024;

      function removeAttachment(attachment) {
        state.attachments = state.attachments.filter(function (a) { return a !== attachment; });
        attachment.node.remove();
        updateSendEnabled();
      }

      // The backend converts whatever it's given, so any image format is fine here.
      function uploadImage(file) {
        if (file.size > IMAGE_MAX_BYTES) {
          showError(strings.imageTooLarge);
          return;
        }
        var attachment = { url: null, node: document.createElement("div") };
        attachment.node.className = "attachment";
        var label = document.createElement("span");
        label.textContent = "…";
        var remove = document.createElement("button");
        remove.textContent = "×";
        remove.addEventListener("click", function () { removeAttachment(attachment); });
        attachment.node.appendChild(label);
        attachment.node.appendChild(remove);
        el.attachments.appendChild(attachment.node);
        state.attachments.push(attachment);
        showError("");
        updateSendEnabled();

        fetch(backendURL + "/v1/support/images", {
          method: "POST",
          headers: { "Content-Type": "application/octet-stream" },
          body: file
        }).then(function (response) {
          if (!response.ok) throw response.status;
          return response.json();
        }).then(function (body) {
          attachment.url = body.url;
          label.textContent = "";
          attachment.node.style.backgroundImage = 'url("' + body.url + '")';
        }).catch(function (status) {
          removeAttachment(attachment);
          showError(status === 415 ? strings.imageUnsupported
            : status === 413 ? strings.imageTooLarge : strings.imageFailed);
        }).finally(updateSendEnabled);
      }

      function attachFiles(files) {
        if (!backendURL) return;
        Array.prototype.forEach.call(files, uploadImage);
      }

      document.addEventListener("paste", function (event) {
        var files = event.clipboardData && event.clipboardData.files;
        if (!files || files.length === 0) return;
        event.preventDefault();
        attachFiles(files);
      });

      // Dragging is tracked on the window so the whole chat is the drop target.
      var dragDepth = 0;
      function isFileDrag(event) {
        return !!event.dataTransfer
          && Array.prototype.indexOf.call(event.dataTransfer.types, "Files") >= 0;
      }
      function setDragging(depth) {
        dragDepth = depth;
        document.body.classList.toggle("dragging", depth > 0);
      }
      window.addEventListener("dragenter", function (event) {
        if (!isFileDrag(event)) return;
        event.preventDefault();
        setDragging(dragDepth + 1);
      });
      window.addEventListener("dragover", function (event) {
        if (!isFileDrag(event)) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = "copy";
      });
      window.addEventListener("dragleave", function (event) {
        if (isFileDrag(event)) setDragging(Math.max(0, dragDepth - 1));
      });
      window.addEventListener("drop", function (event) {
        if (!isFileDrag(event)) return;
        event.preventDefault();
        setDragging(0);
        attachFiles(event.dataTransfer.files);
      });

      // ---- Email ---------------------------------------------------------------

      var EMAIL_KEY = "dayflow.support.email";
      if (isFlowWaitlist) {
        el.email.value = config.email || "";
      } else {
        try { el.email.value = localStorage.getItem(EMAIL_KEY) || ""; } catch (e) {}
      }
      el.email.addEventListener("change", function () {
        try { localStorage.setItem(EMAIL_KEY, el.email.value.trim()); } catch (e) {}
      });

      function isLikelyEmail(value) {
        return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value);
      }

      // ---- Debug log from native --------------------------------------------

      function requestDebugLog() {
        return new Promise(function (resolve) {
          state.pendingDebugLog = resolve;
          native({ event: "requestDebugLog" });
          setTimeout(function () {
            if (state.pendingDebugLog === resolve) {
              state.pendingDebugLog = null;
              resolve(null);
            }
          }, 8000);
        });
      }

      function receiveDebugLog(text) {
        var resolve = state.pendingDebugLog;
        state.pendingDebugLog = null;
        if (resolve) resolve(text);
      }

      function truncate(text, limit) {
        if (text.length <= limit) return text;
        return text.slice(0, limit) + "\n… (truncated, " + (text.length - limit) + " more characters)";
      }

      // Attaches the log to the same PostHog person the ticket belongs to. Open the
      // ticket, click through to the person, and the log is in their activity.
      function sendDebugLogEvent(log, response) {
        try {
          posthog.capture("support_debug_log", {
            ticket_id: posthog.conversations.getCurrentTicketId(),
            message_id: response.message_id,
            app_version: config.appVersion || "",
            debug_log: truncate(log, DEBUG_LOG_LIMIT)
          });
        } catch (e) {}
      }

      // ---- Sending -----------------------------------------------------------

      async function sendCurrentMessage() {
        // Image URLs ride along as their own lines after the text.
        var imageURLs = state.attachments.map(function (a) { return a.url; });
        var text = [el.text.value.trim()].concat(imageURLs).join("\n").trim();
        if (!text || imageURLs.indexOf(null) >= 0 || state.sending || !state.available) return;

        var email = el.email.value.trim();
        if (!isLikelyEmail(email)) {
          showError(strings.emailRequired);
          el.email.focus();
          return;
        }

        state.sending = true;
        updateSendEnabled();
        showError("");

        var attachDebug = !isFlowWaitlist && el.debug.checked;
        var traits = { email: email };

        var log = attachDebug ? await requestDebugLog() : null;
        if (!log) attachDebug = false;

        var hadTicket = !!posthog.conversations.getCurrentTicketId();
        try {
          var outboundText = isFlowWaitlist && !hadTicket ? FLOW_WAITLIST_PREFIX + text : text;
          var response = await posthog.conversations.sendMessage(outboundText, traits);
          if (!response) throw new Error(strings.unavailable);
          if (attachDebug) sendDebugLogEvent(log, response);
          el.text.value = "";
          state.attachments = [];
          el.attachments.innerHTML = "";
          appendMessage({
            id: response.message_id,
            content: text,
            author_type: "customer",
            created_at: response.created_at
          });
          native({ event: "sent", hasDebugLog: attachDebug, newTicket: !hadTicket });
          if (!hadTicket) showStatus(strings.sent);
          startPolling();
        } catch (error) {
          var message = (error && error.message) || strings.sendFailed;
          if (message.indexOf("Too many") >= 0) message = strings.rateLimited;
          showError(message);
        } finally {
          state.sending = false;
          updateSendEnabled();
        }
      }

      el.send.addEventListener("click", sendCurrentMessage);
      el.text.addEventListener("input", updateSendEnabled);
      el.email.addEventListener("input", function () { showError(""); });
      el.text.addEventListener("keydown", function (event) {
        if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
          event.preventDefault();
          sendCurrentMessage();
        }
      });

      // ---- Loading history + polling for replies -----------------------------

      async function loadMessages() {
        if (loadingMessages || !state.available || !posthog.conversations.getCurrentTicketId()) return;
        // The hidden built-in widget polls on its own and spends the shared rate limit.
        if (posthog.conversations.isVisible()) posthog.conversations.hide();
        loadingMessages = true;
        lastAttemptAt = Date.now();
        try {
          var response = await posthog.conversations.getMessages();
          if (!response) return;
          var hadUnread = response.unread_count > 0;
          response.messages
            .filter(function (m) { return !m.is_private; })
            .sort(function (a, b) { return new Date(a.created_at) - new Date(b.created_at); })
            .forEach(appendMessage);
          var replies = response.messages.filter(function (m) {
            return !m.is_private && m.author_type !== "customer";
          }).sort(function (a, b) { return new Date(a.created_at) - new Date(b.created_at); });
          var latest = replies[replies.length - 1];
          var unread = response.unread_count;
          if (reading && hadUnread) {
            var receipt = await posthog.conversations.markAsRead();
            if (receipt && receipt.success) unread = 0;
          }
          unreadCount = unread;
          native({ event: "replies", unread: unread,
            latestID: latest ? String(latest.id) : "" });
          return true;
        } catch (e) {} finally { loadingMessages = false; }
      }

      // PostHog shares one rate limit for message fetches across every install,
      // so each tick asks the Dayflow backend for the ticket's latest message id
      // and only fetches the conversation when that id changes.
      var unreadCount = 0;
      var lastAttemptAt = 0;
      var RETRY_MS = 20 * 1000;
      var latestKnownID;
      var checkingForNew = false;
      var POSTHOG_FALLBACK_MS = 5 * 60 * 1000;

      async function checkForNew() {
        var ticketID = state.available && posthog.conversations.getCurrentTicketId();
        if (!ticketID || checkingForNew) return;
        // A failed mark-as-read is retried, but not on every tick.
        if (reading && unreadCount > 0 && Date.now() - lastAttemptAt > RETRY_MS) return loadMessages();
        checkingForNew = true;
        try {
          if (!backendURL) throw new Error("no backend");
          var response = await fetch(
            backendURL + "/v1/support/tickets/" + encodeURIComponent(ticketID) + "/latest");
          if (!response.ok) throw new Error("status " + response.status);
          var latestID = (await response.json()).latest_message_id || "";
          var changed = latestKnownID !== undefined && latestID !== latestKnownID;
          // Only remember the new id once its message was fetched, so a failed
          // fetch is tried again on a later tick instead of being lost.
          if (!changed) latestKnownID = latestID;
          else if (Date.now() - lastAttemptAt > RETRY_MS && await loadMessages()) latestKnownID = latestID;
        } catch (e) {
          // Backend unreachable: fall back to asking PostHog, but rarely.
          if (Date.now() - lastAttemptAt > POSTHOG_FALLBACK_MS) loadMessages();
        } finally { checkingForNew = false; }
      }

      function startPolling() {
        loadMessages();
      }

      // ---- Boot --------------------------------------------------------------

      appendMessage({ id: "greeting", content: GREETING, author_type: "human", author_name: "Dayflow" });

      function fail(reason) {
        native({ event: "unavailable", reason: reason });
      }

      function onPostHogLoaded() {
        var attempts = 0;
        var timer = setInterval(function () {
          attempts += 1;
          var ready = posthog.conversations && posthog.conversations.isAvailable();
          if (ready) {
            clearInterval(timer);
            state.available = true;
            updateSendEnabled();
            native({ event: "ready" });
            loadMessages().then(startPolling);
          } else if (attempts > 100) {
            clearInterval(timer);
            fail("conversations_not_available");
          }
        }, 100);
      }

      window.__dayflowSupport = {
        poll: loadMessages,
        setReading: function (value) {
          var opened = value && !reading;
          reading = value;
          if (opened) loadMessages(); else checkForNew();
        },
        receiveDebugLog: receiveDebugLog,
        applyPalette: applyPalette
      };

      if (!config.token) {
        fail("missing_token");
        return;
      }

      var assetsHost = (config.apiHost || "https://us.i.posthog.com").replace(".i.posthog.com", "-assets.i.posthog.com");
      var script = document.createElement("script");
      script.src = assetsHost + "/static/array.js";
      script.onerror = function () { fail("script_load_failed"); };
      script.onload = function () {
        var options = {
          api_host: config.apiHost,
          autocapture: false,
          capture_pageview: false,
          capture_pageleave: false,
          disable_session_recording: true,
          persistence: "localStorage",
          loaded: onPostHogLoaded
        };
        if (config.distinctId) {
          options.bootstrap = { distinctID: config.distinctId, isIdentifiedID: true };
        }
        posthog.init(config.token, options);
      };
      document.head.appendChild(script);
    })();
    </script>
    </body>
    </html>
    """#
}
