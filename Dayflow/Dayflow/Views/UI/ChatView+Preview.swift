import AppKit
import Charts
import SwiftUI

// MARK: - Preview

#Preview("Chat View") {
  ChatView()
    .frame(width: 400, height: 600)
}

#Preview("Thinking Indicator") {
  ThinkingIndicator()
    .padding()
    .background(Color(hex: "FFFAF5"))
}
