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
//  Commands: ready, getToken, state, simulateDistraction, openExternal.
//  Events:   nativeState, overlayAction.
//

import SwiftUI
import WebKit

enum FlowWebConfiguration {
  static let bridgeVersion = 1
  static let urlOverrideDefaultsKey = "flowWebURLOverride"

  static var url: URL {
    if let override = UserDefaults.standard.string(forKey: urlOverrideDefaultsKey),
      let url = URL(string: override)
    {
      return url
    }
    return URL(string: "https://www.dayflow.so/flow/")!
  }
}

struct FlowWebView: NSViewRepresentable {
  enum Event {
    case loaded
    case failed(Error)
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
    webView.load(URLRequest(url: url))
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    nsView.configuration.userContentController.removeScriptMessageHandler(forName: "flow")
    nsView.navigationDelegate = nil
    nsView.uiDelegate = nil
    if FlowSessionMirror.shared.webBridge === coordinator {
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
      guard message.name == "flow",
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
        pageIsReady = true
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

      case "openExternal":
        if let urlString = payload["url"] as? String, let url = URL(string: urlString),
          url.scheme == "https" || url.scheme == "http"
        {
          NSWorkspace.shared.open(url)
          reply(id: id, payload: [:])
        } else {
          reply(id: id, error: "invalid url")
        }

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
      payload["token"] = DayflowAuthManager.storedSessionToken()
      payload["backendURL"] = DayflowBackendConfiguration.endpoint()
      return payload
    }

    // MARK: native → JS

    func sendEvent(_ event: String, payload: [String: Any]) {
      deliver(["event": event, "payload": payload])
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
      // Links the page marks as external (target=_blank comes through
      // createWebViewWith below); plain link taps stay in the app's web view
      // only when they stay on the Flow origin.
      if navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url,
        url.host != FlowWebConfiguration.url.host
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
