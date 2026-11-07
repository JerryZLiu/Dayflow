//
//  DocketDeckView.swift
//  Dayflow
//
//  "Take these off your plate": today's docket tasks as a stack of cards. The front card
//  can be swiped (drag, or a two-finger trackpad swipe) left to dismiss or right to hand
//  off to an agent; scrolling down over it opens its prompt. ← and → browse without acting.
//  Under the cards: Dismiss and Hand off, then Undo, the Card/List toggle and the gear.
//  When every task is done, a summary card takes the stack's place.
//
//  Sizes and timings are the prototype's (Centered · glow), in points.
//

import AppKit
import SwiftUI

struct DocketDeckView: View {
  /// Height of the visible page, for centring the card when its prompt opens.
  let viewportHeight: CGFloat
  /// Where the deck's top sits on the page, for the same reason.
  let deckTop: CGFloat

  @ObservedObject private var store = DailyBriefStore.shared
  @ObservedObject private var ui = DocketUIState.shared

  /// A card flying off (a throw) or back on (undo).
  private struct Flight: Equatable {
    /// -1 is left (dismiss), +1 is right (hand off).
    var direction: CGFloat
    var isLeaving: Bool
    /// Set when the hand-off transition takes over the card: it stays where it was
    /// dragged to instead of flying off.
    var heldX: CGFloat?
    /// A held card stays visible when the transition photographs the whole window;
    /// otherwise it vanishes because the overlay draws it from there.
    var staysVisible = false
  }

  /// How far the user has browsed into the stack with ← and →.
  @State private var index = 0
  @State private var flights: [String: Flight] = [:]
  @State private var dragX: CGFloat = 0
  @State private var panel: DocketPanel?
  @State private var promptScroll: CGFloat = 0
  @State private var promptContentHeight: CGFloat = 0
  @State private var isEditingPrompt = false
  @State private var revealStart: Date?
  /// The task Undo would bring back; Undo is enabled only right after a dismiss.
  @State private var undoTitle: String?
  @State private var scanStart: Date?
  @State private var hasEntered = false
  @State private var viewSwitchCount = 0

  // Wheel handling
  /// Kept in a class so the many wheel events a scroll sends don't each redraw the deck.
  @State private var wheel = DocketWheelState()

  static let width: CGFloat = 676
  static let cardHeight: CGFloat = 398
  static let openWidth: CGFloat = 790
  static let openHeight: CGFloat = 480
  static let buttonGap: CGFloat = 18
  static let buttonHeight: CGFloat = 62
  /// Card, gap and buttons: the deck's height before the foot row.
  static let height: CGFloat = cardHeight + buttonGap + buttonHeight
  static let footHeight: CGFloat = 16 + 39
  private static let swipeThreshold: CGFloat = 100
  private static let wheelStep: CGFloat = 90

  // MARK: Derived

  /// Tasks still in the stack, plus any card mid-throw.
  private var stackItems: [DailyBriefDocketItem] {
    store.docketItems.filter {
      !store.isDocketDone($0.title) || flights[$0.title]?.isLeaving == true
    }
  }

  /// Tasks the stack is laid out from: everything not flying away.
  private var settledItems: [DailyBriefDocketItem] {
    stackItems.filter { flights[$0.title]?.isLeaving != true }
  }

  private var frontItem: DailyBriefDocketItem? {
    let settled = settledItems
    return settled.indices.contains(index) ? settled[index] : nil
  }

  private var isOpen: Bool { ui.isPromptOpen && frontItem != nil && !store.docketShowsList }

  private var showsSummary: Bool {
    settledItems.isEmpty && flights.values.allSatisfy { !$0.isLeaving }
  }

  private var reviewedCount: Int {
    store.docketItems.filter { store.isDocketDone($0.title) }.count
  }

  /// Lift so the open card (and its buttons) sit centred in the window.
  private var openLift: CGFloat {
    let openTop = max(
      24, (viewportHeight - (Self.openHeight + Self.buttonGap + Self.buttonHeight)) / 2)
    return min(0, openTop - deckTop)
  }

  // MARK: Body

  var body: some View {
    VStack(spacing: 0) {
      if store.docketShowsList {
        DocketListView()
          .frame(width: 902)
          .padding(.top, -12.2)
          .transition(
            .asymmetric(
              insertion: .modifier(
                active: DocketBoxIn(isIn: false), identity: DocketBoxIn(isIn: true)),
              removal: .identity)
          )
          .id("list-\(viewSwitchCount)")
      } else {
        cardArea
          .frame(
            width: Self.width, height: showsSummary ? 400 : Self.height, alignment: .topLeading
          )
          .background(
            DocketEventMonitor(
              onWheel: handleWheel, onArrow: handleArrow, isWheelEnabled: !showsSummary,
              wheel: wheel)
          )
          .offset(y: isOpen ? openLift : 0)
      }

      footRow
        .padding(.top, 16)
        .opacity(isOpen ? 0 : 1)
        .animation(.easeOut(duration: 0.26), value: isOpen)
        .modifier(DocketEntranceFade(hasEntered: hasEntered, delay: 1.15))
    }
    .frame(width: Self.width)
    .onAppear(perform: startEntrance)
    .onChange(of: store.docketItems.map(\.title)) { clampIndex() }
    .onChange(of: settledItems.count) { clampIndex() }
  }

  // MARK: Cards

  private var cardArea: some View {
    ZStack(alignment: .topLeading) {
      if showsSummary {
        DocketSummaryCard(count: reviewedCount)
          .frame(width: Self.width, height: 400)
          .transition(
            .asymmetric(
              insertion: .modifier(
                active: DocketSummaryIn(isIn: false), identity: DocketSummaryIn(isIn: true)),
              removal: .opacity))
      } else {
        ForEach(Array(stackItems.enumerated()), id: \.element.title) { _, item in
          if let position = position(of: item), position >= -1, position <= 3 {
            card(item, position: position)
          }
        }

        buttonRow
          .offset(y: (isOpen ? Self.openHeight : Self.cardHeight) + Self.buttonGap)
          .modifier(DocketEntranceFade(hasEntered: hasEntered, delay: 1.15))
      }
    }
    .animation(DocketMotion.ease(0.46), value: showsSummary)
  }

  /// The card's place in the stack: 0 is front, 1 and 2 peek behind, -1 was browsed past.
  /// A card mid-throw keeps the front's place.
  private func position(of item: DailyBriefDocketItem) -> Int? {
    if flights[item.title]?.isLeaving == true { return 0 }
    guard let settledIndex = settledItems.firstIndex(where: { $0.title == item.title }) else {
      return nil
    }
    return settledIndex - index
  }

  private struct Slot {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var fill: Color
    var opacity: Double
  }

  private func slot(_ position: Int) -> Slot {
    switch position {
    case ..<0:
      return Slot(
        x: 0, y: -28, width: Self.width, height: Self.cardHeight, fill: DocketColors.cardFront,
        opacity: 0)
    case 0:
      return isOpen
        ? Slot(
          x: -57, y: 0, width: Self.openWidth, height: Self.openHeight,
          fill: DocketColors.cardFront, opacity: 1)
        : Slot(
          x: 0, y: 0, width: Self.width, height: Self.cardHeight, fill: DocketColors.cardFront,
          opacity: 1)
    // The cards behind are full height, so dragging the front card aside uncovers a whole
    // card; at rest only their top edges show.
    case 1:
      return Slot(
        x: 11.94, y: -10.15, width: 651, height: Self.cardHeight, fill: DocketColors.cardSecond,
        opacity: isOpen ? 0 : 1)
    case 2:
      return Slot(
        x: 25.94, y: -20.15, width: 624, height: Self.cardHeight, fill: DocketColors.cardThird,
        opacity: isOpen ? 0 : 1)
    default:
      return Slot(
        x: 25.94, y: -20.15, width: 624, height: Self.cardHeight, fill: DocketColors.cardThird,
        opacity: 0)
    }
  }

  @ViewBuilder
  private func card(_ item: DailyBriefDocketItem, position: Int) -> some View {
    let slot = slot(position)
    let flight = flights[item.title]
    let isFront = position == 0 && flight?.isLeaving != true
    let isDragged = isFront && dragX != 0
    // A throw ends 240pt to the side, 8pt up, tilted 5°.
    let throwX = (flight?.direction ?? 0) * 240
    let moveX = flight?.heldX ?? (flight != nil ? throwX : (isFront ? dragX : 0))
    let lift = -8 * abs(moveX) / 240
    let tilt = 5 * moveX / 240
    let veilSide: CGFloat = flight?.direction ?? (dragX < 0 ? -1 : 1)
    let veilStrength = flight != nil ? 1 : min(1, abs(dragX) / Self.swipeThreshold)

    // The next card shows its task as the front card is dragged off it.
    let previewOpacity = position == 1 ? min(1, abs(dragX) / 160) : 0

    DocketCardShell(fill: slot.fill, isFront: position == 0, previewOpacity: previewOpacity) {
      if position == 0 {
        DocketCardContent(
          item: item, isOpen: isOpen, revealStart: revealStart, panel: $panel,
          promptScroll: $promptScroll, promptContentHeight: $promptContentHeight,
          isEditingPrompt: $isEditingPrompt, togglePrompt: togglePrompt)
      } else if position == 1 {
        DocketCardContent(
          item: item, isOpen: false, revealStart: nil, panel: .constant(nil),
          promptScroll: .constant(0), promptContentHeight: .constant(0),
          isEditingPrompt: .constant(false), togglePrompt: {}
        )
        .allowsHitTesting(false)
      }
    }
    .modifier(DocketScanSurfaceIfFront(start: position == 0 ? scanStart : nil))
    .overlay {
      if position == 0 && (isDragged || flight != nil) {
        DocketSwipeVeil(direction: veilSide)
          .opacity(veilStrength)
          .animation(.easeOut(duration: 0.14), value: veilStrength)
      }
    }
    .frame(width: slot.width, height: slot.height)
    .opacity(slot.opacity)
    .scaleEffect(position < 0 ? 0.98 : 1)
    .offset(x: slot.x, y: slot.y)
    .animation(DocketMotion.ease(0.46), value: position)
    .opacity(flight?.isLeaving == true && flight?.staysVisible != true ? 0 : 1)
    .animation(flight?.heldX == nil ? .linear(duration: 0.18) : nil, value: flight?.isLeaving)
    .rotationEffect(.degrees(tilt), anchor: .center)
    .offset(x: moveX, y: lift)
    .zIndex(flight?.isLeaving == true ? 20 : Double(10 - max(position, -1)))
    .modifier(DocketCardEntrance(hasEntered: hasEntered, position: position))
    .gesture(isFront ? dragGesture : nil)
    .onTapGesture {
      // Clicking a card behind browses to the next one.
      if position > 0 { browse(by: 1) }
    }
    .allowsHitTesting(position >= 0)
  }

  // MARK: Buttons

  private var buttonRow: some View {
    HStack(alignment: .top, spacing: 8) {
      DocketActionButton(title: "Dismiss", hint: "Swipe left", arrowFirst: true) {
        act(direction: -1, eased: false)
      }
      .frame(width: 163)
      .help("Dismiss this task")

      DocketActionButton(title: "Hand off", hint: "Swipe right", arrowFirst: false) {
        act(direction: 1, eased: false)
      }
      .frame(width: 173)
      .help(handOffHelp)
    }
    .frame(width: Self.width, height: Self.buttonHeight)
    .disabled(frontItem == nil)
  }

  private var handOffHelp: String {
    let method = store.docketHandoffMethod == .paste ? "Paste the prompt" : "Run the prompt"
    return "Hand off to \(store.docketAgent.displayName): \(method)"
  }

  private var footRow: some View {
    ZStack(alignment: .topLeading) {
      if !store.docketShowsList {
        Button(action: undo) {
          Image("DocketUndo")
            .resizable()
            .frame(width: 20, height: 20)
            .brightness(-0.47)
            .opacity(undoTitle == nil ? 0.4 : 1)
            .animation(.easeOut(duration: 0.2), value: undoTitle)
            .frame(width: 36, height: 36)
            .docketRoundSkin()
            .contentShape(Circle())
        }
        .buttonStyle(DocketPressStyle())
        .disabled(undoTitle == nil)
        .help("Undo dismiss")
        .offset(x: 225.25, y: 1.75)
        .pointingHandCursor(enabled: undoTitle != nil)
      }

      HStack(spacing: 7) {
        DocketViewToggle(showsList: store.docketShowsList) { showList in
          switchView(toList: showList)
        }
        DocketGearButton()
      }
      .offset(x: store.docketShowsList ? 255.25 : 268.25)
    }
    .frame(width: Self.width, height: 39, alignment: .topLeading)
  }

  // MARK: Entrance

  private func startEntrance() {
    store.refreshDocketRuns()
    clampIndex()
    ui.isPromptOpen = false
    let start = Date()
    ui.entranceStart = start
    hasEntered = false
    scanStart = start.addingTimeInterval(1.2)
    DispatchQueue.main.async { hasEntered = true }
  }

  private func clampIndex() {
    let count = settledItems.count
    if count == 0 {
      index = 0
      if ui.isPromptOpen { ui.isPromptOpen = false }
    } else if index > count - 1 {
      index = count - 1
    }
  }

  // MARK: Actions

  private func togglePrompt() {
    setPromptOpen(!ui.isPromptOpen)
  }

  private func setPromptOpen(_ open: Bool) {
    guard frontItem != nil, open != ui.isPromptOpen else { return }
    isEditingPrompt = false
    promptScroll = 0
    if open {
      panel = nil
      revealStart = Date()
      ui.scrollToTopRequest += 1
      withAnimation(DocketMotion.ease(0.46)) { ui.isPromptOpen = true }
    } else {
      withAnimation(DocketMotion.collapse) { ui.isPromptOpen = false }
    }
  }

  /// Throws the front card left (dismiss) or right (hand off).
  /// `eased` is true when a drag let go, so the card decelerates instead of accelerating.
  private func act(direction: CGFloat, eased: Bool) {
    guard let item = frontItem else { return }
    let title = item.title
    let wasOpen = ui.isPromptOpen
    var heldX: CGFloat?
    var staysVisible = false
    let curve: Animation =
      eased
      ? .timingCurve(0.25, 0.6, 0.4, 1, duration: 0.3)
      : .timingCurve(0.5, 0, 0.75, 0.2, duration: 0.3)

    if direction < 0 {
      store.dismissDocket(title)
      undoTitle = title
      withAnimation(DocketMotion.ease(0.3)) { ui.askTitle = title }
    } else {
      let exit =
        store.docketHandoffMethod == .paste
        ? DocketHandoffDirector.cardExit(for: store.docketAgent) : .thrown
      store.handOffDocket(item, card: exit == .carried ? liftedCard(for: item) : nil)
      undoTitle = nil
      if exit != .thrown {
        heldX = dragX
        staysVisible = exit == .keptInPicture
      }
    }

    panel = nil
    isEditingPrompt = false
    promptScroll = 0
    if let heldX {
      // The transition takes the card from this spot: it either draws it (so hide this
      // one at once) or photographs the window with it still here.
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        flights[title] = Flight(
          direction: direction, isLeaving: true, heldX: heldX, staysVisible: staysVisible)
        dragX = 0
      }
    } else {
      withAnimation(curve) {
        flights[title] = Flight(direction: direction, isLeaving: true)
        dragX = 0
      }
    }
    // The next card comes in already open when the prompt was open.
    if wasOpen { revealStart = Date() }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { flights[title] = nil }
      clampIndex()
    }
  }

  /// The front card as it is on screen right now, when the hand-off transition will carry
  /// it; nil when the card should just be thrown.
  private func liftedCard(for item: DailyBriefDocketItem) -> DocketLiftedCard? {
    guard let view = wheel.hostView, let window = view.window else { return nil }
    // The deck's top-left corner on screen, then the card's slot plus the drag inside it.
    let deck = DocketHandoffDirector.globalRect(
      fromAppKit: window.convertToScreen(view.convert(view.bounds, to: nil)))
    let slot = slot(0)
    let lift = -8 * abs(dragX) / 240
    let frame = CGRect(
      x: deck.minX + slot.x + dragX, y: deck.minY + slot.y + lift, width: slot.width,
      height: slot.height)
    return DocketLiftedCard(item: item, isOpen: isOpen, frame: frame, tilt: Double(5 * dragX / 240))
  }

  private func undo() {
    guard let title = undoTitle else { return }
    undoTitle = nil
    withAnimation(DocketMotion.ease(0.3)) { ui.askTitle = nil }

    // Put the card back, start it where it was thrown, then bring it in.
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      flights[title] = Flight(direction: -1, isLeaving: false)
      store.undoDocketDismiss(title)
    }
    if let restored = settledItems.firstIndex(where: { $0.title == title }) {
      withAnimation(DocketMotion.ease(0.46)) { index = restored }
    }
    DispatchQueue.main.async {
      withAnimation(.timingCurve(0.22, 0.8, 0.24, 1, duration: 0.3)) { flights[title] = nil }
    }
  }

  private func browse(by step: Int) {
    let target = index + step
    guard target >= 0, target < settledItems.count else { return }
    panel = nil
    withAnimation(DocketMotion.ease(0.46)) { index = target }
  }

  private func switchView(toList: Bool) {
    guard toList != store.docketShowsList else { return }
    ui.isPromptOpen = false
    panel = nil
    viewSwitchCount += 1
    withAnimation(DocketMotion.ease(0.36)) { store.docketShowsList = toList }
    if !toList {
      // Coming back to the cards replays the Scan light, sooner than on entrance.
      scanStart = Date().addingTimeInterval(0.2)
    }
  }

  // MARK: Drag

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 6)
      .onChanged { value in
        guard !isEditingPrompt else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dragX = value.translation.width }
      }
      .onEnded { value in
        guard !isEditingPrompt else { return }
        let dx = value.translation.width
        if abs(dx) >= Self.swipeThreshold {
          act(direction: dx < 0 ? -1 : 1, eased: true)
        } else {
          withAnimation(DocketMotion.ease(0.46)) { dragX = 0 }
        }
      }
  }

  // MARK: Wheel and keys

  /// Handles a scroll over the cards. Returns true when the event was used (so the page
  /// doesn't scroll). `dx` and `dy` are finger movement: positive dy reads further down.
  private func handleWheel(dx: CGFloat, dy: CGFloat, phase: DocketWheelPhase) -> Bool {
    if isEditingPrompt { return false }
    if ui.openMenu != nil { ui.openMenu = nil }

    let now = Date()
    let quiet = now.timeIntervalSince(wheel.lastWheelAt)
    wheel.lastWheelAt = now
    if quiet > 0.38 {
      wheel.wheelLockedUntilQuiet = false
      wheel.wheelAccumulated = 0
    }
    if quiet > 0.16 {
      wheel.swipeLockedUntilQuiet = false
      wheel.swipeAccumulated = 0
    }

    // A sideways trackpad swipe: the card follows the fingers 1:1 and nothing happens
    // until they lift. Then it goes if it moved 100pt, or settles back. Coasting after a
    // flick never counts, so only real finger travel can throw a card.
    if phase.isCoasting && (wheel.swipeAccumulated != 0 || abs(dx) > abs(dy)) {
      return true
    }
    if phase.fingersLifted && wheel.swipeAccumulated != 0 {
      finishSwipe()
      return true
    }
    if abs(dx) > abs(dy) {
      guard !wheel.swipeLockedUntilQuiet, frontItem != nil else { return true }
      wheel.swipeAccumulated += dx
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { dragX = wheel.swipeAccumulated }
      // A mouse never reports lifted fingers, so decide once its scrolling stops.
      if !phase.hasFingers {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
          guard Date().timeIntervalSince(wheel.lastWheelAt) >= 0.16, wheel.swipeAccumulated != 0
          else { return }
          finishSwipe()
        }
      }
      return true
    }

    // With the prompt open, its text scrolls first.
    if ui.isPromptOpen {
      let maxScroll = max(0, promptContentHeight - 260)
      if dy > 0 || promptScroll > 0 {
        promptScroll = min(max(promptScroll + dy, 0), maxScroll)
        if dy > 0 || promptScroll > 0 { return true }
      }
    }

    // Scrolling up over a closed card scrolls the page, so the reader is never stuck.
    if !ui.isPromptOpen && dy < 0 {
      wheel.wheelAccumulated = 0
      return false
    }

    guard !wheel.wheelLockedUntilQuiet else { return true }
    wheel.wheelAccumulated += dy
    if wheel.wheelAccumulated >= Self.wheelStep, !ui.isPromptOpen {
      wheel.wheelLockedUntilQuiet = true
      setPromptOpen(true)
    } else if wheel.wheelAccumulated <= -Self.wheelStep, ui.isPromptOpen {
      wheel.wheelLockedUntilQuiet = true
      setPromptOpen(false)
    }
    return true
  }

  /// The fingers lifted (or a mouse stopped): throw the card if it went far enough.
  private func finishSwipe() {
    let total = wheel.swipeAccumulated
    wheel.swipeAccumulated = 0
    if abs(total) >= Self.swipeThreshold {
      wheel.swipeLockedUntilQuiet = true
      act(direction: total < 0 ? -1 : 1, eased: true)
    } else {
      withAnimation(DocketMotion.ease(0.46)) { dragX = 0 }
    }
  }

  /// ← and → browse the stack. Returns true when handled.
  private func handleArrow(_ step: Int) -> Bool {
    guard !store.docketShowsList, ui.askTitle == nil, !isEditingPrompt else { return false }
    if ui.isPromptOpen {
      setPromptOpen(false)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { browse(by: step) }
    } else {
      browse(by: step)
    }
    return true
  }
}

// MARK: - Card shell

/// A card: tinted fill with a white border and soft shadow. Its inside (fill and
/// content) is what the Scan light reveals; the border and shadow are always there.
struct DocketCardShell<Content: View>: View {
  let fill: Color
  let isFront: Bool
  /// How much of a card behind's content shows (while the front card is dragged).
  var previewOpacity: Double = 0
  @ViewBuilder let content: () -> Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    ZStack {
      shape.fill(fill)
      content()
        .opacity(isFront ? 1 : previewOpacity)
        .animation(.easeOut(duration: 0.3).delay(isFront ? 0.1 : 0), value: isFront)
    }
    .clipShape(shape)
    .animation(.easeOut(duration: 0.3), value: fill)
  }
}

/// Applies the Scan light to the inside only, then draws the border and shadow on top.
private struct DocketScanSurfaceIfFront: ViewModifier {
  let start: Date?

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    content
      .modifier(DocketScanSurface(start: start))
      .overlay(InnerGlow(shape: shape, color: Color.white.opacity(0.9), radius: 3))
      .overlay(shape.strokeBorder(Color.white, lineWidth: 1))
      .background(shape.fill(Color.clear).shadow(color: Color.black.opacity(0.06), radius: 5, y: 2))
  }
}

// MARK: - Veil

/// Covers the card while it's dragged: rose with "DISMISS" to the left, blue-green with
/// "HAND OFF" to the right.
struct DocketSwipeVeil: View {
  let direction: CGFloat

  var body: some View {
    let isDismiss = direction < 0
    let glow = isDismiss ? Color(red: 1, green: 0, blue: 0).opacity(0.25) : Color(hex: "A6CBFF")
    ZStack {
      Rectangle().fill(.ultraThinMaterial).opacity(0.5)
      LinearGradient(
        colors: isDismiss
          ? [
            Color(red: 222 / 255, green: 166 / 255, blue: 173 / 255).opacity(0.3),
            Color(red: 82 / 255, green: 70 / 255, blue: 69 / 255).opacity(0.3),
          ]
          : [
            Color(red: 209 / 255, green: 236 / 255, blue: 231 / 255).opacity(0.5),
            Color(red: 121 / 255, green: 142 / 255, blue: 208 / 255).opacity(0.5),
          ],
        startPoint: .top, endPoint: .bottom)
      VStack(spacing: 4) {
        Image(isDismiss ? "DocketVeilClose" : "DocketVeilSend")
          .resizable()
          .frame(width: 24, height: 24)
        Text(isDismiss ? "DISMISS" : "HAND OFF")
          .font(DailyBriefFonts.sans(18, weight: .semibold))
          .foregroundStyle(.white)
      }
      .shadow(color: glow, radius: 4, y: 2)
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .allowsHitTesting(false)
  }
}

// MARK: - Buttons

/// Dismiss or Hand off: the word over "← Swipe left" / "Swipe right →".
private struct DocketActionButton: View {
  let title: String
  let hint: String
  /// The arrow sits before the hint (left) or after it (right).
  let arrowFirst: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 0) {
        Text(title)
          .font(DailyBriefFonts.sans(16, weight: .medium))
          .foregroundStyle(DocketColors.ink)
          .frame(height: 20.8)
        HStack(spacing: 4) {
          if arrowFirst { arrow }
          Text(hint)
            .font(DailyBriefFonts.sans(12))
            .foregroundStyle(Color(hex: "777777"))
          if !arrowFirst { arrow.rotationEffect(.degrees(180)) }
        }
        .frame(height: 15.6)
      }
      .padding(.top, 12)
      .padding(.bottom, 10)
      .frame(maxWidth: .infinity)
      .frame(height: 62)
      .docketPillSkin()
      .docketHoverBrightness(isHovered)
      .contentShape(Capsule())
    }
    .buttonStyle(DocketPressStyle())
    .onHover { isHovered = $0 }
    .pointingHandCursor()
  }

  private var arrow: some View {
    Image("DocketSwipeArrow")
      .resizable()
      .frame(width: 12, height: 12)
  }
}

/// The Card / List capsule.
private struct DocketViewToggle: View {
  let showsList: Bool
  let select: (Bool) -> Void

  var body: some View {
    HStack(spacing: 0) {
      segment("Card", isOn: !showsList) { select(false) }
      segment("List", isOn: showsList) { select(true) }
    }
    .padding(1)
    .background(
      Capsule().fill(Color(red: 223 / 255, green: 223 / 255, blue: 223 / 255).opacity(0.3))
    )
    .overlay(Capsule().strokeBorder(DocketColors.roundBorder, lineWidth: 0.5))
  }

  private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(DailyBriefFonts.sans(16))
        .foregroundStyle(Color(hex: "606060"))
        .frame(width: 68, height: 36)
        .background {
          if isOn {
            Capsule()
              .fill(DocketColors.roundFill)
              .overlay(InnerGlow(shape: Capsule(), color: Color.white.opacity(0.7), radius: 4))
              .overlay(Capsule().strokeBorder(DocketColors.roundBorder, lineWidth: 0.75))
          }
        }
        .animation(.easeOut(duration: 0.2), value: isOn)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

/// The gear that opens the Providers / Hand-off method menu.
private struct DocketGearButton: View {
  @ObservedObject private var ui = DocketUIState.shared

  var body: some View {
    Button {
      ui.openMenu = ui.openMenu == .gear ? nil : .gear
    } label: {
      Image("DocketGear")
        .resizable()
        .frame(width: 20, height: 20)
        .brightness(-0.47)
        .rotationEffect(.degrees(ui.openMenu == .gear ? 60 : 0))
        .animation(DocketMotion.ease(0.3), value: ui.openMenu)
        .frame(width: 36, height: 36)
        .docketRoundSkin()
        .contentShape(Circle())
    }
    .buttonStyle(DocketPressStyle())
    .help("Hand-off settings")
    .pointingHandCursor()
    .anchorPreference(key: DocketAnchorKey.self, value: .bounds) { ["gear": $0] }
  }
}

// MARK: - Entrance and view-switch motion

/// Fades something in at `delay` seconds into the entrance (0.6s ease-out).
struct DocketEntranceFade: ViewModifier {
  let hasEntered: Bool
  let delay: Double

  func body(content: Content) -> some View {
    content
      .opacity(hasEntered ? 1 : 0)
      .animation(hasEntered ? .easeOut(duration: 0.6).delay(delay) : nil, value: hasEntered)
  }
}

/// The cards drop in: front from 24pt up at 0.65s, the others from 16pt at 0.75s and 0.85s.
/// Each is fully opaque by 45% of its move.
private struct DocketCardEntrance: ViewModifier {
  let hasEntered: Bool
  let position: Int

  func body(content: Content) -> some View {
    let delay = 0.65 + Double(max(min(position, 2), 0)) * 0.1
    let duration = position == 0 ? 1.0 : 0.9
    let rise: CGFloat = position == 0 ? -24 : -16
    content
      .opacity(hasEntered ? 1 : 0)
      .animation(
        hasEntered ? .easeOut(duration: duration * 0.45).delay(delay) : nil, value: hasEntered
      )
      .offset(y: hasEntered ? 0 : rise)
      .animation(hasEntered ? DocketMotion.enter(duration).delay(delay) : nil, value: hasEntered)
  }
}

/// The list box coming in: from transparent, 98.5% size and 6pt low.
private struct DocketBoxIn: ViewModifier {
  let isIn: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isIn ? 1 : 0)
      .scaleEffect(isIn ? 1 : 0.985)
      .offset(y: isIn ? 0 : 6)
  }
}

/// The summary card coming in: from 96% size, 14pt below the second card's place.
private struct DocketSummaryIn: ViewModifier {
  let isIn: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isIn ? 1 : 0)
      .scaleEffect(isIn ? 1 : 0.96)
      .offset(y: isIn ? 0 : 4)
  }
}

// MARK: - Event monitor

/// Catches trackpad and mouse-wheel scrolls over the cards (so they open the prompt or
/// swipe instead of scrolling the page) and ← / → in the brief's window.
/// Running totals for wheel and trackpad scrolls over the deck.
private final class DocketWheelState {
  /// The view behind the cards, so a hand-off can find the card's place on screen.
  weak var hostView: NSView?
  var wheelAccumulated: CGFloat = 0
  var swipeAccumulated: CGFloat = 0
  var wheelLockedUntilQuiet = false
  var swipeLockedUntilQuiet = false
  var lastWheelAt = Date.distantPast
}

/// Where a trackpad scroll is: fingers down, just lifted, or coasting after a flick.
/// A mouse wheel has no fingers, so it's never lifted or coasting.
private struct DocketWheelPhase {
  var hasFingers: Bool
  var isCoasting: Bool
  var fingersLifted: Bool
}

private struct DocketEventMonitor: NSViewRepresentable {
  let onWheel: @MainActor (_ dx: CGFloat, _ dy: CGFloat, _ phase: DocketWheelPhase) -> Bool
  let onArrow: @MainActor (_ step: Int) -> Bool
  let isWheelEnabled: Bool
  let wheel: DocketWheelState

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    wheel.hostView = view
    context.coordinator.parent = self
    context.coordinator.start(hostView: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.parent = self
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    var parent: DocketEventMonitor?
    private weak var hostView: NSView?
    private var monitors: [Any] = []

    func start(hostView: NSView) {
      self.hostView = hostView
      let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        let handled = MainActor.assumeIsolated { self?.handleWheel(event) ?? false }
        return handled ? nil : event
      }
      let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
        return handled ? nil : event
      }
      monitors = [wheel, keys].compactMap { $0 }
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
      guard let parent, parent.isWheelEnabled, let view = hostView, let window = view.window,
        event.window === window
      else { return false }
      let point = view.convert(event.locationInWindow, from: nil)
      // The cards area, plus room for the wider open card on each side.
      guard view.bounds.insetBy(dx: -57, dy: 0).contains(point) else { return false }

      // dy > 0 reads further down the page, whatever the scroll direction setting.
      // dx is how far the fingers moved right, so the card always follows them: without
      // natural scrolling, macOS reports sideways deltas the other way round.
      let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
      let fingerX =
        event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
      let dx = fingerX * scale
      let dy = -event.scrollingDeltaY * scale
      let phase = DocketWheelPhase(
        hasFingers: event.phase != [] || event.momentumPhase != [],
        isCoasting: event.momentumPhase != [],
        fingersLifted: event.phase == .ended || event.phase == .cancelled)
      return parent.onWheel(dx, dy, phase)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
      guard let parent, let window = hostView?.window, event.window === window,
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
        !(window.firstResponder is NSTextView)
      else { return false }
      switch event.keyCode {
      case 123: return parent.onArrow(-1)  // ←
      case 124: return parent.onArrow(1)  // →
      default: return false
      }
    }

    func stop() {
      monitors.forEach(NSEvent.removeMonitor)
      monitors = []
    }
  }
}
