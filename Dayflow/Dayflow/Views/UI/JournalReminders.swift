import SwiftUI
import AppKit
import UserNotifications

struct JournalRemindersView: View {
    // Callbacks for dismissal
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    @State private var intentionHour = "9"
    @State private var intentionMinute = "00"
    @State private var intentionPeriod: Period = .am

    @State private var reflectionHour = "5"
    @State private var reflectionMinute = "00"
    @State private var reflectionPeriod: Period = .pm

    @State private var selectedDays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    @FocusState private var focusedField: Field?
    @State private var highlightedField: Field?
    private let labelColumnWidth: CGFloat = 146

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Set reminders")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .kerning(-0.22)
                    .foregroundColor(JournalReminderTokens.primaryText)
                Text("Set recurring notifications to remind yourself to set your intentions and reflect.")
                    .font(.custom("Nunito-Regular", size: 12))
                    .kerning(-0.12)
                    .foregroundColor(JournalReminderTokens.primaryText.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 20) {
                timeRow(
                    label: "Set intentions at",
                    hour: $intentionHour,
                    minute: $intentionMinute,
                    period: $intentionPeriod,
                    hourField: .intentionHour,
                    minuteField: .intentionMinute,
                    periodField: .intentionPeriod
                )

                timeRow(
                    label: "Write reflections at",
                    hour: $reflectionHour,
                    minute: $reflectionMinute,
                    period: $reflectionPeriod,
                    hourField: .reflectionHour,
                    minuteField: .reflectionMinute,
                    periodField: .reflectionPeriod
                )

                repeatOnRow
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .background(Color.white)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "F2F2F2"), lineWidth: 1)
            )

            HStack(spacing: 12) {
                // Test button (fires notification in 3 seconds)
                Button("Test", action: sendTestNotification)
                    .buttonStyle(
                        JournalReminderPillButtonStyle(
                            background: JournalReminderTokens.inputBackground,
                            foreground: JournalReminderTokens.primaryText,
                            borderColor: JournalReminderTokens.cancelBorder
                        )
                    )
                    .journalHoverable()

                Spacer()

                Button("Cancel", action: { onCancel?() })
                    .buttonStyle(
                        JournalReminderPillButtonStyle(
                            background: JournalReminderTokens.cancelFill,
                            foreground: JournalReminderTokens.cancelText,
                            borderColor: JournalReminderTokens.cancelBorder
                        )
                    )
                    .journalHoverable()

                Button("Save", action: saveReminders)
                    .buttonStyle(
                        JournalReminderPillButtonStyle(
                            background: JournalReminderTokens.saveFill,
                            foreground: .white
                        )
                    )
                    .journalHoverable()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(JournalReminderTokens.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white, lineWidth: 1)
                )
        )
        .environment(\.colorScheme, .light)
        .onAppear(perform: loadSavedPreferences)
    }

    // MARK: - Save/Load

    private func loadSavedPreferences() {
        // Load from NotificationPreferences if reminders were previously enabled
        guard NotificationPreferences.isEnabled else { return }

        let savedIntentionHour = NotificationPreferences.intentionHour
        let savedIntentionMinute = NotificationPreferences.intentionMinute
        let savedReflectionHour = NotificationPreferences.reflectionHour
        let savedReflectionMinute = NotificationPreferences.reflectionMinute
        let savedWeekdays = NotificationPreferences.weekdays

        // Convert 24-hour to 12-hour format for intention
        let (intHour12, intPeriod) = convert24to12(hour: savedIntentionHour)
        intentionHour = "\(intHour12)"
        intentionMinute = String(format: "%02d", savedIntentionMinute)
        intentionPeriod = intPeriod

        // Convert 24-hour to 12-hour format for reflection
        let (refHour12, refPeriod) = convert24to12(hour: savedReflectionHour)
        reflectionHour = "\(refHour12)"
        reflectionMinute = String(format: "%02d", savedReflectionMinute)
        reflectionPeriod = refPeriod

        // Convert Calendar weekdays (1=Sun) to Weekday enum (0=Sun)
        selectedDays = Set(savedWeekdays.compactMap { calWeekday in
            Weekday(rawValue: NotificationPreferences.viewWeekday(from: calWeekday))
        })
    }

    private func saveReminders() {
        // Validate at least one day is selected
        guard !selectedDays.isEmpty else { return }

        // Convert 12-hour to 24-hour format
        let intentionHour24 = convert12to24(hour: Int(intentionHour) ?? 9, period: intentionPeriod)
        let reflectionHour24 = convert12to24(hour: Int(reflectionHour) ?? 5, period: reflectionPeriod)

        // Save to preferences
        NotificationPreferences.intentionHour = intentionHour24
        NotificationPreferences.intentionMinute = Int(intentionMinute) ?? 0
        NotificationPreferences.reflectionHour = reflectionHour24
        NotificationPreferences.reflectionMinute = Int(reflectionMinute) ?? 0

        // Convert Weekday enum (0=Sun) to Calendar weekdays (1=Sun)
        NotificationPreferences.weekdays = Set(selectedDays.map { weekday in
            NotificationPreferences.calendarWeekday(from: weekday.rawValue)
        })

        // Request permission and schedule notifications
        Task {
            await NotificationService.shared.requestPermission()
            NotificationService.shared.scheduleReminders()
        }

        onSave?()
    }

    // MARK: - Time Conversion Helpers

    private func convert12to24(hour: Int, period: Period) -> Int {
        var hour24 = hour
        if period == .am {
            if hour == 12 { hour24 = 0 }
        } else {
            if hour != 12 { hour24 = hour + 12 }
        }
        return hour24
    }

    private func convert24to12(hour: Int) -> (Int, Period) {
        if hour == 0 {
            return (12, .am)
        } else if hour < 12 {
            return (hour, .am)
        } else if hour == 12 {
            return (12, .pm)
        } else {
            return (hour - 12, .pm)
        }
    }

    private func sendTestNotification() {
        Task {
            // Request permission first if needed
            await NotificationService.shared.requestPermission()

            // Schedule a test notification in 3 seconds
            let content = UNMutableNotificationContent()
            content.title = "Test: Set your intentions"
            content.body = "This is a test notification from Dayflow."
            content.sound = .default
            content.categoryIdentifier = "journal_reminder"

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
            let request = UNNotificationRequest(
                identifier: "journal.test.\(Date().timeIntervalSince1970)",
                content: content,
                trigger: trigger
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
                print("[JournalReminders] Test notification scheduled for 3 seconds")

                // Also set badge directly after delay (for testing - delegate should also set it)
                try await Task.sleep(nanoseconds: 3_500_000_000) // 3.5 seconds
                await MainActor.run {
                    NotificationBadgeManager.shared.showBadge()
                    print("[JournalReminders] Badge set directly after test notification")
                }
            } catch {
                print("[JournalReminders] Failed to schedule test notification: \(error)")
            }
        }
    }

    private func timeRow(
        label: String,
        hour: Binding<String>,
        minute: Binding<String>,
        period: Binding<Period>,
        hourField: Field,
        minuteField: Field,
        periodField: Field
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(.custom("Nunito-Regular", size: 14))
                .kerning(-0.14)
                .foregroundColor(JournalReminderTokens.primaryText)
                .frame(width: labelColumnWidth, alignment: .leading)

            HStack(spacing: 8) {
                TimeDigitField(text: hour, field: hourField, focusedField: $focusedField)
                Text(":")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .baselineOffset(-1)
                TimeDigitField(text: minute, field: minuteField, focusedField: $focusedField)
                PeriodDropdown(
                    selection: period,
                    field: periodField,
                    highlightedField: $highlightedField
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var repeatOnRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Repeat on")
                .font(.custom("Nunito-Regular", size: 14))
                .kerning(-0.14)
                .foregroundColor(JournalReminderTokens.primaryText)

            DayChipRow(selectedDays: $selectedDays)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Subviews

private struct TimeDigitField: View {
    @Binding var text: String
    let field: JournalRemindersView.Field
    let focusedField: FocusState<JournalRemindersView.Field?>.Binding
    @State private var isHovering = false

    var body: some View {
        let isActive = focusedField.wrappedValue == field

        ReminderField(
            width: nil,
            isActive: isActive,
            highlighted: isActive || isHovering
        ) {
            TextField("", text: Binding(
                get: { text },
                set: { newValue in
                    text = newValue
                        .filter { $0.isNumber }
                        .trimmingCharacters(in: .whitespaces)
                }
            ))
            .font(Font.custom("Nunito-Medium", size: 14))
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .focused(focusedField, equals: field)
            .frame(maxWidth: .infinity)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .journalHoverable()
    }
}

private struct PeriodDropdown: View {
    @Binding var selection: JournalRemindersView.Period
    let field: JournalRemindersView.Field
    @Binding var highlightedField: JournalRemindersView.Field?
    @State private var isHovering = false

    var body: some View {
        Button {
            selection = selection == .am ? .pm : .am
            highlightedField = field
        } label: {
            ReminderField(
                width: nil,
                isActive: false,
                highlighted: isHovering,
                alignment: .leading
            ) {
                Text(selection.display.uppercased())
                    .font(.custom("Nunito-Medium", size: 14))
                    .foregroundColor(JournalReminderTokens.primaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            highlightedField = hovering ? field : nil
        }
        .journalHoverable()
    }
}

private struct DayChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Nunito-Regular", size: 12))
                .kerning(-0.12)
                .frame(width: 32, height: 32)
                .background(isSelected ? JournalReminderTokens.accent : JournalReminderTokens.dayIdleBackground)
                .foregroundColor(isSelected ? .white : JournalReminderTokens.dayIdleText)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(JournalReminderTokens.dayIdleStroke, lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .journalHoverable()
    }
}

private struct DayChipRow: View {
    @Binding var selectedDays: Set<JournalRemindersView.Weekday>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(JournalRemindersView.Weekday.allCases) { day in
                DayChip(
                    title: day.shortLabel,
                    isSelected: selectedDays.contains(day)
                ) {
                    if selectedDays.contains(day) {
                        selectedDays.remove(day)
                    } else {
                        selectedDays.insert(day)
                    }
                }
            }
        }
    }
}

private struct JournalReminderPillButtonStyle: ButtonStyle {
    let background: Color
    let foreground: Color
    let borderColor: Color?

    init(background: Color, foreground: Color, borderColor: Color? = nil) {
        self.background = background
        self.foreground = foreground
        self.borderColor = borderColor
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Nunito-SemiBold", size: 14))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(background.opacity(configuration.isPressed ? 0.85 : 1))
            .foregroundColor(foreground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor ?? .clear, lineWidth: borderColor == nil ? 0 : 1)
            )
    }
}

private struct ReminderField<Content: View>: View {
    let width: CGFloat?
    let isActive: Bool
    let highlighted: Bool
    let alignment: Alignment
    @ViewBuilder let content: () -> Content

    init(
        width: CGFloat?,
        isActive: Bool,
        highlighted: Bool = false,
        alignment: Alignment = .center,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.width = width
        self.isActive = isActive
        self.highlighted = highlighted
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        let shouldExpand = width != nil
        let fieldHeight: CGFloat = 26 // keep baseline consistent whether focused or not

        content()
            .frame(maxWidth: shouldExpand ? .infinity : nil, alignment: alignment)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .frame(height: fieldHeight)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(width: width, alignment: alignment)
            .background(JournalReminderTokens.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .inset(by: 0.5)
                    .stroke(
                        isActive ? JournalReminderTokens.inputStroke : (highlighted ? JournalReminderTokens.focusStroke : .clear),
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}


// MARK: - Tokens & Models

extension JournalRemindersView {
    enum Period: String, CaseIterable, Identifiable {
        case am
        case pm

        var id: String { rawValue }
        var display: String { rawValue }
    }

    enum Weekday: Int, CaseIterable, Identifiable {
        case sunday
        case monday
        case tuesday
        case wednesday
        case thursday
        case friday
        case saturday

        var id: Int { rawValue }

        var shortLabel: String {
            switch self {
            case .sunday, .saturday:
                return "S"
            case .monday:
                return "M"
            case .tuesday:
                return "T"
            case .wednesday:
                return "W"
            case .thursday:
                return "T"
            case .friday:
                return "F"
            }
        }
    }

    enum Field: Hashable {
        case intentionHour
        case intentionMinute
        case intentionPeriod
        case reflectionHour
        case reflectionMinute
        case reflectionPeriod
    }
}

private enum JournalReminderTokens {
    static let canvas = Color(hex: "FAF7F3")
    static let accent = Color(hex: "FFB859")
    static let saveFill = Color(hex: "553000")
    static let cancelFill = Color(hex: "F1ECE7")
    static let cancelBorder = Color(hex: "E1D7CC")
    static let cancelText = Color(hex: "9F8D80")
    static let neutral = Color(hex: "F2EFEE")
    static let secondaryText = Color(hex: "9F8D80")
    static let primaryText = Color(hex: "333333")
    static let inputBackground = Color(hex: "F9F3EC")
    static let inputStroke = Color(hex: "FF9B4C")
    static let inactiveStroke = Color(hex: "E8DCCF")
    static let focusStroke = Color(red: 1, green: 0.61, blue: 0.3)
    static let timeSeparator = Color(hex: "B7A391")
    static let dropdownIndicator = Color(hex: "8F6B4A")
    static let dayIdleBackground = Color(hex: "FBF7F1")
    static let dayIdleStroke = Color(hex: "F6E1CA")
    static let dayIdleText = Color(hex: "B9A595")
}

// MARK: - Hover interactions

private struct HoverInteractionModifier: ViewModifier {
    let scale: CGFloat

    @State private var hovering = false
    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .onHover { inside in
                hovering = inside
                if inside, cursorPushed == false {
                    NSCursor.pointingHand.push()
                    cursorPushed = true
                } else if !inside, cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
    }
}

private extension View {
    func journalHoverable(scale: CGFloat = 1.05) -> some View {
        modifier(HoverInteractionModifier(scale: scale))
    }
}

// MARK: - Preview

struct JournalRemindersView_Previews: PreviewProvider {
    static var previews: some View {
        JournalRemindersView()
            .padding()
            .frame(width: 480, height: 376)
            .background(Color(hex: "E9E5E0"))
            .preferredColorScheme(.light)
            .previewDisplayName("Journal Reminders")
    }
}
