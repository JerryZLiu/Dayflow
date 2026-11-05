//
//  AccessibilityRecorder.swift
//  Dayflow
//
//  Records what the user does, alongside the screenshots: clicks, shortcuts,
//  what they typed into which field, and what changed on screen right after
//  each action. Screen content is read as text through the accessibility API
//  (see AccessibilityTreeReader) and written to JSONL files by
//  AccessibilityLogStore.
//
//  How each action is recorded:
//  - Clicks and drags: the element under the pointer, then the screen's
//    changes 250 ms later (the immediate reaction) and 1.5 s later (the
//    outcome, such as a dialog or a sent message).
//  - Typing: individual keys are never stored. 750 ms after the last key,
//    the focused field is read back as a whole.
//  - Return: what was in the field, then the changes at 250 ms and 1.5 s,
//    which show whether it was sent (the box cleared) or not.
//  - Scrolling: 750 ms after scrolling stops, the screen's changes, so
//    text scrolled into view is captured even without a click.
//  - Window and tab switches: polled once a second, then a snapshot.
//
//  Runs beside ScreenRecorder, which starts and stops it, and never touches
//  the screenshot pipeline. Blocked apps from the privacy settings are
//  skipped entirely, and password fields are never read. Nothing else is
//  redacted yet.
//

import AppKit
import ApplicationServices

final class AccessibilityRecorder: @unchecked Sendable {
  static let shared = AccessibilityRecorder()

  private static let typingPause: TimeInterval = 0.75
  private static let scrollPause: TimeInterval = 0.75
  private static let reactionDelay: TimeInterval = 0.25
  private static let outcomeDelay: TimeInterval = 1.5
  private static let windowPollInterval: TimeInterval = 1.0
  /// Two snapshots closer together than this would show nearly the same thing.
  private static let minSnapshotGap: TimeInterval = 0.4
  /// A press and release this far apart (in points) is a drag, not a click.
  private static let dragDistance: CGFloat = 6

  private static let returnKeyCode: Int64 = 36
  private static let keypadEnterKeyCode: Int64 = 76
  private static let escapeKeyCode: Int64 = 53

  /// Dayflow's own UI is never read. Accessibility calls into our own process
  /// run AppKit and SwiftUI code on the calling thread, and this recorder runs
  /// off the main thread, so reading ourselves would crash.
  private static let ownPID = ProcessInfo.processInfo.processIdentifier

  /// All state below is only touched on `queue`.
  private let queue = DispatchQueue(label: "com.dayflow.accessibility", qos: .utility)
  private let reader = AccessibilityTreeReader()
  private let store = AccessibilityLogStore.shared

  private var isRunning = false
  private var eventTap: CFMachPort?
  private var windowPollTimer: DispatchSourceTimer?

  private var frontApp: AccessibilityAppInfo?
  private var lastWindowKey: String?
  /// The last snapshot of each app, by bundle id, to diff the next one against.
  private var lastSnapshotByApp: [String: AccessibilitySnapshot] = [:]
  private var lastSnapshotAt = Date.distantPast

  private var mouseDownPoint: CGPoint = .zero
  private var mouseDownTarget: String?

  private var typingFlush: DispatchWorkItem?
  /// The last time the focused field was read after typing. Used on Return,
  /// because by the time we read the field the app may have already cleared it.
  private var lastTyped: (field: String, text: String, at: Date)?

  private var scrollSnapshot: DispatchWorkItem?

  private init() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil, queue: nil
    ) { [weak self] notification in
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      self?.queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.setFrontApp(app)
      }
    }
  }

  // MARK: - Start/Stop

  /// Safe to call repeatedly. Does nothing when the setting is off or
  /// Accessibility access isn't granted.
  func start() {
    queue.async { [weak self] in
      guard let self, !self.isRunning else { return }
      guard AccessibilityCaptureConfig.isEnabled else { return }
      guard AXIsProcessTrusted() else {
        print("[AccessibilityRecorder] Not starting: Accessibility access not granted")
        return
      }
      guard let tap = self.makeEventTap() else {
        print("[AccessibilityRecorder] Not starting: could not create event tap")
        return
      }

      self.eventTap = tap
      self.isRunning = true
      self.startWindowPolling()
      self.store.append(AccessibilityLogEvent(time: Date(), kind: "session_start"))

      DispatchQueue.main.async { [weak self] in
        let app = NSWorkspace.shared.frontmostApplication
        self?.queue.async { [weak self] in
          guard let self, self.isRunning, self.frontApp == nil else { return }
          self.setFrontApp(app)
        }
      }
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self, self.isRunning else { return }
      if self.typingFlush != nil { self.flushTyping() }

      self.isRunning = false
      if let tap = self.eventTap {
        CGEvent.tapEnable(tap: tap, enable: false)
        // Invalidating the port also ends the tap thread's run loop.
        CFMachPortInvalidate(tap)
      }
      self.eventTap = nil
      self.windowPollTimer?.cancel()
      self.windowPollTimer = nil
      self.scrollSnapshot?.cancel()
      self.scrollSnapshot = nil

      self.frontApp = nil
      self.lastWindowKey = nil
      self.lastSnapshotByApp.removeAll()
      self.lastTyped = nil
      self.mouseDownTarget = nil
      self.reader.reset()
      self.store.append(AccessibilityLogEvent(time: Date(), kind: "session_stop"))
    }
  }

  // MARK: - Event tap

  /// Raw input, copied out of the CGEvent on the tap thread.
  private enum Input {
    case mouseDown(CGPoint, isRight: Bool)
    case mouseUp(CGPoint)
    case keyDown(keyCode: Int64, flags: CGEventFlags, characters: String?)
    case scroll
  }

  /// A listen-only tap: it sees input but can't block or change it. It runs
  /// on its own thread so a busy main thread never makes macOS disable it.
  private func makeEventTap() -> CFMachPort? {
    let types: [CGEventType] = [
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown, .scrollWheel,
    ]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: Self.tapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return nil }

    let thread = Thread {
      let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      CFRunLoopRun()
    }
    thread.name = "com.dayflow.accessibility.eventtap"
    thread.qualityOfService = .userInteractive
    thread.start()
    return tap
  }

  private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
      let recorder = Unmanaged<AccessibilityRecorder>.fromOpaque(userInfo).takeUnretainedValue()
      recorder.receive(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
  }

  /// Runs on the tap thread: copy what we need and hand off to `queue`.
  private func receive(type: CGEventType, event: CGEvent) {
    let input: Input
    switch type {
    case .leftMouseDown:
      input = .mouseDown(event.location, isRight: false)
    case .rightMouseDown:
      input = .mouseDown(event.location, isRight: true)
    case .leftMouseUp:
      input = .mouseUp(event.location)
    case .keyDown:
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
      let flags = event.flags
      // Characters are only read for shortcuts, never for normal typing.
      let isShortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
      input = .keyDown(
        keyCode: keyCode, flags: flags, characters: isShortcut ? Self.characters(of: event) : nil)
    case .scrollWheel:
      input = .scroll
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      queue.async { [weak self] in
        guard let self, self.isRunning, let tap = self.eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return
    default:
      return
    }

    queue.async { [weak self] in
      guard let self, self.isRunning else { return }
      self.handle(input)
    }
  }

  private static func characters(of event: CGEvent) -> String? {
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(
      maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
    guard length > 0 else { return nil }
    return String(utf16CodeUnits: buffer, count: length)
  }

  // MARK: - Handling input

  private func handle(_ input: Input) {
    guard let app = frontApp, !isBlocked(app) else { return }

    switch input {
    case .mouseDown(let point, let isRight):
      mouseDownPoint = point
      // The click may land on a Dayflow window (or menu bar icon) floating
      // over another app, or in a blocked app before it becomes frontmost.
      // Skip whenever any Dayflow window is under the pointer: asking
      // accessibility about our own window from this thread deadlocks SwiftUI.
      if reader.hasWindow(of: Self.ownPID, at: point) {
        mouseDownTarget = nil
      } else {
        let hit = reader.describeElement(at: point)
        mouseDownTarget = hit.flatMap { isBlocked(pid: $0.pid) ? nil : $0.description }
      }
      if isRight {
        var event = makeEvent("context_menu", app: app)
        event.target = mouseDownTarget
        record(event)
      }

    case .mouseUp(let point):
      if typingFlush != nil { flushTyping() }
      let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
      let kind = distance >= Self.dragDistance ? "drag" : "click"
      var event = makeEvent(kind, app: app)
      event.target = mouseDownTarget
      record(event)
      snapshotAfterAction(kind)

    case .keyDown(let keyCode, let flags, let characters):
      if keyCode == Self.returnKeyCode || keyCode == Self.keypadEnterKeyCode {
        recordSubmit(app: app)
      } else if flags.contains(.maskCommand) || flags.contains(.maskControl) {
        if typingFlush != nil { flushTyping() }
        var event = makeEvent("shortcut", app: app)
        event.keys = Self.modifierSymbols(flags) + (characters ?? "?").uppercased()
        record(event)
        snapshotAfterAction("shortcut")
      } else if keyCode == Self.escapeKeyCode {
        if typingFlush != nil { flushTyping() }
        record(makeEvent("escape", app: app))
        snapshotAfterAction("escape")
      } else {
        scheduleTypingFlush()
      }

    case .scroll:
      scheduleScrollSnapshot()
    }
  }

  /// Scrolling sends dozens of events a second (and keeps going during
  /// trackpad momentum), so wait until it stops, then take one snapshot.
  private func scheduleScrollSnapshot() {
    scrollSnapshot?.cancel()
    let snapshot = DispatchWorkItem { [weak self] in
      guard let self, self.isRunning else { return }
      self.scrollSnapshot = nil
      self.takeSnapshot(trigger: "scroll")
    }
    scrollSnapshot = snapshot
    queue.asyncAfter(deadline: .now() + Self.scrollPause, execute: snapshot)
  }

  private func scheduleTypingFlush() {
    typingFlush?.cancel()
    let flush = DispatchWorkItem { [weak self] in
      guard let self, self.isRunning else { return }
      self.flushTyping()
    }
    typingFlush = flush
    queue.asyncAfter(deadline: .now() + Self.typingPause, execute: flush)
  }

  /// Reads the focused field back and records its whole contents.
  private func flushTyping() {
    typingFlush?.cancel()
    typingFlush = nil
    guard let app = frontApp, !isBlocked(app),
      let field = reader.focusedField(), !isBlocked(pid: field.pid)
    else { return }

    var event = makeEvent("text", app: app)
    event.field = AccessibilityTreeReader.clip(field.label)
    event.text = AccessibilityTreeReader.clip(field.value ?? "")
    record(event)
    if let value = field.value {
      lastTyped = (field.label, value, Date())
    }
  }

  /// Return was pressed. The app may already have cleared the field by the
  /// time we read it, so fall back to the last text we saw typed into it.
  private func recordSubmit(app: AccessibilityAppInfo) {
    typingFlush?.cancel()
    typingFlush = nil

    var field = reader.focusedField()
    if let pid = field?.pid, isBlocked(pid: pid) { field = nil }
    var text = field?.value
    if text == nil, let lastTyped, lastTyped.field == field?.label,
      Date().timeIntervalSince(lastTyped.at) < 10
    {
      text = lastTyped.text
    }
    lastTyped = nil

    var event = makeEvent("submit", app: app)
    event.field = field.map { AccessibilityTreeReader.clip($0.label) }
    event.text = text.map { AccessibilityTreeReader.clip($0) }
    record(event)
    snapshotAfterAction("submit")
  }

  // MARK: - Snapshots

  /// One diff right away, one once the result has settled.
  private func snapshotAfterAction(_ action: String) {
    queue.asyncAfter(deadline: .now() + Self.reactionDelay) { [weak self] in
      self?.takeSnapshot(trigger: "\(action) +250ms")
    }
    queue.asyncAfter(deadline: .now() + Self.outcomeDelay) { [weak self] in
      self?.takeSnapshot(trigger: "\(action) +1.5s")
    }
  }

  /// Records a diff against this app's last snapshot, or the full tree the
  /// first time the app is seen.
  private func takeSnapshot(trigger: String) {
    guard isRunning, let app = frontApp, !isBlocked(app) else { return }
    guard Date().timeIntervalSince(lastSnapshotAt) >= Self.minSnapshotGap else { return }
    lastSnapshotAt = Date()

    guard let snapshot = reader.snapshot(of: app) else { return }
    let appKey = app.bundleId ?? app.name

    var event: AccessibilityLogEvent
    if let previous = lastSnapshotByApp[appKey] {
      guard let diff = reader.diff(from: previous, to: snapshot) else {
        lastSnapshotByApp[appKey] = snapshot
        return  // nothing changed
      }
      event = makeEvent("diff", app: app)
      event.diff = diff
    } else {
      event = makeEvent("snapshot", app: app)
      event.tree = snapshot.text
    }
    event.window = snapshot.windowTitle
    event.trigger = trigger
    event.snapshotMs = snapshot.durationMs
    record(event)
    lastSnapshotByApp[appKey] = snapshot
  }

  // MARK: - Window changes

  private func startWindowPolling() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + Self.windowPollInterval, repeating: Self.windowPollInterval)
    timer.setEventHandler { [weak self] in
      self?.checkForWindowChange()
    }
    timer.resume()
    windowPollTimer = timer
  }

  /// Polling the title also catches browser tab switches, which send no
  /// notification.
  private func checkForWindowChange() {
    guard isRunning, let app = frontApp else { return }

    if isBlocked(app) {
      let key = "blocked|" + (app.bundleId ?? app.name)
      guard key != lastWindowKey else { return }
      lastWindowKey = key
      if typingFlush != nil {
        typingFlush?.cancel()
        typingFlush = nil
      }
      var event = makeEvent("window", app: app)
      event.blocked = true
      store.append(event)  // only the app name, no title or content
      return
    }

    let title = reader.windowTitle(of: app)
    let key = (app.bundleId ?? app.name) + "|" + (title ?? "")
    guard key != lastWindowKey else { return }
    lastWindowKey = key

    var event = makeEvent("window", app: app)
    event.window = title
    record(event)
    queue.asyncAfter(deadline: .now() + Self.reactionDelay) { [weak self] in
      self?.takeSnapshot(trigger: "window")
    }
  }

  // MARK: - Helpers

  /// Nil while Dayflow itself is frontmost, so nothing is read or recorded.
  private func setFrontApp(_ app: NSRunningApplication?) {
    if let app, app.processIdentifier != Self.ownPID {
      frontApp = AccessibilityAppInfo(app)
      checkForWindowChange()
    } else {
      if typingFlush != nil {
        typingFlush?.cancel()
        typingFlush = nil
      }
      frontApp = nil
      lastWindowKey = nil
    }
  }

  private func isBlocked(_ app: AccessibilityAppInfo) -> Bool {
    if RecordingPrivacyPreferences.isApplicationBlocked(
      bundleIdentifier: app.bundleId, applicationName: app.name)
    {
      return true
    }
    // A browser window the user asked us to hide. Screenshots of it get a
    // redaction card; the accessibility log, which would otherwise hold the
    // page's text and its URL, records nothing but the app name.
    return isHiddenBrowserWindow(app)
  }

  private func isHiddenBrowserWindow(_ app: AccessibilityAppInfo) -> Bool {
    let settings = BrowserPrivacyPreferences.settings()
    guard !settings.isInactive else { return false }
    let foreground = BrowserForegroundApp(
      pid: app.pid, bundleIdentifier: app.bundleId, name: app.name)
    return BrowserWindowInspector.shared.blockedBrowser(app: foreground, settings: settings) != nil
  }

  /// For elements that may belong to an app other than `frontApp`.
  private func isBlocked(pid: pid_t) -> Bool {
    if let app = frontApp, app.pid == pid { return isBlocked(app) }
    guard let owner = NSRunningApplication(processIdentifier: pid) else { return false }
    return RecordingPrivacyPreferences.isApplicationBlocked(
      bundleIdentifier: owner.bundleIdentifier, applicationName: owner.localizedName)
  }

  private func makeEvent(_ kind: String, app: AccessibilityAppInfo) -> AccessibilityLogEvent {
    var event = AccessibilityLogEvent(time: Date(), kind: kind)
    event.app = app.name
    event.bundleId = app.bundleId
    return event
  }

  private func record(_ event: AccessibilityLogEvent) {
    store.append(event)
  }

  private static func modifierSymbols(_ flags: CGEventFlags) -> String {
    var symbols = ""
    if flags.contains(.maskControl) { symbols += "⌃" }
    if flags.contains(.maskAlternate) { symbols += "⌥" }
    if flags.contains(.maskShift) { symbols += "⇧" }
    if flags.contains(.maskCommand) { symbols += "⌘" }
    return symbols
  }
}
