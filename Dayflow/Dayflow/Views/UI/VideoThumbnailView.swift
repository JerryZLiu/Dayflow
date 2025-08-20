//
//  VideoThumbnailView.swift
//  Dayflow
//
//  Video thumbnail component for the new UI
//

import SwiftUI
import AVKit
import AVFoundation

struct VideoThumbnailView: View {
    let videoURL: String
    @State private var thumbnail: NSImage?
    @State private var showVideoPlayer = false
    
    var body: some View {
        GeometryReader { geometry in
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
                
                // Play button overlay
                Button(action: {
                    showVideoPlayer = true
                }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.7))
                                .frame(width: 60, height: 60)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .onAppear {
                extractThumbnail()
            }
            .sheet(isPresented: $showVideoPlayer) {
                VideoPlayerModal(videoURL: videoURL)
            }
        }
    }
    
    private func extractThumbnail() {
        let processedURL = videoURL.hasPrefix("file://") ? videoURL : "file://" + videoURL
        
        guard let url = URL(string: processedURL) else { return }
        
        let asset = AVAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Extract frame at 1 second (or 0 if video is shorter)
        let time = CMTime(seconds: 1, preferredTimescale: 1)
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                
                DispatchQueue.main.async {
                    self.thumbnail = nsImage
                }
            } catch {
                // Try at 0 seconds if 1 second fails
                do {
                    let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    
                    DispatchQueue.main.async {
                        self.thumbnail = nsImage
                    }
                } catch {
                    print("Failed to generate thumbnail: \(error)")
                }
            }
        }
    }
}