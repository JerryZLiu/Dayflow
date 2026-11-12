//
//  DailyBriefSections.swift
//  Dayflow
//
//  One view per brief section. Each section is a row: a serif heading in the
//  left column and its items on the right (team decisions puts each decision's
//  date in the left column instead).
//

import SwiftUI

// MARK: - Layout

enum DailyBriefLayout {
  static let pageMaxWidth: CGFloat = 1120
  static let pagePadding: CGFloat = 84
  static let leftColumnWidth: CGFloat = 222
  static let columnGap: CGFloat = 60
  static let sectionSpacing: CGFloat = 72
  /// Below this page width, headings stack above their content.
  static let compactWidth: CGFloat = 860

  static func horizontalPadding(isCompact: Bool) -> CGFloat {
    isCompact ? 32 : pagePadding
  }
}

private struct DailyBriefIsCompactKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// True when the brief is too narrow for the two-column layout.
  var dailyBriefIsCompact: Bool {
    get { self[DailyBriefIsCompactKey.self] }
    set { self[DailyBriefIsCompactKey.self] = newValue }
  }
}

/// Heading on the left, content on the right. On narrow windows the heading
/// sits above the content instead.
struct DailyBriefSectionRow<Content: View>: View {
  let title: String
  var subtitle: String? = nil
  @ViewBuilder let content: () -> Content

  @Environment(\.dailyBriefIsCompact) private var isCompact

  var body: some View {
    if isCompact {
      VStack(alignment: .leading, spacing: 20) {
        DailyBriefSectionHeading(title: title, subtitle: subtitle)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      HStack(alignment: .top, spacing: DailyBriefLayout.columnGap) {
        DailyBriefSectionHeading(title: title, subtitle: subtitle)
          .frame(width: DailyBriefLayout.leftColumnWidth, alignment: .leading)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

// MARK: - Visible items

enum DailyBriefSectionItems {
  /// The title each item is keyed by for checks, dismissals, and feedback.
  static func titles(_ kind: DailyBriefSectionKind, in content: DailyBriefContent) -> [String] {
    switch kind {
    case .docket: return (content.docket ?? []).map(\.title)
    case .keepTracking: return (content.keepTracking ?? []).map(\.label)
    case .completedYesterday: return (content.completedYesterday ?? []).map(\.title)
    case .teamDecisions: return (content.teamDecisions ?? []).map(\.decision)
    case .relatedReading: return (content.relatedReading ?? []).map(\.title)
    case .industryNews: return (content.industryNews ?? []).map(\.headline)
    case .siteSeeing: return (content.siteSeeing ?? []).map(\.file)
    }
  }

  /// Sections that still have something to show after dismissals. The docket
  /// always stays, because it holds the "Add a new task" field.
  @MainActor
  static func visibleKinds(_ brief: DailyBrief, store: DailyBriefStore) -> [DailyBriefSectionKind] {
    brief.content.orderedKinds.filter { kind in
      if kind == .docket { return true }
      return titles(kind, in: brief.content).contains { !store.isDismissed(kind, $0) }
    }
  }

  /// Site-seeing files are relative to the brief folder ("images/x.jpg"). Older
  /// output may hold the bare candidate name, which the app copies into images/.
  static func siteSeeingPath(_ file: String) -> String {
    file.contains("/") ? file : "images/\(file)"
  }
}

// MARK: - Dispatcher

struct DailyBriefSectionView: View {
  let kind: DailyBriefSectionKind
  let brief: DailyBrief

  var body: some View {
    switch kind {
    case .docket:
      DailyBriefDocketSection(brief: brief)
    case .keepTracking:
      DailyBriefSectionRow(title: kind.title) {
        DailyBriefTrackingList(items: brief.content.keepTracking ?? [])
      }
    case .completedYesterday:
      DailyBriefSectionRow(title: kind.title) {
        DailyBriefCompletedList(brief: brief)
      }
    case .teamDecisions:
      DailyBriefDecisionsSection(items: brief.content.teamDecisions ?? [])
    case .relatedReading:
      DailyBriefSectionRow(title: kind.title) {
        DailyBriefReadingGrid(
          day: brief.day,
          items: brief.content.relatedReading ?? [])
      }
    case .industryNews:
      DailyBriefSectionRow(title: kind.title) {
        DailyBriefNewsList(day: brief.day, items: brief.content.industryNews ?? [])
      }
    case .siteSeeing:
      DailyBriefSectionRow(title: kind.title) {
        DailyBriefSiteSeeingCollage(brief: brief)
      }
    }
  }
}

// MARK: - Docket

struct DailyBriefDocketSection: View {
  let brief: DailyBrief

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var newTaskTitle = ""

  private var items: [DailyBriefDocketItem] {
    (brief.content.docket ?? []).filter { !store.isDismissed(.docket, $0.title) }
  }

  var body: some View {
    DailyBriefSectionRow(
      title: DailyBriefSectionKind.docket.title,
      subtitle: "Synthesized from your Timeline and connectors."
    ) {
      VStack(alignment: .leading, spacing: 26) {
        ForEach(items, id: \.title) { item in
          DailyBriefDocketRow(item: item)
            .dailyBriefDismissable { store.dismissItem(.docket, item.title) }
        }
        ForEach(brief.userState.addedTasks) { task in
          addedTaskRow(task)
            .dailyBriefDismissable { store.removeAddedTask(task) }
        }
        addTaskField
      }
    }
  }

  private func addedTaskRow(_ task: DailyBriefAddedTask) -> some View {
    let isChecked = store.isChecked(.docket, task.title)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      DailyBriefCheckbox(isChecked: isChecked) {
        store.toggleChecked(.docket, task.title)
      }
      Text(task.title)
        .font(DailyBriefFonts.sans(14, weight: .medium))
        .foregroundStyle(theme.textPrimary)
        .strikethrough(isChecked)
        .opacity(isChecked ? 0.5 : 1)
    }
  }

  private var addTaskField: some View {
    HStack(spacing: 8) {
      Image(systemName: "plus")
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(DailyBriefColors.muted(theme))
      TextField("Add a new task", text: $newTaskTitle)
        .textFieldStyle(.plain)
        .font(DailyBriefFonts.sans(13))
        .foregroundStyle(theme.textPrimary)
        .onSubmit {
          store.addTask(newTaskTitle)
          newTaskTitle = ""
        }
    }
    .frame(maxWidth: 320, alignment: .leading)
  }
}

struct DailyBriefCheckbox: View {
  let isChecked: Bool
  let action: () -> Void

  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    Button(action: action) {
      Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 13))
        .foregroundStyle(isChecked ? theme.accent : DailyBriefColors.muted(theme))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

private struct DailyBriefDocketRow: View {
  let item: DailyBriefDocketItem

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    let isChecked = store.isChecked(.docket, item.title)

    HStack(alignment: .firstTextBaseline, spacing: 8) {
      DailyBriefCheckbox(isChecked: isChecked) {
        store.toggleChecked(.docket, item.title)
      }

      VStack(alignment: .leading, spacing: 7) {
        Text(item.title)
          .font(DailyBriefFonts.sans(14, weight: .medium))
          .foregroundStyle(theme.textPrimary)
          .strikethrough(isChecked)

        if let due = item.due {
          Text("Due: \(DailyBriefDates.dueText(due))")
            .font(DailyBriefFonts.sans(12))
            .foregroundStyle(DailyBriefColors.accent(theme))
        }

        if let detail = item.detail, !detail.isEmpty {
          Text(detail)
            .font(DailyBriefFonts.sans(13))
            .foregroundStyle(DailyBriefColors.body(theme))
            .fixedSize(horizontal: false, vertical: true)
        }

        if let people = item.people, !people.isEmpty {
          peopleRow(people)
        }

        if let links = item.links, !links.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
              DailyBriefLinkChip(link: link) {
                store.recordFeedback(.docket, item.title, .opened)
              }
            }
          }
        }
      }
      .opacity(isChecked ? 0.5 : 1)
    }
  }

  private func peopleRow(_ people: [DailyBriefPerson]) -> some View {
    let notes = Dictionary(
      people.compactMap { person in person.note.map { (person.name, $0) } },
      uniquingKeysWith: { first, _ in first })
    return HStack(spacing: 8) {
      DailyBriefAvatarStack(names: people.map(\.name), notes: notes, size: 22)
      Text(people.map(\.name).joined(separator: ", "))
        .font(DailyBriefFonts.sans(12))
        .foregroundStyle(DailyBriefColors.muted(theme))
        .lineLimit(1)
    }
  }
}

/// A related document: tinted thumbnail with the app icon, title, and app name.
struct DailyBriefLinkChip: View {
  let link: DailyBriefLink
  var onOpen: () -> Void = {}

  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    Button {
      if DailyBriefLinks.open(link.url) { onOpen() }
    } label: {
      HStack(spacing: 7) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(DailyBriefPalette.documentTint(for: link.title).linear)
          .frame(width: 16, height: 20)
          .overlay {
            if let app = link.app {
              DailyBriefAppIcon(app: app, size: 10)
            }
          }
        Text(link.title)
          .font(DailyBriefFonts.sans(12))
          .foregroundStyle(DailyBriefColors.body(theme))
          .lineLimit(1)
        if let app = link.app {
          Text(DailyBriefApps.displayName(app))
            .font(DailyBriefFonts.sans(11))
            .foregroundStyle(DailyBriefColors.muted(theme))
        }
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 7)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(DailyBriefColors.cardFill(theme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(DailyBriefColors.cardBorder(theme), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .disabled(link.url == nil)
    .pointingHandCursor(enabled: link.url != nil)
  }
}

// MARK: - Keep tracking

private struct DailyBriefTrackingList: View {
  let items: [DailyBriefTrackingItem]

  @ObservedObject private var store = DailyBriefStore.shared

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .top, spacing: 10) {
        ForEach(items.filter { !store.isDismissed(.keepTracking, $0.label) }, id: \.label) { item in
          DailyBriefTrackingCard(item: item)
            .dailyBriefDismissable(inside: true) { store.dismissItem(.keepTracking, item.label) }
        }
      }
    }
  }
}

private struct DailyBriefTrackingCard: View {
  let item: DailyBriefTrackingItem

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Image(systemName: "pin.fill")
          .font(.system(size: 8))
        Text(item.label)
          .font(DailyBriefFonts.sans(12))
          .lineLimit(1)
      }
      .foregroundStyle(DailyBriefColors.muted(theme))

      Text(item.status)
        .font(DailyBriefFonts.sans(16))
        .foregroundStyle(theme.textPrimary)
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 8)

      HStack(spacing: 6) {
        if let app = item.app {
          DailyBriefAppIcon(app: app, size: 12)
        }
        if let asOf = DailyBriefDates.shortText(item.asOf) {
          Text(asOf)
            .font(DailyBriefFonts.sans(11))
            .foregroundStyle(DailyBriefColors.muted(theme))
        }
      }
    }
    .padding(12)
    .frame(width: 200, alignment: .leading)
    .frame(minHeight: 112, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(DailyBriefColors.cardFill(theme))
    )
    .contentShape(Rectangle())
    .onTapGesture {
      if DailyBriefLinks.open(item.url) {
        store.recordFeedback(.keepTracking, item.label, .opened)
      }
    }
    .pointingHandCursor(enabled: item.url != nil)
  }
}

// MARK: - Completed yesterday

private struct DailyBriefCompletedList: View {
  let brief: DailyBrief

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  private var items: [DailyBriefCompletedItem] {
    (brief.content.completedYesterday ?? []).filter {
      !store.isDismissed(.completedYesterday, $0.title)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(items, id: \.title) { item in
            DailyBriefCompletedCard(item: item, briefDay: brief.day)
              .dailyBriefDismissable(inside: true) {
                store.dismissItem(.completedYesterday, item.title)
              }
          }
        }
      }

      Button {
        store.route = .completedHistory
      } label: {
        HStack(spacing: 4) {
          Text("See everything you completed")
          Image(systemName: "arrow.right")
            .font(.system(size: 10, weight: .medium))
        }
        .font(DailyBriefFonts.sans(13, weight: .medium))
        .foregroundStyle(DailyBriefColors.body(theme))
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
  }
}

/// One completed item: project, title, app icons, and the screenshot.
struct DailyBriefCompletedCard: View {
  let item: DailyBriefCompletedItem
  /// The brief whose folder holds `item.imageFile`.
  let briefDay: String
  var width: CGFloat = 241
  var height: CGFloat = 136

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    ZStack(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: 4) {
        if let project = item.project {
          Text(project)
            .font(DailyBriefFonts.sans(13))
            .foregroundStyle(DailyBriefColors.muted(theme))
            .lineLimit(1)
        }
        Text(item.title)
          .font(DailyBriefFonts.sans(14))
          .foregroundStyle(theme.textPrimary)
          .lineLimit(item.imageFile == nil ? 4 : 2)
          .frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
        appIcons
      }
      .padding(13)

      if let image {
        DailyBriefFileImage(url: image.url)
          .frame(width: width * 0.6, height: height * 0.68)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .offset(x: width * 0.33, y: height * 0.44)
          .onTapGesture {
            store.route = .enlargedImage(image)
          }
          .pointingHandCursor()
      }
    }
    .frame(width: width, height: height, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(DailyBriefColors.cardFill(theme))
    )
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var image: DailyBriefImage? {
    guard let file = item.imageFile else { return nil }
    return DailyBriefImage(
      day: briefDay, section: .completedYesterday, file: file, caption: item.title)
  }

  private var appIcons: some View {
    HStack(spacing: -5) {
      ForEach(Array((item.apps ?? []).prefix(3).enumerated()), id: \.offset) { _, app in
        Circle()
          .fill(
            theme.isDark
              ? AnyShapeStyle(Color.white.opacity(0.15))
              : AnyShapeStyle(
                LinearGradient(
                  colors: [.white, Color(hex: "EADFDF")], startPoint: .top, endPoint: .bottom))
          )
          .overlay(
            Circle().strokeBorder(
              theme.isDark ? Color.white.opacity(0.2) : Color(hex: "FFFCFB"), lineWidth: 2)
          )
          .overlay(DailyBriefAppIcon(app: app, size: 15))
          .frame(width: 28, height: 28)
          .help(DailyBriefApps.displayName(app))
      }
    }
  }
}

// MARK: - Team decisions

private struct DailyBriefDecisionsSection: View {
  let items: [DailyBriefDecisionItem]

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.dailyBriefIsCompact) private var isCompact

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      DailyBriefSectionHeading(title: DailyBriefSectionKind.teamDecisions.title)
        .frame(maxWidth: DailyBriefLayout.leftColumnWidth, alignment: .leading)

      ForEach(items.filter { !store.isDismissed(.teamDecisions, $0.decision) }, id: \.decision) {
        item in
        // Narrow windows put the date above the decision instead of beside it.
        let layout =
          isCompact
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
          : AnyLayout(HStackLayout(alignment: .top, spacing: DailyBriefLayout.columnGap))
        layout {
          Text(DailyBriefDates.capsText(item.date) ?? "")
            .font(DailyBriefFonts.sans(11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(DailyBriefColors.muted(theme))
            .frame(width: isCompact ? nil : DailyBriefLayout.leftColumnWidth, alignment: .leading)
            .padding(.top, isCompact ? 0 : 2)

          decisionBody(item)
            .dailyBriefDismissable { store.dismissItem(.teamDecisions, item.decision) }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private func decisionBody(_ item: DailyBriefDecisionItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(item.decision)
        .font(DailyBriefFonts.sans(14))
        .foregroundStyle(theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(theme.accent)
            .frame(width: 2)
        }

      HStack(spacing: 8) {
        if let people = item.people, !people.isEmpty {
          DailyBriefAvatarStack(names: people, size: 24)
        }
        if item.place != nil || item.app != nil {
          placeChip(item)
        }
      }
    }
  }

  private func placeChip(_ item: DailyBriefDecisionItem) -> some View {
    Button {
      if DailyBriefLinks.open(item.url) {
        store.recordFeedback(.teamDecisions, item.decision, .opened)
      }
    } label: {
      HStack(spacing: 5) {
        if let app = item.app {
          DailyBriefAppIcon(app: app, size: 12)
        }
        Text(item.place ?? item.app.map(DailyBriefApps.displayName) ?? "")
          .font(DailyBriefFonts.sans(12, weight: .medium))
          .foregroundStyle(DailyBriefColors.body(theme))
        if item.url != nil {
          Image(systemName: "arrow.up.right")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DailyBriefColors.muted(theme))
        }
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 7)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(DailyBriefColors.cardFill(theme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(DailyBriefColors.cardBorder(theme), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .disabled(item.url == nil)
    .pointingHandCursor(enabled: item.url != nil)
  }
}

// MARK: - Related reading

private struct DailyBriefReadingGrid: View {
  /// The brief whose folder holds each item's picture.
  let day: String
  let items: [DailyBriefReadingItem]

  @ObservedObject private var store = DailyBriefStore.shared

  private static let columns = [
    GridItem(.flexible(), spacing: 28, alignment: .top),
    GridItem(.flexible(), alignment: .top),
  ]

  var body: some View {
    let visible = items.filter { !store.isDismissed(.relatedReading, $0.title) }

    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 26) {
      ForEach(visible, id: \.title) { item in
        DailyBriefReadingCard(item: item, day: day)
          .dailyBriefDismissable(inside: true) {
            store.dismissItem(.relatedReading, item.title)
          }
      }
    }
  }
}

/// A wide card: the page's own picture, then one bold line, why it's for them, and
/// the source with the reading time. A page with no usable picture gets a gradient
/// poster with the bold line set large instead.
private struct DailyBriefReadingCard: View {
  let item: DailyBriefReadingItem
  let day: String

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false

  /// The bold line under a picture. Under a poster, which already shows the hook,
  /// it's the page's title.
  private var heading: String? {
    if item.imageFile != nil { return item.hook ?? item.title }
    return item.hook == nil ? nil : item.title
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      picture
        .scaleEffect(isHovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .padding(.bottom, 12)

      if let heading {
        Text(heading)
          .font(DailyBriefFonts.sans(15, weight: .semibold))
          .foregroundStyle(theme.textPrimary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let reason = item.reason {
        Text(reason)
          .font(DailyBriefFonts.sans(13))
          .foregroundStyle(DailyBriefColors.body(theme))
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 3)
      }
      if !sourceLine.isEmpty {
        Text(sourceLine)
          .font(DailyBriefFonts.sans(12))
          .foregroundStyle(DailyBriefColors.muted(theme))
          .lineLimit(1)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .help(item.title)
    .onTapGesture {
      if DailyBriefLinks.open(item.url) {
        store.recordFeedback(.relatedReading, item.title, .opened)
      }
    }
    .pointingHandCursor()
  }

  /// "iGeeksBlog · 4 min"
  private var sourceLine: String {
    [item.source ?? DailyBriefLinks.host(of: item.url), item.minutes.map { "\($0) min" }]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  /// The shape most sites make their share pictures in, so those show whole.
  private static let pictureAspect: CGFloat = 1.91

  private var picture: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return Color.clear
      .aspectRatio(Self.pictureAspect, contentMode: .fit)
      .overlay {
        if let file = item.imageFile {
          DailyBriefFileImage(url: DailyBriefStore.briefImageURL(day: day, file: file))
        } else {
          poster
        }
      }
      .clipShape(shape)
      // A thin edge keeps pale pictures from fading into the page.
      .overlay(
        shape.strokeBorder(
          theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
  }

  /// Shown when the page has no usable picture: a soft gradient with the hook in large type.
  private var poster: some View {
    ZStack(alignment: .leading) {
      DailyBriefPalette.documentTint(for: item.title).linear
      Text(item.hook ?? item.title)
        .font(DailyBriefFonts.serif(26))
        .foregroundStyle(Color(hex: "22233A"))
        .lineLimit(4)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
  }
}

// MARK: - Industry news

private struct DailyBriefNewsList: View {
  /// The brief whose folder holds each item's picture.
  let day: String
  let items: [DailyBriefNewsItem]

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    let visible = items.filter { !store.isDismissed(.industryNews, $0.headline) }

    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(visible.enumerated()), id: \.element.headline) { index, item in
        if index > 0 {
          Rectangle()
            .fill(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08))
            .frame(height: 1)
        }
        row(item)
          .padding(.top, index == 0 ? 0 : 14)
          .padding(.bottom, 14)
          .dailyBriefDismissable { store.dismissItem(.industryNews, item.headline) }
      }
    }
    .frame(maxWidth: 640, alignment: .leading)
  }

  /// The headline with its source and date, and the article's own picture on the right.
  private func row(_ item: DailyBriefNewsItem) -> some View {
    let meta = [
      item.source ?? DailyBriefLinks.host(of: item.url),
      DailyBriefDates.shortText(item.published),
    ]
    .compactMap { $0 }

    return HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text(item.headline)
          .font(DailyBriefFonts.serif(21))
          .foregroundStyle(theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        if !meta.isEmpty {
          Text(meta.joined(separator: " · "))
            .font(DailyBriefFonts.sans(12))
            .foregroundStyle(DailyBriefColors.muted(theme))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let file = item.imageFile {
        DailyBriefFileImage(url: DailyBriefStore.briefImageURL(day: day, file: file))
          .frame(width: 120, height: 80)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .shadow(color: Color.black.opacity(0.14), radius: 3, y: 1)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if DailyBriefLinks.open(item.url) {
        store.recordFeedback(.industryNews, item.headline, .opened)
      }
    }
    .pointingHandCursor()
  }
}

// MARK: - Site-seeing

private struct DailyBriefSiteSeeingCollage: View {
  let brief: DailyBrief

  @ObservedObject private var store = DailyBriefStore.shared

  private static let tilts: [Double] = [-6, 4, -2, 7, -4, 3, -7, 5]
  private static let lifts: [CGFloat] = [18, 0, 26, 6, 22, -4, 14, 4]

  var body: some View {
    let items = (brief.content.siteSeeing ?? []).filter { !store.isDismissed(.siteSeeing, $0.file) }
    let rows = stride(from: 0, to: items.count, by: 4).map {
      Array(items[$0..<min($0 + 4, items.count)])
    }

    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
        HStack(spacing: -26) {
          ForEach(Array(row.enumerated()), id: \.element.file) { index, item in
            let position = rowIndex * 4 + index
            DailyBriefSiteSeeingTile(brief: brief, item: item)
              .rotationEffect(.degrees(Self.tilts[position % Self.tilts.count]))
              .offset(y: Self.lifts[position % Self.lifts.count])
          }
        }
        .padding(.leading, 10)
        .padding(.vertical, 16)
      }
    }
  }
}

private struct DailyBriefSiteSeeingTile: View {
  let brief: DailyBrief
  let item: DailyBriefSiteSeeingItem

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isHovering = false

  private var image: DailyBriefImage {
    DailyBriefImage(
      day: brief.day,
      section: .siteSeeing,
      file: DailyBriefSectionItems.siteSeeingPath(item.file),
      caption: item.caption)
  }

  var body: some View {
    DailyBriefFileImage(url: image.url)
      .frame(width: 176, height: 116)
      .overlay(alignment: .bottomLeading) {
        if isHovering, let caption = item.caption, !caption.isEmpty {
          Text(caption)
            .font(DailyBriefFonts.sans(11, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              LinearGradient(
                colors: [.clear, Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            )
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(alignment: .topTrailing) {
        if isHovering {
          saveButton.padding(6)
        }
      }
      .overlay(alignment: .topLeading) {
        if isHovering {
          dismissButton.padding(6)
        }
      }
      .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
      .scaleEffect(isHovering ? 1.06 : 1)
      .zIndex(isHovering ? 10 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovering)
      .onHover { isHovering = $0 }
      .help(item.caption ?? "")
      .onTapGesture {
        store.route = .enlargedImage(image)
      }
      .pointingHandCursor()
  }

  private var saveButton: some View {
    let isSaved = store.isSaved(image)
    return Button {
      store.save(image)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
          .font(.system(size: 9, weight: .semibold))
        Text(isSaved ? "Saved" : "Save")
          .font(DailyBriefFonts.sans(11, weight: .semibold))
      }
      .foregroundStyle(.white)
      .padding(.vertical, 4)
      .padding(.horizontal, 8)
      .background(Capsule().fill(Color.black.opacity(0.45)))
    }
    .buttonStyle(.plain)
    .disabled(isSaved)
  }

  private var dismissButton: some View {
    Button {
      store.dismissItem(.siteSeeing, item.file)
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.black.opacity(0.45)))
    }
    .buttonStyle(.plain)
    .help("Hide this")
  }
}
