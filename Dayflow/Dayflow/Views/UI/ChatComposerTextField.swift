import AppKit
import SwiftUI

/// Multi-line chat composer. Enter submits, Shift+Enter inserts a newline, and
/// the field grows with its content (up to a few lines) before scrolling.
struct AppKitComposerTextField: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let focusToken: Int
  let placeholder: String
  let onSubmit: () -> Void

  private static let minHeight: CGFloat = 50
  private static let maxHeight: CGFloat = 120
  private static let font =
    NSFont(name: "Figtree-Medium", size: 16) ?? NSFont.systemFont(ofSize: 16, weight: .medium)

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = ComposerTextView()
    textView.delegate = context.coordinator
    textView.font = Self.font
    textView.textColor = NSColor(hex: "2F2A24") ?? .labelColor
    textView.drawsBackground = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.textContainerInset = NSSize(width: 9, height: 14)
    textView.textContainer?.lineFragmentPadding = 5
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.string = text
    textView.configurePlaceholder(
      placeholder,
      font: Self.font,
      color: NSColor(hex: "9B948D") ?? .secondaryLabelColor
    )

    let scrollView = NSScrollView()
    scrollView.documentView = textView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.verticalScrollElasticity = .none
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scrollView.documentView as? ComposerTextView else { return }

    if textView.string != text {
      textView.string = text
    }
    textView.refreshPlaceholderVisibility()

    if context.coordinator.lastFocusToken != focusToken {
      context.coordinator.lastFocusToken = focusToken
      DispatchQueue.main.async {
        textView.window?.makeFirstResponder(textView)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
      }
    }

    if isFocused, textView.window?.firstResponder !== textView {
      DispatchQueue.main.async {
        textView.window?.makeFirstResponder(textView)
      }
    }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context
  ) -> CGSize? {
    let width = proposal.width ?? scrollView.frame.width
    guard let textView = scrollView.documentView as? ComposerTextView,
      let container = textView.textContainer,
      let layoutManager = textView.layoutManager,
      width > 0
    else {
      return nil
    }

    container.containerSize = NSSize(
      width: width - textView.textContainerInset.width * 2,
      height: .greatestFiniteMagnitude
    )
    layoutManager.ensureLayout(for: container)
    let textHeight = layoutManager.usedRect(for: container).height
    let height = min(
      Self.maxHeight,
      max(Self.minHeight, textHeight + textView.textContainerInset.height * 2)
    )
    return CGSize(width: width, height: height)
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: AppKitComposerTextField
    var lastFocusToken: Int = -1

    init(parent: AppKitComposerTextField) {
      self.parent = parent
    }

    func textDidBeginEditing(_ notification: Notification) {
      parent.isFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
      parent.isFocused = false
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? ComposerTextView else { return }
      parent.text = textView.string
      textView.refreshPlaceholderVisibility()
      textView.invalidateIntrinsicContentSize()
    }

    func textView(
      _ textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        // Shift+Enter (and Option+Enter) insert a newline; plain Enter submits.
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift) || modifiers.contains(.option) {
          return false
        }
        parent.onSubmit()
        return true
      }
      return false
    }
  }
}

final class ComposerTextView: NSTextView {
  private let placeholderLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    configurePlaceholderLabel()
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configurePlaceholderLabel()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configurePlaceholderLabel()
  }

  override func layout() {
    super.layout()
    placeholderLabel.frame = NSRect(
      x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
      y: textContainerInset.height,
      width: max(0, bounds.width - textContainerInset.width * 2 - 10),
      height: placeholderLabel.intrinsicContentSize.height
    )
  }

  func configurePlaceholder(_ text: String, font: NSFont, color: NSColor) {
    placeholderLabel.stringValue = text
    placeholderLabel.font = font
    placeholderLabel.textColor = color
    refreshPlaceholderVisibility()
    needsLayout = true
  }

  func refreshPlaceholderVisibility() {
    placeholderLabel.isHidden = !string.isEmpty
  }

  private func configurePlaceholderLabel() {
    placeholderLabel.isEditable = false
    placeholderLabel.isSelectable = false
    placeholderLabel.isBordered = false
    placeholderLabel.drawsBackground = false
    placeholderLabel.lineBreakMode = .byTruncatingTail
    placeholderLabel.maximumNumberOfLines = 1
    addSubview(placeholderLabel)
  }
}
