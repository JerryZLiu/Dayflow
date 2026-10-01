import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private var cancellable: AnyCancellable?
  private var flowCancellable: AnyCancellable?
  private var flowTimer: Timer?
  /// What the Flow pill last drew, so the once-a-second tick only re-renders
  /// when the label actually changes.
  private var flowPillLabel: String??
  private var visibilityCancellable: AnyCancellable?

  override init() {
    super.init()
    menu.delegate = self
    statusItem.menu = menu

    if let button = statusItem.button {
      button.imageScaling = .scaleProportionallyDown
      button.imagePosition = .imageOnly

      let isRecording = AppState.shared.isRecording
      button.image = menuBarIcon(isRecording: isRecording)
    }

    // Observe recording state changes and update icon
    cancellable = AppState.shared.$isRecording
      .removeDuplicates()
      .sink { [weak self] isRecording in
        self?.updateIcon(isRecording: isRecording)
      }

    // While a Flow session is on, the icon gives way to the Flow pill.
    flowCancellable = FlowSessionMirror.shared.$snapshot
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.flowSessionChanged()
      }

    visibilityCancellable = UserDefaults.standard.publisher(for: \.showMenuBarIcon)
      .sink { [weak self] isVisible in
        self?.statusItem.isVisible = isVisible
      }
  }

  private func updateIcon(isRecording: Bool) {
    guard !FlowSessionMirror.shared.isSessionOn else { return }
    statusItem.button?.image = menuBarIcon(isRecording: isRecording)
  }

  // MARK: - Flow session pill

  private func flowSessionChanged() {
    if FlowSessionMirror.shared.isSessionOn {
      statusItem.length = NSStatusItem.variableLength
      if flowTimer == nil {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.renderFlowPill() }
        }
        // .common so the countdown keeps moving while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        flowTimer = timer
      }
      renderFlowPill()
    } else {
      flowTimer?.invalidate()
      flowTimer = nil
      flowPillLabel = nil
      statusItem.length = NSStatusItem.squareLength
      statusItem.button?.image = menuBarIcon(isRecording: AppState.shared.isRecording)
    }
  }

  private func renderFlowPill() {
    let label = flowTimeLabel()
    guard flowPillLabel != .some(label) else { return }
    let renderer = ImageRenderer(content: FlowMenuBarPill(time: label))
    renderer.scale = statusItem.button?.window?.backingScaleFactor ?? 2
    guard let image = renderer.nsImage else { return }
    flowPillLabel = .some(label)
    statusItem.button?.image = image
  }

  /// Time left in the session or the break; an always-on session counts up.
  private func flowTimeLabel() -> String? {
    let snapshot = FlowSessionMirror.shared.snapshot
    let now = Int(Date().timeIntervalSince1970)
    let seconds: Int
    if snapshot.phase == .onBreak, let endsAt = snapshot.breakEndsAt {
      seconds = endsAt - now
    } else if let endsAt = snapshot.sessionEndsAt {
      seconds = endsAt - now
    } else if let startedAt = snapshot.sessionStartedAt {
      seconds = now - startedAt
    } else {
      return nil
    }
    let clamped = max(0, seconds)
    if clamped >= 3600 {
      return String(format: "%d:%02d:%02d", clamped / 3600, clamped % 3600 / 60, clamped % 60)
    }
    return String(format: "%d:%02d", clamped / 60, clamped % 60)
  }

  private func flowSessionCardItem() -> NSMenuItem {
    let mirror = FlowSessionMirror.shared
    let mode: FlowMenuSessionCard.Mode
    if RecordingControl.currentMode() != .active {
      mode = .dayflowPaused
    } else if mirror.snapshot.phase == .onBreak {
      mode = .onBreak
    } else {
      mode = .inProgress
    }

    let card = FlowMenuSessionCard(mode: mode) { [weak self] control in
      self?.menu.cancelTracking()
      switch control {
      case .pause: mirror.menuBarControl("break")
      case .resume: mirror.menuBarControl("resume")
      case .stop: mirror.menuBarControl("end")
      case .snooze: mirror.menuBarSnooze(minutes: 5)
      }
    }
    let size = FlowMenuSessionCard.size
    let host = NSHostingView(
      rootView: card.padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 6))
    host.frame = NSRect(x: 0, y: 0, width: size.width + 12, height: size.height + 8)

    let item = NSMenuItem()
    item.view = host
    return item
  }

  private func menuBarIcon(isRecording: Bool) -> NSImage? {
    let name = isRecording ? "MenuBarOnIcon" : "MenuBarOffIcon"
    guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
    image.size = NSSize(width: 22, height: 18)
    return image
  }

  // MARK: - Menu

  // Rebuilt every time the menu opens, so it always reflects the current recording state.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    if FlowSessionMirror.shared.isSessionOn {
      menu.addItem(flowSessionCardItem())
    }

    switch RecordingControl.currentMode() {
    case .active:
      menu.addItem(.sectionHeader(title: String(localized: "Pause Dayflow")))
      menu.addItem(pauseStripItem())
    case .pausedTimed(let endTime):
      let time = endTime.formatted(date: .omitted, time: .shortened)
      menu.addItem(infoItem(String(localized: "Paused until \(time)")))
      menu.addItem(actionItem(String(localized: "Resume Dayflow"), #selector(resumeRecording)))
    case .pausedIndefinite, .stopped:
      menu.addItem(actionItem(String(localized: "Resume Dayflow"), #selector(resumeRecording)))
    }

    menu.addItem(.separator())
    menu.addItem(actionItem(String(localized: "Open Dayflow"), #selector(openDayflow)))
    menu.addItem(actionItem(String(localized: "Open Recordings"), #selector(openRecordingsFolder)))
    menu.addItem(actionItem(String(localized: "Check for Updates"), #selector(checkForUpdates)))
    menu.addItem(.separator())
    menu.addItem(
      actionItem(String(localized: "Quit Completely"), #selector(quitDayflow), keyEquivalent: "q"))
  }

  private func actionItem(_ title: String, _ action: Selector, keyEquivalent: String = "")
    -> NSMenuItem
  {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    return item
  }

  /// The horizontal row of pause lengths. Custom views don't close the menu on
  /// click the way normal items do, so the handler closes it first.
  private func pauseStripItem() -> NSMenuItem {
    let strip = StatusMenuPauseStrip(durations: PausePresets.durations) { [weak self] duration in
      self?.menu.cancelTracking()
      PauseManager.shared.pause(for: duration, source: .menuBar)
    }
    let host = NSHostingView(rootView: strip)
    host.frame = NSRect(x: 0, y: 0, width: 220, height: StatusMenuPauseStrip.height)
    host.autoresizingMask = [.width]

    let item = NSMenuItem()
    item.view = host
    return item
  }

  // No action, so the menu shows it greyed out as a status line.
  private func infoItem(_ title: String) -> NSMenuItem {
    NSMenuItem(title: title, action: nil, keyEquivalent: "")
  }

  // MARK: - Actions

  @objc private func resumeRecording() {
    if PauseManager.shared.isPaused {
      PauseManager.shared.resume(source: .userClickedMenuBar)
    } else {
      RecordingControl.start(reason: "user_menu_bar")
    }
  }

  @objc private func openDayflow() {
    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    if showDockIcon {
      NSApp.setActivationPolicy(.regular)
    }

    NSApp.unhide(nil)
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func openRecordingsFolder() {
    NSWorkspace.shared.open(StorageManager.shared.recordingsRoot)
  }

  @objc private func checkForUpdates() {
    UpdaterManager.shared.checkForUpdates(showUI: true)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func quitDayflow() {
    AppDelegate.allowTermination = true
    NSApp.terminate(nil)
  }
}

extension UserDefaults {
  // KVO needs the property name to match the defaults key.
  @objc dynamic var showMenuBarIcon: Bool {
    object(forKey: "showMenuBarIcon") as? Bool ?? true
  }
}
