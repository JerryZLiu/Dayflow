//
//  DocketHandoffTransition.swift
//  Dayflow
//
//  How Dayflow gets out of the way when a task is pasted into Claude or ChatGPT. Switching
//  apps straight away looked like Dayflow had crashed, so each style below shows the hand-off
//  instead. The gear menu has a toggle so they can be compared:
//    instant     switch straight to the app (the old behavior)
//    cardGenie   the card floats above everything while the app comes forward, then genies
//                down into the app's message box, where the prompt appears
//    appGenie    Dayflow genies into the app's Dock icon, then the app genies back out of it
//    slide       Dayflow slides off to the left as the app slides in, like switching desktops
//    zoom        the card grows into the app's window, like opening an app on an iPhone
//    crab        a pixel crab catches the card, holds it while the app comes forward, then
//                throws it into the message box (the crab is in DocketCrab.swift)
//
//  We can't animate another app's window, so everything happens in a transparent, click-
//  through window above every app. It draws the card live, and the windows as pictures taken
//  with ScreenCaptureKit (Dayflow already has Screen Recording access). Each picture sits
//  exactly where its real window is, so swapping one for the other is invisible.
//
//  Rectangles here are in global screen points, top-left origin (what Accessibility and the
//  window list use) until they go into the model, which uses the overlay's own coordinates.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

enum DocketTransitionStyle: String, CaseIterable {
  case instant
  case cardGenie
  case appGenie
  case slide
  case zoom
  case crab

  static let defaultsKey = "docketTransitionStyle"

  static var current: DocketTransitionStyle {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .crab
  }

  var displayName: String {
    switch self {
    case .instant: return "Instant"
    case .cardGenie: return "Card into message box"
    case .appGenie: return "Dayflow into Dock, app out"
    case .slide: return "Slide across"
    case .zoom: return "Card opens into app"
    case .crab: return "Crab catches and throws"
    }
  }

  var note: String {
    switch self {
    case .instant: return "Switches straight to the app, like before."
    case .cardGenie: return "The card floats above while the app opens, then genies into its message box."
    case .appGenie: return "Dayflow genies into the app’s Dock icon, then the app genies out of it."
    case .slide: return "Dayflow slides away as the app slides in, like switching desktops."
    case .zoom: return "The card grows into the app’s window, like opening an app on iPhone."
    case .crab: return "A pixel crab catches the card and throws it into the message box."
    }
  }

  /// The card itself carries the hand-off, so the deck hides it in place instead of throwing it.
  var liftsCard: Bool { self == .cardGenie || self == .zoom || self == .crab }
}

/// The front card at the moment it was handed off.
struct DocketLiftedCard {
  let item: DailyBriefDocketItem
  let isOpen: Bool
  /// Where it is on screen (global, top-left origin), including the drag.
  let frame: CGRect
  /// Its drag tilt in degrees.
  let tilt: Double
}

// MARK: - Director

/// What happens to the front card when it's handed off.
enum DocketCardExit {
  /// It flies off to the side (no transition, or the Run method).
  case thrown
  /// It vanishes in place, and the overlay draws it and carries it into the app.
  case carried
  /// It stays in place for a moment, so the picture of Dayflow's window includes it.
  case keptInPicture
}

/// Every style starts when the fingers lift (the deck only hands off then), and nothing
/// switches apps until the overlay is ready to cover the switch.
@MainActor
enum DocketHandoffDirector {
  private static let model = DocketTransitionModel()
  private static var panel: NSPanel?
  private static var isRunning = false
  private static var runID = 0
  /// The overlay screen's top-left corner, in global top-left coordinates.
  private static var overlayOrigin = CGPoint.zero
  private static weak var dayflowWindow: NSWindow?
  /// The Dock and slide styles leave Dayflow hidden, as if minimized, until the user
  /// comes back to it. Showing it again behind the app would look like a glitch.
  private static var keepsDayflowHidden = false
  private static var isWatchingForReturn = false

  /// Reduce Motion turns every style into the instant switch.
  private static var style: DocketTransitionStyle {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .instant : DocketTransitionStyle.current
  }

  /// What the deck should do with the card if it's handed off right now.
  static func cardExit(for agent: DailyBriefAgent) -> DocketCardExit {
    guard style != .instant, !isRunning, let app = runningApp(agent),
      frontWindow(of: app.processIdentifier) != nil
    else { return .thrown }
    return style.liftsCard ? .carried : .keptInPicture
  }

  /// Copies the prompt and brings the agent's app forward with the chosen transition,
  /// then pastes. Falls back to an instant switch when the app isn't open with a window.
  static func paste(prompt: String, agent: DailyBriefAgent, card: DocketLiftedCard?) {
    let style = self.style
    // A card-carrying style needs the card; without one (the list's button) switch instantly.
    guard style != .instant, !isRunning, !style.liftsCard || card != nil,
      let app = runningApp(agent),
      let agentWindow = frontWindow(of: app.processIdentifier),
      let window = NSApp.keyWindow ?? NSApp.mainWindow,
      let screen = window.screen ?? NSScreen.main
    else {
      DailyBriefHandoffRunner.paste(prompt: prompt, agent: agent, folder: nil)
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(prompt, forType: .string)

    isRunning = true
    runID += 1
    let id = runID
    dayflowWindow = window
    watchForReturn()
    openOverlay(on: screen, style: style)
    let pid = app.processIdentifier
    Task.detached { prepareAccessibility(pid: pid) }

    // Whatever happens, never leave the overlay up or Dayflow invisible.
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(8))
      guard runID == id else { return }
      keepsDayflowHidden = false
      closeOverlay()
    }

    Task { @MainActor in
      switch style {
      case .instant:
        break
      case .cardGenie:
        if let card { await carry(card, agent: agent, pid: pid, agentWindow: agentWindow) }
      case .zoom:
        if let card { await zoom(card, agent: agent, pid: pid, agentWindow: agentWindow) }
      case .appGenie:
        await appGenie(agent: agent, pid: pid, agentWindow: agentWindow, screen: screen)
      case .slide:
        await slide(agent: agent, pid: pid, agentWindow: agentWindow)
      case .crab:
        if let card { await crabCarry(card, agent: agent, pid: pid, agentWindow: agentWindow) }
      }
      if runID == id { closeOverlay() }
    }
  }

  // MARK: Styles

  /// Card into message box, from the moment the fingers lift:
  ///   0.0   the overlay's copy of the card replaces the real one and rises a little
  ///         while it straightens (0.25s)
  ///   ~0.15 Dayflow has a picture of its own window and has found the message box, both
  ///         done while the card rose. The app comes forward under that picture.
  ///   ~0.25 the picture dissolves (0.2s), so the app appears instead of jumping in
  ///   ~0.35 the card genies into the message box (0.5s)
  ///   ~0.85 the box glows as the prompt is pasted into it
  private static func carry(
    _ card: DocketLiftedCard, agent: DailyBriefAgent, pid: pid_t, agentWindow: AgentWindow
  ) async {
    lift(card)
    let boxSearch = Task.detached { findMessageBox(pid: pid, within: 0.35) }
    if let window = dayflowWindow {
      let id = CGWindowID(window.windowNumber)
      if let picture = await capture([id])[id] {
        model.dayflowFrame = local(globalRect(fromAppKit: window.frame))
        model.dayflowImage = picture
      }
    }
    await genieCard(into: await boxSearch.value, agent: agent, pid: pid, fallbackFrame: agentWindow.frame)
  }

  /// Card opens into app:
  ///   0.0   the card rises and straightens while Dayflow takes a picture of the app (~0.1s)
  ///   ~0.1  the card grows into the app's window and fades into its picture (0.5s)
  ///   ~0.6  the real window comes forward under the picture, which goes; the box glows
  ///         as the prompt is pasted
  private static func zoom(
    _ card: DocketLiftedCard, agent: DailyBriefAgent, pid: pid_t, agentWindow: AgentWindow
  ) async {
    lift(card)
    let boxSearch = Task.detached { findMessageBox(pid: pid, within: 0.35) }
    guard let picture = await capture([agentWindow.id])[agentWindow.id] else {
      await genieCard(into: await boxSearch.value, agent: agent, pid: pid, fallbackFrame: agentWindow.frame)
      return
    }
    model.agentImage = picture
    model.agentFrame = local(agentWindow.frame)
    withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
      model.zoom = 1
      model.cardScale = 1
    }
    try? await Task.sleep(for: .seconds(0.5))
    await finishOnRealWindow(
      agent: agent, pid: pid, box: await boxSearch.value, windowFrame: agentWindow.frame)
  }

  /// Dayflow into Dock, app out. The card stays where the fingers left it, so it's in
  /// the picture.
  ///   0.0   Dayflow takes pictures of both windows and finds the Dock icon (~0.1s)
  ///   ~0.1  the picture replaces Dayflow and genies into the app's Dock icon (0.45s)
  ///   ~0.45 the app's picture genies out of the icon (0.45s), overlapping the first
  ///   ~0.9  the real window comes forward under its picture; the box glows as the
  ///         prompt is pasted. Dayflow stays hidden until the user comes back.
  private static func appGenie(
    agent: DailyBriefAgent, pid: pid_t, agentWindow: AgentWindow, screen: NSScreen
  ) async {
    let title = agent.displayName
    let dockSearch = Task.detached { dockIconFrame(title: title) }
    let boxSearch = Task.detached { findMessageBox(pid: pid, within: 0.35) }
    guard let pictures = await capturePictures(agentWindow: agentWindow) else {
      await finishOnRealWindow(
        agent: agent, pid: pid, box: await boxSearch.value, windowFrame: agentWindow.frame)
      return
    }
    model.dockFrame = local(await dockSearch.value ?? fallbackDockIcon(on: screen))
    model.dayflowImage = pictures.dayflow
    model.agentImage = pictures.agent
    model.agentGenie = 1
    model.showsAgent = false
    hideDayflow()

    withAnimation(.timingCurve(0.55, 0, 0.75, 0.9, duration: 0.45)) { model.dayflowGenie = 1 }
    try? await Task.sleep(for: .seconds(0.35))
    model.showsAgent = true
    withAnimation(.timingCurve(0.2, 0.55, 0.3, 1, duration: 0.45)) { model.agentGenie = 0 }
    try? await Task.sleep(for: .seconds(0.45))
    model.dayflowImage = nil
    await finishOnRealWindow(
      agent: agent, pid: pid, box: await boxSearch.value, windowFrame: agentWindow.frame)
  }

  /// Slide across. The card stays where the fingers left it, so it's in the picture.
  ///   0.0   Dayflow takes pictures of both windows (~0.1s)
  ///   ~0.1  the screen dims and Dayflow slides off to the left as the app slides in
  ///         from the right (0.5s)
  ///   ~0.6  the real window comes forward under its picture and the dimming lifts; the
  ///         box glows as the prompt is pasted. Dayflow stays hidden until the user
  ///         comes back.
  private static func slide(agent: DailyBriefAgent, pid: pid_t, agentWindow: AgentWindow) async {
    let boxSearch = Task.detached { findMessageBox(pid: pid, within: 0.35) }
    guard let pictures = await capturePictures(agentWindow: agentWindow) else {
      await finishOnRealWindow(
        agent: agent, pid: pid, box: await boxSearch.value, windowFrame: agentWindow.frame)
      return
    }
    model.dayflowImage = pictures.dayflow
    model.agentImage = pictures.agent
    hideDayflow()
    withAnimation(.easeOut(duration: 0.15)) { model.backdrop = 0.45 }
    withAnimation(.spring(response: 0.5, dampingFraction: 1)) { model.slide = 1 }
    try? await Task.sleep(for: .seconds(0.5))
    model.dayflowImage = nil
    await finishOnRealWindow(
      agent: agent, pid: pid, box: await boxSearch.value, windowFrame: agentWindow.frame)
  }

  /// Crab catches and throws, from the moment the fingers lift. The crab steps at 12
  /// frames a second (one frame is ~0.083s); the card's flight is smooth.
  ///   0.0   the crab rises out of the ground under the card and raises its claws (5 frames),
  ///         while Dayflow takes a picture of its window to cover the switch
  ///   ~0.33 the card snaps down onto the claws, shrinking to a third (3 frames)
  ///   ~0.58 the crab bobs with the card while the app comes forward under the picture,
  ///         which dissolves; this covers however long the app and its message box take
  ///   then  the crab crouches and looks back (3 frames), throws the card along an arc
  ///         into the message box (0.45s), winks and hops as the box glows and the prompt
  ///         is pasted, then vanishes in a puff of dust
  private static func crabCarry(
    _ card: DocketLiftedCard, agent: DailyBriefAgent, pid: pid_t, agentWindow: AgentWindow
  ) async {
    let boxSearch = Task.detached { findMessageBox(pid: pid, within: 0.35) }
    let start = local(card.frame)
    let ground = CGPoint(x: start.midX, y: min(start.maxY + 4, model.screenSize.height - 8))
    model.card = DocketTransitionModel.Card(item: card.item, isOpen: card.isOpen, frame: start)
    model.cardRect = start
    model.cardTilt = card.tilt
    model.crab = DocketCrab(move: .catching, start: Date(), ground: ground)

    let started = Date()
    if let window = dayflowWindow {
      let id = CGWindowID(window.windowNumber)
      if let picture = await capture([id])[id] {
        model.dayflowFrame = local(globalRect(fromAppKit: window.frame))
        model.dayflowImage = picture
      }
    }
    // Let the rise finish (the picture usually takes less time than that).
    let rise = DocketCrabArt.duration(of: .catching) - DocketCrabArt.frameTime
    let waited = Date().timeIntervalSince(started)
    if waited < rise { try? await Task.sleep(for: .seconds(rise - waited)) }

    // The card snaps onto the claws in three held steps, no easing.
    let heldWidth = min(start.width * 0.32, 110)
    let heldHeight = start.height * heldWidth / max(start.width, 1)
    let clawTop = DocketCrabSprite.clawTop(standingOn: ground)
    let held = CGRect(x: ground.x - heldWidth / 2, y: clawTop + 4 - heldHeight, width: heldWidth, height: heldHeight)
    for step in 1...3 {
      let amount = Double(step) / 3
      model.cardRect = CGRect(
        x: DocketMotion.mix(start.minX, held.minX, amount), y: DocketMotion.mix(start.minY, held.minY, amount),
        width: DocketMotion.mix(start.width, held.width, amount),
        height: DocketMotion.mix(start.height, held.height, amount))
      model.cardTilt = DocketMotion.mix(card.tilt, -4, amount)
      try? await Task.sleep(for: .seconds(DocketCrabArt.frameTime))
    }
    model.cardRidesCrab = true
    model.crab?.move = .holding
    model.crab?.start = Date()

    guard await bringForward(agent) else { return }
    withAnimation(.easeOut(duration: 0.2)) { model.dayflowOpacity = 0 }
    let box = await boxSearch.value
    let target = box?.frame ?? fallbackMessageBox(in: frontWindow(of: pid)?.frame ?? agentWindow.frame)
    let landing = local(target)
    try? await Task.sleep(for: .seconds(0.2))

    // Wind up: crouch and look back, pulling the card away from the box.
    let facesLeft = landing.midX < ground.x
    model.crab?.facesLeft = facesLeft
    model.crab?.move = .windingUp
    model.crab?.start = Date()
    model.cardRect = held.offsetBy(dx: facesLeft ? 10 : -10, dy: 0)
    try? await Task.sleep(for: .seconds(DocketCrabArt.duration(of: .windingUp)))

    // Throw: the card shrinks to fit inside the box as it flies in.
    let endWidth = min(heldWidth * 0.7, landing.width)
    let endHeight = heldHeight * endWidth / max(heldWidth, 1)
    model.cardRidesCrab = false
    model.cardRect = held
    model.throwTarget = CGRect(
      x: landing.midX - endWidth / 2, y: landing.midY - endHeight / 2, width: endWidth, height: endHeight)
    model.crab?.move = .throwing
    model.crab?.start = Date()
    withAnimation(.timingCurve(0.3, 0.1, 0.55, 1, duration: 0.45)) { model.throwProgress = 1 }
    try? await Task.sleep(for: .seconds(0.45))
    model.card = nil
    model.dayflowImage = nil

    // Cheer while the box glows, then go in a puff of dust.
    model.crab?.move = .cheering
    model.crab?.start = Date()
    let leave = Task { @MainActor in
      try? await Task.sleep(for: .seconds(DocketCrabArt.duration(of: .cheering)))
      model.crab?.move = .leaving
      model.crab?.start = Date()
    }
    await land(in: box, at: target)
    await leave.value
    let gone = DocketCrabArt.duration(of: .leaving) - Date().timeIntervalSince(model.crab?.start ?? Date())
    if gone > 0 { try? await Task.sleep(for: .seconds(gone)) }
    model.crab = nil
  }

  // MARK: Steps

  /// Puts the card in the overlay exactly where the deck had it, then lifts and straightens it.
  private static func lift(_ card: DocketLiftedCard) {
    model.card = DocketTransitionModel.Card(item: card.item, isOpen: card.isOpen, frame: local(card.frame))
    model.cardTilt = card.tilt
    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
      model.cardTilt = 0
      model.cardScale = 1.03
    }
  }

  /// Brings the app forward under the picture of Dayflow (when there is one), dissolves
  /// the picture, genies the card into the message box and pastes.
  private static func genieCard(
    into box: MessageBox?, agent: DailyBriefAgent, pid: pid_t, fallbackFrame: CGRect
  ) async {
    guard await bringForward(agent) else { return }
    withAnimation(.easeOut(duration: 0.2)) { model.dayflowOpacity = 0 }
    try? await Task.sleep(for: .seconds(0.1))

    let target = box?.frame ?? fallbackMessageBox(in: frontWindow(of: pid)?.frame ?? fallbackFrame)
    model.cardTarget = local(target)
    withAnimation(.easeOut(duration: 0.15)) { model.cardScale = 1 }
    withAnimation(.timingCurve(0.45, 0, 0.35, 1, duration: 0.5)) { model.cardGenie = 1 }
    try? await Task.sleep(for: .seconds(0.5))
    model.card = nil
    model.dayflowImage = nil
    await land(in: box, at: target)
  }

  /// The picture of the app now covers its real window: bring the real one forward
  /// underneath, drop the pictures, and paste.
  private static func finishOnRealWindow(
    agent: DailyBriefAgent, pid: pid_t, box: MessageBox?, windowFrame: CGRect
  ) async {
    guard await bringForward(agent) else { return }
    try? await Task.sleep(for: .milliseconds(60))
    model.agentImage = nil
    model.dayflowImage = nil
    model.card = nil
    withAnimation(.easeOut(duration: 0.15)) { model.backdrop = 0 }
    await land(in: box, at: box?.frame ?? fallbackMessageBox(in: windowFrame))
  }

  /// Takes pictures of Dayflow and the app, and notes where both windows are.
  private static func capturePictures(agentWindow: AgentWindow) async -> (dayflow: CGImage, agent: CGImage)? {
    guard let window = dayflowWindow else { return nil }
    let dayflowID = CGWindowID(window.windowNumber)
    let pictures = await capture([dayflowID, agentWindow.id])
    guard let dayflow = pictures[dayflowID], let agent = pictures[agentWindow.id] else { return nil }
    model.dayflowFrame = local(globalRect(fromAppKit: window.frame))
    model.agentFrame = local(agentWindow.frame)
    return (dayflow, agent)
  }

  // MARK: Paste

  /// Pastes into the message box, which glows for a moment so the eye lands on it.
  /// The glow only shows when the real box was found, never on a guessed spot.
  private static func land(in box: MessageBox?, at target: CGRect) async {
    if box != nil {
      model.glowFrame = local(target)
      withAnimation(.easeOut(duration: 0.12)) { model.glow = 1 }
    }
    await pasteAndHint(into: box, at: target)
    withAnimation(.easeIn(duration: 0.35)) { model.glow = 0 }
    try? await Task.sleep(for: .seconds(0.35))
  }

  /// Focuses the message box and presses ⌘V. Without Accessibility access Dayflow can't,
  /// so it shows "Press ⌘V to paste" where the prompt should go.
  private static func pasteAndHint(into box: MessageBox?, at target: CGRect) async {
    if AXIsProcessTrusted() {
      if let box {
        AXUIElementSetAttributeValue(box.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(60))
      }
      DailyBriefHandoffRunner.pressCommandV()
      return
    }
    withAnimation(.easeOut(duration: 0.2)) { model.hintFrame = local(target) }
    try? await Task.sleep(for: .seconds(2.6))
    withAnimation(.easeOut(duration: 0.2)) { model.hintFrame = nil }
    try? await Task.sleep(for: .seconds(0.2))
  }

  /// Opens the app and waits (up to 3 seconds) until it's actually in front.
  private static func bringForward(_ agent: DailyBriefAgent) async -> Bool {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleIdentifier)
    else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    for _ in 0..<100 {
      if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == agent.bundleIdentifier { return true }
      try? await Task.sleep(for: .milliseconds(30))
    }
    return false
  }

  // MARK: Dayflow's window

  private static func hideDayflow() {
    dayflowWindow?.alphaValue = 0
    keepsDayflowHidden = true
  }

  /// Fades Dayflow back in when the user returns to it (Dock, ⌘Tab, a click).
  private static func watchForReturn() {
    guard !isWatchingForReturn else { return }
    isWatchingForReturn = true
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { showDayflowAgain() }
    }
  }

  private static func showDayflowAgain() {
    guard keepsDayflowHidden, !isRunning else { return }
    keepsDayflowHidden = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      dayflowWindow?.animator().alphaValue = 1
    }
  }

  // MARK: Overlay window

  private static func openOverlay(on screen: NSScreen, style: DocketTransitionStyle) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    overlayOrigin = globalRect(fromAppKit: screen.frame).origin
    model.reset(style: style, screenSize: screen.frame.size)
    panel.setFrame(screen.frame, display: true)
    panel.orderFrontRegardless()
  }

  private static func closeOverlay() {
    panel?.orderOut(nil)
    model.reset(style: .instant, screenSize: model.screenSize)
    isRunning = false
    runID += 1
    // The user may have come back to Dayflow while the transition was still running.
    if !keepsDayflowHidden || NSApp.isActive {
      keepsDayflowHidden = false
      dayflowWindow?.alphaValue = 1
    }
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // Above the app as it comes forward, never taking clicks or focus.
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let hosting = NSHostingView(rootView: DocketTransitionView(model: model))
    hosting.sizingOptions = []
    panel.contentView = hosting
    return panel
  }

  // MARK: Geometry

  /// A global top-left rectangle in the overlay's own coordinates.
  private static func local(_ rect: CGRect) -> CGRect {
    rect.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y)
  }

  /// AppKit's bottom-left screen rectangle as a global top-left one.
  static func globalRect(fromAppKit rect: NSRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  /// Roughly where a chat app's message box sits: low and centred in its window.
  private static func fallbackMessageBox(in window: CGRect) -> CGRect {
    CGRect(x: window.minX + window.width * 0.2, y: window.maxY - 120, width: window.width * 0.6, height: 64)
  }

  /// The middle of the screen's bottom edge, for when the Dock icon can't be found.
  private static func fallbackDockIcon(on screen: NSScreen) -> CGRect {
    let frame = globalRect(fromAppKit: screen.frame)
    return CGRect(x: frame.midX - 32, y: frame.maxY - 72, width: 64, height: 64)
  }

  // MARK: Windows

  struct AgentWindow {
    let id: CGWindowID
    /// Global, top-left origin.
    let frame: CGRect
  }

  private static func runningApp(_ agent: DailyBriefAgent) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: agent.bundleIdentifier).first
  }

  /// The app's frontmost normal window on the current desktop. The window list runs
  /// front to back, so the first match is the one the user last used.
  private static func frontWindow(of pid: pid_t) -> AgentWindow? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return nil
    }
    for info in list {
      guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
        (info[kCGWindowLayer as String] as? Int) == 0,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        frame.width > 200, frame.height > 200,
        let number = info[kCGWindowNumber as String] as? NSNumber
      else { continue }
      return AgentWindow(id: number.uint32Value, frame: frame)
    }
    return nil
  }

  /// Pictures of windows, without their shadows, at the screen's full resolution.
  /// Windows that can't be captured are left out.
  private static func capture(_ ids: [CGWindowID]) async -> [CGWindowID: CGImage] {
    guard
      let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    else { return [:] }
    let scale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    var pictures: [CGWindowID: CGImage] = [:]
    for id in ids {
      guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
      let configuration = SCStreamConfiguration()
      configuration.width = Int(window.frame.width * scale)
      configuration.height = Int(window.frame.height * scale)
      configuration.showsCursor = false
      configuration.ignoreShadowsSingleWindow = true
      pictures[id] = try? await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    }
    return pictures
  }

  // MARK: Accessibility

  struct MessageBox: @unchecked Sendable {
    let element: AXUIElement
    /// Global, top-left origin.
    let frame: CGRect
  }

  /// Claude's desktop app is Electron, which only builds its page's accessibility tree
  /// once someone asks for it, so ask as early as possible.
  nonisolated private static func prepareAccessibility(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  }

  /// The app's message box: the lowest wide text area in its focused window. Gives up
  /// after `seconds` so the animation never waits on a slow app.
  nonisolated private static func findMessageBox(pid: pid_t, within seconds: Double) -> MessageBox? {
    let deadline = Date().addingTimeInterval(seconds)
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
    else { return nil }

    var queue = [window]
    var index = 0
    var best: MessageBox?
    while index < queue.count && index < 4000 && Date() < deadline {
      let current = queue[index]
      index += 1
      let role = string(current, kAXRoleAttribute)
      if role == kAXTextAreaRole, let frame = frame(of: current), frame.width >= 160 {
        if best == nil || frame.maxY > best!.frame.maxY {
          best = MessageBox(element: current, frame: frame)
        }
        continue
      }
      queue.append(contentsOf: children(of: current))
    }
    return best
  }

  /// The Dock icon whose title matches, like "Claude".
  nonisolated private static func dockIconFrame(title: String) -> CGRect? {
    guard
      let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return nil }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    for list in children(of: app) where string(list, kAXRoleAttribute) == kAXListRole {
      for item in children(of: list) where string(item, kAXTitleAttribute) == title {
        return frame(of: item)
      }
    }
    return nil
  }

  nonisolated private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  nonisolated private static func string(_ element: AXUIElement, _ name: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? String
  }

  nonisolated private static func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
    else { return [] }
    return (value as? [AXUIElement]) ?? []
  }

  nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
      let positionValue, let sizeValue
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
  }
}

// MARK: - Model

/// What the overlay draws right now. Rectangles are in the overlay's coordinates.
@MainActor
final class DocketTransitionModel: ObservableObject {
  struct Card {
    let item: DailyBriefDocketItem
    let isOpen: Bool
    let frame: CGRect
  }

  @Published var style: DocketTransitionStyle = .instant
  @Published var screenSize: CGSize = .zero

  // The card (cardGenie, zoom)
  @Published var card: Card?
  @Published var cardTilt: Double = 0
  /// Grows a little as the card is picked up.
  @Published var cardScale: Double = 1
  @Published var cardTarget: CGRect = .zero
  /// 0 is the card as it was, 1 is fully inside the message box.
  @Published var cardGenie: Double = 0
  /// 0 is the card, 1 is the app's window.
  @Published var zoom: Double = 0

  // The crab (crab). The card is drawn at `cardRect`, which moves in held steps until
  // the throw, then flies smoothly to `throwTarget` as `throwProgress` runs to 1.
  @Published var crab: DocketCrab?
  @Published var cardRect: CGRect = .zero
  /// While held, the card bobs with the crab.
  @Published var cardRidesCrab = false
  @Published var throwTarget: CGRect = .zero
  @Published var throwProgress: Double = 0

  // Window pictures
  @Published var dayflowImage: CGImage?
  @Published var dayflowFrame: CGRect = .zero
  /// cardGenie dissolves Dayflow's picture to reveal the app underneath.
  @Published var dayflowOpacity: Double = 1
  @Published var agentImage: CGImage?
  @Published var agentFrame: CGRect = .zero
  @Published var showsAgent = true
  @Published var dockFrame: CGRect = .zero
  /// 0 is Dayflow's window, 1 is inside the Dock icon.
  @Published var dayflowGenie: Double = 0
  /// 1 is inside the Dock icon, 0 is the app's window.
  @Published var agentGenie: Double = 0
  /// 0 shows Dayflow in place, 1 shows the app in place.
  @Published var slide: Double = 0
  @Published var backdrop: Double = 0

  /// The message box's glow as the prompt lands.
  @Published var glowFrame: CGRect?
  @Published var glow: Double = 0
  /// Where to say "Press ⌘V to paste", when Dayflow can't paste itself.
  @Published var hintFrame: CGRect?

  func reset(style: DocketTransitionStyle, screenSize: CGSize) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      self.style = style
      self.screenSize = screenSize
      card = nil
      cardTilt = 0
      cardScale = 1
      cardTarget = .zero
      cardGenie = 0
      zoom = 0
      crab = nil
      cardRect = .zero
      cardRidesCrab = false
      throwTarget = .zero
      throwProgress = 0
      dayflowImage = nil
      dayflowOpacity = 1
      agentImage = nil
      showsAgent = true
      dayflowGenie = 0
      agentGenie = 0
      slide = 0
      backdrop = 0
      glowFrame = nil
      glow = 0
      hintFrame = nil
    }
  }
}

// MARK: - Overlay view

private struct DocketTransitionView: View {
  @ObservedObject var model: DocketTransitionModel

  var body: some View {
    let size = model.screenSize
    ZStack(alignment: .topLeading) {
      Color.black.opacity(model.backdrop)

      if let image = model.dayflowImage {
        switch model.style {
        case .appGenie:
          placed(picture(image), in: model.dayflowFrame)
            .modifier(DocketGenieEffect(
              progress: model.dayflowGenie, source: model.dayflowFrame, target: model.dockFrame,
              size: size))
        case .slide:
          placed(picture(image), in: model.dayflowFrame.offsetBy(dx: -model.slide * size.width, dy: 0))
        default:
          // Covers the switch, then dissolves to show the app underneath.
          placed(picture(image), in: model.dayflowFrame)
            .opacity(model.dayflowOpacity)
        }
      }

      if let image = model.agentImage, model.showsAgent {
        switch model.style {
        case .appGenie:
          placed(picture(image), in: model.agentFrame)
            .modifier(DocketGenieEffect(
              progress: model.agentGenie, source: model.agentFrame, target: model.dockFrame,
              size: size))
        case .slide:
          placed(picture(image), in: model.agentFrame.offsetBy(dx: (1 - model.slide) * size.width, dy: 0))
        default:
          EmptyView()
        }
      }

      if model.style == .crab {
        crabLayer
      } else if let card = model.card {
        if model.style == .zoom {
          DocketZoomLayer(
            progress: model.zoom, from: card.frame, to: model.agentFrame, screenSize: size,
            card: AnyView(liftedCardView(card)),
            picture: model.agentImage)
        } else {
          placed(liftedCardView(card), in: card.frame)
            .modifier(DocketGenieEffect(
              progress: model.cardGenie, source: card.frame, target: model.cardTarget,
              size: size))
        }
      }

      if let glow = model.glowFrame {
        let color = Color(hex: "A6CBFF")
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(color, lineWidth: 2)
          .shadow(color: color.opacity(0.9), radius: 10)
          .frame(width: glow.width + 8, height: glow.height + 8)
          .position(x: glow.midX, y: glow.midY)
          .opacity(model.glow)
      }

      if let hint = model.hintFrame {
        Text("Press ⌘V to paste")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white)
          .padding(.horizontal, 14)
          .frame(height: 32)
          .background(Capsule().fill(Color.black.opacity(0.78)))
          .position(x: hint.midX, y: hint.midY)
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .dayflowTheme(.light)
    .allowsHitTesting(false)
  }

  /// A full-screen layer with `view` sized and placed at `frame`, so effects that move
  /// pixels across the screen have room to work.
  private func placed<V: View>(_ view: V, in frame: CGRect) -> some View {
    view
      .frame(width: frame.width, height: frame.height)
      .position(x: frame.midX, y: frame.midY)
      .frame(width: model.screenSize.width, height: model.screenSize.height)
  }

  /// The crab, stepped at 12 frames a second, with the card resting on its claws until
  /// it's thrown. The crab is in front, so it pops up over the card's edge and its claws
  /// grip the held card's corners.
  private var crabLayer: some View {
    TimelineView(.animation(minimumInterval: DocketCrabArt.frameTime)) { timeline in
      ZStack(alignment: .topLeading) {
        if let card = model.card {
          let bob = model.cardRidesCrab ? CGFloat(model.crab?.frame(at: timeline.date).dy ?? 0) : 0
          DocketThrownCard(
            progress: model.throwProgress,
            from: model.cardRect.offsetBy(dx: 0, dy: bob * DocketCrabArt.pixel),
            to: model.throwTarget, tilt: model.cardTilt, base: card.frame.size,
            screenSize: model.screenSize, card: cardView(card))
        }
        if let crab = model.crab {
          placed(
            DocketCrabSprite(frame: crab.frame(at: timeline.date), facesLeft: crab.facesLeft),
            in: DocketCrabSprite.box(standingOn: crab.ground))
        }
      }
    }
  }

  private func picture(_ image: CGImage) -> some View {
    Image(decorative: image, scale: 1).resizable()
  }

  private func liftedCardView(_ card: DocketTransitionModel.Card) -> some View {
    cardView(card)
      .scaleEffect(model.cardScale)
      .rotationEffect(.degrees(model.cardTilt))
  }

  /// The card as the deck drew it at the moment of the hand-off, "HAND OFF" veil included.
  private func cardView(_ card: DocketTransitionModel.Card) -> some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    return DocketCardShell(fill: DocketColors.cardFront, isFront: true) {
      DocketCardContent(
        item: card.item, isOpen: card.isOpen, revealStart: nil, panel: .constant(nil),
        promptScroll: .constant(0), promptContentHeight: .constant(0),
        isEditingPrompt: .constant(false), togglePrompt: {})
    }
    .overlay(DocketSwipeVeil(direction: 1))
    .overlay(shape.strokeBorder(Color.white, lineWidth: 1))
    .background(shape.fill(Color.clear).shadow(color: Color.black.opacity(0.1), radius: 8, y: 4))
  }
}

/// The macOS "Genie" minimize, on a full-screen layer, in plain SwiftUI: the picture at
/// `source` is cut into horizontal strips, and each strip is squeezed and moved along a
/// funnel that narrows to `target`. Two overlapping phases, like the Dock's:
///   1. the bottom heads for the target while the sides bend in to the target's width
///   2. the top slides down the funnel, squeezing the picture into the target
/// Fades out over the last 12%, once the picture is inside the target.
private struct DocketGenieEffect: ViewModifier, Animatable {
  var progress: Double
  let source: CGRect
  let target: CGRect
  /// The layer's size, for flipping and for each strip's scaling anchor.
  let size: CGSize

  private static let strips = 20

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if progress <= 0.001 {
      content
    } else {
      ZStack(alignment: .topLeading) {
        ForEach(0..<Self.strips, id: \.self) { index in
          strip(content, index: index)
        }
      }
      .opacity(progress > 0.88 ? max(0, (1 - progress) / 0.12) : 1)
    }
  }

  /// One strip: the content cut down to the strip, then scaled and moved into place.
  private func strip(_ content: Content, index: Int) -> some View {
    let (from, to) = rects(for: index)
    return content
      .mask {
        Rectangle()
          .frame(width: from.width, height: from.height)
          .position(x: from.midX, y: from.midY)
      }
      .scaleEffect(
        x: to.width / from.width, y: to.height / from.height,
        anchor: UnitPoint(x: from.minX / size.width, y: from.minY / size.height))
      .offset(x: to.minX - from.minX, y: to.minY - from.minY)
  }

  /// Where strip `index` is in the picture, and where it goes on screen right now.
  private func rects(for index: Int) -> (from: CGRect, to: CGRect) {
    // The math pours downward; when the target is above, work upside down.
    let flip = target.midY < source.midY
    let from = flip ? flipped(source) : source
    let to = flip ? flipped(target) : target

    let bend = smooth((progress / 0.6).clamped01)
    let slide = smooth(((progress - 0.35) / 0.65).clamped01)
    let top = DocketMotion.mix(from.minY, to.minY, slide)
    let bottom = DocketMotion.mix(from.maxY, to.maxY, bend)

    let v0 = Double(index) / Double(Self.strips)
    let v1 = Double(index + 1) / Double(Self.strips)
    let y0 = top + v0 * (bottom - top)
    let y1 = top + v1 * (bottom - top)

    // How far down the funnel the strip is: 0 at the picture's top, 1 at the target's top.
    let span = max(Double(to.minY - from.minY), 1)
    let along = smooth((((y0 + y1) / 2 - Double(from.minY)) / span).clamped01) * bend
    let left = DocketMotion.mix(from.minX, to.minX, along)
    let right = DocketMotion.mix(from.maxX, to.maxX, along)

    // Each strip reaches 1pt into the next, so no hairline gaps show between them.
    let stripHeight = (v1 - v0) * Double(from.height)
    let stretch = (y1 - y0) / stripHeight
    var piece = CGRect(x: from.minX, y: Double(from.minY) + v0 * Double(from.height), width: from.width, height: stripHeight + 1)
    var place = CGRect(x: left, y: y0, width: max(right - left, 0.01), height: max((y1 - y0) + stretch, 0.01))
    if flip {
      piece = flipped(piece)
      place = flipped(place)
    }
    return (piece, place)
  }

  private func flipped(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
  }

  private func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

private extension Double {
  var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

/// The card growing into the app's window: its frame moves from the card's to the
/// window's while the card fades into the window's picture.
private struct DocketZoomLayer: View, Animatable {
  var progress: Double
  let from: CGRect
  let to: CGRect
  let screenSize: CGSize
  let card: AnyView
  let picture: CGImage?

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let p = progress
    let frame = CGRect(
      x: DocketMotion.mix(from.minX, to.minX, p), y: DocketMotion.mix(from.minY, to.minY, p),
      width: DocketMotion.mix(from.width, to.width, p), height: DocketMotion.mix(from.height, to.height, p))
    let crossfade = min(p * 1.8, 1)
    ZStack {
      card
        .frame(width: from.width, height: from.height)
        .scaleEffect(x: frame.width / from.width, y: frame.height / from.height)
        .opacity(1 - crossfade)
      if let picture {
        Image(decorative: picture, scale: 1)
          .resizable()
          .opacity(crossfade)
      }
    }
    .frame(width: frame.width, height: frame.height)
    .clipShape(RoundedRectangle(cornerRadius: DocketMotion.mix(7, 10, p), style: .continuous))
    .shadow(color: Color.black.opacity(0.18 * (1 - p)), radius: 16, y: 8)
    .position(x: frame.midX, y: frame.midY)
    .frame(width: screenSize.width, height: screenSize.height)
  }
}
