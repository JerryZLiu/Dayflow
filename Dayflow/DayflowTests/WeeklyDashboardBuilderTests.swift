import XCTest

@testable import Dayflow

final class WeeklyDashboardBuilderTests: XCTestCase {
  func testWeeklyDashboardSnapshotIsSendableForBackgroundLoading() {
    let weekRange = WeeklyDateRange.containing(Date(timeIntervalSince1970: 1_770_000_000))
    let snapshot = WeeklyDashboardBuilder.build(
      cards: [],
      previousWeekCards: [],
      categories: [],
      weekRange: weekRange
    )

    assertSendable(snapshot)
  }

  func testSankeyCoalescesRealOtherAppWithOverflowBucket() {
    let weekRange = WeeklyDateRange.containing(Date(timeIntervalSince1970: 1_770_000_000))
    let day = DateFormatter.yyyyMMdd.string(from: weekRange.weekStart)
    let cards = [
      card(day: day, appName: "Other", minutes: 120),
      card(day: day, appName: "App 1", minutes: 110),
      card(day: day, appName: "App 2", minutes: 100),
      card(day: day, appName: "App 3", minutes: 90),
      card(day: day, appName: "App 4", minutes: 80),
      card(day: day, appName: "App 5", minutes: 70),
      card(day: day, appName: "App 6", minutes: 60),
      card(day: day, appName: "App 7", minutes: 50),
      card(day: day, appName: "App 8", minutes: 40),
      card(day: day, appName: "App 9", minutes: 30),
      card(day: day, appName: "App 10", minutes: 20),
    ]

    let snapshot = WeeklyDashboardBuilder.build(
      cards: cards,
      previousWeekCards: [],
      categories: [TimelineCategory(name: "Focus", colorHex: "4F8EF7", order: 0)],
      weekRange: weekRange
    )

    let otherApps = snapshot.sankey.apps.filter { $0.id == "other" }
    XCTAssertEqual(otherApps.count, 1)
    XCTAssertEqual(otherApps.first?.minutes, 170)
    XCTAssertEqual(Set(snapshot.sankey.apps.map(\.id)).count, snapshot.sankey.apps.count)
  }

  private func card(day: String, appName: String, minutes: Int) -> TimelineCard {
    TimelineCard(
      recordId: nil,
      batchId: nil,
      startTimestamp: "09:00 AM",
      endTimestamp: endTime(minutesAfterNine: minutes),
      category: "Focus",
      subcategory: "Work",
      title: "\(appName) work",
      summary: "Worked in \(appName)",
      detailedSummary: "",
      day: day,
      distractions: nil,
      videoSummaryURL: nil,
      otherVideoSummaryURLs: nil,
      appSites: AppSites(primary: appName, secondary: nil)
    )
  }

  private func endTime(minutesAfterNine minutes: Int) -> String {
    let totalMinutes = 9 * 60 + minutes
    let hour = totalMinutes / 60
    let minute = totalMinutes % 60
    if hour == 12 {
      return String(format: "12:%02d PM", minute)
    }
    if hour > 12 {
      return String(format: "%d:%02d PM", hour - 12, minute)
    }
    return String(format: "%d:%02d AM", hour, minute)
  }

  private func assertSendable<T: Sendable>(_ value: T) {
    _ = value
  }
}
