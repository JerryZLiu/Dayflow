import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

struct TimelineReviewCard: View {
  let activity: TimelineActivity
  let categoryColor: Color
  let progressText: String
  let overlayRating: TimelineReviewRating?
  let highlightOpacity: Double
  let isActive: Bool
  let playbackToggleToken: Int
  let onSummaryHover: (Bool) -> Void

  @AppStorage(TimelapsePreferences.saveAllTimelapsesToDiskKey) private var saveAllTimelapsesToDisk =
    false
  @StateObject private var playerModel: TimelineReviewPlayerModel
  @StateObject private var legacyPlayerModel: TimelineReviewLegacyPlayerModel
  private let previewSource = TimelineReviewScreenshotSource()
  @State private var isHoveringMedia = false
  @State private var previewImage: CGImage?
  @State private var previewRequestID: Int = 0
  @State private var wasPlayingBeforeScrub = false

  init(
    activity: TimelineActivity,
    categoryColor: Color,
    progressText: String,
    overlayRating: TimelineReviewRating?,
    highlightOpacity: Double,
    isActive: Bool,
    playbackToggleToken: Int,
    onSummaryHover: @escaping (Bool) -> Void
  ) {
    self.activity = activity
    self.categoryColor = categoryColor
    self.progressText = progressText
    self.overlayRating = overlayRating
    self.highlightOpacity = highlightOpacity
    self.isActive = isActive
    self.playbackToggleToken = playbackToggleToken
    self.onSummaryHover = onSummaryHover
    _playerModel = StateObject(wrappedValue: TimelineReviewPlayerModel(activity: activity))
    _legacyPlayerModel = StateObject(wrappedValue: TimelineReviewLegacyPlayerModel())
  }

  var body: some View {
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.white)
        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)

      VStack(spacing: 0) {
        TimelineReviewCardMedia(
          previewImage: previewImage,
          playbackState: playerModel.mediaState,
          player: usingVideoPlayer ? legacyPlayerModel.player : nil,
          onTogglePlayback: {
            guard isActive else { return }
            togglePlayback()
          }
        )
        .frame(height: Design.mediaHeight)
        .overlay(alignment: .bottom) {
          TimelineReviewPlaybackTimeline(
            playbackState: activePlaybackState,
            activityStartTime: activity.startTime,
            activityEndTime: activity.endTime,
            mediaHeight: Design.mediaHeight,
            lineHeight: Design.progressLineHeight,
            isInteractive: isActive,
            onScrubStart: beginScrub,
            onScrubChange: updateScrub(progress:),
            onScrubEnd: endScrub
          )
          .frame(height: Design.timelineHeight)
        }
        .overlay(alignment: .bottomTrailing) {
          if isHoveringMedia && isActive {
            TimelineReviewSpeedChip(
              playbackState: activePlaybackState,
              onTap: {
                if usingVideoPlayer {
                  legacyPlayerModel.cycleSpeed()
                } else {
                  playerModel.cycleSpeed()
                }
              }
            )
            .padding(SpeedChipDesign.padding)
            .zIndex(2)
          }
        }
        .onHover { hovering in
          isHoveringMedia = hovering
        }

        VStack(alignment: .leading, spacing: 12) {
          Text(activity.title)
            .font(.custom("InstrumentSerif-Regular", size: 24))
            .foregroundColor(Color.black)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)

          HStack(alignment: .center) {
            TimelineReviewCategoryPill(name: activity.category, color: categoryColor)
            Spacer()
            TimelineReviewTimeRangePill(timeRange: timeRangeText)
          }

          ScrollView(.vertical, showsIndicators: true) {
            Text(summaryText)
              .font(.custom("Nunito", size: 14).weight(.medium))
              .foregroundColor(Color(hex: "333333"))
              .lineSpacing(3)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.trailing, 4)
          }
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
          .onHover { hovering in onSummaryHover(hovering) }

          HStack {
            Spacer()
            Text(progressText)
              .font(.custom("Nunito", size: 10).weight(.medium))
              .foregroundColor(Color(hex: "AFAFAF"))
          }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))

      if let overlayRating = overlayRating {
        TimelineReviewOverlayBadge(rating: overlayRating)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .transition(.opacity)
      }
    }
    .opacity(highlightOpacity)
    .overlay {
      if !usingVideoPlayer {
        TimelineReviewDisplayLinkDriver(
          playbackState: playerModel.timelineState,
          isEnabled: isActive,
          onTick: { displayLink in playerModel.handleDisplayTick(displayLink) }
        )
        .allowsHitTesting(false)
      }
    }
    .onAppear { syncPlaybackMode() }
    .onChange(of: isActive) { syncPlaybackMode() }
    .onChange(of: activity.id) { syncPlaybackMode() }
    .onChange(of: activity.videoSummaryURL) { syncPlaybackMode() }
    .onChange(of: saveAllTimelapsesToDisk) { syncPlaybackMode() }
    .onChange(of: playbackToggleToken) { _, _ in
      guard isActive else { return }
      togglePlayback()
    }
  }

  private var summaryText: String {
    activity.summary.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var timeRangeText: String {
    let start = TimelineReviewTimeCache.shared.string(from: activity.startTime)
    let end = TimelineReviewTimeCache.shared.string(from: activity.endTime)
    return "\(start) - \(end)"
  }

  private var usingVideoPlayer: Bool {
    usesLegacySavedTimelapsePlayback && legacyPlayerModel.player != nil
  }

  private func beginScrub() {
    guard isActive else { return }
    if usingVideoPlayer {
      wasPlayingBeforeScrub = legacyPlayerModel.timelineState.isPlaying
      legacyPlayerModel.pause()
    } else {
      wasPlayingBeforeScrub = playerModel.timelineState.isPlaying
      playerModel.pause()
    }
  }

  private func updateScrub(progress: CGFloat) {
    guard isActive else { return }
    let seconds = Double(progress) * activePlaybackState.duration
    if usingVideoPlayer {
      legacyPlayerModel.seek(to: seconds, resume: false)
    } else {
      playerModel.seek(to: seconds, resume: false)
    }
  }

  private func endScrub() {
    guard isActive else { return }
    if wasPlayingBeforeScrub {
      if usingVideoPlayer { legacyPlayerModel.play() } else { playerModel.play() }
    } else {
      // Force final seek to guarantee the exact frame is rendered if left paused
      if !usingVideoPlayer {
        playerModel.seek(to: playerModel.timelineState.currentTime, resume: false)
      }
    }
    wasPlayingBeforeScrub = false
  }

  private var activePlaybackState: TimelineReviewPlaybackTimelineState {
    usingVideoPlayer ? legacyPlayerModel.timelineState : playerModel.timelineState
  }

  private func togglePlayback() {
    if usingVideoPlayer { legacyPlayerModel.togglePlay() } else { playerModel.togglePlay() }
  }

  private var usesLegacySavedTimelapsePlayback: Bool {
    saveAllTimelapsesToDisk && !(activity.videoSummaryURL?.isEmpty ?? true)
  }

  private func syncPlaybackMode() {
    if usesLegacySavedTimelapsePlayback {
      previewRequestID &+= 1
      let requestID = previewRequestID
      playerModel.reset()
      legacyPlayerModel.updateVideo(url: activity.videoSummaryURL)
      legacyPlayerModel.setActive(isActive)

      // Generate a thumbnail from the video to show while the player loads
      if let videoURL = activity.videoSummaryURL {
        let targetSize = CGSize(width: 340, height: Design.mediaHeight)
        ThumbnailCache.shared.fetchThumbnail(videoURL: videoURL, targetSize: targetSize) { image in
          guard requestID == previewRequestID else { return }
          previewImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
      } else {
        previewImage = nil
      }
      return
    }

    legacyPlayerModel.resetIfNeeded()
    loadPreviewIfNeeded()

    if isActive {
      playerModel.updateActivity(activity)
      playerModel.setActive(true)
      return
    }
    playerModel.reset()
  }

  private func loadPreviewIfNeeded() {
    previewRequestID &+= 1
    let requestID = previewRequestID
    let targetSize = CGSize(width: 340, height: Design.mediaHeight)

    Task {
      let screenshotURL = await previewSource.previewScreenshotURL(for: activity)
      guard !Task.isCancelled else { return }

      guard let screenshotURL else {
        await MainActor.run {
          guard requestID == previewRequestID else { return }
          previewImage = nil
        }
        return
      }

      await MainActor.run {
        guard requestID == previewRequestID else { return }
        ScreenshotThumbnailCache.shared.fetchThumbnail(
          fileURL: screenshotURL, targetSize: targetSize
        ) { image in
          guard requestID == previewRequestID else { return }
          previewImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
      }
    }
  }

  private enum Design {
    static let mediaHeight: CGFloat = 220
    static let progressLineHeight: CGFloat = 4
    static let timelineHeight: CGFloat = 28
  }
  private enum SpeedChipDesign { static let padding: CGFloat = 10 }
}
