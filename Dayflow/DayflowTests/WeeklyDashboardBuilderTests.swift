import XCTest

@testable import Dayflow

final class WeeklyDashboardBuilderTests: XCTestCase {
  func testWeeklyDistributionExcludesIdleFromDonutTotal() {
    let weekRange = WeeklyDateRange.containing(Date(timeIntervalSince1970: 1_770_000_000))
    let day = DateFormatter.yyyyMMdd.string(from: weekRange.weekStart)
    let categories = [
      TimelineCategory(name: "Focus", colorHex: "4F8EF7", order: 0),
      TimelineCategory(name: "Idle", colorHex: "C7BDB5", order: 1, isIdle: true),
    ]
    let cards = [
      card(day: day, category: "Focus", appName: "Xcode", minutes: 60),
      card(day: day, category: "Idle", appName: "Idle", minutes: 120),
    ]

    let snapshot = WeeklyDashboardBuilder.build(
      cards: cards,
      previousWeekCards: [],
      categories: categories,
      weekRange: weekRange
    )

    XCTAssertEqual(snapshot.donut.totalMinutes, 60)
    XCTAssertEqual(snapshot.donut.items.map(\.name), ["Focus"])
  }

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

  func testWorkflowAndHeatmapPutAfterMidnightWorkOnTheNextCalendarDay() {
    let weekRange = WeeklyDateRange.containing(Date(timeIntervalSince1970: 1_770_000_000))
    func day(_ offset: Int) -> String {
      DateFormatter.yyyyMMdd.string(
        from: Calendar.current.date(byAdding: .day, value: offset, to: weekRange.weekStart)!)
    }
    // Last week's Sunday night after midnight is this week's Monday. The range fetches
    // overlap, so a card near the boundary can come back in both lists.
    let sundayNight = card(day: day(-1), appName: "Xcode", start: "1:00 AM", end: "2:00 AM")
    let cards = [
      sundayNight,
      // Friday 11:30 PM - Saturday 1 AM, recorded under Friday's 4 AM logical day.
      card(day: day(4), appName: "Xcode", start: "11:30 PM", end: "1:00 AM"),
      // Sunday night after midnight is next week's Monday.
      card(day: day(6), appName: "Xcode", start: "2:00 AM", end: "3:00 AM"),
    ]
    let previousWeekCards = [sundayNight]

    let snapshot = WeeklyDashboardBuilder.build(
      cards: cards,
      previousWeekCards: previousWeekCards,
      categories: [TimelineCategory(name: "Focus", colorHex: "4F8EF7", order: 0)],
      weekRange: weekRange
    )

    let minutesByDay = Dictionary(
      uniqueKeysWithValues: snapshot.workflow.rows.map {
        ($0.id, $0.cells.reduce(0) { $0 + $1.minutes })
      })
    XCTAssertEqual(
      minutesByDay, ["mon": 60, "tue": 0, "wed": 0, "thu": 0, "fri": 30, "sat": 60, "sun": 0])
    XCTAssertEqual(snapshot.workflow.startMinute, 0)
    XCTAssertEqual(snapshot.workflow.endMinute, 24 * 60)
    XCTAssertEqual(snapshot.workflow.totals.map(\.minutes), [150])
    let activeHeatmapDays = snapshot.heatmap.rows.filter { $0.values.contains { $0 != 0 } }.map(\.id)
    XCTAssertEqual(Set(activeHeatmapDays), ["mon", "fri", "sat"])
  }

  private func card(
    day: String,
    category: String = "Focus",
    appName: String,
    minutes: Int = 0,
    start: String = "09:00 AM",
    end: String? = nil
  ) -> TimelineCard {
    TimelineCard(
      recordId: nil,
      batchId: nil,
      startTimestamp: start,
      endTimestamp: end ?? endTime(minutesAfterNine: minutes),
      category: category,
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
