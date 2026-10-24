//
//  AccessibilityTreeReader.swift
//  Dayflow
//
//  Reads what's on screen through the macOS accessibility API and turns it
//  into short indented text, one element per line:
//
//    [12] button "Send" (disabled)
//    [13] textarea "Message #general" (focused) = "draft text"
//
//  Each element keeps the same [id] across snapshots of an app, so two
//  snapshots can be compared and only the changed lines written out.
//  Not thread-safe: AccessibilityRecorder calls it only from its own queue.
//

import AppKit
import ApplicationServices

/// The frontmost app, captured once when it becomes active.
struct AccessibilityAppInfo {
  let pid: pid_t
  let bundleId: String?
  let name: String
  /// Electron and Chromium apps. Their trees are huge, so they get a smaller
  /// child limit, and their page content has to be switched on first.
  let isWebShaped: Bool
  let element: AXUIElement

  init(_ app: NSRunningApplication) {
    pid = app.processIdentifier
    bundleId = app.bundleIdentifier
    name = app.localizedName ?? app.bundleIdentifier ?? "Unknown app"
    isWebShaped = Self.isWebShaped(app)
    element = AXUIElementCreateApplication(app.processIdentifier)
  }

  private static func isWebShaped(_ app: NSRunningApplication) -> Bool {
    guard let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary else {
      return false
    }
    let principalClass = info["NSPrincipalClass"] as? String ?? ""
    return principalClass == "AtomApplication" || principalClass == "BrowserCrApplication"
  }
}

struct AccessibilitySnapshot {
  struct Line {
    /// The element's path in the tree; stays the same across snapshots.
    let key: String
    let text: String
  }

  let windowTitle: String?
  let lines: [Line]
  let durationMs: Int

  var text: String { lines.map(\.text).joined(separator: "\n") }
}

final class AccessibilityTreeReader {
  private static let maxLines = 1500
  private static let maxDepth = 60
  private static let maxChildren = 100
  private static let maxChildrenWebShaped = 40

  private static let wantedAttributes =
    [
      "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXURL", "AXFocused",
      "AXSelected", "AXEnabled", "AXChildren", "AXPosition", "AXSize", "AXPlaceholderValue",
    ] as CFArray

  /// Containers that carry no meaning of their own. When unlabeled they're
  /// skipped and their children move up a level.
  private static let flattenRoles: Set<String> = [
    "AXGroup", "AXUnknown", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem",
    "AXCell", "AXGenericElement", "AXSection", "AXLandmarkMain", "AXLandmarkNavigation",
    "AXLandmarkBanner", "AXLandmarkContentInfo", "AXLandmarkComplementary", "AXLandmarkRegion",
    "AXLandmarkSearch", "AXColumn",
  ]

  /// Never useful as text, so dropped with everything inside them.
  private static let dropRoles: Set<String> = [
    "AXScrollBar", "AXSplitter", "AXValueIndicator", "AXGrowArea", "AXMenuBar", "AXImage",
    "AXRuler", "AXRulerMarker",
  ]

  /// Small controls keep their label in their key. Containers and text use
  /// only their position, so a window title change doesn't re-key everything
  /// under it.
  private static let labelKeyedRoles: Set<String> = [
    "AXButton", "AXLink", "AXRadioButton", "AXCheckBox", "AXRow", "AXMenuItem",
    "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXComboBox",
  ]

  private let systemWide = AXUIElementCreateSystemWide()
  private var idForKey: [String: Int] = [:]
  /// Apps whose web content has already been switched on.
  private var enabledWebPIDs = Set<pid_t>()

  init() {
    // Applies to every accessibility call Dayflow makes, so one hung app
    // can't stall the recorder for the default 6 seconds per call.
    AXUIElementSetMessagingTimeout(systemWide, 0.5)
  }

  /// Forgets all element ids. Called when recording stops, and when the id
  /// table gets large.
  func reset() {
    idForKey.removeAll()
    enabledWebPIDs.removeAll()
  }

  // MARK: - Snapshot

  func snapshot(of app: AccessibilityAppInfo) -> AccessibilitySnapshot? {
    let start = Date()
    if idForKey.count > 50_000 { idForKey.removeAll() }
    enableWebContentIfNeeded(app)

    guard let windowValue = Self.attribute(app.element, "AXFocusedWindow") else { return nil }
    let window = windowValue as! AXUIElement
    let windowData = Self.fetch(window)
    let windowFrame = Self.frame(windowData) ?? .infinite
    let maxChildren = app.isWebShaped ? Self.maxChildrenWebShaped : Self.maxChildren

    var lines: [AccessibilitySnapshot.Line] = []
    var tabStripDepth = 0
    var hiddenTabs = 0

    func walk(
      _ element: AXUIElement, _ data: [String: AnyObject], depth: Int, parentKey: String,
      slot: String, parentLabel: String?
    ) {
      if lines.count >= Self.maxLines || depth > Self.maxDepth { return }

      let role = data["AXRole"] as? String ?? "AXUnknown"
      if Self.dropRoles.contains(role) { return }
      if let frame = Self.frame(data), frame.width > 0, frame.height > 0,
        !frame.intersects(windowFrame)
      {
        return  // off-screen
      }

      let label = Self.text(data["AXTitle"]) ?? Self.text(data["AXDescription"])
      var value = Self.text(data["AXValue"])
      if Self.isSecure(data) { value = value == nil ? nil : "[secure field]" }
      if value == label { value = nil }
      let url = (role == "AXWebArea" || role == "AXLink") ? Self.text(data["AXURL"]) : nil
      let placeholder = Self.text(data["AXPlaceholderValue"])
      let key = parentKey + "/" + slot

      // Browser tab strips: keep only the selected tab and count the rest.
      if tabStripDepth > 0 && role == "AXRadioButton" && !Self.isSelectedTab(data) {
        hiddenTabs += 1
        return
      }

      // Static text that only repeats its parent's label adds nothing.
      let isRedundant = role == "AXStaticText" && (value ?? label) == parentLabel
      let isInformative =
        !isRedundant
        && (label != nil || value != nil || url != nil || !Self.flattenRoles.contains(role))

      var childDepth = depth
      if isInformative {
        var line =
          String(repeating: " ", count: depth) + "[\(stableID(key))] "
          + role.dropFirst(2).lowercased()
        if let label { line += " \"\(Self.clip(label))\"" }
        let states = Self.states(data)
        if !states.isEmpty { line += " (" + states.joined(separator: ",") + ")" }
        if let value {
          line += " = \"\(Self.clip(value))\""
        } else if let placeholder, role == "AXTextField" || role == "AXTextArea" {
          line += " placeholder=\"\(Self.clip(placeholder))\""
        }
        if let url { line += " <\(Self.clip(url))>" }
        lines.append(.init(key: key, text: line))
        childDepth = depth + 1
      }

      guard let children = data["AXChildren"] as? [AXUIElement], !children.isEmpty else { return }

      let isTabStrip = role == "AXTabGroup" && app.isWebShaped
      if isTabStrip {
        tabStripDepth += 1
        hiddenTabs = 0
      }
      defer {
        if isTabStrip {
          tabStripDepth -= 1
          if hiddenTabs > 0 {
            lines.append(
              .init(
                key: key + "/tabs",
                text: String(repeating: " ", count: childDepth) + "(+\(hiddenTabs) other tabs)"))
          }
        }
      }

      var slotCounts: [String: Int] = [:]
      for (index, child) in children.enumerated() {
        if index >= maxChildren {
          lines.append(
            .init(
              key: key + "/more",
              text: String(repeating: " ", count: childDepth)
                + "… \(children.count - maxChildren) more"))
          break
        }
        let childData = Self.fetch(child)
        let childRole = childData["AXRole"] as? String ?? "?"
        let childLabel =
          Self.text(childData["AXTitle"]) ?? Self.text(childData["AXDescription"]) ?? ""
        let base =
          (childLabel.isEmpty || !Self.labelKeyedRoles.contains(childRole))
          ? childRole : childRole + ":" + String(childLabel.prefix(40))
        let count = slotCounts[base, default: 0]
        slotCounts[base] = count + 1
        walk(
          child, childData, depth: childDepth, parentKey: key, slot: base + "#\(count)",
          parentLabel: label ?? parentLabel)
      }
    }

    walk(
      window, windowData, depth: 0, parentKey: app.bundleId ?? "app", slot: "win",
      parentLabel: nil)

    return AccessibilitySnapshot(
      windowTitle: Self.text(windowData["AXTitle"]),
      lines: lines,
      durationMs: Int(Date().timeIntervalSince(start) * 1000))
  }

  /// `~` changed lines, `+` added lines, and the ids of removed elements as
  /// ranges. Nil when nothing changed.
  func diff(from old: AccessibilitySnapshot, to new: AccessibilitySnapshot) -> String? {
    let oldTextByKey = Dictionary(
      old.lines.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
    let newKeys = Set(new.lines.map(\.key))

    var output: [String] = []
    for line in new.lines {
      let trimmed = line.text.trimmingCharacters(in: .whitespaces)
      if let oldText = oldTextByKey[line.key] {
        if oldText != line.text { output.append("~ " + trimmed) }
      } else {
        output.append("+ " + trimmed)
      }
    }

    let removedIDs = old.lines
      .filter { !newKeys.contains($0.key) }
      .compactMap { idForKey[$0.key] }
      .sorted()
    if !removedIDs.isEmpty {
      output.append("- removed: " + Self.ranges(removedIDs))
    }

    return output.isEmpty ? nil : output.joined(separator: "\n")
  }

  // MARK: - Single elements

  /// The element under a screen point, described by the nearest labeled
  /// element at or above it, e.g. `button "Send"`, plus the pid of the app
  /// that owns it.
  func describeElement(at point: CGPoint) -> (pid: pid_t, description: String)? {
    var hit: AXUIElement?
    guard
      AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        == .success,
      let hit
    else { return nil }
    var pid: pid_t = 0
    AXUIElementGetPid(hit, &pid)

    var current: AXUIElement? = hit
    var clickedRole = ""
    for _ in 0..<6 {
      guard let element = current else { break }
      let data = Self.fetch(element)
      let role = String((data["AXRole"] as? String ?? "?").dropFirst(2)).lowercased()
      if clickedRole.isEmpty { clickedRole = role }

      let value = Self.isSecure(data) ? nil : Self.text(data["AXValue"])
      if let label = Self.text(data["AXTitle"]) ?? Self.text(data["AXDescription"]) ?? value {
        let suffix = role == clickedRole ? "" : " (clicked \(clickedRole) inside it)"
        return (pid, "\(role) \"\(Self.clip(label))\"" + suffix)
      }
      current = Self.attribute(element, "AXParent").map { $0 as! AXUIElement }
    }
    return clickedRole.isEmpty ? nil : (pid, clickedRole + " (no label)")
  }

  /// The focused text field's label and contents, plus the pid of the app
  /// that owns it. Password fields come back as `[secure field]`.
  func focusedField() -> (pid: pid_t, label: String, value: String?)? {
    guard let focusedValue = Self.attribute(systemWide, "AXFocusedUIElement") else { return nil }
    let focused = focusedValue as! AXUIElement
    var pid: pid_t = 0
    AXUIElementGetPid(focused, &pid)

    let data = Self.fetch(focused)
    let label =
      Self.text(data["AXTitle"]) ?? Self.text(data["AXDescription"])
      ?? Self.text(data["AXPlaceholderValue"]) ?? (data["AXRole"] as? String ?? "?")
    if Self.isSecure(data) { return (pid, label, "[secure field]") }
    return (pid, label, Self.text(data["AXValue"]))
  }

  /// Whether any on-screen window of `pid` covers a screen point, even one
  /// behind other windows. Reads the window list, not accessibility, so it's
  /// safe for any window.
  ///
  /// Every window counts, not just the top one, because invisible overlays
  /// (the Dock keeps a transparent full-screen window above everything) would
  /// otherwise hide the window the click actually lands in.
  func hasWindow(of pid: pid_t, at point: CGPoint) -> Bool {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }

    return windows.contains { info in
      guard
        let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
        let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDict)
      else { return false }
      return bounds.contains(point)
    }
  }

  /// The focused window's title for an app, without reading the whole tree.
  func windowTitle(of app: AccessibilityAppInfo) -> String? {
    guard let window = Self.attribute(app.element, "AXFocusedWindow") else { return nil }
    return Self.text(Self.attribute(window as! AXUIElement, "AXTitle"))
  }

  // MARK: - Helpers

  private func stableID(_ key: String) -> Int {
    if let id = idForKey[key] { return id }
    let id = idForKey.count + 1
    idForKey[key] = id
    return id
  }

  /// Electron apps and Chrome only build their page's accessibility tree once
  /// a client asks for it. The content shows up a few seconds later.
  private func enableWebContentIfNeeded(_ app: AccessibilityAppInfo) {
    guard app.isWebShaped, !enabledWebPIDs.contains(app.pid) else { return }
    enabledWebPIDs.insert(app.pid)
    AXUIElementSetAttributeValue(app.element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(
      app.element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
  }

  /// Reads all the attributes the snapshot needs in one call.
  private static func fetch(_ element: AXUIElement) -> [String: AnyObject] {
    var values: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        element, wantedAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        == .success,
      let array = values as? [AnyObject],
      let names = wantedAttributes as? [String]
    else { return [:] }

    var result: [String: AnyObject] = [:]
    for (index, value) in array.enumerated() where index < names.count && !isAXError(value) {
      result[names[index]] = value
    }
    return result
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  /// Missing attributes come back from the bulk read as AXValue error markers.
  private static func isAXError(_ value: AnyObject) -> Bool {
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return false }
    return AXValueGetType(value as! AXValue) == .axError
  }

  /// Strings, URLs and numbers as trimmed text; nil when empty. Zero-width
  /// characters are trimmed too: Slack's empty message box reports one as its
  /// value.
  private static func text(_ value: AnyObject?) -> String? {
    guard let value else { return nil }
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: invisibleCharacters)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let url = value as? URL { return url.absoluteString }
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private static let invisibleCharacters = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{FFFC}"))

  private static func frame(_ data: [String: AnyObject]) -> CGRect? {
    guard let position = data["AXPosition"], let size = data["AXSize"],
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    return CGRect(origin: point, size: dimensions)
  }

  private static func isSecure(_ data: [String: AnyObject]) -> Bool {
    (data["AXSubrole"] as? String) == "AXSecureTextField"
  }

  private static func isSelectedTab(_ data: [String: AnyObject]) -> Bool {
    (data["AXSelected"] as? Bool) == true || (data["AXValue"] as? NSNumber)?.intValue == 1
  }

  private static func states(_ data: [String: AnyObject]) -> [String] {
    var states: [String] = []
    if (data["AXFocused"] as? Bool) == true { states.append("focused") }
    if (data["AXSelected"] as? Bool) == true { states.append("selected") }
    if (data["AXEnabled"] as? Bool) == false { states.append("disabled") }
    return states
  }

  /// Text longer than this is cut. It's high enough that only unusual
  /// elements (a whole document in one text area) ever hit it.
  static let maxTextLength = 10_000

  /// Puts text on one line and cuts it to `maxTextLength` characters.
  static func clip(_ string: String) -> String {
    let oneLine = string.replacingOccurrences(of: "\n", with: " ⏎ ")
    guard oneLine.count > maxTextLength else { return oneLine }
    return String(oneLine.prefix(maxTextLength)) + "…(+\(oneLine.count - maxTextLength))"
  }

  /// [3, 4, 5, 9] → "3-5,9"
  private static func ranges(_ sortedIDs: [Int]) -> String {
    var parts: [String] = []
    var start = sortedIDs[0]
    var previous = sortedIDs[0]
    for id in sortedIDs.dropFirst() {
      if id == previous + 1 {
        previous = id
        continue
      }
      parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
      start = id
      previous = id
    }
    parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
    return parts.joined(separator: ",")
  }
}
