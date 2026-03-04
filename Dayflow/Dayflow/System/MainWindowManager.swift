import AppKit
import SwiftUI

@MainActor
final class MainWindowManager: NSObject {
  static let shared = MainWindowManager()

  private var window: NSWindow?

  func showMainWindow() {
    if let window = window {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      return
    }

    let window = makeWindow()
    self.window = window
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    style.insert(.fullSizeContentView)
    let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.minSize = NSSize(width: 900, height: 600)
    window.backgroundColor = NSColor.windowBackgroundColor
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("MainUIWindow")
    window.center()

    let hostingView = NSHostingView(rootView: makeContentView())
    window.contentView = hostingView

    window.delegate = self
    return window
  }

  private func makeContentView() -> some View {
    MainWindowContent()
      .environmentObject(CategoryStore.shared)
  }
}

extension MainWindowManager: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    if let closingWindow = notification.object as? NSWindow, closingWindow == window {
      window = nil
    }
  }
}
