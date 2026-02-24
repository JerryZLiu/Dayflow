//
//  WindowSizeReader.swift
//  Dayflow
//
//  Reads the size of the hosting NSWindow and reports it to SwiftUI.
//

import AppKit
import SwiftUI

struct WindowSizeReader: NSViewRepresentable {
  var onChange: (CGSize) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = ObservingView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class ObservingView: NSView {
    var onChange: ((CGSize) -> Void)?
    private var observer: Any?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attach(to: window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      detach()
    }

    private func attach(to window: NSWindow?) {
      guard let window = window else { return }
      observedWindow = window
      notifySize(for: window)
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didResizeNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self, let w = self.observedWindow else { return }
        self.notifySize(for: w)
      }
    }

    private func detach() {
      if let observer = observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      observedWindow = nil
    }

    private func notifySize(for window: NSWindow) {
      let size = window.contentLayoutRect.size
      onChange?(size)
    }
  }
}
