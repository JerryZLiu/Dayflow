//
//  FlippedTextLayerWorkaround.swift
//  Dayflow
//

import ObjectiveC
import QuartzCore

/// Works around a SwiftUI/AppKit race that renders `Text` upside down (#295).
///
/// AppKit derives each layer's `geometryFlipped` from the view's `isFlipped`
/// relative to its ancestors. When a SwiftUI view is inserted mid-transaction
/// (e.g. the timeline failure toast animating in), SwiftUI's text layer can
/// draw before its ancestor chain is attached. The flip is computed against an
/// incomplete hierarchy, the layer draws with an inverted CTM, and it keeps the
/// upside-down bitmap after the hierarchy settles and the flip is corrected.
///
/// Fix: when `contentsAreFlipped` changes on a SwiftUI drawing layer, redraw it
/// so its contents match the settled geometry. Apple fixed the framework side in
/// macOS 26.2, but this stays on for all versions: the flag rarely changes, so
/// the extra redraw is cheap.
/// Background: https://oskargroth.com/blog/debugging-strange-calayers-chatgpt
///
/// Only SwiftUI's own drawing layers are redrawn. Calling `setNeedsDisplay` on a
/// plain CALayer whose `contents` were assigned directly (as the timeline review
/// and slideshow image views do) would wipe that image.
enum FlippedTextLayerWorkaround {
  private static var isInstalled = false

  static func install() {
    guard !isInstalled else { return }
    isInstalled = true

    let layerClass: AnyClass = CALayer.self
    let originalSelector = #selector(NSObject.didChangeValue(forKey:))
    let swizzledSelector = #selector(CALayer.dayflow_didChangeValue(forKey:))

    guard
      let originalMethod = class_getInstanceMethod(layerClass, originalSelector),
      let swizzledMethod = class_getInstanceMethod(layerClass, swizzledSelector)
    else { return }

    // CALayer inherits didChangeValue(forKey:) from NSObject. Add it on CALayer
    // first so the exchange below never touches NSObject's implementation.
    class_addMethod(
      layerClass,
      originalSelector,
      method_getImplementation(originalMethod),
      method_getTypeEncoding(originalMethod)
    )
    guard let layerOriginalMethod = class_getInstanceMethod(layerClass, originalSelector) else {
      return
    }
    method_exchangeImplementations(layerOriginalMethod, swizzledMethod)
  }

  fileprivate static func isSwiftUIDrawingLayer(_ layer: CALayer) -> Bool {
    NSStringFromClass(type(of: layer)).contains("CGDrawingLayer")
  }
}

extension CALayer {
  @objc fileprivate func dayflow_didChangeValue(forKey key: String) {
    // Implementations are exchanged, so this calls the original.
    dayflow_didChangeValue(forKey: key)

    guard key == "contentsAreFlipped",
      FlippedTextLayerWorkaround.isSwiftUIDrawingLayer(self)
    else { return }
    setNeedsDisplay()
  }
}
