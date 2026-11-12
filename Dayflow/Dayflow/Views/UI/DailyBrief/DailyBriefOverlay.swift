//
//  DailyBriefOverlay.swift
//  Dayflow
//
//  The Daily brief as an in-tab overlay: it covers the main panel (the sidebar
//  stays visible), shows the brief page, and layers the current route
//  (enlarged image, saved, everything completed, range summary) on top. The
//  first time it opens, the "Introducing Dayflow Daily Briefs" walkthrough
//  covers the page until it's finished or skipped.
//

import AppKit
import SwiftUI

struct DailyBriefOverlay: View {
  @ObservedObject private var store = DailyBriefStore.shared

  var body: some View {
    ZStack {
      // Dimmed backdrop. The page normally covers it; a click that reaches it closes the brief.
      Color.black.opacity(0.18)
        .contentShape(Rectangle())
        .onTapGesture { store.dismiss() }

      DailyBriefPageView()

      if let route = store.route {
        DailyBriefRouteLayer(route: route)
          .transition(.opacity)
          .zIndex(1)
      }

      if store.showsIntro {
        DailyBriefIntroLayer()
          .transition(.opacity)
          .zIndex(2)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .animation(.easeOut(duration: 0.2), value: store.route)
    .animation(.easeOut(duration: 0.45), value: store.showsIntro)
    .background(DailyBriefEscapeKeyHandler(onEscape: handleEscape))
  }

  private func handleEscape() {
    if store.showsIntro {
      store.finishIntro("skipped", step: store.introStep)
      return
    }
    // Docket menus and the "Tell us why" pop-up close before anything else.
    if DocketUIState.shared.closeTopPopup() { return }
    if store.route != nil {
      store.route = nil
    } else {
      store.dismiss()
    }
  }
}

/// One route screen over a frosted, darkened copy of the brief page.
private struct DailyBriefRouteLayer: View {
  @ObservedObject private var store = DailyBriefStore.shared
  let route: DailyBriefStore.Route

  var body: some View {
    ZStack {
      DailyBriefRouteBackdrop()
        .contentShape(Rectangle())
        .onTapGesture { store.route = nil }

      content

      DailyBriefRouteCloseButton { store.route = nil }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 18)
        .padding(.trailing, 18)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch route {
    case .enlargedImage(let image):
      DailyBriefEnlargedImageView(image: image)
    case .saved:
      DailyBriefSavedView()
    case .completedHistory:
      DailyBriefCompletedView()
    case .rangeSummary(let range):
      DailyBriefRangeSummaryView(range: range)
    }
  }
}

// MARK: - Shared pieces for the route screens

/// Blurred, darkened layer the route screens sit on ("In-tab overlay" in Figma).
struct DailyBriefRouteBackdrop: View {
  var body: some View {
    Rectangle()
      .fill(.ultraThinMaterial)
      .overlay(Color.black.opacity(0.38))
  }
}

/// The white X in the top-right corner of a route screen.
struct DailyBriefRouteCloseButton: View {
  var color: Color = .white
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(color)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .accessibilityLabel("Close")
  }
}

/// Pill used for "Summarize for my review", "Export image", "Save" and similar.
/// Prominent pills are peach; the others are glassy, white on the dark
/// backdrop or dark on a light card (`onLight`).
struct DailyBriefRoutePill: View {
  let title: String
  var systemImage: String? = nil
  var isProminent = true
  var onLight = false

  var body: some View {
    HStack(spacing: 6) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
      }
      Text(title)
        .font(.custom("Figtree", size: 13).weight(.medium))
        .lineLimit(1)
    }
    .foregroundStyle(foreground)
    .padding(.horizontal, 14)
    .frame(height: 30)
    .background(Capsule().fill(fill))
    .overlay(Capsule().strokeBorder(border, lineWidth: 0.75))
    .contentShape(Capsule())
  }

  private var foreground: Color {
    if isProminent { return Color(hex: "7A3E1D") }
    return onLight ? Color(hex: "3A3A3A") : .white
  }

  private var fill: Color {
    if isProminent { return Color(hex: "FFD5BF") }
    return onLight ? Color.black.opacity(0.05) : Color.white.opacity(0.16)
  }

  private var border: Color {
    if isProminent { return Color(hex: "F6B999").opacity(0.6) }
    return onLight ? Color.black.opacity(0.08) : Color.white.opacity(0.28)
  }
}

enum DailyBriefRouteDates {
  private static let longFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMM d"
    return formatter
  }()

  private static let shortFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter
  }()

  /// "Tuesday, Oct 21" for "2026-10-21".
  static func long(_ day: String) -> String {
    guard let date = DateFormatter.yyyyMMdd.date(from: day) else { return day }
    return longFormatter.string(from: date)
  }

  /// "Oct 21" for "2026-10-21".
  static func short(_ day: String) -> String {
    guard let date = DateFormatter.yyyyMMdd.date(from: day) else { return day }
    return shortFormatter.string(from: date)
  }
}

// MARK: - Escape key

/// Calls `onEscape` when Escape is pressed in the window that hosts this view.
/// A local event monitor is used instead of a first-responder view so text
/// fields inside the brief (like "Add a new task") keep their focus.
private struct DailyBriefEscapeKeyHandler: NSViewRepresentable {
  let onEscape: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onEscape: onEscape)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.start(hostView: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onEscape = onEscape
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    var onEscape: () -> Void
    private weak var hostView: NSView?
    private var monitor: Any?

    init(onEscape: @escaping () -> Void) {
      self.onEscape = onEscape
    }

    func start(hostView: NSView) {
      self.hostView = hostView
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard event.keyCode == 53 else { return event }  // Escape
        let eventWindowNumber = event.windowNumber
        let handled = MainActor.assumeIsolated {
          self?.handleEscape(eventWindowNumber: eventWindowNumber) ?? false
        }
        return handled ? nil : event
      }
    }

    /// Only reacts when Escape was pressed in the window that shows the brief.
    private func handleEscape(eventWindowNumber: Int) -> Bool {
      guard let window = hostView?.window, window.windowNumber == eventWindowNumber else {
        return false
      }
      onEscape()
      return true
    }

    func stop() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
      }
      monitor = nil
    }
  }
}
