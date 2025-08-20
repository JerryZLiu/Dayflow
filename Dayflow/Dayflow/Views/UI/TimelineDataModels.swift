//
//  TimelineDataModels.swift
//  Dayflow
//
//  Data models for the new UI timeline components
//

import Foundation
import SwiftUI

// MARK: - TimelineActivity

/// Represents an activity in the timeline view
struct TimelineActivity: Identifiable {
    let id = UUID()
    let startTime: Date
    let endTime: Date
    let title: String
    let summary: String
    let detailedSummary: String
    let category: String
    let subcategory: String
    let distractions: [Distraction]?
    let videoSummaryURL: String?
    let screenshot: NSImage?
}

// MARK: - DatePickerSheet

/// Sheet view for selecting a date
struct DatePickerSheet: View {
    @Binding var selectedDate: Date
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Select Date")
                .font(.title2)
                .fontWeight(.semibold)
            
            DatePicker(
                "",
                selection: $selectedDate,
                in: ...Date(), // Only allow past dates and today
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .frame(width: 350)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
                
                Button("Select") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding(30)
        .frame(width: 420)
    }
}