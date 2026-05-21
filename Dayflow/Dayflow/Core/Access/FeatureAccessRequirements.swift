import Foundation

enum FeatureAccessRequirements {
  static let batchDurationMinutes = 15

  static let dailyRequiredHours = 5
  static let chatRequiredHours = 10

  static var dailyRequiredBatchCount: Int {
    requiredBatchCount(forHours: dailyRequiredHours)
  }

  static var chatRequiredBatchCount: Int {
    requiredBatchCount(forHours: chatRequiredHours)
  }

  static func completedBatchCount() -> Int {
    StorageManager.shared.countCompletedAnalysisBatchesForWeeklyAccess()
  }

  static func hasRequiredBatches(_ completedBatchCount: Int, requiredBatchCount: Int) -> Bool {
    completedBatchCount >= requiredBatchCount
  }

  static func progressText(completedBatchCount: Int, requiredHours: Int) -> String {
    let cappedBatchCount = min(
      max(completedBatchCount, 0), requiredBatchCount(forHours: requiredHours))
    let minutes = cappedBatchCount * batchDurationMinutes
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if minutes == 0 {
      return "0h / \(requiredHours)h"
    }

    if hours == 0 {
      return "\(remainingMinutes)m / \(requiredHours)h"
    }

    if remainingMinutes == 0 {
      return "\(hours)h / \(requiredHours)h"
    }

    return "\(hours)h \(remainingMinutes)m / \(requiredHours)h"
  }

  private static func requiredBatchCount(forHours hours: Int) -> Int {
    (hours * 60) / batchDurationMinutes
  }
}
