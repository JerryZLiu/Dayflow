import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GoalCategoryPool: View {
  let categories: [TimelineCategory]
  let focusIDs: Set<String>
  let distractionIDs: Set<String>
  var onCycle: (TimelineCategory) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Drag and drop to set the categories you want to track")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color(hex: "5E5E5E"))

      DayGoalFlowLayout(spacing: 8, rowSpacing: 6) {
        ForEach(categories) { category in
          Button {
            onCycle(category)
          } label: {
            GoalCategoryChip(
              title: category.name,
              colorHex: category.colorHex,
              status: status(for: category)
            )
          }
          .buttonStyle(.plain)
          .onDrag {
            NSItemProvider(object: category.id.uuidString as NSString)
          }
          .pointingHandCursor()
          .help(
            "Drag into a goal panel, or click to cycle between Focus, Distraction, and untracked")
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(hex: "FCFCFC").opacity(0.76))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(hex: "E7DFDF"), lineWidth: 1)
    )
  }

  private func status(for category: TimelineCategory) -> GoalCategoryChip.Status {
    let id = category.id.uuidString
    if focusIDs.contains(id) {
      return .focus
    }
    if distractionIDs.contains(id) {
      return .distraction
    }
    return .untracked
  }
}

struct GoalSetupPanel: View {
  let kind: DayGoalCategoryKind
  let title: String
  @Binding var durationMinutes: Int
  let leadingStatTitle: String
  let leadingStatMinutes: Int
  let trailingStatTitle: String
  let trailingStatMinutes: Int
  let statScaleMaxMinutes: Int
  let selectedCategories: [DayGoalCategorySnapshot]
  var onRemoveCategory: (String) -> Void
  var onDropCategory: (String) -> Void

  private var accent: Color {
    switch kind {
    case .focus:
      return Color(hex: "628CFF")
    case .distraction:
      return Color(hex: "FA8282")
    }
  }

  private var iconName: String {
    switch kind {
    case .focus:
      return "DayGoalFocus"
    case .distraction:
      return "DayGoalDistraction"
    }
  }

  private var panelWidth: CGFloat {
    switch kind {
    case .focus:
      return 396
    case .distraction:
      return 400.28
    }
  }

  private var statColumnWidth: CGFloat {
    (panelWidth - 32 - 18) / 2
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(iconName)
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)

        Text(title)
          .font(.custom("Figtree", size: 14))
          .foregroundColor(.white)

        Spacer()
      }
      .padding(.horizontal, 11)
      .frame(height: 30)
      .background(accent)

      HStack(spacing: 10) {
        categoryBox
          .frame(width: 140, height: 187)

        GoalDurationPicker(minutes: $durationMinutes)
          .frame(width: 192, height: 187)
      }
      .padding(.top, 21)
      .padding(.bottom, 23)
      .padding(.horizontal, 24)
      .frame(maxWidth: .infinity)
      .background(Color.white.opacity(0.8))

      footer
        .frame(height: 59)
    }
    .frame(width: panelWidth)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(hex: "E7DFDF"), lineWidth: 1)
    )
  }

  private var categoryBox: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Categories")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color(hex: "7A7A7A"))

      VStack(alignment: .leading, spacing: 6) {
        ForEach(selectedCategories) { category in
          Button {
            onRemoveCategory(category.categoryID)
          } label: {
            GoalCategoryChip(
              title: category.name,
              colorHex: category.colorHex,
              status: kind == .focus ? .focus : .distraction,
              showsRemove: true
            )
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }
      }
      Spacer(minLength: 0)
    }
    .padding(11)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(hex: "F8F6F5"))
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color(hex: "E6DDD5"), lineWidth: 1)
    )
    .onDrop(of: [.plainText], isTargeted: nil, perform: handleCategoryDrop)
  }

  private func handleCategoryDrop(_ providers: [NSItemProvider]) -> Bool {
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
      })
    else {
      return false
    }

    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
      let categoryID: String?
      if let data = item as? Data {
        categoryID = String(data: data, encoding: .utf8)
      } else if let string = item as? String {
        categoryID = string
      } else if let nsString = item as? NSString {
        categoryID = String(nsString)
      } else {
        categoryID = nil
      }

      guard let categoryID else { return }
      Task { @MainActor in
        onDropCategory(categoryID)
      }
    }
    return true
  }

  private var footer: some View {
    HStack(spacing: 18) {
      goalStat(title: leadingStatTitle, minutes: leadingStatMinutes)
        .frame(width: statColumnWidth, alignment: .leading)
      goalStat(title: trailingStatTitle, minutes: trailingStatMinutes)
        .frame(width: statColumnWidth, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Color(hex: "FCFCFC").opacity(0.7))
  }

  private func goalStat(title: String, minutes: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.custom("Figtree", size: 12))
        .foregroundColor(.black)
        .lineLimit(1)
        .minimumScaleFactor(0.82)

      HStack(spacing: 5) {
        RoundedRectangle(cornerRadius: 20)
          .fill(accent)
          .frame(width: statBarWidth(minutes: minutes), height: 6)

        Text(formatShort(minutes: minutes))
          .font(.custom("Figtree", size: 12))
          .foregroundColor(.black)
          .lineLimit(1)
          .minimumScaleFactor(0.86)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func formatShort(minutes: Int) -> String {
    let hours = minutes / 60
    let mins = minutes % 60
    if hours > 0 && mins == 0 {
      return "\(hours) hours"
    }
    if hours > 0 {
      return "\(hours)h \(mins)m"
    }
    return "\(mins)m"
  }

  private func statBarWidth(minutes: Int) -> CGFloat {
    guard minutes > 0, statScaleMaxMinutes > 0 else { return 0 }
    let ratio = min(max(CGFloat(minutes) / CGFloat(statScaleMaxMinutes), 0), 1)
    return max(12, 86 * ratio)
  }
}

private struct GoalCategoryChip: View {
  enum Status {
    case untracked
    case focus
    case distraction
  }

  let title: String
  let colorHex: String
  let status: Status
  var showsRemove = false

  private var color: Color {
    if let nsColor = NSColor(hex: colorHex) {
      return Color(nsColor: nsColor)
    }
    return .gray
  }

  private var background: Color {
    switch status {
    case .focus:
      return color.opacity(0.16)
    case .distraction:
      return Color(hex: "FFEDED")
    case .untracked:
      return color.opacity(0.16)
    }
  }

  var body: some View {
    HStack(spacing: 2) {
      ChipDragHandle(color: color)
        .frame(width: 16, height: 16)

      Text(title)
        .font(.custom("Figtree", size: 12))
        .foregroundColor(Color(hex: "333333"))
        .lineLimit(1)
        .minimumScaleFactor(0.8)

      if showsRemove {
        Image(systemName: "xmark")
          .font(.system(size: 7, weight: .semibold))
          .foregroundColor(Color(hex: "777777"))
      }
    }
    .padding(4)
    .background(background)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(color.opacity(status == .untracked ? 0.75 : 1), lineWidth: 0.5)
    )
  }
}

private struct ChipDragHandle: View {
  let color: Color

  var body: some View {
    VStack(spacing: 2) {
      HStack(spacing: 2) {
        Circle().fill(color)
        Circle().fill(color)
      }
      HStack(spacing: 2) {
        Circle().fill(color)
        Circle().fill(color)
      }
    }
    .padding(3)
  }
}

private struct DayGoalFlowLayout: Layout {
  var spacing: CGFloat = 6
  var rowSpacing: CGFloat = 6

  func makeCache(subviews: Subviews) {}

  func updateCache(_ cache: inout (), subviews: Subviews) {}

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maxRowWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
        totalHeight += rowHeight + rowSpacing
        maxRowWidth = max(maxRowWidth, rowWidth)
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
        rowHeight = max(rowHeight, size.height)
      }
    }

    maxRowWidth = max(maxRowWidth, rowWidth)
    totalHeight += rowHeight
    return CGSize(width: maxRowWidth, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var origin = CGPoint(x: bounds.minX, y: bounds.minY)
    var currentRowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += currentRowHeight + rowSpacing
        currentRowHeight = 0
      }

      subview.place(
        at: CGPoint(x: origin.x, y: origin.y),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )

      origin.x += size.width + spacing
      currentRowHeight = max(currentRowHeight, size.height)
    }
  }
}
