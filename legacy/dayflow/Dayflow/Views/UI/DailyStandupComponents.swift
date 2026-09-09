import AppKit
import Foundation
import SwiftUI
import UserNotifications

struct DailyCopyPressButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .dayflowPressScale(
        configuration.isPressed,
        pressedScale: 0.97,
        animation: .easeOut(duration: 0.14)
      )
  }
}

struct DailyBulletCard: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  enum SeamMode {
    case standalone
    case joinedLeading
    case joinedTrailing
  }

  enum Style {
    case highlights
    case tasks
  }

  let style: Style
  let seamMode: SeamMode
  let title: String
  @Binding var items: [DailyBulletItem]
  @Binding var blockersTitle: String
  @Binding var blockersBody: String
  let scale: CGFloat
  @State private var draggedItemID: UUID? = nil
  @State private var pendingScrollTargetID: UUID? = nil
  @FocusState private var focusedItemID: UUID?
  @State private var keyMonitor: Any? = nil

  private var listViewportHeight: CGFloat {
    style == .tasks ? 142 * scale : 230 * scale
  }

  private var listMinHeight: CGFloat {
    style == .tasks ? 92 * scale : 154 * scale
  }

  private var cardShape: UnevenRoundedRectangle {
    let cornerRadius = 12 * scale
    let cornerRadii: RectangleCornerRadii

    switch seamMode {
    case .standalone:
      cornerRadii = .init(
        topLeading: cornerRadius,
        bottomLeading: cornerRadius,
        bottomTrailing: cornerRadius,
        topTrailing: cornerRadius
      )
    case .joinedLeading:
      cornerRadii = .init(
        topLeading: cornerRadius,
        bottomLeading: cornerRadius,
        bottomTrailing: 0,
        topTrailing: 0
      )
    case .joinedTrailing:
      cornerRadii = .init(
        topLeading: 0,
        bottomLeading: 0,
        bottomTrailing: cornerRadius,
        topTrailing: cornerRadius
      )
    }

    return UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 18 * scale) {
        Text(title)
          .font(.custom("InstrumentSerif-Regular", size: (stylePreviewAfter ? 20 : 24) * scale))
          .foregroundStyle(theme.isDark ? theme.textSecondary : StandupStyle.headingColor)
          .frame(maxWidth: .infinity, alignment: .leading)

        itemListEditor
      }
      .padding(.leading, 26 * scale)
      .padding(.trailing, 26 * scale)
      .padding(.top, 26 * scale)

      addItemButton
        .padding(.leading, style == .highlights ? 16 * scale : 26 * scale)
        .padding(.bottom, style == .tasks ? 24 * scale : 20 * scale)

      if style == .tasks {
        blockersSection
      }
    }
    .frame(maxWidth: .infinity, minHeight: max(180, 394 * scale), alignment: .topLeading)
    .background(cardShape.fill(theme.standupCardGradient))
    .clipShape(cardShape)
    .overlay(
      cardShape
        .stroke(
          theme.isDark ? theme.standupCardBorder : StandupStyle.strokeColor,
          lineWidth: 0.75
        )
    )
    .shadow(
      color: theme.isDark ? Color.black.opacity(0.1) : StandupStyle.shadowColor,
      radius: theme.isDark ? 8 : StandupStyle.shadowBlur,
      x: 0,
      y: theme.isDark ? 4 : StandupStyle.shadowDistance
    )
    .onAppear {
      setupKeyMonitor()
    }
    .onDisappear {
      removeKeyMonitor()
    }
  }

  @ViewBuilder
  private var blockersSection: some View {
    if stylePreviewAfter {
      GeometryReader { proxy in
        DailyBlockersSection(
          scale: scale,
          title: $blockersTitle,
          prompt: $blockersBody
        )
        .frame(height: proxy.size.height * 0.85, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      }
    } else {
      DailyBlockersSection(
        scale: scale,
        title: $blockersTitle,
        prompt: $blockersBody
      )
    }
  }

  private var itemListEditor: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: items.count > 5) {
        LazyVStack(alignment: .leading, spacing: 10 * scale) {
          ForEach(items) { item in
            let itemID = item.id
            HStack(alignment: .top, spacing: 8 * scale) {
              DailyDragHandleIcon(scale: scale)
                .frame(width: 18 * scale, height: 18 * scale)
                .padding(.top, 2 * scale)
                .contentShape(Rectangle())
                .onDrag {
                  draggedItemID = itemID
                  return NSItemProvider(object: itemID.uuidString as NSString)
                }
                .pointingHandCursorOnHover(reassertOnPressEnd: true)

              TextField("", text: bindingForItemText(id: itemID), axis: .vertical)
                .font(.custom("Figtree-Regular", size: 14 * scale))
                .foregroundStyle(theme.textPrimary)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focusedItemID, equals: itemID)
                .onSubmit {
                  addItem(after: itemID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(itemID)
            .frame(minHeight: 22 * scale, alignment: .top)
            .onDrop(
              of: ["public.text"],
              delegate: DailyListItemDropDelegate(
                targetItemID: itemID,
                items: $items,
                draggedItemID: $draggedItemID
              )
            )
          }
        }
        .padding(.vertical, 2 * scale)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: listMinHeight, maxHeight: listViewportHeight, alignment: .topLeading)
      .onDrop(
        of: ["public.text"],
        delegate: DailyListDropToEndDelegate(
          items: $items,
          draggedItemID: $draggedItemID
        )
      )
      .onChange(of: pendingScrollTargetID) { _, newValue in
        guard let newValue else { return }
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo(newValue, anchor: .bottom)
        }
        pendingScrollTargetID = nil
      }
    }
  }

  private func bindingForItemText(id itemID: UUID) -> Binding<String> {
    Binding(
      get: {
        items.first(where: { $0.id == itemID })?.text ?? ""
      },
      set: { newValue in
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].text = newValue
      }
    )
  }

  private var addItemButton: some View {
    Button(action: { addItem(after: nil) }) {
      HStack(spacing: 6 * scale) {
        Image(systemName: "plus")
          .font(.system(size: 18 * scale, weight: .regular))
          .foregroundStyle(theme.textMuted)
          .frame(width: 18 * scale, height: 18 * scale)

        Text("Add item")
          .font(.custom("Figtree-Regular", size: 13 * scale))
          .foregroundStyle(theme.textMuted)
          .lineLimit(1)
      }
      .padding(.vertical, 6 * scale)
    }
    .buttonStyle(.plain)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }

  private func addItem(after itemID: UUID?) {
    let newItem = DailyBulletItem(text: "")
    if let itemID, let index = items.firstIndex(where: { $0.id == itemID }) {
      items.insert(newItem, at: index + 1)
    } else {
      items.append(newItem)
    }

    pendingScrollTargetID = newItem.id
    focusedItemID = newItem.id
  }

  private func setupKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 51 else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags.isEmpty else { return event }
      return scheduleFocusedItemRemovalIfEmpty() ? nil : event
    }
  }

  private func removeKeyMonitor() {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
  }

  private func scheduleFocusedItemRemovalIfEmpty() -> Bool {
    guard let activeFocusedItemID = focusedItemID,
      let index = items.firstIndex(where: { $0.id == activeFocusedItemID })
    else {
      return false
    }

    guard items.indices.contains(index) else {
      return false
    }

    guard items[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }

    DispatchQueue.main.async {
      removeItemIfStillEmpty(withID: activeFocusedItemID)
    }
    return true
  }

  private func removeItemIfStillEmpty(withID itemID: UUID) {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else {
      return
    }

    guard items.indices.contains(index) else {
      return
    }

    guard items[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    focusedItemID = nil
    items.remove(at: index)
  }
}

struct DailyDragHandleIcon: View {
  @Environment(\.dayflowTheme) private var theme

  let scale: CGFloat

  var body: some View {
    VStack(spacing: 2 * scale) {
      ForEach(0..<3, id: \.self) { _ in
        HStack(spacing: 2 * scale) {
          Circle()
            .fill(theme.textMuted)
            .frame(width: 2.5 * scale, height: 2.5 * scale)
          Circle()
            .fill(theme.textMuted)
            .frame(width: 2.5 * scale, height: 2.5 * scale)
        }
      }
    }
    .frame(width: 12 * scale, height: 12 * scale, alignment: .center)
  }
}

struct DailyBlockersSection: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  let scale: CGFloat
  @Binding var title: String
  @Binding var prompt: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8 * scale) {
      TextField("Blockers", text: $title)
        .font(.custom("Figtree-Medium", size: 14 * scale))
        .foregroundStyle(theme.isDark ? theme.textSecondary : StandupStyle.headingColor)
        .textFieldStyle(.plain)

      HStack(alignment: .center, spacing: 8 * scale) {
        DailyDragHandleIcon(scale: scale)
          .frame(width: 18 * scale, height: 18 * scale)

        TextField("Fill in any blockers you may have", text: $prompt, axis: .vertical)
          .font(.custom("Figtree-Regular", size: 14 * scale))
          .foregroundStyle(theme.textPrimary)
          .textFieldStyle(.plain)
          .lineLimit(1...4)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.leading, 26 * scale)
    .padding(.trailing, 26 * scale)
    .padding(.top, 14 * scale)
    .frame(
      maxWidth: .infinity, minHeight: 94 * scale,
      maxHeight: stylePreviewAfter ? .infinity : nil, alignment: .topLeading
    )
    .background(theme.standupBlockersFill)
    .overlay {
      Rectangle()
        .stroke(theme.standupBlockersBorder, lineWidth: max(0.7, 1 * scale))
    }
  }
}

struct DailyListItemDropDelegate: DropDelegate {
  let targetItemID: UUID
  @Binding var items: [DailyBulletItem]
  @Binding var draggedItemID: UUID?

  func dropEntered(info: DropInfo) {
    guard let draggedID = draggedItemID,
      draggedID != targetItemID,
      let fromIndex = items.firstIndex(where: { $0.id == draggedID }),
      let toIndex = items.firstIndex(where: { $0.id == targetItemID })
    else {
      return
    }

    withAnimation(.easeInOut(duration: 0.14)) {
      items.move(
        fromOffsets: IndexSet(integer: fromIndex),
        toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
      )
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedItemID = nil
    return true
  }
}

struct DailyListDropToEndDelegate: DropDelegate {
  @Binding var items: [DailyBulletItem]
  @Binding var draggedItemID: UUID?

  func dropEntered(info: DropInfo) {
    guard let draggedID = draggedItemID,
      let fromIndex = items.firstIndex(where: { $0.id == draggedID })
    else {
      return
    }

    let endIndex = items.count
    guard fromIndex != endIndex - 1 else { return }

    withAnimation(.easeInOut(duration: 0.14)) {
      items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: endIndex)
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedItemID = nil
    return true
  }
}
