//
//  SplashWindow.swift
//  Dayflow
//
//  Splash screen window controller
//

import AppKit
import SwiftUI

class SplashWindow: NSWindow {
  var onClose: (() -> Void)?

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 250, height: 250),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    // Configure window
    self.isOpaque = false
    self.backgroundColor = .clear
    self.level = .floating
    self.hasShadow = false
    self.isMovableByWindowBackground = false
    self.ignoresMouseEvents = true  // never block clicks if this borderless window lingers

    // Center window
    self.center()

    // Set content
    self.contentView = NSHostingView(rootView: SplashView())

    // Show window
    self.makeKeyAndOrderFront(nil)

    // Auto-close after delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
      self.fadeOut()
    }
  }

  private func fadeOut() {
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.3
        self.animator().alphaValue = 0
      },
      completionHandler: {
        self.close()
        self.onClose?()
      })
  }
}

struct SplashView: View {
  @State private var logoOpacity: Double = 0

  var body: some View {
    ZStack {
      Color.clear

      Image("DayflowLaunch")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 180, height: 180)
        .opacity(logoOpacity)
    }
    .frame(width: 250, height: 250)
    .onAppear {
      withAnimation(.easeIn(duration: 0.5)) {
        logoOpacity = 1.0
      }
    }
  }
}
