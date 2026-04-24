import AppKit
import Charts
import SwiftUI

struct AppKitComposerTextField: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let focusToken: Int
  let placeholder: String
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> ComposerTextField {
    let textField = ComposerTextField()
    textField.delegate = context.coordinator
    textField.stringValue = text
    textField.font =
      NSFont(name: "Nunito-Medium", size: 16) ?? NSFont.systemFont(ofSize: 16, weight: .medium)
    textField.textColor = NSColor(hex: "2F2A24") ?? .labelColor
    textField.alignment = .left
    textField.lineBreakMode = .byTruncatingTail
    textField.maximumNumberOfLines = 1
    textField.usesSingleLineMode = true
    textField.focusRingType = .none
    textField.isBordered = false
    textField.isBezeled = false
    textField.drawsBackground = false
    textField.isEditable = true
    textField.isSelectable = true
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.configurePlaceholder(
      placeholder,
      font: NSFont(name: "Nunito-Medium", size: 16)
        ?? NSFont.systemFont(ofSize: 16, weight: .medium),
      color: NSColor(hex: "9B948D") ?? .secondaryLabelColor
    )
    return textField
  }

  func updateNSView(_ nsView: ComposerTextField, context: Context) {
    context.coordinator.parent = self

    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    nsView.refreshPlaceholderVisibility()

    if context.coordinator.lastFocusToken != focusToken {
      context.coordinator.lastFocusToken = focusToken
      DispatchQueue.main.async {
        nsView.window?.makeFirstResponder(nsView)
        if let editor = nsView.currentEditor() as? NSTextView {
          let end = (nsView.stringValue as NSString).length
          let insertion = NSRange(location: end, length: 0)
          editor.setSelectedRange(insertion)
          editor.scrollRangeToVisible(insertion)
        }
      }
    }

    if isFocused, nsView.window?.firstResponder !== nsView.currentEditor() {
      DispatchQueue.main.async {
        nsView.window?.makeFirstResponder(nsView)
      }
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AppKitComposerTextField
    var lastFocusToken: Int = -1

    init(parent: AppKitComposerTextField) {
      self.parent = parent
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
      parent.isFocused = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      parent.isFocused = false
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      parent.text = field.stringValue
      (field as? ComposerTextField)?.refreshPlaceholderVisibility()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
      -> Bool
    {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        parent.onSubmit()
        return true
      }
      return false
    }
  }
}

final class ComposerTextField: NSTextField {
  let placeholderLabel = NSTextField(labelWithString: "")

  var composerCell: ComposerTextFieldCell? {
    cell as? ComposerTextFieldCell
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    cell = ComposerTextFieldCell(textCell: "")
    composerCell?.horizontalInset = 14
    composerCell?.verticalInset = 0
    configurePlaceholderLabel()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    cell = ComposerTextFieldCell(textCell: "")
    composerCell?.horizontalInset = 14
    composerCell?.verticalInset = 0
    configurePlaceholderLabel()
  }

  override var stringValue: String {
    didSet {
      refreshPlaceholderVisibility()
    }
  }

  override func layout() {
    super.layout()
    guard let cell = composerCell else { return }
    placeholderLabel.frame = cell.titleRect(forBounds: bounds)
  }

  func configurePlaceholder(_ text: String, font: NSFont, color: NSColor) {
    placeholderLabel.stringValue = text
    placeholderLabel.font = font
    placeholderLabel.textColor = color
    refreshPlaceholderVisibility()
    needsLayout = true
  }

  func refreshPlaceholderVisibility() {
    placeholderLabel.isHidden = !stringValue.isEmpty
  }

  func configurePlaceholderLabel() {
    placeholderLabel.isEditable = false
    placeholderLabel.isSelectable = false
    placeholderLabel.isBordered = false
    placeholderLabel.drawsBackground = false
    placeholderLabel.lineBreakMode = .byTruncatingTail
    placeholderLabel.maximumNumberOfLines = 1
    addSubview(placeholderLabel)
  }
}

final class ComposerTextFieldCell: NSTextFieldCell {
  var horizontalInset: CGFloat = 14
  var verticalInset: CGFloat = 0

  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    centeredRect(forBounds: super.drawingRect(forBounds: rect))
  }

  override func titleRect(forBounds rect: NSRect) -> NSRect {
    centeredRect(forBounds: super.titleRect(forBounds: rect))
  }

  override func edit(
    withFrame aRect: NSRect,
    in controlView: NSView,
    editor textObj: NSText,
    delegate: Any?,
    event: NSEvent?
  ) {
    super.edit(
      withFrame: titleRect(forBounds: aRect),
      in: controlView,
      editor: textObj,
      delegate: delegate,
      event: event
    )
  }

  override func select(
    withFrame aRect: NSRect,
    in controlView: NSView,
    editor textObj: NSText,
    delegate: Any?,
    start selStart: Int,
    length selLength: Int
  ) {
    super.select(
      withFrame: titleRect(forBounds: aRect),
      in: controlView,
      editor: textObj,
      delegate: delegate,
      start: selStart,
      length: selLength
    )
  }

  func centeredRect(forBounds rect: NSRect) -> NSRect {
    var insetRect = rect.insetBy(dx: horizontalInset, dy: verticalInset)
    let textHeight = (font?.ascender ?? 10) - (font?.descender ?? -4) + (font?.leading ?? 0)
    let yOffset = (insetRect.height - textHeight) / 2
    insetRect.origin.y += max(0, yOffset.rounded(.down) - 0.5)
    insetRect.size.height = textHeight
    return insetRect.integral
  }
}
