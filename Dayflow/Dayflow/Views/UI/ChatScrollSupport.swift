//
//  ChatScrollSupport.swift
//  Dayflow
//
//  Scroll engineering for the chat transcript, ported from shadcn's
//  message-scroller primitive (github.com/shadcn-ui/ui, @shadcn/react).
//
//  Core rule: never move the reader against their intent.
//  - A new user turn anchors near the top of the viewport, with a peek of the
//    previous turn above it. A tail spacer below makes that position reachable,
//    so the streaming reply grows into the empty space without any scrolling.
//  - Auto-follow engages only when the reader is already at the live edge, and
//    releases on any deliberate scroll gesture (wheel, scrollbar drag).
//  - A jump-to-latest pill appears whenever real content is hidden below.
//

import AppKit
import SwiftUI

// MARK: - Scroll model

@MainActor
final class ChatScrollModel: ObservableObject {

  enum Mode {
    case followingBottom  // pinned to the live edge; new content keeps the view at the end
    case freeScrolling  // reader scrolled away; leave them alone
    case settlingJump  // a programmatic jump is animating; ignore transient geometry
  }

  // Tuning constants from shadcn's message-scroller.
  static let scrollEdgeThreshold: CGFloat = 8  // distance that still counts as "at the edge"
  static let previousTurnPeek: CGFloat = 64  // previous turn kept visible above an anchored turn
  private static let settleDelay: TimeInterval = 0.35  // how long a programmatic scroll may animate

  /// True when real content (excluding the tail spacer) is hidden below the viewport.
  @Published private(set) var showJumpToLatest = false

  /// Blank space after the last message so a new turn can anchor near the top
  /// while its reply streams into the space below it.
  @Published private(set) var tailSpacerHeight: CGFloat = 0

  private(set) var mode: Mode = .followingBottom

  private var viewportHeight: CGFloat = 0
  private var contentHeight: CGFloat = 0  // includes the tail spacer
  private var scrollOffset: CGFloat = 0
  private var rowFrames: [AnyHashable: CGRect] = [:]  // content-space frames of transcript rows
  private var pendingAnchorMessageID: UUID?
  private var didApplyOpeningPosition = false
  private var settleDeadline = Date.distantPast
  // While an animated command (anchor, jump, opening) is in flight, instant
  // follow ticks must stay out of its way or the animation visibly teleports.
  private var smoothCommandDeadline = Date.distantPast

  // MARK: Geometry

  /// Bottom edge of the last real row, ignoring the tail spacer.
  private var realContentBottom: CGFloat {
    rowFrames.values.map(\.maxY).max() ?? 0
  }

  /// How much real content is hidden below the viewport.
  private var hiddenContentBelow: CGFloat {
    realContentBottom - (scrollOffset + viewportHeight)
  }

  /// How far the viewport is from the maximum scroll position (spacer included).
  private var distanceFromMaxScroll: CGFloat {
    max(0, contentHeight - viewportHeight - scrollOffset)
  }

  private var isAtLiveEdge: Bool {
    hiddenContentBelow <= Self.scrollEdgeThreshold
      || distanceFromMaxScroll <= Self.scrollEdgeThreshold
  }

  private var isSettling: Bool {
    Date() < settleDeadline
  }

  func updateViewportHeight(_ height: CGFloat) {
    viewportHeight = height
  }

  /// Called from the content frame preference whenever layout or scroll changes.
  func updateContentFrame(_ frame: CGRect) {
    contentHeight = frame.height
    scrollOffset = -frame.minY
    reconcileFollowMode()
    updateJumpPill()
  }

  func updateRowFrames(_ frames: [AnyHashable: CGRect]) {
    rowFrames = frames
    updateJumpPill()
  }

  // MARK: Mode transitions

  /// Owns the follow-bottom transition: arm at the live edge, release when the
  /// reader moves away (scrollbar drags included), but never release while a
  /// programmatic scroll is still settling.
  private func reconcileFollowMode() {
    if isAtLiveEdge && mode != .settlingJump {
      mode = .followingBottom
    } else if mode == .followingBottom && !isAtLiveEdge && !isSettling {
      mode = .freeScrolling
    } else if mode == .settlingJump && !isSettling {
      mode = isAtLiveEdge ? .followingBottom : .freeScrolling
    }
  }

  /// A deliberate gesture (wheel scroll) always hands control back to the reader.
  func noteUserGesture() {
    mode = .freeScrolling
  }

  private func updateJumpPill() {
    let show = hiddenContentBelow > Self.scrollEdgeThreshold
    if show != showJumpToLatest {
      showJumpToLatest = show
    }
  }

  private func beginProgrammaticScroll(mode nextMode: Mode) {
    settleDeadline = Date().addingTimeInterval(Self.settleDelay)
    smoothCommandDeadline = settleDeadline
    mode = nextMode
  }

  // MARK: Commands

  /// Queue the just-sent user message as the next scroll anchor. The actual
  /// move happens once its row frame is known (after the next layout pass).
  func queueAnchor(for messageID: UUID) {
    pendingAnchorMessageID = messageID
  }

  /// Anchor the pending user turn near the top of the viewport: size the tail
  /// spacer so the position is reachable, then scroll its marker (64pt above
  /// the row) to the top. The streaming reply then grows into the space below
  /// without moving the view.
  func anchorPendingTurnIfReady(using proxy: ScrollViewProxy) {
    guard let messageID = pendingAnchorMessageID,
      let rowFrame = rowFrames[AnyHashable(messageID)],
      viewportHeight > 0
    else { return }

    pendingAnchorMessageID = nil
    didApplyOpeningPosition = true

    let desiredOffset = max(0, rowFrame.minY - Self.previousTurnPeek)
    let spacer = max(0, desiredOffset + viewportHeight - realContentBottom)
    tailSpacerHeight = spacer

    beginProgrammaticScroll(mode: .followingBottom)
    withAnimation(.easeOut(duration: 0.2)) {
      proxy.scrollTo(ChatAnchorMarkerID(messageID: messageID), anchor: .top)
    }
  }

  /// Keep the live edge in view while the reader is following. While the tail
  /// spacer still absorbs the growing reply this is a no-op, which is exactly
  /// the anchored "grow into available space" behavior.
  func followIfNeeded(using proxy: ScrollViewProxy, bottomID: some Hashable) {
    guard mode == .followingBottom else { return }
    guard Date() >= smoothCommandDeadline else { return }
    guard distanceFromMaxScroll > Self.scrollEdgeThreshold else { return }
    // Instant follow ticks get a short settle window so a scrollbar drag
    // between streamed tokens can still release follow mode.
    settleDeadline = max(settleDeadline, Date().addingTimeInterval(0.12))
    proxy.scrollTo(bottomID, anchor: .bottom)
  }

  /// Jump-to-latest: drop the spacer, scroll to the end, resume following.
  func jumpToLatest(using proxy: ScrollViewProxy, bottomID: some Hashable) {
    tailSpacerHeight = 0
    beginProgrammaticScroll(mode: .followingBottom)
    withAnimation(.easeOut(duration: 0.25)) {
      proxy.scrollTo(bottomID, anchor: .bottom)
    }
  }

  /// Opening position for a non-empty transcript (shadcn's "last-anchor"):
  /// open at the last user message unless the final turn already fits below it,
  /// in which case open at the end. Applied once per conversation load.
  func applyOpeningPositionIfNeeded(
    lastUserMessageID: UUID?,
    using proxy: ScrollViewProxy,
    bottomID: some Hashable
  ) {
    guard !didApplyOpeningPosition, viewportHeight > 0, !rowFrames.isEmpty else { return }
    didApplyOpeningPosition = true

    guard let lastUserMessageID,
      let anchorFrame = rowFrames[AnyHashable(lastUserMessageID)]
    else {
      beginProgrammaticScroll(mode: .followingBottom)
      proxy.scrollTo(bottomID, anchor: .bottom)
      return
    }

    let lastTurnFits =
      realContentBottom - anchorFrame.minY + Self.previousTurnPeek <= viewportHeight

    beginProgrammaticScroll(mode: lastTurnFits ? .followingBottom : .freeScrolling)
    if lastTurnFits {
      proxy.scrollTo(bottomID, anchor: .bottom)
    } else {
      proxy.scrollTo(ChatAnchorMarkerID(messageID: lastUserMessageID), anchor: .top)
    }
  }

  /// Reset for a fresh conversation (or after loading a different one).
  func resetForNewConversation() {
    mode = .followingBottom
    tailSpacerHeight = 0
    pendingAnchorMessageID = nil
    didApplyOpeningPosition = false
    showJumpToLatest = false
    rowFrames = [:]
  }

  /// Allow the next conversation load to re-apply its opening position.
  func prepareForConversationLoad() {
    resetForNewConversation()
  }
}

// MARK: - Scroll target identifiers

/// Scroll target sitting `previousTurnPeek` above a user message, so scrolling
/// it to `.top` leaves the previous turn peeking above the anchored row.
struct ChatAnchorMarkerID: Hashable {
  let messageID: UUID
}

// MARK: - Preference keys

struct ChatContentFrameKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

struct ChatRowFramesKey: PreferenceKey {
  static let defaultValue: [AnyHashable: CGRect] = [:]
  static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

extension View {
  /// Report this row's frame (in the chat content coordinate space) so the
  /// scroll model can anchor turns and detect hidden content.
  func chatRowFrame(id: AnyHashable) -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: ChatRowFramesKey.self,
          value: [id: proxy.frame(in: .named(ChatScrollCoordinateSpace.content))]
        )
      }
    )
  }
}

enum ChatScrollCoordinateSpace {
  /// Attached to the scroll view; frames measured here move as the user scrolls,
  /// so the content frame's origin yields the scroll offset.
  static let viewport = "chat-scroll-viewport"
  /// Attached to the padded transcript content; row frames measured here are
  /// stable content-space positions, independent of scrolling.
  static let content = "chat-scroll-content"
}

// MARK: - Wheel monitor

/// Local scroll-wheel monitor scoped to a view's window-space frame. Any wheel
/// over the transcript counts as reader intent and releases auto-follow.
struct ChatScrollWheelMonitor: ViewModifier {
  let onWheel: () -> Void

  @State private var monitor: Any?
  @State private var frameInWindow: CGRect = .zero

  func body(content: Content) -> some View {
    content
      .background(
        GeometryReader { proxy in
          Color.clear
            .onAppear { frameInWindow = proxy.frame(in: .global) }
            .onChange(of: proxy.frame(in: .global)) { _, newFrame in
              frameInWindow = newFrame
            }
        }
      )
      .onAppear {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
          if let window = event.window, let contentView = window.contentView {
            // SwiftUI's .global space is top-left based; AppKit windows are bottom-left.
            let location = event.locationInWindow
            let flipped = CGPoint(x: location.x, y: contentView.bounds.height - location.y)
            if frameInWindow.contains(flipped) {
              onWheel()
            }
          }
          return event
        }
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
      }
  }
}

extension View {
  func onChatScrollWheel(_ action: @escaping () -> Void) -> some View {
    modifier(ChatScrollWheelMonitor(onWheel: action))
  }
}

// MARK: - Jump to latest pill

struct JumpToLatestPill: View {
  let isStreaming: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.down")
          .font(.system(size: 11, weight: .semibold))
        if isStreaming {
          Text("New reply")
            .font(.custom("Figtree", size: 11).weight(.semibold))
        }
      }
      .foregroundColor(Color(hex: "F96E00"))
      .padding(.horizontal, isStreaming ? 12 : 9)
      .padding(.vertical, 8)
      .background(
        Capsule()
          .fill(Color.white)
          .shadow(color: Color.black.opacity(isHovered ? 0.16 : 0.1), radius: 8, x: 0, y: 3)
      )
      .overlay(
        Capsule()
          .stroke(Color(hex: "F96E00").opacity(0.25), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { isHovered = $0 }
    .accessibilityLabel(Text("Jump to latest message"))
  }
}
