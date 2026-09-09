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

import AppKit
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

// MARK: - View

struct SupportChatWebView: NSViewRepresentable {
  enum Event {
    case ready
    case unavailable(reason: String)
  }

  let palette: SupportChatPalette
  let onEvent: (Event) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onEvent: onEvent)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "support")
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.configScript(palette: palette),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    #if DEBUG
      webView.isInspectable = true
    #endif

    context.coordinator.webView = webView
    context.coordinator.lastPalette = palette
    // A real https origin so posthog-js gets working localStorage for ticket persistence.
    webView.loadHTMLString(
      SupportChatPage.html, baseURL: URL(string: "https://www.dayflow.so/support-chat"))
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    guard context.coordinator.lastPalette != palette else { return }
    context.coordinator.lastPalette = palette
    context.coordinator.send("applyPalette", palette.values)
  }

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    nsView.configuration.userContentController.removeScriptMessageHandler(forName: "support")
    nsView.navigationDelegate = nil
    nsView.uiDelegate = nil
  }

  /// Everything the page needs before posthog-js loads: keys, distinct ID, and theme.
  private static func configScript(palette: SupportChatPalette) -> String {
    let info = Bundle.main.infoDictionary
    var config: [String: Any] = [
      "token": info?["PHPostHogApiKey"] as? String ?? "",
      "apiHost": info?["PHPostHogHost"] as? String ?? "https://us.i.posthog.com",
      "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
      "palette": palette.values,
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
    private let onEvent: (Event) -> Void
    weak var webView: WKWebView?
    var lastPalette: SupportChatPalette?

    init(onEvent: @escaping (Event) -> Void) {
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
        onEvent(.ready)

      case "unavailable":
        let reason = body["reason"] as? String ?? "unknown"
        AnalyticsService.shared.capture("support_chat_unavailable", ["reason": reason])
        onEvent(.unavailable(reason: reason))

      case "sent":
        AnalyticsService.shared.capture(
          "support_message_sent",
          [
            "has_debug_log": body["hasDebugLog"] as? Bool ?? false,
            "new_ticket": body["newTicket"] as? Bool ?? false,
          ]
        )

      case "requestDebugLog":
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
        self.onEvent(.unavailable(reason: "load_failed"))
      }
    }

    nonisolated func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      Task { @MainActor in
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
        debug: document.getElementById("debug"),
        send: document.getElementById("send"),
        error: document.getElementById("error")
      };

      var GREETING = "Hey there! Found a bug, have an idea, or just confused about something? Drop it here and a real person on the Dayflow team will get back to you in this chat.";
      // Logs travel as a PostHog event on the same person, not inside the message,
      // so the ticket thread stays readable. Event properties allow ~1MB; stay well under.
      var DEBUG_LOG_LIMIT = 200000;
      var POLL_MS = 5000;

      var state = {
        available: false,
        sending: false,
        rendered: {},           // message id -> true
        pendingDebugLog: null,  // resolver waiting on native
        pollTimer: null
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
        return date.toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
      }

      function appendMessage(message) {
        if (message.id && state.rendered[message.id]) return;
        if (message.id) state.rendered[message.id] = true;

        var isUser = message.author_type === "customer";
        var content = message.content || "";

        var bubble = document.createElement("div");
        bubble.className = "msg " + (isUser ? "user" : "team");
        bubble.innerHTML = linkify(escapeHTML(content.trim()));
        el.messages.appendChild(bubble);

        var meta = document.createElement("div");
        meta.className = "meta " + (isUser ? "user" : "team");
        var who = isUser ? "You" : (message.author_name || "Dayflow");
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
        el.send.disabled = !state.available || state.sending || el.text.value.trim().length === 0;
      }

      // ---- Email ---------------------------------------------------------------

      var EMAIL_KEY = "dayflow.support.email";
      try { el.email.value = localStorage.getItem(EMAIL_KEY) || ""; } catch (e) {}
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
        var text = el.text.value.trim();
        if (!text || state.sending || !state.available) return;

        var email = el.email.value.trim();
        if (!isLikelyEmail(email)) {
          showError("Add your email so we can reply.");
          el.email.focus();
          return;
        }

        state.sending = true;
        updateSendEnabled();
        showError("");

        var attachDebug = el.debug.checked;
        var traits = { email: email };

        var log = attachDebug ? await requestDebugLog() : null;
        if (!log) attachDebug = false;

        var hadTicket = !!posthog.conversations.getCurrentTicketId();
        try {
          var response = await posthog.conversations.sendMessage(text, traits);
          if (!response) throw new Error("Support is not available right now.");
          if (attachDebug) sendDebugLogEvent(log, response);
          el.text.value = "";
          appendMessage({
            id: response.message_id,
            content: text,
            author_type: "customer",
            created_at: response.created_at
          });
          native({ event: "sent", hasDebugLog: attachDebug, newTicket: !hadTicket });
          if (!hadTicket) showStatus("Sent. Replies show up here and in your inbox.");
          startPolling();
        } catch (error) {
          var message = (error && error.message) || "Couldn't send. Try again.";
          if (message.indexOf("Too many") >= 0) message = "Slow down a little — try again in a minute.";
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
        if (!posthog.conversations.getCurrentTicketId()) return;
        try {
          var response = await posthog.conversations.getMessages();
          if (!response) return;
          var hadUnread = response.unread_count > 0;
          response.messages
            .filter(function (m) { return !m.is_private; })
            .sort(function (a, b) { return new Date(a.created_at) - new Date(b.created_at); })
            .forEach(appendMessage);
          if (hadUnread) posthog.conversations.markAsRead();
        } catch (e) {}
      }

      function startPolling() {
        if (state.pollTimer) return;
        state.pollTimer = setInterval(function () {
          if (document.hidden) return;
          loadMessages();
        }, POLL_MS);
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
