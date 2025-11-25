//
//  NotificationBadgeManager.swift
//  Dayflow
//
//  Manages badge state for Dock icon and sidebar indicator.
//

import SwiftUI
import AppKit

@MainActor
final class NotificationBadgeManager: ObservableObject {
    static let shared = NotificationBadgeManager()

    /// Whether there's a pending journal reminder the user hasn't acknowledged
    @Published private(set) var hasPendingReminder: Bool = false

    private init() {}

    // MARK: - Public Methods

    /// Shows the badge on both Dock icon and updates state for sidebar
    func showBadge() {
        hasPendingReminder = true
        NSApplication.shared.dockTile.badgeLabel = "1"
    }

    /// Clears the badge from Dock icon and sidebar
    func clearBadge() {
        hasPendingReminder = false
        NSApplication.shared.dockTile.badgeLabel = nil
    }
}
