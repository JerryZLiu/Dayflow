//
//  DailyBriefComponents.swift
//  Dayflow
//
//  Small shared pieces for the Daily brief screens: fonts, colors, avatars,
//  app chips, disk images, and section headings.
//

import AppKit
import ImageIO
import SwiftUI

// MARK: - Fonts

enum DailyBriefFonts {
  /// Instrument Serif, used for the page title and section headings.
  static func serif(_ size: CGFloat) -> Font {
    Font.custom("InstrumentSerif-Regular", size: size)
  }

  /// Figtree, used for body text.
  static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    Font.custom("Figtree", size: size).weight(weight)
  }
}

// MARK: - Colors

/// Brief-specific colors that sit on top of the shared DayflowTheme tokens.
enum DailyBriefColors {
  static func heading(_ theme: DayflowTheme) -> Color {
    theme.isDark ? theme.textPrimary : Color(hex: "474747")
  }

  static func body(_ theme: DayflowTheme) -> Color {
    theme.isDark ? theme.textSecondary : Color(hex: "333333")
  }

  static func muted(_ theme: DayflowTheme) -> Color {
    theme.isDark ? theme.textMuted : Color(hex: "9D9D9D")
  }

  /// Orange used for due dates and the decision bar.
  static func accent(_ theme: DayflowTheme) -> Color {
    theme.isDark ? theme.accentText : Color(hex: "F3A57D")
  }

  static func cardFill(_ theme: DayflowTheme) -> Color {
    theme.isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.8)
  }

  static func cardBorder(_ theme: DayflowTheme) -> Color {
    theme.isDark ? Color.white.opacity(0.12) : Color(hex: "F0F0F0")
  }

  /// The page itself: a soft warm white in light mode, the panel navy in dark mode.
  static func pageBackground(_ theme: DayflowTheme) -> LinearGradient {
    if theme.isDark {
      return LinearGradient(
        colors: [Color(hex: "272A3C"), Color(hex: "2A2B3F")],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    return LinearGradient(
      colors: [Color(hex: "FBF8F7"), Color(hex: "FCEEEC")],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  /// Opaque color the header painting fades into.
  static func pageTop(_ theme: DayflowTheme) -> Color {
    theme.isDark ? Color(hex: "272A3C") : Color(hex: "FBF8F7")
  }
}

// MARK: - Dates

enum DailyBriefDates {
  /// "2026-10-12" → Date, or nil.
  static func date(from day: String?) -> Date? {
    guard let day else { return nil }
    return DateFormatter.yyyyMMdd.date(from: day)
  }

  /// "Monday, October 12"
  static func longTitle(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.wide).month(.wide).day())
  }

  /// "Friday October 24"
  static func dueText(_ day: String) -> String {
    guard let date = date(from: day) else { return day }
    return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
      .replacingOccurrences(of: ",", with: "")
  }

  /// "Oct 19"
  static func shortText(_ day: String?) -> String? {
    guard let day else { return nil }
    guard let date = date(from: day) else { return day }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }

  /// "MONDAY, OCT. 12"
  static func capsText(_ day: String?) -> String? {
    guard let day else { return nil }
    guard let date = date(from: day) else { return day.uppercased() }
    return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
  }
}

// MARK: - Section heading

struct DailyBriefSectionHeading: View {
  let title: String
  var subtitle: String? = nil

  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(DailyBriefFonts.serif(28))
        .foregroundStyle(DailyBriefColors.heading(theme))
        .fixedSize(horizontal: false, vertical: true)
      if let subtitle {
        Text(subtitle)
          .font(DailyBriefFonts.sans(14))
          .foregroundStyle(DailyBriefColors.muted(theme))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Avatar

/// A round avatar: initials over a gradient picked from the person's name.
struct DailyBriefAvatar: View {
  let name: String
  var size: CGFloat = 22
  /// Shown with the name in the hover tooltip.
  var note: String? = nil

  var body: some View {
    Circle()
      .fill(DailyBriefPalette.avatarGradient(for: name).linear)
      .overlay(
        Text(DailyBriefPalette.initials(for: name))
          .font(DailyBriefFonts.sans(size * 0.36, weight: .medium))
          .foregroundStyle(Color.black.opacity(0.45))
      )
      .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
      .frame(width: size, height: size)
      .help(tooltip)
  }

  private var tooltip: String {
    if let note, !note.isEmpty { return "\(name): \(note)" }
    return name
  }
}

/// Overlapping avatars, like the Figma people rows.
struct DailyBriefAvatarStack: View {
  let names: [String]
  var notes: [String: String] = [:]
  var size: CGFloat = 22

  var body: some View {
    HStack(spacing: -size * 0.3) {
      ForEach(Array(names.enumerated()), id: \.offset) { index, name in
        DailyBriefAvatar(name: name, size: size, note: notes[name])
          .zIndex(Double(names.count - index))
      }
    }
  }
}

// MARK: - Apps

/// Maps the model's lowercase app ids to a readable name and a host for the favicon.
enum DailyBriefApps {
  static func displayName(_ app: String) -> String {
    switch app.lowercased() {
    case "slack": return "Slack"
    case "figma": return "Figma"
    case "linear": return "Linear"
    case "notion": return "Notion"
    case "google_docs", "gdocs", "docs": return "Google Docs"
    case "google_sheets", "sheets": return "Google Sheets"
    case "google_slides", "slides": return "Google Slides"
    case "google_drive", "drive": return "Google Drive"
    case "gmail": return "Gmail"
    case "google_calendar", "calendar": return "Calendar"
    case "github": return "GitHub"
    case "chrome": return "Chrome"
    case "zoom": return "Zoom"
    case "jira": return "Jira"
    case "posthog": return "PostHog"
    case "x", "twitter": return "X"
    default:
      return app.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  static func host(_ app: String) -> String? {
    switch app.lowercased() {
    case "slack": return "slack.com"
    case "figma": return "figma.com"
    case "linear": return "linear.app"
    case "notion": return "notion.so"
    case "google_docs", "gdocs", "docs": return "docs.google.com"
    case "google_sheets", "sheets": return "sheets.google.com"
    case "google_slides", "slides": return "slides.google.com"
    case "google_drive", "drive": return "drive.google.com"
    case "gmail": return "mail.google.com"
    case "google_calendar", "calendar": return "calendar.google.com"
    case "github": return "github.com"
    case "zoom": return "zoom.us"
    case "jira": return "atlassian.com"
    case "posthog": return "posthog.com"
    case "x", "twitter": return "x.com"
    default: return nil
    }
  }
}

/// Just the app's icon.
struct DailyBriefAppIcon: View {
  let app: String
  var size: CGFloat = 14

  var body: some View {
    FaviconImageView(
      primaryRaw: app,
      secondaryRaw: nil,
      primaryHost: DailyBriefApps.host(app),
      secondaryHost: nil,
      size: size,
      cornerRadius: 3
    )
  }
}

/// App icon plus readable name, e.g. "[icon] Figma".
struct DailyBriefAppChip: View {
  let app: String

  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    HStack(spacing: 5) {
      DailyBriefAppIcon(app: app, size: 13)
      Text(DailyBriefApps.displayName(app))
        .font(DailyBriefFonts.sans(12))
        .foregroundStyle(DailyBriefColors.muted(theme))
        .lineLimit(1)
    }
  }
}

// MARK: - Images from disk

/// Loads an image file off the main thread and shows it aspect-filled (or fit),
/// with a soft tinted placeholder while loading or when the file is missing.
struct DailyBriefFileImage: View {
  let url: URL
  var contentMode: ContentMode = .fill

  @State private var image: CGImage?

  var body: some View {
    ZStack {
      DailyBriefPalette.documentTint(for: url.lastPathComponent).linear
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .aspectRatio(contentMode: contentMode)
      }
    }
    .clipped()
    .task(id: url) {
      let fileURL = url
      image = await Task.detached(priority: .utility) {
        Self.loadThumbnail(fileURL)
      }.value
    }
  }

  /// Decodes a downsized copy (long edge 1200px) so big screenshots stay cheap.
  nonisolated static func loadThumbnail(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 1200,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

// MARK: - Hover dismiss

/// Adds a small X while the pointer is over an item. By default it sits just
/// left of the item (list rows); `inside: true` puts it in the top-right
/// corner instead (cards and images).
private struct DailyBriefDismissButton: ViewModifier {
  let inside: Bool
  let action: () -> Void

  @State private var isHovering = false
  @Environment(\.dayflowTheme) private var theme

  /// Room left of a list row for the X. The hover area grows into it so the X
  /// stays visible while the pointer moves onto it.
  private var gutter: CGFloat { inside ? 0 : 28 }

  func body(content: Content) -> some View {
    content
      .padding(.leading, gutter)
      .overlay(alignment: inside ? .topTrailing : .topLeading) {
        Button(action: action) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(inside ? Color.white : DailyBriefColors.muted(theme))
            .frame(width: 18, height: 18)
            .background(Circle().fill(inside ? Color.black.opacity(0.35) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide this")
        .offset(x: inside ? -6 : 4, y: inside ? 6 : 0)
        .opacity(isHovering ? 1 : 0)
      }
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
      .padding(.leading, -gutter)
  }
}

extension View {
  /// Shows a hover X that calls `action` (used for "dismiss this item").
  func dailyBriefDismissable(inside: Bool = false, _ action: @escaping () -> Void) -> some View {
    modifier(DailyBriefDismissButton(inside: inside, action: action))
  }
}

// MARK: - Links

enum DailyBriefLinks {
  /// Opens a link in the browser, or a Slack message link in the Slack app when it can
  /// (the browser usually isn't signed in to Slack, so it lands on a sign-in page).
  /// Returns false when the string isn't a URL.
  @discardableResult
  static func open(_ string: String?) -> Bool {
    guard let string, let url = URL(string: string), url.scheme != nil else { return false }
    NSWorkspace.shared.open(slackAppURL(for: url) ?? url)
    return true
  }

  /// https://teleport-labs.slack.com/archives/C0B1BC1TJNN/p1794427192743539
  /// → slack://channel?team=T077AB269M4&id=C0B1BC1TJNN&message=1794427192.743539
  ///
  /// slack:// links need the workspace ID, which isn't in the web link, so it's looked
  /// up in the Slack app's own list of signed-in workspaces. nil when the link isn't a
  /// Slack message link or the Slack app isn't signed in to that workspace.
  static func slackAppURL(for url: URL) -> URL? {
    guard let host = url.host, host.hasSuffix(".slack.com") else { return nil }
    let parts = url.pathComponents  // ["/", "archives", "C0B1BC1TJNN", "p1794427192743539"]
    guard parts.count >= 3, parts[1] == "archives",
      let teamID = slackWorkspaceIDs()[host]
    else { return nil }

    var components = URLComponents()
    components.scheme = "slack"
    components.host = "channel"
    var query = [
      URLQueryItem(name: "team", value: teamID),
      URLQueryItem(name: "id", value: parts[2]),
    ]
    // "p1794427192743539" is the message timestamp 1794427192.743539 without the dot.
    if parts.count >= 4, parts[3].hasPrefix("p"), parts[3].count > 7 {
      let digits = String(parts[3].dropFirst())
      let timestamp = "\(digits.dropLast(6)).\(digits.suffix(6))"
      query.append(URLQueryItem(name: "message", value: timestamp))
    }
    if let threadTimestamp = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "thread_ts" })?.value
    {
      query.append(URLQueryItem(name: "thread_ts", value: threadTimestamp))
    }
    components.queryItems = query
    return components.url
  }

  /// Workspace web host ("teleport-labs.slack.com") → workspace ID ("T077AB269M4"),
  /// read from the Slack desktop app's saved state.
  private static func slackWorkspaceIDs() -> [String: String] {
    let stateURL = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/Slack/storage/root-state.json")
    guard let data = try? Data(contentsOf: stateURL),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let workspaces = json["workspaces"] as? [String: [String: Any]]
    else { return [:] }

    var result: [String: String] = [:]
    for (id, workspace) in workspaces {
      if let link = workspace["url"] as? String, let host = URL(string: link)?.host {
        result[host] = workspace["id"] as? String ?? id
      }
    }
    return result
  }

  static func host(of string: String?) -> String? {
    guard let string, let host = URL(string: string)?.host else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}
