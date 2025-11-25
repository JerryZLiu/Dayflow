//
//  NotificationPreferences.swift
//  Dayflow
//
//  Stores journal reminder notification settings in UserDefaults.
//

import Foundation

enum NotificationPreferences {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys
    private static let enabledKey = "journalRemindersEnabled"
    private static let intentionHourKey = "journalIntentionHour"
    private static let intentionMinuteKey = "journalIntentionMinute"
    private static let reflectionHourKey = "journalReflectionHour"
    private static let reflectionMinuteKey = "journalReflectionMinute"
    private static let weekdaysKey = "journalReminderWeekdays"

    // MARK: - Defaults
    private static let defaultIntentionHour = 9      // 9 AM
    private static let defaultIntentionMinute = 0
    private static let defaultReflectionHour = 17    // 5 PM
    private static let defaultReflectionMinute = 0
    private static let defaultWeekdays: Set<Int> = [2, 3, 4, 5, 6] // Mon-Fri (Calendar weekday: 1=Sun, 2=Mon...)

    // MARK: - Properties

    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Hour in 24-hour format (0-23)
    static var intentionHour: Int {
        get {
            if defaults.object(forKey: intentionHourKey) == nil {
                return defaultIntentionHour
            }
            return defaults.integer(forKey: intentionHourKey)
        }
        set { defaults.set(newValue, forKey: intentionHourKey) }
    }

    static var intentionMinute: Int {
        get {
            if defaults.object(forKey: intentionMinuteKey) == nil {
                return defaultIntentionMinute
            }
            return defaults.integer(forKey: intentionMinuteKey)
        }
        set { defaults.set(newValue, forKey: intentionMinuteKey) }
    }

    /// Hour in 24-hour format (0-23)
    static var reflectionHour: Int {
        get {
            if defaults.object(forKey: reflectionHourKey) == nil {
                return defaultReflectionHour
            }
            return defaults.integer(forKey: reflectionHourKey)
        }
        set { defaults.set(newValue, forKey: reflectionHourKey) }
    }

    static var reflectionMinute: Int {
        get {
            if defaults.object(forKey: reflectionMinuteKey) == nil {
                return defaultReflectionMinute
            }
            return defaults.integer(forKey: reflectionMinuteKey)
        }
        set { defaults.set(newValue, forKey: reflectionMinuteKey) }
    }

    /// Calendar weekday values: 1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday
    static var weekdays: Set<Int> {
        get {
            guard let array = defaults.array(forKey: weekdaysKey) as? [Int] else {
                return defaultWeekdays
            }
            return Set(array)
        }
        set {
            defaults.set(Array(newValue), forKey: weekdaysKey)
        }
    }

    // MARK: - Convenience

    /// Converts JournalRemindersView.Weekday rawValue (0=Sunday) to Calendar weekday (1=Sunday)
    static func calendarWeekday(from viewWeekday: Int) -> Int {
        return viewWeekday + 1
    }

    /// Converts Calendar weekday (1=Sunday) to JournalRemindersView.Weekday rawValue (0=Sunday)
    static func viewWeekday(from calendarWeekday: Int) -> Int {
        return calendarWeekday - 1
    }
}
