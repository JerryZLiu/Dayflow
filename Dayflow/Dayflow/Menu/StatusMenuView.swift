import SwiftUI
import AppKit

@MainActor
struct StatusMenuView: View {
    let dismissMenu: () -> Void
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var pauseManager = PauseManager.shared
    private let updaterManager = UpdaterManager.shared

    var body: some View {
        VStack(spacing: 6) {
            // Pause/Resume section
            if pauseManager.isPaused {
                PausedSection(onResume: resumeRecording)
            } else {
                PauseSection(onPause: pauseRecording)
            }

            MenuDivider()

            MenuRow(title: "Open Dayflow", systemImage: "macwindow", action: openDayflow)
            MenuRow(title: "Open Recordings", systemImage: "folder", action: openRecordingsFolder)
            MenuRow(title: "Check for Updates", systemImage: "arrow.triangle.2.circlepath", action: checkForUpdates)

            MenuDivider()

            MenuRow(title: "Quit Completely", systemImage: "power", accent: .red, action: quitDayflow)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 9)
        .frame(minWidth: 200, maxWidth: 210)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pauseRecording(duration: PauseDuration) {
        pauseManager.pause(for: duration, source: .menuBar)
    }

    private func resumeRecording() {
        pauseManager.resume(source: .userClickedMenuBar)
    }

    private func openDayflow() {
        let menuWindowNumber = NSApp.keyWindow?.windowNumber

        performAfterMenuDismiss {
            NSApp.setActivationPolicy(.regular)
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)

            var showedWindow = false
            for window in NSApp.windows
            where window.canBecomeKey && window.windowNumber != menuWindowNumber {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                showedWindow = true
            }

            if !showedWindow {
                MainWindowManager.shared.showMainWindow()
            }
        }
    }

    private func openRecordingsFolder() {
        performAfterMenuDismiss {
            let directory = StorageManager.shared.recordingsRoot
            NSWorkspace.shared.open(directory)
        }
    }

    private func checkForUpdates() {
        performAfterMenuDismiss {
            updaterManager.checkForUpdates(showUI: true)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func quitDayflow() {
        performAfterMenuDismiss {
            AppDelegate.allowTermination = true
            NSApp.terminate(nil)
        }
    }

    private func performAfterMenuDismiss(_ action: @escaping () -> Void) {
        dismissMenu()

        DispatchQueue.main.async {
            DispatchQueue.main.async {
                action()
            }
        }
    }
}

// MARK: - Pause Section (Not Paused State)

private struct PauseSection: View {
    let onPause: (PauseDuration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            Text("Pause Dayflow")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)

            // Duration picker
            DurationPicker(onSelect: onPause)
        }
    }
}

// MARK: - Duration Picker

private struct DurationPicker: View {
    let onSelect: (PauseDuration) -> Void

    private let options: [(label: String, duration: PauseDuration)] = [
        ("15 Min", .minutes15),
        ("30 Min", .minutes30),
        ("1 Hour", .hour1),
        ("∞", .indefinite)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                DurationOption(
                    label: option.label,
                    isFirst: index == 0,
                    isLast: index == options.count - 1,
                    onTap: { onSelect(option.duration) }
                )

                if index < options.count - 1 {
                    Divider()
                        .frame(height: 16)
                        .opacity(0.3)
                }
            }
        }
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct DurationOption: View {
    let label: String
    let isFirst: Bool
    let isLast: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? .white : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Group {
                        if isHovering {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Paused Section (Active Pause State)

private struct PausedSection: View {
    let onResume: () -> Void
    @ObservedObject private var pauseManager = PauseManager.shared

    var body: some View {
        VStack(spacing: 6) {
            // Countdown badge (only shown for timed pause)
            if let timeString = pauseManager.remainingTimeFormatted {
                CountdownBadge(remainingTime: timeString)
            }

            // Resume button
            MenuRow(
                title: "Resume Dayflow",
                systemImage: "play.circle",
                accent: .accentColor,
                action: onResume
            )
        }
    }
}

// MARK: - Countdown Badge

private struct CountdownBadge: View {
    let remainingTime: String

    var body: some View {
        HStack(spacing: 0) {
            Text("Dayflow paused for ")
                .font(.system(size: 11, weight: .medium))
            Text(remainingTime)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Menu Row

private struct MenuRow: View {
    let title: String
    let systemImage: String
    var accent: Color = .primary
    var keepsMenuOpen: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 17)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 3.5)
            .padding(.horizontal, 5)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func handleTap() {
        action()
    }
}

// MARK: - Menu Divider

private struct MenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.75)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }
}
