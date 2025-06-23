import SwiftUI
import AVKit
import AppKit

struct DebugView: View {
    @State private var batches = StorageManager.shared.allBatches()
    @State private var selected: Int64?
    @State private var player = AVPlayer()
    @State private var timelineEntries: [TimelineEntry] = []
    @State private var llmCalls: [LLMCall] = []
    @State private var composition: AVMutableComposition?
    @State private var isProcessing = false

    var body: some View {
        HStack(spacing: 0) {
            List(batches, id: \.id, selection: $selected) { b in
                VStack(alignment: .leading) {
                    Text("Batch \(b.id)").font(.headline)
                    Text("\(tsString(b.start)) – \(tsString(b.end))")
                        .font(.caption)
                    Text(b.status).font(.caption2)
                }
            }
            .frame(width: 220)
            .onChange(of: selected) { _, new in Task { await loadBatch(new) } }

            Divider()

            if let _ = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VideoPlayer(player: player)
                            .frame(height: 200)
                            .cornerRadius(8)
                        Button("Export Video…") { exportVideo() }
                            .disabled(composition == nil || isProcessing)

                        Button("Reprocess Batch") { triggerReprocessBatch() }
                            .disabled(isProcessing)
                            .padding(.top, 5)

                        if !timelineEntries.isEmpty {
                            Text("Timeline").font(.headline)
                            ForEach(timelineEntries) { entry in
                                TimelineEntryRowV2(entry: entry)
                            }
                        }

                        if !llmCalls.isEmpty {
                            Text("LLM Calls").font(.headline)
                            ForEach(Array(llmCalls.enumerated()), id: \.offset) { index, call in
                                LLMCallRow(index: index, call: call, dateFormatter: dateFormatter, prettyJSON: prettyJSON)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                VStack { Spacer(); Text("Select a batch").foregroundColor(.secondary); Spacer() }
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { refresh() }
        .onDisappear { player.pause() }
    }

    private func refresh() { batches = StorageManager.shared.allBatches() }

    private func loadBatch(_ id: Int64?) async {
        player.pause()
        timelineEntries = []
        llmCalls = []
        composition = nil

        guard let id else { return }
        let chunks = StorageManager.shared.recordingsForBatch(id)
        if !chunks.isEmpty {
            let comp = AVMutableComposition()
            for c in chunks {
                let asset = AVURLAsset(url: URL(fileURLWithPath: c.file_url))
                do {
                    guard try await asset.load(.isPlayable) else { continue }
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    let altTracks = try await asset.loadTracks(withMediaType: .audio)
                    guard let track = tracks.first ?? altTracks.first else { continue }
                    let dur = try await asset.load(.duration)
                    try await comp.insertTimeRange(.init(start: .zero, duration: dur), of: asset, at: comp.duration)
                } catch {
                    print("Failed to process asset \(c.file_url): \(error)")
                }
            }
            if comp.tracks.first != nil {
                composition = comp
                player.replaceCurrentItem(with: AVPlayerItem(asset: comp))
            } else {
                composition = nil
            }
        } else {
            composition = nil
        }
        timelineEntries = StorageManager.shared.fetchTimelineEntries(batchId: id)
        llmCalls = StorageManager.shared.fetchBatchLLMMetadata(batchId: id)
    }

    private func triggerReprocessBatch() {
        guard let batchId = selected, !isProcessing else { return }

        isProcessing = true
        print("Starting reprocessing for batch \(batchId)...")

        GeminiService.shared.processBatch(batchId) { result in
            DispatchQueue.main.async {
                self.isProcessing = false
                switch result {
                case .success(let cards):
                    print("Successfully reprocessed batch \(batchId). Found \(cards.count) cards.")
                case .failure(let error):
                    print("Failed to reprocess batch \(batchId): \(error.localizedDescription)")
                }
                self.refresh()
                Task { await self.loadBatch(batchId) }
            }
        }
    }

    private func exportVideo() {
        guard let comp = composition else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Batch\(selected ?? 0).mp4"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await exportComposition(comp, to: url) }
        }
    }

    private func exportComposition(_ comp: AVMutableComposition, to url: URL) async {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            guard let exp = AVAssetExportSession(asset: comp,
                                                presetName: AVAssetExportPresetPassthrough) else { return }
            exp.outputURL = url
            exp.outputFileType = .mp4
            await withCheckedContinuation { cont in
                exp.exportAsynchronously { cont.resume() }
            }
        } catch {
            print("Export failed: \(error)")
        }
    }

    private func tsString(_ ts: Int) -> String {
        dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }

    private func videoURL(from path: String) -> URL? {
        if path.hasPrefix("file://") {
            return URL(string: path)
        }
        return URL(string: "file://" + path)
    }

    private func prettyJSON(_ text: String?) -> String {
        guard let text, !text.isEmpty,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return text ?? ""
        }
        return prettyString
    }
}

struct LLMCallRow: View {
    let index: Int
    let call: LLMCall
    let dateFormatter: DateFormatter
    let prettyJSON: (String?) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Call \(index + 1) – " + dateFormatter.string(from: call.timestamp ?? Date()))
                .font(.subheadline)
            Text(String(format: "Latency %.2fs", call.latency ?? 0.0))
                .font(.caption2)
            Text("Input:")
                .font(.caption2)
            Text(prettyJSON(call.input))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Text("Output:")
                .font(.caption2)
            Text(prettyJSON(call.output))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.bottom, 6)
    }
}

struct InlineVideoPlayer: View {
    let url: URL
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: url)) }
            .onDisappear { player.pause() }
    }
}

struct TimelineEntryRowV2: View {
    let entry: TimelineEntry

    private func videoURL(from path: String) -> URL? {
        path.hasPrefix("file://") ? URL(string: path)
                                  : URL(string: "file://" + path)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(entry.start) – \(entry.end)")
                    .font(.caption)
                Text(entry.category + (entry.subcategory.map { " / \($0)" } ?? ""))
                    .font(.caption2)
                if let s = entry.summary { Text(s).font(.caption) }

                if let path = entry.video_summary_url,
                   !path.isEmpty,
                   let url  = videoURL(from: path) {
                    InlineVideoPlayer(url: url)
                        .frame(height: 120)
                        .cornerRadius(6)
                }

                // Raw distractions / metadata JSON for now
                if let meta = entry.metadata, !meta.isEmpty {
                    Text(meta)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text(entry.title).bold()
        }
        .padding(.bottom, 4)
    }
}
