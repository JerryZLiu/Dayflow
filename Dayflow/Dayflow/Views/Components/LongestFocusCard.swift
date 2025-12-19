//
//  LongestFocusCard.swift
//  Dayflow
//
//  A card showing the longest focus duration with a timeline visualization
//

import SwiftUI

// MARK: - Data Model

struct FocusBlock: Identifiable {
    let id: UUID
    let startTime: Date
    let endTime: Date

    init(id: UUID = UUID(), startTime: Date, endTime: Date) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

// MARK: - Main View

struct LongestFocusCard: View {
    let focusBlocks: [FocusBlock]

    // MARK: - Design Constants

    private enum Design {
        // Colors
        static let backgroundColor = Color(hex: "f7f7f7")
        static let borderColor = Color(hex: "ececec")
        static let titleColor = Color(hex: "333333")
        static let orangeSolid = Color(hex: "f3854b")
        static let orangeLight = Color(hex: "f3854b").opacity(0.4)
        static let dotColor = Color(hex: "f3854b").opacity(0.3)
        static let lineColor = Color(hex: "e0e0e0")

        // Sizing
        static let cardCornerRadius: CGFloat = 8
        static let blockCornerRadius: CGFloat = 6
        static let tallBlockHeight: CGFloat = 50
        static let shortBlockHeight: CGFloat = 28
        static let dotSize: CGFloat = 4
        static let timelinePadding: CGFloat = 16
    }

    // MARK: - Computed Properties

    private var longestBlock: FocusBlock? {
        focusBlocks.max(by: { $0.duration < $1.duration })
    }

    private var formattedDuration: String {
        guard let longest = longestBlock else { return "0 minutes" }
        let totalMinutes = Int(longest.duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours) hours \(minutes) minutes"
        } else if hours > 0 {
            return "\(hours) hours"
        } else {
            return "\(minutes) minutes"
        }
    }

    private var timeRange: (start: Date, end: Date)? {
        guard !focusBlocks.isEmpty else { return nil }
        let allTimes = focusBlocks.flatMap { [$0.startTime, $0.endTime] }
        guard let minTime = allTimes.min(), let maxTime = allTimes.max() else { return nil }

        // Expand to full hours for cleaner display
        let calendar = Calendar.current
        let startHour = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: minTime))!
        let endHour = calendar.date(byAdding: .hour, value: 1, to: calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: maxTime))!)!

        return (startHour, endHour)
    }

    private var hourMarkers: [Date] {
        guard let range = timeRange else { return [] }
        var markers: [Date] = []
        var current = range.start
        while current <= range.end {
            markers.append(current)
            current = Calendar.current.date(byAdding: .hour, value: 1, to: current)!
        }
        return markers
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            Text("Longest focus duration")
                .font(.custom("InstrumentSerif-Regular", size: 16))
                .foregroundColor(Design.titleColor)
                .padding(.top, 12)
                .padding(.horizontal, 14)

            // Duration value
            Text(formattedDuration)
                .font(.custom("InstrumentSerif-Regular", size: 24))
                .foregroundColor(Design.orangeSolid)
                .padding(.top, 2)
                .padding(.horizontal, 13)

            // Timeline visualization
            GeometryReader { geometry in
                timelineVisualization(width: geometry.size.width - (Design.timelinePadding * 2))
                    .padding(.horizontal, Design.timelinePadding)
            }
            .frame(height: 100)
            .padding(.top, 16)
        }
        .padding(.bottom, 16)
        .background(Design.backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardCornerRadius)
                .stroke(Design.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCornerRadius))
    }

    // MARK: - Timeline Visualization

    private func timelineVisualization(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // Timeline axis with dots
            timelineAxis(width: width)
                .offset(y: -20) // Space for time labels below

            // Focus blocks
            focusBlocksView(width: width)
                .offset(y: -24) // Sit on top of timeline

            // Time labels (only for longest block)
            if let longest = longestBlock, let range = timeRange {
                timeLabels(for: longest, totalWidth: width, range: range)
            }
        }
    }

    private func timelineAxis(width: CGFloat) -> some View {
        let dotCount = hourMarkers.count
        let spacing = dotCount > 1 ? width / CGFloat(dotCount - 1) : width

        return ZStack {
            // Connecting line
            Rectangle()
                .fill(Design.lineColor)
                .frame(width: width, height: 1)

            // Hour dots
            HStack(spacing: 0) {
                ForEach(0..<dotCount, id: \.self) { index in
                    Circle()
                        .fill(Design.dotColor)
                        .frame(width: Design.dotSize, height: Design.dotSize)

                    if index < dotCount - 1 {
                        Spacer()
                    }
                }
            }
            .frame(width: width)
        }
    }

    @ViewBuilder
    private func focusBlocksView(width: CGFloat) -> some View {
        if let range = timeRange {
            let totalDuration = range.end.timeIntervalSince(range.start)

            ZStack(alignment: .bottom) {
                ForEach(focusBlocks) { block in
                    let isLongest = block.id == longestBlock?.id
                    let blockX = xPosition(for: block.startTime, in: range, width: width)
                    let blockWidth = (block.duration / totalDuration) * width

                    RoundedRectangle(cornerRadius: Design.blockCornerRadius)
                        .fill(isLongest ? Design.orangeSolid : Design.orangeLight)
                        .frame(
                            width: max(blockWidth, 8), // Minimum width for visibility
                            height: isLongest ? Design.tallBlockHeight : Design.shortBlockHeight
                        )
                        .position(
                            x: blockX + blockWidth / 2,
                            y: isLongest ? Design.tallBlockHeight / 2 : Design.shortBlockHeight / 2
                        )
                }
            }
            .frame(width: width, height: Design.tallBlockHeight)
        }
    }

    private func timeLabels(for block: FocusBlock, totalWidth: CGFloat, range: (start: Date, end: Date)) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        let startX = xPosition(for: block.startTime, in: range, width: totalWidth)
        let endX = xPosition(for: block.endTime, in: range, width: totalWidth)

        return ZStack {
            // Start time label
            Text(formatter.string(from: block.startTime))
                .font(.custom("Nunito-Bold", size: 10))
                .foregroundColor(Design.orangeSolid)
                .position(x: startX, y: 0)

            // End time label
            Text(formatter.string(from: block.endTime))
                .font(.custom("Nunito-Bold", size: 10))
                .foregroundColor(Design.orangeSolid)
                .position(x: endX, y: 0)
        }
        .frame(height: 14)
    }

    // MARK: - Helper Functions

    private func xPosition(for date: Date, in range: (start: Date, end: Date), width: CGFloat) -> CGFloat {
        let totalDuration = range.end.timeIntervalSince(range.start)
        let offset = date.timeIntervalSince(range.start)
        return (offset / totalDuration) * width
    }
}

// MARK: - Preview

#Preview("Longest Focus Card") {
    // Create sample focus blocks for preview
    let calendar = Calendar.current
    let now = Date()
    let baseDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!

    let sampleBlocks: [FocusBlock] = [
        // Short block at 9:30 AM (15 min)
        FocusBlock(
            startTime: calendar.date(byAdding: .minute, value: 30, to: baseDate)!,
            endTime: calendar.date(byAdding: .minute, value: 45, to: baseDate)!
        ),
        // Longest block at 11:24 AM - 2:49 PM (3h 25m)
        FocusBlock(
            startTime: calendar.date(byAdding: .hour, value: 2, to: calendar.date(byAdding: .minute, value: 24, to: baseDate)!)!,
            endTime: calendar.date(byAdding: .hour, value: 5, to: calendar.date(byAdding: .minute, value: 49, to: baseDate)!)!
        ),
        // Medium block at 3:30 PM (45 min)
        FocusBlock(
            startTime: calendar.date(byAdding: .hour, value: 6, to: calendar.date(byAdding: .minute, value: 30, to: baseDate)!)!,
            endTime: calendar.date(byAdding: .hour, value: 7, to: calendar.date(byAdding: .minute, value: 15, to: baseDate)!)!
        ),
        // Short block at 4:30 PM (20 min)
        FocusBlock(
            startTime: calendar.date(byAdding: .hour, value: 7, to: calendar.date(byAdding: .minute, value: 30, to: baseDate)!)!,
            endTime: calendar.date(byAdding: .hour, value: 7, to: calendar.date(byAdding: .minute, value: 50, to: baseDate)!)!
        ),
    ]

    LongestFocusCard(focusBlocks: sampleBlocks)
        .frame(width: 322)
        .padding(20)
        .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}

#Preview("Empty State") {
    LongestFocusCard(focusBlocks: [])
        .frame(width: 322)
        .padding(20)
        .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}

#Preview("Single Block") {
    let calendar = Calendar.current
    let now = Date()
    let baseDate = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now)!

    let singleBlock: [FocusBlock] = [
        FocusBlock(
            startTime: baseDate,
            endTime: calendar.date(byAdding: .hour, value: 2, to: baseDate)!
        )
    ]

    LongestFocusCard(focusBlocks: singleBlock)
        .frame(width: 322)
        .padding(20)
        .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
