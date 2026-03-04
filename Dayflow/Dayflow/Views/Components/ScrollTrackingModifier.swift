import AppKit
import SwiftUI

/// Observes the underlying NSScrollView's clip view bounds changes.
/// Unlike SwiftUI's PreferenceKey approach, this fires continuously during active scrolling.
private struct ScrollObserverView: NSViewRepresentable {
  let onScroll: (_ offset: CGFloat, _ delta: CGFloat) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = ScrollObserverNSView()
    view.onScroll = onScroll
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let observer = nsView as? ScrollObserverNSView {
      observer.onScroll = onScroll
    }
  }

  private class ScrollObserverNSView: NSView {
    var onScroll: ((_ offset: CGFloat, _ delta: CGFloat) -> Void)?
    private var lastOffset: CGFloat?
    private var scrollViewObservation: NSObjectProtocol?
    private var isReady = false

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()

      // Reset state when view is (re-)added to window
      isReady = false
      lastOffset = nil
      setupScrollObserver()

      // Ignore initial layout bounds changes
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.isReady = true
      }
    }

    private func setupScrollObserver() {
      // Clean up existing observation
      if let observation = scrollViewObservation {
        NotificationCenter.default.removeObserver(observation)
        scrollViewObservation = nil
      }

      // Find the parent NSScrollView (SwiftUI's ScrollView wraps an NSScrollView)
      guard let scrollView = findEnclosingScrollView() else { return }

      // Enable postsBoundsChangedNotifications on the clip view
      scrollView.contentView.postsBoundsChangedNotifications = true

      // Observe bounds changes - this fires during actual scrolling
      scrollViewObservation = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak self] _ in
        self?.handleBoundsChange(scrollView: scrollView)
      }
    }

    private func findEnclosingScrollView() -> NSScrollView? {
      var current: NSView? = superview
      while let view = current {
        if let scrollView = view as? NSScrollView {
          return scrollView
        }
        current = view.superview
      }
      return nil
    }

    private func handleBoundsChange(scrollView: NSScrollView) {
      let currentOffset = scrollView.contentView.bounds.origin.y

      if isReady, let last = lastOffset {
        let delta = currentOffset - last
        if abs(delta) > 0.5 {
          onScroll?(currentOffset, delta)
        }
      }

      lastOffset = currentOffset
    }

    deinit {
      if let observation = scrollViewObservation {
        NotificationCenter.default.removeObserver(observation)
      }
    }
  }
}

/// View modifier that tracks scroll events with debouncing.
/// Fires a callback once per "scroll session" (not per frame).
private struct ScrollTrackingModifier: ViewModifier {
  let panelName: String
  let onScrollStart: ((_ direction: String) -> Void)?

  @State private var isScrolling = false
  @State private var scrollResetWork: DispatchWorkItem?

  func body(content: Content) -> some View {
    content
      .background(
        ScrollObserverView { offset, delta in
          handleScroll(delta: delta)
        }
        .allowsHitTesting(false)
      )
  }

  private func handleScroll(delta: CGFloat) {
    // Defer state modifications to avoid "Modifying state during view update"
    DispatchQueue.main.async {
      // Fire event once when scrolling starts
      if !isScrolling {
        let direction = delta > 0 ? "down" : "up"
        onScrollStart?(direction)
        isScrolling = true
      }

      // Reset isScrolling after 0.6s of no scroll activity
      scrollResetWork?.cancel()
      let resetWork = DispatchWorkItem {
        isScrolling = false
      }
      scrollResetWork = resetWork
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: resetWork)
    }
  }
}

extension View {
  /// Tracks scroll activity and fires a debounced callback when scrolling starts.
  /// The callback receives the scroll direction ("up" or "down").
  /// Events are debounced - only fires once per "scroll session" (resets after 0.6s of no activity).
  func onScrollStart(panelName: String = "", action: @escaping (_ direction: String) -> Void)
    -> some View
  {
    modifier(ScrollTrackingModifier(panelName: panelName, onScrollStart: action))
  }
}
