//
//  DayflowNotifications.swift
//  Dayflow
//
//  Extension points for personal plugins and integrations.
//  Upstream files post these notifications once — observers never require
//  additional upstream changes.
//

import Foundation

extension Notification.Name {
  // Posted by DailyRecapScheduler after a successful daily recap.
  // object: String — the day string (YYYY-MM-DD)
  static let dayflowDailyRecapCompleted = Notification.Name("dayflow.dailyRecapCompleted")
}
