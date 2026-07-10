import SwiftUI

// MARK: - Hover-expand prototype preview

/// Xcode Preview harness for experimenting with the hover-expand interaction.
/// The segmented control at the top lets you flip between Overlay (card lifts,
/// neighbours unaffected) and Displace (overlapped neighbours temporarily hide).
private struct WeekTimelineHoverPrototypeHarness: View {
  @State private var selectedDate: Date = Date()
  @State private var selectedActivity: TimelineActivity? = nil
  @State private var hasAny: Bool = true
  @State private var refresh: Int = 0

  private static let weekRange = TimelineWeekRange.containing(Date())

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Hover-expand prototype")
          .font(.custom("Figtree", size: 13).weight(.semibold))
          .foregroundColor(Color(hex: "333333"))
        Text(
          "Hover a short card — the card grows to reveal the full title. No text shifts; only new lines appear below."
        )
        .font(.custom("Figtree", size: 11))
        .foregroundColor(Color(hex: "6B5548"))
      }

      WeekTimelineGridView(
        selectedDate: $selectedDate,
        selectedActivity: $selectedActivity,
        hasAnyActivities: $hasAny,
        refreshTrigger: $refresh,
        weekRange: Self.weekRange,
        onSelectDay: { selectedDate = $0 },
        onSelectActivity: { selectedActivity = $0 },
        onClearSelection: { selectedActivity = nil },
        previewPositionedActivities: Self.mockActivities()
      )
      .background(Color(hex: "FFF6EE"))
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(hex: "FAF3EB"))
    .preferredColorScheme(.light)
  }

  private static func mockActivities() -> [WeekPositionedActivity] {
    // Build a synthetic day of cards around late morning with several stacked
    // short cards so both modes have something interesting to show.
    // yPosition is minutes-from-4AM * pixelsPerMinute.
    let ppm = WeekTimelineConfig.pixelsPerMinute

    struct Spec {
      let column: Int
      let startMinutes: Int  // minutes after 4:00 AM
      let durationMinutes: Int
      let title: String
      let category: String
      let favicon: String?
    }

    let specs: [Spec] = [
      // Monday (col 1) — one long card, easy baseline
      Spec(
        column: 1, startMinutes: 6 * 60, durationMinutes: 45,
        title: "Refining UI mockups for the weekly view",
        category: "Work", favicon: "figma.com"),

      // Tuesday (col 2) — stacked cluster of short cards (displace showcase)
      Spec(
        column: 2, startMinutes: 6 * 60, durationMinutes: 12,
        title: "Refining UI mockups — iteration 1 of the hover card",
        category: "Work", favicon: "figma.com"),
      Spec(
        column: 2, startMinutes: 6 * 60 + 12, durationMinutes: 10,
        title: "Refining UI mockups — iteration 2",
        category: "Work", favicon: "figma.com"),
      Spec(
        column: 2, startMinutes: 6 * 60 + 22, durationMinutes: 8,
        title: "Refining UI mockups — quick pass",
        category: "Work", favicon: "figma.com"),
      Spec(
        column: 2, startMinutes: 6 * 60 + 30, durationMinutes: 11,
        title: "Refining UI mockups — small tweaks",
        category: "Work", favicon: "figma.com"),

      // Wednesday (col 3) — medium card followed closely by a tiny one
      Spec(
        column: 3, startMinutes: 7 * 60, durationMinutes: 30,
        title: "Browsing X looking for design inspiration around calendars",
        category: "Distraction", favicon: "x.com"),
      Spec(
        column: 3, startMinutes: 7 * 60 + 32, durationMinutes: 6,
        title: "Quick Slack check",
        category: "Communication", favicon: "slack.com"),

      // Thursday (col 4) — mid-length card that fits comfortably
      Spec(
        column: 4, startMinutes: 8 * 60, durationMinutes: 28,
        title:
          "Researching, creating roadmap, and summarizing documents with Chat GPT for the next planning cycle",
        category: "Research", favicon: "chat.openai.com"),

      // Friday (col 5) — very short card isolated
      Spec(
        column: 5, startMinutes: 7 * 60 + 30, durationMinutes: 5,
        title: "Messaging Alex on Slack about the design review",
        category: "Communication", favicon: "slack.com"),

      // Saturday (col 6) — two back-to-back short cards
      Spec(
        column: 6, startMinutes: 9 * 60, durationMinutes: 9,
        title: "Comparing screenshots",
        category: "Work", favicon: nil),
      Spec(
        column: 6, startMinutes: 9 * 60 + 9, durationMinutes: 7,
        title: "Next card preview",
        category: "Work", favicon: nil),
    ]

    return specs.enumerated().map { index, spec in
      let startDate = Date(timeIntervalSinceReferenceDate: Double(index * 3600))
      let endDate = startDate.addingTimeInterval(Double(spec.durationMinutes * 60))
      let activity = TimelineActivity(
        id: "preview-\(index)",
        recordId: nil,
        batchId: nil,
        startTime: startDate,
        endTime: endDate,
        title: spec.title,
        summary: spec.title,
        detailedSummary: spec.title,
        category: spec.category,
        subcategory: "",
        distractions: nil,
        videoSummaryURL: nil,
        screenshot: nil,
        appSites: spec.favicon.map { AppSites(primary: $0, secondary: nil) },
        isBackupGenerated: false
      )

      let yPos = CGFloat(spec.startMinutes) * ppm + 1
      let rawHeight = CGFloat(spec.durationMinutes) * ppm
      let height = max(WeekTimelineConfig.minimumCardHeight, rawHeight - 2)
      let hoverTimeLabel =
        "\(Self.minutesLabel(fromFourAM: spec.startMinutes)) - \(Self.minutesLabel(fromFourAM: spec.startMinutes + spec.durationMinutes))"

      return WeekPositionedActivity(
        id: activity.id,
        activity: activity,
        columnIndex: spec.column,
        yPosition: yPos,
        height: height,
        durationMinutes: Double(spec.durationMinutes),
        title: spec.title,
        hoverTimeLabel: hoverTimeLabel,
        categoryName: spec.category,
        faviconPrimaryRaw: spec.favicon,
        faviconSecondaryRaw: nil,
        faviconPrimaryHost: spec.favicon,
        faviconSecondaryHost: nil
      )
    }
  }

  private static func minutesLabel(fromFourAM minutes: Int) -> String {
    let absoluteMinutes = minutes + 4 * 60
    let hour24 = (absoluteMinutes / 60) % 24
    let minute = absoluteMinutes % 60
    let period = hour24 >= 12 ? "PM" : "AM"
    let hour12: Int = {
      let raw = hour24 % 12
      return raw == 0 ? 12 : raw
    }()
    return String(format: "%d:%02d %@", hour12, minute, period)
  }
}

#Preview("Week timeline hover prototype") {
  WeekTimelineHoverPrototypeHarness()
    .environmentObject(AppState.shared)
    .environmentObject(CategoryStore.shared)
    .frame(width: 980, height: 640)
}
