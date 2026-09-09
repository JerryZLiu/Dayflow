import AppKit
import Foundation

enum RecordingPrivacyPlaceholder {
  /// Renders a redaction card at exactly `width` x `height` pixels so it slots into
  /// the current segment without forcing a resolution change.
  @MainActor
  static func image(
    width: Int,
    height: Int,
    applicationName: String = "Private app"
  ) -> CGImage? {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return nil }

    let size = CGSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

    let maxTextWidth = size.width * 0.82
    let title = "\(displayName(applicationName)) hidden by your privacy settings"
    let subtitle =
      "This screenshot was saved without the app's contents because you blocked it from recording."
    drawCenteredText(
      title,
      fontSize: min(size.width, size.height) * 0.035,
      yOffset: 18,
      maxWidth: maxTextWidth
    )
    drawCenteredText(
      subtitle,
      fontSize: min(size.width, size.height) * 0.018,
      yOffset: -26,
      maxWidth: maxTextWidth
    )

    NSGraphicsContext.current?.flushGraphics()
    return context.makeImage()
  }

  private static func drawCenteredText(
    _ text: String,
    fontSize: CGFloat,
    yOffset: CGFloat,
    maxWidth: CGFloat
  ) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let canvas = context.boundingBoxOfClipPath
    let resolvedFontSize = fittedFontSize(
      for: text,
      startingAt: fontSize,
      minimum: fontSize * 0.55,
      maxWidth: maxWidth
    )
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: resolvedFontSize, weight: .semibold),
      .foregroundColor: NSColor.white.withAlphaComponent(0.82),
    ]
    let attributedText = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributedText.size()
    let origin = CGPoint(
      x: canvas.midX - textSize.width / 2,
      y: canvas.midY - textSize.height / 2 + yOffset
    )
    attributedText.draw(at: origin)
  }

  private static func fittedFontSize(
    for text: String,
    startingAt fontSize: CGFloat,
    minimum: CGFloat,
    maxWidth: CGFloat
  ) -> CGFloat {
    var currentSize = fontSize
    while currentSize > minimum {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: currentSize, weight: .semibold)
      ]
      if NSAttributedString(string: text, attributes: attributes).size().width <= maxWidth {
        return currentSize
      }
      currentSize -= 1
    }
    return minimum
  }

  private static func displayName(_ applicationName: String) -> String {
    let trimmed = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Private app" : trimmed
  }
}
