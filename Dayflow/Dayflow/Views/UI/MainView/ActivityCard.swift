import AppKit
import Foundation
import ImageIO
import SwiftUI

struct ActivityCard: View {
  let activity: TimelineActivity?
  var maxHeight: CGFloat? = nil
  var scrollSummary: Bool = false
  var hasAnyActivities: Bool = true
  var onCategoryChange: ((TimelineCategory, TimelineActivity) -> Void)? = nil
  var onNavigateToCategoryEditor: (() -> Void)? = nil
  var onRetryBatchCompleted: ((Int64) -> Void)? = nil
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var categoryStore: CategoryStore
  @EnvironmentObject private var retryCoordinator: RetryCoordinator

  @State private var showCategoryPicker = false
  @State private var isPreparingSlideshow = false
  @State private var slideshowError: String?
  @State private var slideshowRequestID = 0
  @State private var timelapsePreviewThumbnail: NSImage?
  @State private var timelapsePreviewRequestID = 0
  @State private var showSlideshowPlayer = false
  @State private var slideshowScreenshots: [Screenshot] = []
  @State private var slideshowTitle: String?
  @State private var slideshowStartTime: Date?
  @State private var slideshowEndTime: Date?

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
        isPreparingSlideshow = false
        slideshowError = nil
        slideshowRequestID &+= 1
        timelapsePreviewThumbnail = nil
        timelapsePreviewRequestID &+= 1
        slideshowScreenshots = []
        slideshowTitle = nil
        slideshowStartTime = nil
        slideshowEndTime = nil
        showSlideshowPlayer = false
      }
      .sheet(
        isPresented: $showSlideshowPlayer,
        onDismiss: {
          slideshowScreenshots = []
          slideshowTitle = nil
          slideshowStartTime = nil
          slideshowEndTime = nil
        }
      ) {
        if !slideshowScreenshots.isEmpty {
          ScreenshotSlideshowModal(
            screenshots: slideshowScreenshots,
            title: slideshowTitle,
            startTime: slideshowStartTime,
            endTime: slideshowEndTime
          )
        }
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
              Text(
                "Cards are generated about every 15 minutes. If Dayflow is on and no cards show up within 30 minutes, please report a bug."
              )
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
            Text(
              "\(timeFormatter.string(from: activity.startTime)) - \(timeFormatter.string(from: activity.endTime))"
            )
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
                .hoverScaleEffect(scale: 1.02)
                .pointingHandCursorOnHover(reassertOnPressEnd: true)
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
      if isFailedCard(activity), let statusLine = retryCoordinator.statusLine(for: activity.batchId)
      {
        Text(statusLine)
          .font(.custom("Nunito", size: 11))
          .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
          .lineLimit(1)
      }

      // Timelapse thumbnail (slideshow pipeline)
      if !isFailedCard(activity) {
        timelapsePreviewView(for: activity)
      }

      // Summary section (scrolls internally when constrained)
      Group {
        if scrollSummary {
          ScrollView(.vertical, showsIndicators: false) {
            summaryContent(for: activity)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .onScrollStart(panelName: "activity_card") { direction in
                AnalyticsService.shared.capture(
                  "right_panel_scrolled",
                  [
                    "panel": "activity_card",
                    "direction": direction,
                  ])
              }
          }
          .id(activity.id)  // Reset scroll position whenever the selected activity changes
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
    let matched = categories.first {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }

    let category =
      matched
      ?? CategoryPersistence.defaultCategories.first {
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
      .hoverScaleEffect(enabled: !isDisabled, scale: 1.02)
      .pointingHandCursorOnHover(enabled: !isDisabled, reassertOnPressEnd: true)
    }
  }

  private func handleRetry(for activity: TimelineActivity) {
    let dayString = activity.startTime.getDayInfoFor4AMBoundary().dayString
    retryCoordinator.startRetry(for: dayString) { batchId in
      onRetryBatchCompleted?(batchId)
    }
  }

  private func commitCategorySelection(_ category: TimelineCategory, for activity: TimelineActivity)
  {
    let normalizedCurrent = activity.category.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let normalizedNew = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
      showCategoryPicker = false
    }

    guard normalizedCurrent != normalizedNew else { return }
    onCategoryChange?(category, activity)
  }

  @ViewBuilder
  private func timelapsePreviewView(for activity: TimelineActivity) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      GeometryReader { geometry in
        ZStack {
          if let thumbnail = timelapsePreviewThumbnail {
            Image(nsImage: thumbnail)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .scaleEffect(1.3)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()
              .cornerRadius(12)
          } else {
            RoundedRectangle(cornerRadius: 12)
              .fill(Color.gray.opacity(0.3))
              .overlay(
                Image(systemName: "photo")
                  .font(.system(size: 18, weight: .medium))
                  .foregroundColor(Color.white.opacity(0.9))
              )
          }

          if isPreparingSlideshow {
            ZStack {
              RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.28))

              HStack(spacing: 8) {
                ProgressView()
                  .scaleEffect(0.8)
                Text("Loading slideshow...")
                  .font(.custom("Nunito", size: 12).weight(.semibold))
                  .foregroundColor(.white)
              }
            }
          } else {
            ZStack {
              Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.black.opacity(0.35)))
              Image(systemName: "play.fill")
                .foregroundColor(.white)
                .font(.system(size: 24, weight: .bold))
            }
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
          }
        }
        .contentShape(Rectangle())
        .onTapGesture {
          guard let cardId = activity.recordId else {
            slideshowError = "This activity cannot load a slideshow."
            return
          }
          openSlideshow(for: activity, cardId: cardId)
        }
        .hoverScaleEffect(scale: 1.02)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
        .id(activity.id)
        .onAppear {
          loadTimelapsePreviewThumbnail(for: activity, size: geometry.size)
        }
        .onChange(of: geometry.size.width) {
          loadTimelapsePreviewThumbnail(for: activity, size: geometry.size)
        }
      }
      .frame(height: 200)

      if let errorMessage = slideshowError {
        Text(errorMessage)
          .font(Font.custom("Nunito", size: 11))
          .foregroundColor(Color(red: 0.76, green: 0.16, blue: 0.2))
      }
    }
  }

  private func openSlideshow(for activity: TimelineActivity, cardId: Int64) {
    guard !isPreparingSlideshow else { return }

    isPreparingSlideshow = true
    slideshowError = nil
    slideshowRequestID &+= 1
    let requestID = slideshowRequestID

    AnalyticsService.shared.capture(
      "timelapse_slideshow_started",
      [
        "card_id": cardId
      ])

    Task {
      do {
        let screenshots = try await ActivityCardTimelapseGenerator.shared.screenshots(
          forCardId: cardId)
        await MainActor.run {
          guard requestID == slideshowRequestID else { return }
          isPreparingSlideshow = false
          slideshowError = nil
          slideshowScreenshots = screenshots
          slideshowTitle = activity.title
          slideshowStartTime = activity.startTime
          slideshowEndTime = activity.endTime
          showSlideshowPlayer = true
        }

        AnalyticsService.shared.capture(
          "timelapse_slideshow_completed",
          [
            "card_id": cardId,
            "frame_count": screenshots.count,
          ])
      } catch {
        await MainActor.run {
          guard requestID == slideshowRequestID else { return }
          isPreparingSlideshow = false
          slideshowError = error.localizedDescription
        }
        AnalyticsService.shared.capture(
          "timelapse_slideshow_failed",
          [
            "card_id": cardId,
            "error": error.localizedDescription,
          ])
      }
    }
  }

  private func loadTimelapsePreviewThumbnail(for activity: TimelineActivity, size: CGSize) {
    guard let cardId = activity.recordId else {
      timelapsePreviewThumbnail = nil
      return
    }

    timelapsePreviewRequestID &+= 1
    let requestID = timelapsePreviewRequestID
    let targetSize = CGSize(width: max(1, size.width), height: max(1, size.height))

    Task {
      let screenshotURL = await ActivityCardTimelapseGenerator.shared.middleScreenshotURL(
        forCardId: cardId)
      await MainActor.run {
        guard requestID == timelapsePreviewRequestID else { return }
        guard let screenshotURL else {
          timelapsePreviewThumbnail = nil
          return
        }

        ScreenshotThumbnailCache.shared.fetchThumbnail(
          fileURL: screenshotURL, targetSize: targetSize
        ) { image in
          guard requestID == timelapsePreviewRequestID else { return }
          timelapsePreviewThumbnail = image
        }
      }
    }
  }
}

private enum ActivityCardTimelapseError: LocalizedError {
  case timelineCardMissing
  case noScreenshots

  var errorDescription: String? {
    switch self {
    case .timelineCardMissing:
      return "Could not find this activity in storage."
    case .noScreenshots:
      return "No screenshots are available for this activity range."
    }
  }
}

private actor ActivityCardTimelapseGenerator {
  static let shared = ActivityCardTimelapseGenerator()

  private let storage: any StorageManaging

  init(
    storage: any StorageManaging = StorageManager.shared
  ) {
    self.storage = storage
  }

  func screenshots(forCardId cardId: Int64) throws -> [Screenshot] {
    guard let timelineCard = storage.fetchTimelineCard(byId: cardId) else {
      throw ActivityCardTimelapseError.timelineCardMissing
    }

    let screenshots = storage.fetchScreenshotsInTimeRange(
      startTs: timelineCard.startTs, endTs: timelineCard.endTs)
    guard !screenshots.isEmpty else {
      throw ActivityCardTimelapseError.noScreenshots
    }
    return screenshots
  }

  func middleScreenshotURL(forCardId cardId: Int64) -> URL? {
    guard let screenshots = try? screenshots(forCardId: cardId), !screenshots.isEmpty else {
      return nil
    }
    let middleIndex = screenshots.count / 2
    return screenshots[middleIndex].fileURL
  }
}

private struct ScreenshotSlideshowModal: View {
  let screenshots: [Screenshot]
  let title: String?
  let startTime: Date?
  let endTime: Date?

  @Environment(\.dismiss) private var dismiss
  @StateObject private var playbackModel: ScreenshotSlideshowPlaybackModel
  @State private var keyMonitor: Any?

  init(
    screenshots: [Screenshot],
    title: String?,
    startTime: Date?,
    endTime: Date?
  ) {
    self.screenshots = screenshots
    self.title = title
    self.startTime = startTime
    self.endTime = endTime
    _playbackModel = StateObject(
      wrappedValue: ScreenshotSlideshowPlaybackModel(screenshots: screenshots, maxRenderHeight: 720)
    )
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 3) {
          if let title {
            Text(title)
              .font(.title3)
              .fontWeight(.semibold)
          }
          if let startTime, let endTime {
            Text(
              "\(Self.timeFormatter.string(from: startTime)) to \(Self.timeFormatter.string(from: endTime))"
            )
            .font(.caption)
            .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
          }
        }
        Spacer()
        Button(action: { dismiss() }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 20))
            .foregroundColor(Color.black.opacity(0.5))
        }
        .buttonStyle(PlainButtonStyle())
        .hoverScaleEffect(scale: 1.02)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(Color.white)

      Divider()

      GeometryReader { geometry in
        ZStack {
          Color.black.opacity(0.95)

          if let image = playbackModel.currentImage {
            Image(nsImage: image)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
          } else {
            ProgressView()
              .controlSize(.large)
              .allowsHitTesting(false)
          }

          Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
              playbackModel.togglePlayPause()
            }
            .pointingHandCursor()

          if !playbackModel.isPlaying {
            ZStack {
              Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: 68, height: 68)
                .background(Circle().fill(Color.black.opacity(0.35)))
              Image(systemName: "play.fill")
                .foregroundColor(.white)
                .font(.system(size: 26, weight: .bold))
            }
            .allowsHitTesting(false)
          }

          VStack {
            Spacer()
            HStack {
              Spacer()
              Button(action: { playbackModel.cycleSpeed() }) {
                Text(playbackModel.speedLabel)
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundColor(.white)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(Color.black.opacity(0.8))
                  .cornerRadius(4)
              }
              .buttonStyle(PlainButtonStyle())
              .hoverScaleEffect(scale: 1.02)
              .pointingHandCursorOnHover(reassertOnPressEnd: true)
              .padding(12)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      VStack(spacing: 12) {
        ScreenshotScrubberView(
          screenshots: screenshots,
          duration: max(0.001, playbackModel.timelineDurationSeconds),
          currentTime: playbackModel.currentTimelineTimeSeconds,
          onSeek: { timelineTime in
            playbackModel.seek(toTimelineTime: timelineTime)
          },
          onScrubStateChange: { isScrubbing in
            playbackModel.setScrubbing(isScrubbing)
          },
          absoluteStart: startTime,
          absoluteEnd: endTime
        )
        .padding(.horizontal)
        .padding(.bottom, 12)
      }
      .background(Color.white)
    }
    .frame(minWidth: 960, minHeight: 640)
    .background(Color.white)
    .onAppear {
      playbackModel.start()
      setupKeyMonitor()
    }
    .onDisappear {
      playbackModel.stop()
      removeKeyMonitor()
    }
  }

  private func setupKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if let responder = NSApp.keyWindow?.firstResponder {
        if responder is NSTextField || responder is NSTextView || responder is NSText {
          return event
        }
        let className = NSStringFromClass(type(of: responder))
        if className.contains("TextField") || className.contains("TextEditor")
          || className.contains("TextInput")
        {
          return event
        }
      }

      if event.keyCode == 49
        && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
      {
        playbackModel.togglePlayPause()
        return nil
      }
      return event
    }
  }

  private func removeKeyMonitor() {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
  }
}

private let cachedScreenshotScrubberTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  return formatter
}()

private final class ScreenshotFilmstripGenerator {
  static let shared = ScreenshotFilmstripGenerator()

  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "com.dayflow.screenshotfilmstrip"
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .userInitiated
    return q
  }()

  private let syncQueue = DispatchQueue(label: "com.dayflow.screenshotfilmstrip.sync")
  private var cache: [String: [NSImage]] = [:]
  private var inflight: [String: [([NSImage]) -> Void]] = [:]

  private init() {}

  func generate(
    screenshots: [Screenshot],
    frameCount: Int,
    targetHeight: CGFloat,
    completion: @escaping ([NSImage]) -> Void
  ) {
    guard frameCount > 0, !screenshots.isEmpty else {
      completion([])
      return
    }

    let key = Self.cacheKey(for: screenshots, frameCount: frameCount, targetHeight: targetHeight)
    if let images = syncQueue.sync(execute: { cache[key] }) {
      completion(images)
      return
    }

    var shouldStart = false
    syncQueue.sync {
      if var callbacks = inflight[key] {
        callbacks.append(completion)
        inflight[key] = callbacks
      } else {
        inflight[key] = [completion]
        shouldStart = true
      }
    }

    guard shouldStart else { return }

    queue.addOperation { [weak self] in
      guard let self else { return }
      let sampled = Self.sampledIndices(total: screenshots.count, count: frameCount)
      let targetWidth = targetHeight * 16.0 / 9.0

      var generated: [NSImage] = []
      generated.reserveCapacity(sampled.count)

      for index in sampled {
        let url = screenshots[index].fileURL
        if let image = self.decodeThumbnail(url: url, targetHeight: targetHeight) {
          generated.append(image)
        } else {
          generated.append(self.placeholderImage(width: targetWidth, height: targetHeight))
        }
      }

      self.syncQueue.sync {
        self.cache[key] = generated
      }
      self.finish(key: key, images: generated)
    }
  }

  private func finish(key: String, images: [NSImage]) {
    var callbacks: [([NSImage]) -> Void] = []
    syncQueue.sync {
      callbacks = inflight[key] ?? []
      inflight.removeValue(forKey: key)
    }
    DispatchQueue.main.async {
      callbacks.forEach { $0(images) }
    }
  }

  private func decodeThumbnail(url: URL, targetHeight: CGFloat) -> NSImage? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    let targetWidth = targetHeight * 16.0 / 9.0
    let maxPixel = max(64, Int(max(targetHeight, targetWidth) * scale))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }

  private func placeholderImage(width: CGFloat, height: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    image.unlockFocus()
    return image
  }

  private static func cacheKey(
    for screenshots: [Screenshot], frameCount: Int, targetHeight: CGFloat
  ) -> String {
    let firstPath = screenshots.first?.filePath ?? "-"
    let lastPath = screenshots.last?.filePath ?? "-"
    let firstTs = screenshots.first?.capturedAt ?? 0
    let lastTs = screenshots.last?.capturedAt ?? 0
    return
      "\(screenshots.count)|\(firstTs)|\(lastTs)|\(firstPath)|\(lastPath)|n:\(frameCount)|h:\(Int(targetHeight.rounded()))"
  }

  private static func sampledIndices(total: Int, count: Int) -> [Int] {
    guard total > 0 else { return [] }
    guard count > 1 else { return [0] }
    if total == 1 { return Array(repeating: 0, count: count) }

    let maxIndex = total - 1
    return (0..<count).map { i in
      let ratio = Double(i) / Double(count - 1)
      return Int((ratio * Double(maxIndex)).rounded())
    }
  }
}

private struct ScreenshotScrubberView: View {
  let screenshots: [Screenshot]
  let duration: Double
  let currentTime: Double
  let onSeek: (Double) -> Void
  let onScrubStateChange: (Bool) -> Void
  var absoluteStart: Date? = nil
  var absoluteEnd: Date? = nil

  @State private var images: [NSImage] = []
  @State private var isDragging: Bool = false

  private let frameCount = 12
  private let filmstripHeight: CGFloat = 64
  private let aspect: CGFloat = 16.0 / 9.0
  private let zoom: CGFloat = 1.2
  private let chipRowHeight: CGFloat = 28
  private let chipSpacing: CGFloat = 0
  private let sideGutter: CGFloat = 30
  private var totalHeight: CGFloat { chipRowHeight + chipSpacing + filmstripHeight }

  var body: some View {
    GeometryReader { outer in
      let stripWidth = max(1, outer.size.width - sideGutter * 2)
      let xInsideRaw = xFor(time: currentTime, width: stripWidth)
      let scale = NSScreen.main?.backingScaleFactor ?? 2.0
      let xInside = (xInsideRaw * scale).rounded() / scale
      let x = sideGutter + xInside

      ZStack(alignment: .topLeading) {
        VStack(spacing: chipSpacing) {
          ZStack(alignment: .topLeading) {
            Color.clear.frame(height: chipRowHeight)
            Text(timeLabel(for: currentTime))
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.white)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.black.opacity(0.85))
              .cornerRadius(12)
              .scaleEffect(0.8)
              .position(x: x, y: chipRowHeight / 2)
          }
          .zIndex(1)

          ZStack(alignment: .topLeading) {
            Rectangle()
              .fill(Color.white)

            let tileWidth = filmstripHeight * aspect
            let columnsNeeded = max(1, Int(ceil(stripWidth / tileWidth)))
            HStack(spacing: 0) {
              if images.count == columnsNeeded {
                ForEach(0..<images.count, id: \.self) { idx in
                  Image(nsImage: images[idx])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(zoom, anchor: .center)
                    .frame(width: tileWidth, height: filmstripHeight)
                    .clipped()
                }
              } else if images.isEmpty {
                ForEach(0..<columnsNeeded, id: \.self) { _ in
                  Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(width: tileWidth, height: filmstripHeight)
                }
              } else {
                ForEach(0..<columnsNeeded, id: \.self) { i in
                  let image = i < images.count ? images[i] : nil
                  Group {
                    if let image {
                      Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(zoom, anchor: .center)
                    } else {
                      Rectangle().fill(Color.black.opacity(0.06))
                    }
                  }
                  .frame(width: tileWidth, height: filmstripHeight)
                  .clipped()
                }
              }
            }
            .frame(width: stripWidth, alignment: .leading)
            .clipped()
            .onChange(of: columnsNeeded) { _, newValue in
              generateFilmstripIfNeeded(count: newValue)
            }
            .onAppear { generateFilmstripIfNeeded(count: columnsNeeded) }

            let barHeight = filmstripHeight + 3
            Rectangle()
              .fill(Color.black)
              .frame(width: 5, height: barHeight)
              .shadow(color: .black.opacity(0.25), radius: 1.0, x: 0, y: 0)
              .offset(x: xInside - 2.5, y: -3)
              .allowsHitTesting(false)
            Rectangle()
              .fill(Color.white)
              .frame(width: 3, height: barHeight)
              .offset(x: xInside - 1.5, y: -3)
              .allowsHitTesting(false)
          }
          .frame(width: stripWidth, height: filmstripHeight)
          .padding(.horizontal, sideGutter)
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            if !isDragging {
              isDragging = true
              onScrubStateChange(true)
            }
            let activeStripWidth = max(1, outer.size.width - sideGutter * 2)
            let xLocal = (value.location.x - sideGutter).clamped(to: 0, activeStripWidth)
            let pct = xLocal / activeStripWidth
            onSeek(Double(pct) * max(duration, 0.0001))
          }
          .onEnded { _ in
            isDragging = false
            onScrubStateChange(false)
          }
      )
    }
    .frame(height: totalHeight)
  }

  private func xFor(time: Double, width: CGFloat) -> CGFloat {
    guard duration > 0 else { return 0 }
    return CGFloat(time / duration) * width
  }

  private func timeLabel(for time: Double) -> String {
    if let absoluteStart, let absoluteEnd, duration > 0 {
      let total = absoluteEnd.timeIntervalSince(absoluteStart)
      let progress = max(0, min(1, time / duration))
      let absolute = absoluteStart.addingTimeInterval(total * progress)
      return cachedScreenshotScrubberTimeFormatter.string(from: absolute)
    }

    let mins = Int(time) / 60
    let secs = Int(time) % 60
    return String(format: "%d:%02d", mins, secs)
  }

  private func generateFilmstripIfNeeded(count: Int) {
    guard count > 0 else { return }
    ScreenshotFilmstripGenerator.shared.generate(
      screenshots: screenshots,
      frameCount: count,
      targetHeight: filmstripHeight
    ) { generated in
      images = generated
    }
  }
}

extension Comparable {
  fileprivate func clamped(to lower: Self, _ upper: Self) -> Self {
    min(max(self, lower), upper)
  }
}

@MainActor
private final class ScreenshotSlideshowPlaybackModel: ObservableObject {
  @Published private(set) var currentImage: NSImage?
  @Published private(set) var currentIndex: Int = 0
  @Published private(set) var currentTimelineTimeSeconds: Double = 0
  @Published private(set) var speedLabel: String = "20x"
  @Published var isPlaying: Bool = true

  let frameCount: Int

  private let loader: ScreenshotSlideshowFrameLoader
  private let frameOffsets: [Double]
  private let fallbackTimelineDurationSeconds: Double
  private let averageFrameIntervalSeconds: Double
  private static let speedDefaultsKey = "activitySlideshowPlaybackSpeedX"
  private let speedOptions: [Double] = [20, 40, 60]
  private let playheadTickNanoseconds: UInt64 = 33_000_000
  private var speedOptionIndex: Int = 0
  private var requestID: Int = 0
  private var currentFrameStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  private var wasPlayingBeforeScrubbing = false
  private var playbackTask: Task<Void, Never>?

  init(screenshots: [Screenshot], maxRenderHeight: Int) {
    self.frameCount = screenshots.count
    self.loader = ScreenshotSlideshowFrameLoader(
      screenshots: screenshots, maxRenderHeight: maxRenderHeight)

    if let firstCapture = screenshots.first?.capturedAt {
      self.frameOffsets = screenshots.map { screenshot in
        Double(max(0, screenshot.capturedAt - firstCapture))
      }
    } else {
      self.frameOffsets = []
    }

    if screenshots.count > 1 {
      let totalSeconds = Double(
        max(1, screenshots.last!.capturedAt - screenshots.first!.capturedAt))
      self.fallbackTimelineDurationSeconds = totalSeconds
      self.averageFrameIntervalSeconds = max(0.1, totalSeconds / Double(screenshots.count - 1))
    } else {
      self.fallbackTimelineDurationSeconds = max(0.1, ScreenshotConfig.interval)
      self.averageFrameIntervalSeconds = max(0.1, ScreenshotConfig.interval)
    }

    if let savedIndex = Self.savedSpeedIndex(in: speedOptions) {
      self.speedOptionIndex = savedIndex
      self.speedLabel = "\(Int(speedOptions[savedIndex]))x"
    }
  }

  deinit {
    playbackTask?.cancel()
  }

  func start() {
    guard frameCount > 0 else { return }
    guard playbackTask == nil else { return }
    playbackTask = Task { [weak self] in
      await self?.runPlaybackLoop()
    }
  }

  func stop() {
    playbackTask?.cancel()
    playbackTask = nil
  }

  func togglePlayPause() {
    isPlaying.toggle()
  }

  func cycleSpeed() {
    speedOptionIndex = (speedOptionIndex + 1) % speedOptions.count
    speedLabel = "\(Int(speedOptions[speedOptionIndex]))x"
    UserDefaults.standard.set(speedOptions[speedOptionIndex], forKey: Self.speedDefaultsKey)
  }

  func seek(to index: Int) {
    guard frameCount > 0 else { return }
    let clamped = min(max(0, index), frameCount - 1)
    currentTimelineTimeSeconds = frameOffset(for: clamped)
    Task { [weak self] in
      await self?.displayFrame(at: clamped)
    }
  }

  func seek(toTimelineTime seconds: Double) {
    guard frameCount > 0 else { return }
    let clampedSeconds = min(max(0, seconds), timelineDurationSeconds)
    currentTimelineTimeSeconds = clampedSeconds
    let nearest = nearestFrameIndex(forTimelineTime: clampedSeconds)
    seek(to: nearest)
  }

  func setScrubbing(_ isScrubbing: Bool) {
    if isScrubbing {
      wasPlayingBeforeScrubbing = isPlaying
      isPlaying = false
      return
    }
    isPlaying = wasPlayingBeforeScrubbing
  }

  var timelineDurationSeconds: Double {
    let offsetDuration = frameOffsets.last ?? 0
    return max(0.001, max(offsetDuration, fallbackTimelineDurationSeconds))
  }

  private var playbackIntervalSeconds: Double {
    let speed = speedOptions[speedOptionIndex]
    return max(1.0 / 30.0, averageFrameIntervalSeconds / speed)
  }

  private func runPlaybackLoop() async {
    await displayFrame(at: currentIndex)

    while !Task.isCancelled {
      if !isPlaying || frameCount <= 1 {
        try? await Task.sleep(nanoseconds: 80_000_000)
        continue
      }

      let interval = playbackIntervalSeconds
      let frameStartUptime = currentFrameStartUptime
      let startOffset = frameOffset(for: currentIndex)
      let endOffset = nextFrameOffset(after: currentIndex)

      while !Task.isCancelled && isPlaying {
        let elapsed = ProcessInfo.processInfo.systemUptime - frameStartUptime
        if elapsed >= interval {
          break
        }
        let progress = min(1, max(0, elapsed / interval))
        currentTimelineTimeSeconds = startOffset + (endOffset - startOffset) * progress
        try? await Task.sleep(nanoseconds: playheadTickNanoseconds)
      }
      if Task.isCancelled { break }
      if !isPlaying { continue }

      let nextIndex = (currentIndex + 1) % frameCount
      await displayFrame(at: nextIndex)
    }
  }

  private func frameOffset(for index: Int) -> Double {
    guard frameOffsets.indices.contains(index) else {
      return min(Double(index) * averageFrameIntervalSeconds, timelineDurationSeconds)
    }
    return frameOffsets[index]
  }

  private func nextFrameOffset(after index: Int) -> Double {
    let nextIndex = index + 1
    if frameOffsets.indices.contains(nextIndex) {
      return frameOffsets[nextIndex]
    }
    return timelineDurationSeconds
  }

  private func nearestFrameIndex(forTimelineTime seconds: Double) -> Int {
    guard !frameOffsets.isEmpty else { return 0 }

    var nearestIndex = 0
    var nearestDistance = abs(frameOffsets[0] - seconds)
    for (index, offset) in frameOffsets.enumerated() {
      let distance = abs(offset - seconds)
      if distance < nearestDistance {
        nearestDistance = distance
        nearestIndex = index
      }
    }
    return nearestIndex
  }

  private func displayFrame(at index: Int) async {
    guard frameCount > 0 else { return }
    let clamped = min(max(0, index), frameCount - 1)
    requestID &+= 1
    let currentRequestID = requestID

    guard let image = await loader.image(at: clamped) else { return }
    guard currentRequestID == requestID else { return }

    currentIndex = clamped
    currentImage = image
    currentTimelineTimeSeconds = frameOffset(for: clamped)
    currentFrameStartUptime = ProcessInfo.processInfo.systemUptime
    loader.prefetch(after: clamped, lookahead: 4)
  }

  private static func savedSpeedIndex(in options: [Double]) -> Int? {
    let saved = UserDefaults.standard.double(forKey: speedDefaultsKey)
    guard saved > 0 else { return nil }
    return options.firstIndex(where: { abs($0 - saved) < 0.001 })
  }
}

private final class ScreenshotSlideshowFrameLoader: @unchecked Sendable {
  private let screenshots: [Screenshot]
  private let maxPixelSize: Int
  private let decodeQueue = DispatchQueue(
    label: "com.dayflow.slideshow.decode", qos: .userInitiated)
  private var cache: [Int: NSImage] = [:]
  private var cacheOrder: [Int] = []
  private let cacheLimit = 24
  private let cacheLock = NSLock()

  init(screenshots: [Screenshot], maxRenderHeight: Int) {
    self.screenshots = screenshots
    let derivedWidth = Int((Double(maxRenderHeight) * 16.0 / 9.0).rounded())
    self.maxPixelSize = max(64, max(maxRenderHeight, derivedWidth))
  }

  func image(at index: Int) async -> NSImage? {
    if let cached = cachedImage(for: index) {
      return cached
    }

    return await withCheckedContinuation { continuation in
      decodeQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }
        let decoded = self.decodeImage(at: index)
        if let decoded {
          self.storeImage(decoded, for: index)
        }
        continuation.resume(returning: decoded)
      }
    }
  }

  func prefetch(after index: Int, lookahead: Int) {
    guard !screenshots.isEmpty else { return }
    guard lookahead > 0 else { return }

    let total = screenshots.count
    let candidateIndices = (1...lookahead).map { (index + $0) % total }
    decodeQueue.async { [weak self] in
      guard let self else { return }
      for idx in candidateIndices where self.cachedImage(for: idx) == nil {
        if let decoded = self.decodeImage(at: idx) {
          self.storeImage(decoded, for: idx)
        }
      }
    }
  }

  private func cachedImage(for index: Int) -> NSImage? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return cache[index]
  }

  private func storeImage(_ image: NSImage, for index: Int) {
    cacheLock.lock()
    defer { cacheLock.unlock() }

    cache[index] = image
    cacheOrder.removeAll { $0 == index }
    cacheOrder.append(index)

    while cacheOrder.count > cacheLimit {
      let evicted = cacheOrder.removeFirst()
      cache.removeValue(forKey: evicted)
    }
  }

  private func decodeImage(at index: Int) -> NSImage? {
    guard screenshots.indices.contains(index) else { return nil }
    let url = screenshots[index].fileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }
}
