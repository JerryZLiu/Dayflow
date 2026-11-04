//
//  BrowserWindowInspector.swift
//  Dayflow
//
//  Reads the frontmost browser window's chrome through the accessibility API
//  and decides whether this capture should be redacted. Runs on every capture
//  tick, so it keeps a short-lived cache and a tight messaging timeout: a
//  browser that stops answering can't stall the recorder.
//
//  The URL is read, matched against the bundled category list, and dropped.
//  It is never cached, logged, sent anywhere, or written to the database.
//

import AppKit
import ApplicationServices
import Foundation

/// The app whose window is being inspected. Gathered on the main actor by the
/// caller, so the accessibility walk itself can happen off it.
struct BrowserForegroundApp: Sendable {
  let pid: pid_t
  let bundleIdentifier: String?
  let name: String

  @MainActor
  static func frontmost() -> BrowserForegroundApp? {
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return nil }

    return BrowserForegroundApp(
      pid: app.processIdentifier,
      bundleIdentifier: app.bundleIdentifier,
      name: app.localizedName ?? app.bundleIdentifier ?? "Browser"
    )
  }
}

final class BrowserWindowInspector: @unchecked Sendable {
  static let shared = BrowserWindowInspector()

  /// How long one decision stays good. The window is re-read when the title
  /// changes, so this only bounds how stale a same-title window can get.
  private static let cacheTTL: TimeInterval = 1.0
  private static let messagingTimeout: Float = 0.3
  private static let maxDepth = 8
  private static let maxChildren = 40
  private static let maxLabels = 60
  /// Hard ceiling on elements touched per read, so a pathological tree can't
  /// turn one capture tick into a long accessibility walk.
  private static let maxVisits = 400

  private struct CacheEntry {
    let titleKey: String
    let decision: BrowserPrivacyDecision
    let readAt: Date
  }

  private let lock = NSLock()
  private var cache: [pid_t: CacheEntry] = [:]

  /// Nil when browser privacy is off, the app isn't a browser, or the window
  /// should be recorded as normal. Non-nil means: redact this frame.
  func blockedBrowser(
    app: BrowserForegroundApp,
    settings: BrowserPrivacyPreferences.Settings = BrowserPrivacyPreferences.settings()
  ) -> (app: BrowserForegroundApp, reason: BrowserPrivacyReason)? {
    guard !settings.isInactive else { return nil }
    guard let family = BrowserFamily.family(forBundleIdentifier: app.bundleIdentifier) else {
      return nil
    }
    guard AXIsProcessTrusted() else { return nil }

    let element = AXUIElementCreateApplication(app.pid)
    AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

    guard let window = focusedWindow(of: element) else {
      // No window to read. Treat it the way the user asked us to treat a
      // window we can't classify.
      let decision = BrowserPrivacyPreferences.decision(
        privacy: .unknown, urlString: nil, settings: settings)
      return decision.reason.map { (app, $0) }
    }

    let title = Self.string(Self.attribute(window, kAXTitleAttribute as String))
    let titleKey = title ?? ""

    if let cached = cachedDecision(pid: app.pid, titleKey: titleKey) {
      return cached.reason.map { (app, $0) }
    }

    var signals = BrowserWindowSignals(windowTitle: title)
    var visits = 0
    collect(into: &signals, element: window, depth: 0, visits: &visits)

    let privacy = BrowserWindowClassifier.classify(family: family, signals: signals)
    let decision = BrowserPrivacyPreferences.decision(
      privacy: privacy, urlString: signals.url, settings: settings)
    // signals (and the URL inside it) goes out of scope here and is never
    // stored; only the decision is cached.
    store(decision, pid: app.pid, titleKey: titleKey)

    return decision.reason.map { (app, $0) }
  }

  func invalidate() {
    lock.lock()
    cache.removeAll()
    lock.unlock()
  }

  // MARK: - Cache

  private func cachedDecision(pid: pid_t, titleKey: String) -> BrowserPrivacyDecision? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = cache[pid], entry.titleKey == titleKey,
      Date().timeIntervalSince(entry.readAt) < Self.cacheTTL
    else { return nil }
    return entry.decision
  }

  private func store(_ decision: BrowserPrivacyDecision, pid: pid_t, titleKey: String) {
    lock.lock()
    cache[pid] = CacheEntry(titleKey: titleKey, decision: decision, readAt: Date())
    if cache.count > 32 { cache = [pid: cache[pid]!] }
    lock.unlock()
  }

  // MARK: - Accessibility

  private func focusedWindow(of application: AXUIElement) -> AXUIElement? {
    if let focused = Self.attribute(application, kAXFocusedWindowAttribute as String),
      CFGetTypeID(focused) == AXUIElementGetTypeID()
    {
      return (focused as! AXUIElement)
    }
    if let windows = Self.attribute(application, kAXWindowsAttribute as String) as? [AXUIElement] {
      return windows.first
    }
    return nil
  }

  /// A shallow walk over the window chrome. It stops before page content —
  /// an `AXWebArea` and everything under it is the page, and the markers we
  /// want all live above it, in the title bar and the toolbar.
  private func collect(
    into signals: inout BrowserWindowSignals,
    element: AXUIElement,
    depth: Int,
    visits: inout Int
  ) {
    guard depth <= Self.maxDepth, visits < Self.maxVisits else { return }
    guard
      signals.controlLabels.count + signals.staticTexts.count < Self.maxLabels
    else { return }
    visits += 1

    let role = Self.string(Self.attribute(element, kAXRoleAttribute as String)) ?? ""

    if signals.url == nil,
      let url = Self.attribute(element, kAXURLAttribute as String) as? URL
    {
      signals.url = url.absoluteString
    }

    switch role {
    case "AXWebArea":
      // Page content starts here. Nothing below is window chrome.
      return
    case "AXButton", "AXMenuButton", "AXPopUpButton", "AXRadioButton", "AXCheckBox":
      if let title = Self.string(Self.attribute(element, kAXTitleAttribute as String)) {
        signals.controlLabels.append(title)
      }
      if let description = Self.string(Self.attribute(element, kAXDescriptionAttribute as String)) {
        signals.controlLabels.append(description)
      }
      return
    case "AXStaticText":
      if let value = Self.string(Self.attribute(element, kAXValueAttribute as String)) {
        signals.staticTexts.append(value)
      }
      return
    case "AXTextField", "AXComboBox", "AXSearchField":
      if let description = Self.string(Self.attribute(element, kAXDescriptionAttribute as String)) {
        signals.locationFieldDescriptions.append(description)
      }
      if let title = Self.string(Self.attribute(element, kAXTitleAttribute as String)) {
        signals.locationFieldDescriptions.append(title)
      }
      // Safari's smart search field holds the full URL including the scheme,
      // and is the only place Safari exposes it above the web area.
      if signals.url == nil,
        let value = Self.string(Self.attribute(element, kAXValueAttribute as String)),
        value.contains("://")
      {
        signals.url = value
      }
      return
    default:
      break
    }

    guard
      let children = Self.attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]
    else { return }

    for child in children.prefix(Self.maxChildren) {
      collect(into: &signals, element: child, depth: depth + 1, visits: &visits)
    }
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private static func string(_ value: AnyObject?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
