//
//  VideoThumbnailView.swift
//  Dayflow
//
//  Video thumbnail component for the new UI
//  Updated to support hero animation (Emil Kowalski: shared element transitions)
//

import SwiftUI
import AVKit
import AVFoundation

struct VideoThumbnailView: View {
    let videoURL: String
    var title: String? = nil
    var startTime: Date? = nil
    var endTime: Date? = nil

    // Hero animation support
    var namespace: Namespace.ID? = nil
    var expansionState: VideoExpansionState? = nil

    @State private var thumbnail: NSImage?
    @State private var showVideoPlayer = false
    @State private var requestId: Int = 0
    @State private var hostWindowSize: CGSize = .zero
    @State private var thumbnailFrame: CGRect = .zero

    // Check if hero animation is available
    private var useHeroAnimation: Bool {
        namespace != nil && expansionState != nil
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                thumbnailContent(geometry: geometry)
            }
            // Also open the viewer when clicking anywhere on the preview area
            .contentShape(Rectangle())
            .onTapGesture { triggerExpansion(geometry: geometry) }
            .id(videoURL)
            // Track containing window size to size the modal at 90%
            .background(WindowSizeReader { size in
                self.hostWindowSize = size
            })
            // Capture global frame for hero animation
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ThumbnailFrameKey.self, value: proxy.frame(in: .global))
                }
            )
            .onPreferenceChange(ThumbnailFrameKey.self) { frame in
                self.thumbnailFrame = frame
            }
            .onAppear { fetchViaCache(size: geometry.size) }
            // Ensure thumbnail updates when a new video URL is provided
            .onChange(of: videoURL) { _ in
                thumbnail = nil
                fetchViaCache(size: geometry.size)
            }
            // If our layout width meaningfully changes, refresh to better size
            .onChange(of: geometry.size.width) { _ in
                fetchViaCache(size: geometry.size)
            }
            // Fallback sheet for when hero animation isn't available
            .sheet(isPresented: $showVideoPlayer) {
                VideoPlayerModal(
                    videoURL: videoURL,
                    title: title,
                    startTime: startTime,
                    endTime: endTime,
                    containerSize: hostWindowSize
                )
            }
        }
    }

    @ViewBuilder
    private func thumbnailContent(geometry: GeometryProxy) -> some View {
        let isHeroSource = useHeroAnimation && expansionState?.videoURL == videoURL
        let shouldHide = isHeroSource && (expansionState?.isExpanded == true || expansionState?.animationPhase == .collapsing)

        ZStack {
            if let thumbnail = thumbnail {
                // Display thumbnail with 30% zoom
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.3) // 30% zoom
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .cornerRadius(12)
            } else {
                // Loading state
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.5)
                    )
            }

            // Play button overlay (match timelapse viewer style)
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
                .accessibilityLabel("Play video summary")
            }
            .buttonStyle(PlainButtonStyle())
        }
        // Apply matched geometry for hero animation
        .modifier(HeroGeometryModifier(
            id: "heroVideo_\(videoURL)",
            namespace: namespace,
            isSource: !shouldHide
        ))
        // Hide thumbnail when expanded (the overlay takes over)
        .opacity(shouldHide ? 0 : 1)
    }

    private func triggerExpansion(geometry: GeometryProxy) {
        if useHeroAnimation, let state = expansionState {
            // Immediate expansion - no delays
            state.expand(
                videoURL: videoURL,
                title: title,
                startTime: startTime,
                endTime: endTime,
                thumbnailFrame: thumbnailFrame,
                containerSize: hostWindowSize
            )
        } else {
            // Fallback to sheet presentation
            showVideoPlayer = true
        }
    }

    private func fetchViaCache(size: CGSize) {
        // Create a unique request token to guard against race conditions
        requestId &+= 1
        let currentId = requestId
        // Use the actual geometry size; avoid zero sizes
        let w = max(1, size.width)
        let h = max(1, size.height)
        let target = CGSize(width: w, height: h)
        ThumbnailCache.shared.fetchThumbnail(videoURL: videoURL, targetSize: target) { image in
            // Guard against late completions from older URLs
            if currentId == requestId {
                self.thumbnail = image
            } else {
                // Ignore stale completion
            }
        }
    }
}

// MARK: - Hero Animation Support

/// Preference key to capture thumbnail's global frame
private struct ThumbnailFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Conditional matchedGeometryEffect modifier
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
