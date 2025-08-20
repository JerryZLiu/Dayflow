//
//  TimelineView.swift
//  Dayflow
//
//  Timeline visualization for the UI
//

import SwiftUI
import AppKit

struct TimelineView: View {
    @Binding var selectedDate: Date
    @Binding var selectedActivity: TimelineActivity?
    @State private var activities: [TimelineActivity] = []
    @State private var isLoading = false
    @State private var refreshTimer: Timer?
    
    private let storageManager = StorageManager.shared
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else if activities.isEmpty {
                    VStack {
                        Image(systemName: "clock")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding()
                        Text("No activities recorded today")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TimelineContent(
                        activities: activities,
                        selectedActivity: $selectedActivity,
                        containerHeight: max(geometry.size.height, calculateTotalHeight())
                    )
                }
            }
        }
        .background(Color.gray.opacity(0.05))
        .cornerRadius(20)
        .onAppear {
            loadActivities()
            startRefreshTimer()
        }
        .onDisappear {
            stopRefreshTimer()
        }
        .onChange(of: selectedDate) { _ in
            loadActivities()
        }
    }
    
    private func calculateTotalHeight() -> CGFloat {
        guard let firstActivity = activities.first,
              let lastActivity = activities.last else { return 800 }
        
        let startTime = firstActivity.startTime
        let endTime = lastActivity.endTime
        let totalMinutes = Int(endTime.timeIntervalSince(startTime) / 60)
        
        // Minimum 3 pixels per minute for readability
        return max(CGFloat(totalMinutes) * 3 + 100, 800)
    }
    
    // MARK: - Data Loading
    private func loadActivities() {
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Adjust for 4 AM boundary - if it's before 4 AM, we want yesterday's logical day
            var logicalDate = selectedDate
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: selectedDate)
            
            if hour < 4 {
                // It's after midnight but before 4 AM, so this belongs to yesterday's logical day
                logicalDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dayString = formatter.string(from: logicalDate)
            
            let timelineCards = storageManager.fetchTimelineCards(forDay: dayString)
            let activities = processTimelineCards(timelineCards, for: logicalDate)
            
            DispatchQueue.main.async {
                self.activities = activities
                self.isLoading = false
            }
        }
    }
    
    private func processTimelineCards(_ cards: [TimelineCard], for date: Date) -> [TimelineActivity] {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Create a base date for the selected date
        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: date)
        
        return cards.compactMap { card -> TimelineActivity? in
            // Parse timestamps (they're in format like "3:19 PM")
            guard let startDate = timeFormatter.date(from: card.startTimestamp),
                  let endDate = timeFormatter.date(from: card.endTimestamp) else {
                print("Failed to parse timestamps: \(card.startTimestamp) - \(card.endTimestamp)")
                return nil
            }
            
            // Combine with today's date
            let startComponents = calendar.dateComponents([.hour, .minute], from: startDate)
            let endComponents = calendar.dateComponents([.hour, .minute], from: endDate)
            
            guard let finalStartDate = calendar.date(bySettingHour: startComponents.hour ?? 0, 
                                                    minute: startComponents.minute ?? 0, 
                                                    second: 0, 
                                                    of: baseDate),
                  let finalEndDate = calendar.date(bySettingHour: endComponents.hour ?? 0, 
                                                  minute: endComponents.minute ?? 0, 
                                                  second: 0, 
                                                  of: baseDate) else {
                print("Failed to create final dates")
                return nil
            }
            
            // Convert distractions if any
            let distractions = card.distractions
            
            // Get screenshot if available
            var screenshot: NSImage? = nil
            if let videoURL = card.videoSummaryURL,
               let url = URL(string: videoURL),
               url.scheme == "file" {
                // Try to extract a frame from the video
                // For now, we'll leave this nil
            }
            
            // Handle times based on 4AM boundary
            var adjustedStartDate = finalStartDate
            var adjustedEndDate = finalEndDate
            
            // If start time is between 12:00 AM and 4:00 AM, it belongs to the next day
            let startHour = calendar.component(.hour, from: finalStartDate)
            if startHour < 4 {
                adjustedStartDate = calendar.date(byAdding: .day, value: 1, to: finalStartDate) ?? finalStartDate
            }
            
            // If end time is between 12:00 AM and 4:00 AM, it belongs to the next day
            let endHour = calendar.component(.hour, from: finalEndDate)
            if endHour < 4 {
                adjustedEndDate = calendar.date(byAdding: .day, value: 1, to: finalEndDate) ?? finalEndDate
            }
            
            // Also handle case where end time appears before start time within the same day
            if adjustedEndDate < adjustedStartDate {
                adjustedEndDate = calendar.date(byAdding: .day, value: 1, to: adjustedEndDate) ?? adjustedEndDate
            }
            
            return TimelineActivity(
                startTime: adjustedStartDate,
                endTime: adjustedEndDate,
                title: card.title,
                summary: card.summary,
                detailedSummary: card.detailedSummary,
                category: card.category,
                subcategory: card.subcategory,
                distractions: distractions,
                videoSummaryURL: card.videoSummaryURL,
                screenshot: screenshot
            )
        }
    }
    
    // MARK: - Timer Management
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        
        // Refresh every 60 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            loadActivities()
        }
    }
    
    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

struct TimelineContent: View {
    let activities: [TimelineActivity]
    @Binding var selectedActivity: TimelineActivity?
    let containerHeight: CGFloat
    
    private let timeColumnWidth: CGFloat = 80
    private let cardPadding: CGFloat = 20
    private let minSpacing: CGFloat = 6
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Time column with markers
            TimeColumn(
                activities: activities,
                containerHeight: containerHeight
            )
            .frame(width: timeColumnWidth)
            
            // Activities column
            ZStack(alignment: .topLeading) {
                // Dotted line
                DottedLine()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundColor(Color.gray.opacity(0.3))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                
                // Activity cards
                ForEach(adjustedActivities) { activityInfo in
                    TimelineActivityCard(
                        activity: activityInfo.activity,
                        isSelected: selectedActivity?.id == activityInfo.activity.id,
                        position: (start: activityInfo.adjustedY, height: activityInfo.adjustedHeight),
                        height: activityInfo.adjustedHeight
                    ) {
                        selectedActivity = activityInfo.activity
                    }
                    .offset(x: 10, y: activityInfo.adjustedY)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, cardPadding)
        }
        .frame(minHeight: containerHeight, alignment: .top)
        .padding(.vertical, 20)
    }
    
    private func calculatePosition(for activity: TimelineActivity) -> (start: CGFloat, height: CGFloat) {
        guard let firstActivity = activities.first else { return (0, 50) }
        
        let baseTime = firstActivity.startTime
        let startOffset = activity.startTime.timeIntervalSince(baseTime) / 60 // minutes
        let duration = activity.endTime.timeIntervalSince(activity.startTime) / 60 // minutes
        
        let totalMinutes = activities.last!.endTime.timeIntervalSince(baseTime) / 60
        let pixelsPerMinute = (containerHeight - 40) / CGFloat(totalMinutes)
        
        let yPosition = CGFloat(startOffset) * pixelsPerMinute + 20
        let height = max(CGFloat(duration) * pixelsPerMinute, 30) // Minimum height
        
        return (yPosition, height)
    }
    
    private func position(for activity: TimelineActivity) -> CGFloat {
        calculatePosition(for: activity).start
    }
    
    private func calculateHeight(for activity: TimelineActivity) -> CGFloat {
        calculatePosition(for: activity).height
    }
    
    // Adjusted activities with collision detection
    private struct AdjustedActivity: Identifiable {
        let activity: TimelineActivity
        let adjustedY: CGFloat
        let adjustedHeight: CGFloat
        var id: UUID { activity.id }
    }
    
    private var adjustedActivities: [AdjustedActivity] {
        // First, calculate initial positions
        var positions: [(activity: TimelineActivity, y: CGFloat, height: CGFloat)] = activities.map { activity in
            let pos = calculatePosition(for: activity)
            return (activity, pos.start, pos.height)
        }
        
        // Sort by start position
        positions.sort { $0.y < $1.y }
        
        var result: [AdjustedActivity] = []
        
        // Adjust for overlaps
        for i in 0..<positions.count {
            var currentY = positions[i].y
            var currentHeight = positions[i].height
            
            // Check if previous card overlaps
            if i > 0, !result.isEmpty {
                let prevIndex = result.count - 1
                let prevEnd = result[prevIndex].adjustedY + result[prevIndex].adjustedHeight
                let gap = currentY - prevEnd
                
                if gap < minSpacing {
                    // Need to adjust both cards
                    let adjustment = (minSpacing - gap) / 2
                    
                    // Shrink previous card if possible
                    if result[prevIndex].adjustedHeight > 30 {
                        let newHeight = max(30, result[prevIndex].adjustedHeight - adjustment)
                        result[prevIndex] = AdjustedActivity(
                            activity: result[prevIndex].activity,
                            adjustedY: result[prevIndex].adjustedY,
                            adjustedHeight: newHeight
                        )
                    }
                    
                    // Adjust current card
                    currentHeight = max(30, currentHeight - adjustment)
                    currentY = result[prevIndex].adjustedY + result[prevIndex].adjustedHeight + minSpacing
                }
            }
            
            result.append(AdjustedActivity(
                activity: positions[i].activity,
                adjustedY: currentY,
                adjustedHeight: currentHeight
            ))
        }
        
        return result
    }
}

struct TimeColumn: View {
    let activities: [TimelineActivity]
    let containerHeight: CGFloat
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(timeMarkers, id: \.date) { marker in
                Text(marker.label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                    .offset(y: positionForTime(marker.date) - 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
    
    private var timeMarkers: [(date: Date, label: String)] {
        // Extract unique start times and sort them
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        let uniqueTimes = Array(Set(activities.map { $0.startTime }))
            .sorted()
        
        return uniqueTimes.map { date in
            (date: date, label: formatter.string(from: date))
        }
    }
    
    private func positionForTime(_ time: Date) -> CGFloat {
        guard let firstActivity = activities.first else { return 0 }
        
        let baseTime = firstActivity.startTime
        let offset = time.timeIntervalSince(baseTime) / 60 // minutes
        let totalMinutes = activities.last!.endTime.timeIntervalSince(baseTime) / 60
        
        let pixelsPerMinute = (containerHeight - 40) / CGFloat(totalMinutes)
        
        return CGFloat(offset) * pixelsPerMinute + 20
    }
}

struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

struct TimelineActivityCard: View {
    let activity: TimelineActivity
    let isSelected: Bool
    let position: (start: CGFloat, height: CGFloat)
    let height: CGFloat
    let action: () -> Void
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
    
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                // Icon based on category
                Text(iconForCategory(activity.category))
                    .font(.system(size: 16))
                
                VStack(alignment: .leading, spacing: 2) {
                    // Title
                    Text(activity.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(height > 40 ? 2 : 1)
                    
                    // Time range (only if card is tall enough)
                    if height > 60 {
                        Text("\(timeFormatter.string(from: activity.startTime)) to \(timeFormatter.string(from: activity.endTime))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, height > 40 ? 10 : 6)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(backgroundGradient)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func iconForCategory(_ category: String) -> String {
        switch category.lowercased() {
        case "productive work", "work", "research", "coding", "writing", "learning":
            return "🧠"
        case "distraction", "entertainment", "social media":
            return "😑"
        default:
            return "⏰"
        }
    }
    
    private var backgroundGradient: some View {
        Group {
            switch activity.category.lowercased() {
            case "productive work", "work", "research", "coding", "writing", "learning":
                LinearGradient(
                    colors: [Color(red: 0.95, green: 0.95, blue: 1), Color.white],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case "distraction", "entertainment", "social media":
                LinearGradient(
                    colors: [Color(red: 1, green: 0.95, blue: 0.95), Color.white],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            default:
                LinearGradient(
                    colors: [Color(red: 0.95, green: 0.95, blue: 0.95), Color.white],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

