import AppKit
import SwiftUI

extension NSColor {
  convenience init?(hex: String) {
    let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    guard Scanner(string: sanitized).scanHexInt64(&int) else { return nil }
    let r: UInt64
    let g: UInt64
    let b: UInt64
    let a: UInt64
    switch sanitized.count {
    case 3:  // RGB (12-bit)
      (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
    case 6:  // RGB (24-bit)
      (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8:  // ARGB (32-bit)
      (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
      return nil
    }
    self.init(
      calibratedRed: CGFloat(r) / 255.0,
      green: CGFloat(g) / 255.0,
      blue: CGFloat(b) / 255.0,
      alpha: CGFloat(a) / 255.0
    )
  }

  func blended(with fraction: CGFloat, of color: NSColor) -> NSColor? {
    return usingColorSpace(.sRGB)?.blended(withFraction: fraction, of: color)
  }
}

extension Color {
  init(nsColor: NSColor) {
    self.init(nsColor)
  }
}
