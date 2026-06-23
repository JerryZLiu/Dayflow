//
//  JournalTextEditor.swift
//  Dayflow
//
//  AppKit-backed auto-growing text editor used by the journal forms.
//

import AppKit
import SwiftUI

struct JournalTextEditor: View {
  @Binding var text: String
  var placeholder: String
  var minLines: Int = 3
  var autoFocus: Bool = false

  private let font = NSFont(name: "Figtree-Regular", size: 15) ?? .systemFont(ofSize: 15)
  private let verticalInset: CGFloat = 4
  @State private var height: CGFloat = 0

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder)
          .font(.custom("Figtree-Regular", size: 15))
          .foregroundStyle(JournalDayTokens.bodyText.opacity(0.45))
          .padding(.top, verticalInset)
          .padding(.leading, 4)
          .allowsHitTesting(false)
      }

      MacTextView(
        text: $text,
        height: $height,
        minLines: minLines,
        font: font,
        autoFocus: autoFocus
      )
      .frame(height: max(height, calculateMinHeight()))
    }
    .padding(.vertical, 2)
    .padding(.horizontal, 2)
  }

  private func calculateMinHeight() -> CGFloat {
    let layoutManager = NSLayoutManager()
    let lineHeight = layoutManager.defaultLineHeight(for: font)
    return (lineHeight * CGFloat(minLines)) + (verticalInset * 2)
  }
}

// MARK: - AppKit Wrappers

private struct MacTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var height: CGFloat
  var minLines: Int
  var font: NSFont
  var autoFocus: Bool = false

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> JournalClickableTextView {
    let textView = JournalClickableTextView()
    textView.delegate = context.coordinator
    textView.font = font
    textView.textColor = NSColor(red: 0.18, green: 0.11, blue: 0.06, alpha: 1.0)
    textView.drawsBackground = false
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 0, height: 4)

    if let container = textView.textContainer {
      container.lineFragmentPadding = 4
      container.widthTracksTextView = true
      container.containerSize = NSSize(
        width: textView.bounds.width, height: .greatestFiniteMagnitude)
    }

    textView.selectedTextAttributes = [
      .backgroundColor: NSColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1.0),
      .foregroundColor: NSColor(red: 0.18, green: 0.11, blue: 0.06, alpha: 1.0),
    ]

    if autoFocus {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        textView.window?.makeFirstResponder(textView)
      }
    }
    return textView
  }

  func updateNSView(_ nsView: JournalClickableTextView, context: Context) {
    if nsView.string != text {
      let selectedRange = nsView.selectedRange()
      nsView.string = text
      let newLength = (text as NSString).length
      let location = min(selectedRange.location, newLength)
      let length = min(selectedRange.length, newLength - location)
      if location >= 0 {
        nsView.setSelectedRange(NSRange(location: location, length: length))
      }
    }
    if let container = nsView.textContainer, container.containerSize.width != nsView.bounds.width {
      container.containerSize = NSSize(width: nsView.bounds.width, height: .greatestFiniteMagnitude)
    }
    context.coordinator.recalculateHeight(view: nsView)
  }

  class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MacTextView
    init(parent: MacTextView) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
      recalculateHeight(view: textView)
    }
    func recalculateHeight(view: NSTextView) {
      guard let layoutManager = view.layoutManager, let textContainer = view.textContainer else {
        return
      }
      layoutManager.ensureLayout(for: textContainer)
      let usedRect = layoutManager.usedRect(for: textContainer)
      let newHeight = usedRect.height + view.textContainerInset.height * 2
      if abs(parent.height - newHeight) > 0.5 {
        DispatchQueue.main.async { self.parent.height = newHeight }
      }
    }
  }
}

private class JournalClickableTextView: NSTextView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hitView = super.hitTest(point)
    if hitView != nil { return hitView }
    if self.bounds.contains(point) { return self }
    return nil
  }
}
