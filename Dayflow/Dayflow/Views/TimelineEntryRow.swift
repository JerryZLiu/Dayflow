import SwiftUI

struct TimelineEntryRow: View {
    let entry: TimelineEntry

    // Decode distractions lazily from metadata JSON
    private var distractions: [Distraction] {
        guard
            let json = entry.metadata,
            let data = json.data(using: .utf8),
            let arr  = try? JSONDecoder().decode([Distraction].self, from: data)
        else { return [] }
        return arr
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(entry.start) – \(entry.end)")
                    .font(.caption)
                Text(entry.category + (entry.subcategory.map { " / " + $0 } ?? ""))
                    .font(.caption2)
                if let s = entry.summary { Text(s).font(.caption) }

                if let path = entry.video_summary_url,
                   !path.isEmpty,
                   let url  = URL(string: path.hasPrefix("file://") ? path : "file://\(path)") {
                    InlineVideoPlayer(url: url)
                        .frame(height: 120)
                        .cornerRadius(6)
                }

                if !distractions.isEmpty {
                    Text("Distractions").font(.subheadline)
                    ForEach(distractions) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(d.title).bold().font(.caption)
                            Text("\(d.startTime) – \(d.endTime)").font(.caption2)
                            Text(d.summary).font(.caption2)
                        }
                        .padding(.leading, 8)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text(entry.title).bold()
        }
        .padding(.bottom, 4)
    }
}