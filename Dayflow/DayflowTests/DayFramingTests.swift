import XCTest

@testable import Dayflow

final class DayFramingTests: XCTestCase {
  private var originalBoundaryHour = 4
  private var originalLabelMode = DayLabelMode.startDate

  override func setUp() {
    super.setUp()
    originalBoundaryHour = DayBoundaryPreferences.boundaryHour
    originalLabelMode = DayLabelPreferences.mode
  }

  override func tearDown() {
    DayBoundaryPreferences.boundaryHour = originalBoundaryHour
    DayLabelPreferences.mode = originalLabelMode
    super.tearDown()
  }

  func testEndDateMapsLabelBackToStartDateAtFourAMAndFourPM() {
    DayLabelPreferences.mode = .endDate

    for boundaryHour in [4, 16] {
      DayBoundaryPreferences.boundaryHour = boundaryHour
      let labelDate = date(2026, 7, 6, hour: boundaryHour)

      XCTAssertEqual(
        DateFormatter.yyyyMMdd.string(from: labelDate.timelineDateFromLabel()),
        "2026-07-05"
      )
      XCTAssertEqual(
        DateFormatter.yyyyMMdd.string(from: labelDate.timelineDateFromLabel().timelineLabelDate()),
        "2026-07-06"
      )
    }
  }

  func testEndDateIsIdentityAtMidnightBoundary() {
    DayBoundaryPreferences.boundaryHour = 0
    DayLabelPreferences.mode = .endDate
    let date = date(2026, 7, 6, hour: 0)

    XCTAssertEqual(date.timelineDateFromLabel(), date)
    XCTAssertEqual(date.timelineLabelDate(), date)
  }

  func testTimelineWeekKeepsNaturalColumnsAndUsesMappedStorageDays() {
    DayBoundaryPreferences.boundaryHour = 16
    DayLabelPreferences.mode = .endDate
    let range = TimelineWeekRange.containingLabelDate(date(2026, 7, 8, hour: 12))

    XCTAssertEqual(range.days.map(\.weekdayLabel), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    XCTAssertEqual(range.days.map(\.dayString).first, "2026-07-06")
    XCTAssertEqual(range.days.map(\.storageDayString).first, "2026-07-05")
    XCTAssertEqual(DateFormatter.yyyyMMdd.string(from: range.storageRange.start), "2026-07-05")
    XCTAssertEqual(DateFormatter.yyyyMMdd.string(from: range.storageRange.end), "2026-07-12")
  }

  func testWeeklyDescriptorsMapStorageKeysWithoutMovingLabels() {
    DayBoundaryPreferences.boundaryHour = 4
    DayLabelPreferences.mode = .endDate
    let range = WeeklyDateRange.containingLabelDate(date(2026, 7, 8, hour: 12))
    let descriptors = WeeklyDashboardBuilder.dayDescriptors(for: range, offsets: Array(0..<7))

    XCTAssertEqual(descriptors.map(\.label), ["Mon", "Tue", "Wed", "Thur", "Fri", "Sat", "Sun"])
    XCTAssertEqual(descriptors.map(\.dayString).first, "2026-07-05")
    XCTAssertEqual(descriptors.map(\.dayString).last, "2026-07-11")
  }

  func testStartDateKeepsDisplayAndStorageDatesAligned() {
    DayBoundaryPreferences.boundaryHour = 16
    DayLabelPreferences.mode = .startDate
    let range = TimelineWeekRange.containingLabelDate(date(2026, 7, 8, hour: 12))

    XCTAssertEqual(range.days.map(\.dayString), range.days.map(\.storageDayString))
    XCTAssertEqual(DateFormatter.yyyyMMdd.string(from: range.storageRange.start), "2026-07-06")
  }

  func testUserFacingDayStringNeverLeaksEndDateStorageKey() {
    DayBoundaryPreferences.boundaryHour = 16
    DayLabelPreferences.mode = .endDate
    let storageDate = date(2026, 7, 10, hour: 16)

    XCTAssertEqual(DateFormatter.yyyyMMdd.string(from: storageDate), "2026-07-10")
    XCTAssertEqual(storageDate.timelineLabelDayString, "2026-07-11")
  }

  func testChatPromptDescribesConfiguredEndDateStorageMapping() {
    DayBoundaryPreferences.boundaryHour = 16
    DayLabelPreferences.mode = .endDate

    let prompt = ChatPromptBuilder.cliSystemPrompt()
    XCTAssertTrue(prompt.contains("4:00 PM-to-4:00 PM"))
    XCTAssertTrue(prompt.contains("labeled by their END date"))
    XCTAssertTrue(prompt.contains("subtract one calendar day"))
    XCTAssertFalse(prompt.contains("Days start at 4:00 AM"))
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar.current
    components.timeZone = Calendar.current.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    return components.date!
  }
}
