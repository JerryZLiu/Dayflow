import SwiftUI
import AppKit
import Foundation

struct ActivityCard: View {
    let activity: TimelineActivity?
    var maxHeight: CGFloat? = nil
    var scrollSummary: Bool = false
    var hasAnyActivities: Bool = true
    var onCategoryChange: ((TimelineCategory, TimelineActivity) -> Void)? = nil
    var onNavigateToCategoryEditor: (() -> Void)? = nil
    var onRetryBatchCompleted: ((Int64) -> Void)? = nil
    // Hero animation for video expansion
    var videoNamespace: Namespace.ID? = nil
    var videoExpansionState: VideoExpansionState? = nil
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var categoryStore: CategoryStore
    @EnvironmentObject private var retryCoordinator: RetryCoordinator

    @State private var showCategoryPicker = false

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    var body: some View {
        if let activity = activity {
            ZStack(alignment: .top) {
                activityDetails(for: activity)
                    .padding(16)
                    .allowsHitTesting(!showCategoryPicker)
                    .id(activity.id)
                    .transition(
                        .blurReplace.animation(
                            .easeOut(duration: 0.2)
                        )
                    )

                if showCategoryPicker && !isFailedCard(activity) {
                    CategoryPickerOverlay(
                        categories: categoryStore.categories,
                        currentCategoryName: activity.category,
                        onSelect: { selectedCategory in
                            commitCategorySelection(selectedCategory, for: activity)
                        },
                        onNavigateToEditor: {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                showCategoryPicker = false
                            }
                            onNavigateToCategoryEditor?()
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .if(maxHeight != nil) { view in
                view.frame(maxHeight: maxHeight!)
            }
            .onChange(of: activity.id) {
                showCategoryPicker = false
            }
        } else {
            // Empty state
            VStack(spacing: 10) {
                Spacer()
                if hasAnyActivities {
                    Text("Select an activity to view details")
                        .font(.custom("Nunito", size: 15))
                        .fontWeight(.regular)
                        .foregroundColor(.gray.opacity(0.5))
                } else {
                    if appState.isRecording {
                        VStack(spacing: 6) {
                            Text("No cards yet")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.7))
                            Text("Cards are generated about every 15 minutes. If Dayflow is on and no cards show up within 30 minutes, please report a bug.")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.gray.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Text("Recording is off")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.7))
                            Text("Dayflow recording is currently turned off, so cards aren’t being produced.")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.gray.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .if(maxHeight != nil) { view in
                view.frame(maxHeight: maxHeight!)
            }
        }
    }

    @ViewBuilder
    private func activityDetails(for activity: TimelineActivity) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activity.title)
                        .font(
                            Font.custom("Nunito", size: 16)
                                .weight(.semibold)
                        )
                        .foregroundColor(.black)

                    HStack(alignment: .center, spacing: 6) {
                        Text("\(timeFormatter.string(from: activity.startTime)) - \(timeFormatter.string(from: activity.endTime))")
                            .font(
                                Font.custom("Nunito", size: 12)
                            )
                            .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.9))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .inset(by: 0.38)
                                    .stroke(Color(red: 0.9, green: 0.9, blue: 0.9), lineWidth: 0.75)
                            )

                        Spacer(minLength: 6)

                        HStack(spacing: 6) {
                            if let badge = categoryBadge(for: activity.category) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(badge.indicator)
                                        .frame(width: 8, height: 8)

                                    Text(badge.name)
                                        .font(Font.custom("Nunito", size: 12))
                                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.76))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .inset(by: 0.25)
                                        .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 0.5)
                                )
                            }

                            if !isFailedCard(activity) {
                                Button(action: {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        showCategoryPicker.toggle()
                                    }
                                }) {
                                    Image("CategorySwapButton")
                                        .resizable()
                                        .renderingMode(.original)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .accessibilityLabel(Text("Change category"))
                            }
                        }
                    }
                }

                Spacer()

                // Retry button centered between title and time (only for failed cards)
                if isFailedCard(activity) {
                    retryButtonInline(for: activity)
                }
            }

            // Error message (if retry failed)
            if isFailedCard(activity), let statusLine = retryCoordinator.statusLine(for: activity.batchId) {
                Text(statusLine)
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                    .lineLimit(1)
            }

            // Video thumbnail (render only when available)
            // Uses hero animation for smooth expansion (Emil Kowalski: shared element transitions)
            if let videoURL = activity.videoSummaryURL {
                VideoThumbnailView(
                    videoURL: videoURL,
                    title: activity.title,
                    startTime: activity.startTime,
                    endTime: activity.endTime,
                    namespace: videoNamespace,
                    expansionState: videoExpansionState
                )
                .id(videoURL)
                .frame(height: 200)
            }

            // Summary section (scrolls internally when constrained)
            Group {
                if scrollSummary {
                    ScrollView(.vertical, showsIndicators: false) {
                        summaryContent(for: activity)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .onScrollStart(panelName: "activity_card") { direction in
                                AnalyticsService.shared.capture("right_panel_scrolled", [
                                    "panel": "activity_card",
                                    "direction": direction
                                ])
                            }
                    }
                    .id(activity.id) // Reset scroll position whenever the selected activity changes
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                } else {
                    summaryContent(for: activity)
                }
            }
        }
    }

    @ViewBuilder
    private func summaryContent(for activity: TimelineActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SUMMARY")
                    .font(
                        Font.custom("Nunito", size: 12)
                            .weight(.semibold)
                    )
                    .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.55))

                renderMarkdownText(activity.summary)
                    .font(
                        Font.custom("Nunito", size: 12)
                    )
                    .foregroundColor(.black)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !activity.detailedSummary.isEmpty && activity.detailedSummary != activity.summary {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DETAILED SUMMARY")
                        .font(
                            Font.custom("Nunito", size: 12)
                                .weight(.semibold)
                        )
                        .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.55))

                    renderMarkdownText(formattedDetailedSummary(activity.detailedSummary))
                        .font(
                            Font.custom("Nunito", size: 12)
                        )
                        .foregroundColor(.black)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func renderMarkdownText(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: content, options: options) {
            return Text(parsed)
        }
        return Text(content)
    }

    private func formattedDetailedSummary(_ content: String) -> String {
        if content.contains("\n") || content.contains("\r") {
            return content
        }

        let pattern = #"\b\d{1,2}:\d{2}\s?(?:AM|PM)\s*-\s*\d{1,2}:\d{2}\s?(?:AM|PM)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        guard matches.count > 1 else {
            return content
        }

        let mutable = NSMutableString(string: content)
        for idx in stride(from: matches.count - 1, through: 1, by: -1) {
            mutable.insert("\n", at: matches[idx].range.location)
        }
        return mutable as String
    }

    private func categoryBadge(for raw: String) -> (name: String, indicator: Color)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased()
        let categories = categoryStore.categories
        let matched = categories.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }

        let category = matched ?? CategoryPersistence.defaultCategories.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }

        guard let resolvedCategory = category else { return nil }

        let nsColor = NSColor(hex: resolvedCategory.colorHex) ?? NSColor(hex: "#4F80EB") ?? .systemBlue
        return (name: resolvedCategory.name, indicator: Color(nsColor: nsColor))
    }

    // MARK: - Retry Functionality

    private func isFailedCard(_ activity: TimelineActivity) -> Bool {
        return activity.title == "Processing failed"
    }

    @ViewBuilder
    private func retryButtonInline(for activity: TimelineActivity) -> some View {
        let isProcessing = retryCoordinator.isActive(batchId: activity.batchId)
        let isDisabled = retryCoordinator.isRunning

        if isProcessing {
            // Processing state - beige pill with spinner
            HStack(alignment: .center, spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)

                Text("Processing")
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.91, green: 0.85, blue: 0.8))
            .cornerRadius(200)
        } else {
            // Retry button - orange pill
            Button(action: { handleRetry(for: activity) }) {
                HStack(alignment: .center, spacing: 4) {
                    Text("Retry")
                        .font(.custom("Nunito", size: 13).weight(.medium))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(red: 1, green: 0.54, blue: 0.17))
                .cornerRadius(200)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.6 : 1)
        }
    }

    private func handleRetry(for activity: TimelineActivity) {
        let dayString = activity.startTime.getDayInfoFor4AMBoundary().dayString
        retryCoordinator.startRetry(for: dayString) { batchId in
            onRetryBatchCompleted?(batchId)
        }
    }

    private func commitCategorySelection(_ category: TimelineCategory, for activity: TimelineActivity) {
        let normalizedCurrent = activity.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedNew = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            showCategoryPicker = false
        }

        guard normalizedCurrent != normalizedNew else { return }
        onCategoryChange?(category, activity)
    }
}
