//
//  ScreenshotThumbnailView.swift
//  Dayflow
//
//  Screenshot-based timelapse thumbnail with hero expansion.
//

import AppKit
import SwiftUI

struct ScreenshotThumbnailView: View {
    let activity: TimelineActivity

    var namespace: Namespace.ID? = nil
    var expansionState: VideoExpansionState? = nil

    @State private var thumbnail: NSImage?
    @State private var showPlayer = false
    @State private var requestId: Int = 0
    @State private var hostWindowSize: CGSize = .zero
    @State private var thumbnailFrame: CGRect = .zero
    @State private var hasScreenshots = true

    private var useHeroAnimation: Bool {
        namespace != nil && expansionState != nil
    }

    private var heroId: String {
        "heroScreenshot_\(activity.id)"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                thumbnailContent(geometry: geometry)
            }
            .contentShape(Rectangle())
            .onTapGesture { triggerExpansion(geometry: geometry) }
            .id(activity.id)
            .background(WindowSizeReader { size in
                self.hostWindowSize = size
            })
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ThumbnailFrameKey.self, value: proxy.frame(in: .global))
                }
            )
            .onPreferenceChange(ThumbnailFrameKey.self) { frame in
                self.thumbnailFrame = frame
            }
            .onAppear { fetchThumbnail(size: geometry.size) }
            .onChange(of: activity.id) { _, _ in
                thumbnail = nil
                fetchThumbnail(size: geometry.size)
            }
            .onChange(of: geometry.size.width) { _, _ in
                fetchThumbnail(size: geometry.size)
            }
            .sheet(isPresented: $showPlayer) {
                ScreenshotPlayerModal(
                    title: activity.title,
                    startTime: activity.startTime,
                    endTime: activity.endTime,
                    containerSize: hostWindowSize
                )
            }
        }
    }

    @ViewBuilder
    private func thumbnailContent(geometry: GeometryProxy) -> some View {
        let isHeroSource = useHeroAnimation && expansionState?.heroId == heroId
        let shouldHide = isHeroSource && (expansionState?.isExpanded == true || expansionState?.animationPhase == .collapsing)

        ZStack {
            if let thumbnail = thumbnail {
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
                        Group {
                            if hasScreenshots {
                                ProgressView()
                                    .scaleEffect(0.5)
                            } else {
                                Text("No screenshots")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray.opacity(0.7))
                            }
                        }
                    )
            }

            Button(action: { triggerExpansion(geometry: geometry) }) {
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
                .accessibilityLabel("Play timelapse")
            }
            .buttonStyle(PlainButtonStyle())
        }
        .modifier(HeroGeometryModifier(
            id: heroId,
            namespace: namespace,
            isSource: !shouldHide
        ))
        .opacity(shouldHide ? 0 : 1)
    }

    private func triggerExpansion(geometry: GeometryProxy) {
        if useHeroAnimation, let state = expansionState {
            state.expandScreenshots(
                sourceId: activity.id,
                title: activity.title,
                startTime: activity.startTime,
                endTime: activity.endTime,
                thumbnailFrame: thumbnailFrame,
                containerSize: hostWindowSize
            )
        } else {
            showPlayer = true
        }
    }

    private func fetchThumbnail(size: CGSize) {
        requestId &+= 1
        let currentId = requestId
        let w = max(1, size.width)
        let h = max(1, size.height)
        let target = CGSize(width: w, height: h)
        let startTs = Int(activity.startTime.timeIntervalSince1970)
        let endTs = Int(activity.endTime.timeIntervalSince1970)

        DispatchQueue.global(qos: .userInitiated).async {
            let screenshots = StorageManager.shared.fetchScreenshotsInTimeRange(startTs: min(startTs, endTs), endTs: max(startTs, endTs))
            let mid = screenshots.isEmpty ? nil : screenshots[screenshots.count / 2]
            DispatchQueue.main.async {
                guard currentId == requestId else { return }
                guard let mid else {
                    hasScreenshots = false
                    thumbnail = nil
                    return
                }
                hasScreenshots = true
                ScreenshotThumbnailCache.shared.fetchThumbnail(fileURL: mid.fileURL, targetSize: target) { image in
                    if currentId == requestId {
                        self.thumbnail = image
                    }
                }
            }
        }
    }
}

// MARK: - Hero Animation Support

private struct ThumbnailFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct HeroGeometryModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    let isSource: Bool

    func body(content: Content) -> some View {
        if let ns = namespace {
            content
                .matchedGeometryEffect(id: id, in: ns, isSource: isSource)
        } else {
            content
        }
    }
}
