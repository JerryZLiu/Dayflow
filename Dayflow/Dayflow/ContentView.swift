//
//  ContentView.swift
//  TimelineDemo
//
//  Drop-in file: only `TimelineCard` changed so long labels
//  spill past the right edge without stretching the card.
// Never touch the scrollsync logic without explicit instructions to do so. 
//

import SwiftUI
import AppKit
import AVKit // Import AVKit for VideoPlayer

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: – Data -----------------------------------------------------------------

// Add a struct to hold grouped TimelineCard data for the UI
struct CategoryGroup: Identifiable {
    let id = UUID()
    var category: String
    var cards: [TimelineCard] // Keep original cards for details
    var subcategories: [String] { // Extract unique subcategories for sidebar display (optional)
        Array(Set(cards.map { $0.subcategory })).sorted()
    }
    var rows: Int { subcategories.count } // Or adjust based on how you display in sidebar
}

// MARK: – Zoom model -----------------------------------------------------------

enum Zoom: Int, CaseIterable, Identifiable {
    case h1 = 1, h2, h4 = 4, h8 = 8
    var id: Self { self }
    var label: String { "\(rawValue) h" }
    var pxPerMin: CGFloat {
        switch self {
        case .h1: return 10
        case .h2: return 5
        case .h4: return 2.5
        case .h8: return 1.25
        }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

private let appBG = Color(hex: 0xFDFDFD)

// MARK: – Helpers --------------------------------------------------------------

private let sidebarW:  CGFloat = 240
private let headerH:   CGFloat = 36
private let rowH:      CGFloat = 40
private let startMin            = 6 * 60     // 06:00
private let endMin              = 27 * 60    // 03:00 next day
private let scrollerH           = NSScroller.scrollerWidth(for: .regular,
                                                           scrollerStyle: .legacy)

// Wrap minutes that fall *before* the 06:00 boundary into “next day”.
@inline(__always) func adjustedMinute(_ m: Int) -> Int {
    m < startMin ? m + 24*60 : m
}

@inline(__always) func minutes(at x: CGFloat, pxPerMin: CGFloat) -> Int {
    Int((x / pxPerMin).rounded())
}

private func timeString(_ min: Int) -> String {
    let total = min % (24 * 60)
    let h24   = total / 60
    let m     = total % 60
    let amPM  = h24 < 12 ? "AM" : "PM"
    let h12   = h24 == 0 ? 12 : (h24 > 12 ? h24 - 12 : h24)
    return String(format: "%d:%02d %@", h12, m, amPM)
}

// MARK: – Scroll link model ----------------------------------------------------

final class ScrollSync: ObservableObject {
    @Published var x: CGFloat = .zero
    @Published var y: CGFloat = .zero
}

// MARK: – SyncableScroll (unchanged) ------------------------------------------

struct SyncableScroll<Content: View>: NSViewRepresentable {
    enum Axis { case x, y, both }
    enum Role { case master, follower }
    let axis: Axis
    let role: Role
    @ObservedObject var sync: ScrollSync
    let content: Content
    
    init(_ axis: Axis, role: Role = .master, sync: ScrollSync,
         @ViewBuilder _ content: () -> Content) {
        self.axis   = axis
        self.role   = role
        self._sync  = ObservedObject(wrappedValue: sync)
        self.content = content()
    }
    
    func makeCoordinator() -> Coord { Coord(sync: sync, role: role) }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller   = false
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle         = .overlay
        scroll.autohidesScrollers    = true
        
        let host = context.coordinator.host
        scroll.documentView = host
        host.translatesAutoresizingMaskIntoConstraints = false
        host.topAnchor    .constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        host.widthAnchor  .constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor).isActive = true
        host.heightAnchor .constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true
        
        if role == .master && (axis == .x || axis == .both) {
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers    = false
            scroll.scrollerStyle         = .legacy
        }
        
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coord.boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        
        if role == .master {
            let pan = NSPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coord.handlePan(_:)))
            pan.buttonMask = 0x1   // left mouse
            scroll.contentView.addGestureRecognizer(pan)
        }
        return scroll
    }
    
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if axis != .y && scroll.contentView.bounds.origin.x != sync.x {
            scroll.contentView.bounds.origin.x = sync.x
        }
        if axis != .x && scroll.contentView.bounds.origin.y != sync.y {
            scroll.contentView.bounds.origin.y = sync.y
        }
        context.coordinator.host.rootView = AnyView(content)
    }
    
    // MARK: – Coordinator
    class Coord: NSObject {
        let role: Role
        let host = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
        @ObservedObject var sync: ScrollSync
        init(sync: ScrollSync, role: Role) {
            self._sync = ObservedObject(wrappedValue: sync)
            self.role = role
        }
        private var isProgrammatic = false
        private var dragAnchor = CGPoint.zero
        
        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            guard role == .master, let clip = g.view as? NSClipView else { return }
            switch g.state {
            case .began: dragAnchor = clip.bounds.origin
            case .changed:
                let delta = g.translation(in: clip)
                let doc   = clip.documentView?.frame.size ?? .zero
                let clipS = clip.bounds.size
                var newX = dragAnchor.x - delta.x
                var newY = dragAnchor.y - delta.y
                newX = max(0, min(newX, doc.width  - clipS.width))
                newY = max(0, min(newY, doc.height - clipS.height))
                isProgrammatic = true
                clip.bounds.origin = CGPoint(x: newX, y: newY)
                isProgrammatic = false
                DispatchQueue.main.async {
                    self.sync.x = newX
                    self.sync.y = newY
                }
            default: break
            }
        }
        
        @objc func boundsChanged(_ n: Notification) {
            guard let clip = n.object as? NSClipView else { return }
            if isProgrammatic { return }
            if role == .master {
                    let newX = clip.bounds.origin.x
                    let newY = clip.bounds.origin.y

                    DispatchQueue.main.async { [weak self] in
                        guard let sync = self?.sync else { return }
                        if newX != sync.x { sync.x = newX }
                        if newY != sync.y { sync.y = newY }
                    }
                } else {
                if clip.bounds.origin.x != sync.x || clip.bounds.origin.y != sync.y {
                    isProgrammatic = true
                    clip.bounds.origin = CGPoint(x: sync.x, y: sync.y)
                    isProgrammatic = false
                }
            }
        }
    }
}

// MARK: – Placeholder View for No Data

struct WaitingForDataView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Waiting to collect enough data...")
                .font(.title2)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appBG) // Match the app background
    }
}

// MARK: – Root view -------------------------------------------------------------

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var link = ScrollSync()
    @State private var categoryGroups: [CategoryGroup] = []
    @State private var zoom: Zoom = .h4
    @State private var hoverX: CGFloat?
    @State private var currentDayString: String = ""
    @State private var refreshTimer: Timer?

    // Access StorageManager (kept for future switch back)
    private let storageManager = StorageManager.shared

    var body: some View {
        let pxPerMin = zoom.pxPerMin

        VStack(spacing: 0) {
            // header
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("CATEGORIES") // Changed from SUBJECTS
                    Picker("", selection: $zoom) {
                        ForEach(Zoom.allCases) { z in Text(z.label) }
                    }
                    .frame(width: 70)
                    .padding(.trailing, 20)

                    Spacer()
                }
                .padding(.leading, 12)
                .font(.caption.weight(.semibold))
                .frame(width: sidebarW, height: headerH, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 0.5)
                }

                SyncableScroll(.x, role: .follower, sync: link) {
                    TimeScale(pxPerMin: pxPerMin,
                              hoverX: hoverX,
                              startMin: startMin)
                    .frame(height: headerH)
                }
                .disabled(true)
            }
            .background(appBG)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
            }

            // --- Body: Conditional display of Timeline or Placeholder ---
            if categoryGroups.isEmpty {
                WaitingForDataView()
            } else {
                // sidebar + canvas (REPLACED with HSplitView for view switching)
                HSplitView {
                    // Left Pane: Sidebar
                    SyncableScroll(.y, role: .follower, sync: link) {
                        Sidebar(groups: $categoryGroups)
                            .frame(width: sidebarW, alignment: .leading)
                    }
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 0.5)
                    }
                    .frame(minWidth: sidebarW, idealWidth: sidebarW, maxWidth: sidebarW)
                    
                    // Right Pane: Always show Timeline Canvas
                    SyncableScroll(.both, role: .master, sync: link) {
                        Canvas(groups: categoryGroups,
                               pxPerMin: pxPerMin,
                               hoverX: $hoverX)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.30), value: zoom)
        .frame(maxWidth: .infinity,
               maxHeight: .infinity,
               alignment: .topLeading)
        .background(appBG)
        .onAppear {
            loadTimelineData()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in
                loadTimelineData()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            print("ContentView disappeared: Refresh timer invalidated.")
        }
    }

    func loadTimelineData() {
        let dayInfo = Date().getDayInfoFor4AMBoundary()
        currentDayString = dayInfo.dayString
        let fetchedCards = storageManager.fetchTimelineCards(forDay: currentDayString)
        print("Fetched \(fetchedCards.count) cards for day \(currentDayString):")
        for card in fetchedCards {
            print("  - \(card.title) (\(card.startTimestamp) - \(card.endTimestamp)), Category: \(card.category), Subcategory: \(card.subcategory)")
        }
        
        // Merge timeline segments with small gaps
        let mergedCards = mergeCardsWithSmallGaps(cards: fetchedCards)
        
        // Group fetched cards by category (Keep this logic)
        let grouped = Dictionary(grouping: mergedCards, by: { $0.category })
        
        // Convert grouped dictionary to CategoryGroup array (Keep this logic)
        categoryGroups = grouped.map { category, cardsInGroup in
            // Sort cards within the group by start time using the parser
            let sortedCards = cardsInGroup.sorted {
                guard let s1 = parseTimeHMMA(timeString: $0.startTimestamp).map(adjustedMinute),
                       let s2 = parseTimeHMMA(timeString: $1.startTimestamp).map(adjustedMinute) else { return false }
                return s1 < s2
            }

            return CategoryGroup(category: category, cards: sortedCards)
        }.sorted { $0.category < $1.category } // Sort categories alphabetically
        
    }
    
    /// Merges timeline cards that have the same category and subcategory with less than 5 minutes gap between them
    private func mergeCardsWithSmallGaps(cards: [TimelineCard]) -> [TimelineCard] {
        guard !cards.isEmpty else { return [] }
        
        // Sort cards by start time
        let sortedCards = cards.sorted { card1, card2 -> Bool in
            guard let startMin1 = parseTimeHMMA(timeString: card1.startTimestamp),
                  let startMin2 = parseTimeHMMA(timeString: card2.startTimestamp) else {
                return false
            }
            return startMin1 < startMin2
        }
        
        var result: [TimelineCard] = []
        var currentCardAccumulator: TimelineCard? = nil // Renamed for clarity
        var accumulatedVideoURLs: [String] = [] // To collect video URLs for merging
        
        for card in sortedCards {
            if let current = currentCardAccumulator {
                guard let currentEndMin = parseTimeHMMA(timeString: current.endTimestamp),
                      let nextStartMin = parseTimeHMMA(timeString: card.startTimestamp) else {
                    result.append(current) // Add accumulated card
                    currentCardAccumulator = card // Start new accumulation with current card
                    accumulatedVideoURLs = [card.videoSummaryURL].compactMap { $0 } + (card.otherVideoSummaryURLs ?? [])
                    continue
                }
                
                let timeDifference = nextStartMin - currentEndMin
                let sameCategory = current.category == card.category
                let sameSubcategory = current.subcategory == card.subcategory
                
                if timeDifference <= 5 && sameCategory && sameSubcategory {
                    // Merge this card into currentCardAccumulator
                    let mergedDistractions = combineDistractions(current.distractions, card.distractions)
                    
                    // Collect video URLs
                    if let videoURL = card.videoSummaryURL, !videoURL.isEmpty {
                        accumulatedVideoURLs.append(videoURL)
                    }
                    if let otherURLs = card.otherVideoSummaryURLs {
                        accumulatedVideoURLs.append(contentsOf: otherURLs)
                    }
                    // Remove duplicates just in case, though ideally source data is clean
                    accumulatedVideoURLs = Array(Set(accumulatedVideoURLs))

                    currentCardAccumulator = TimelineCard(
                        startTimestamp: current.startTimestamp,
                        endTimestamp: card.endTimestamp, // Extend to the new card's end time
                        category: current.category,
                        subcategory: current.subcategory,
                        title: current.title, // Keep the first card's title for the merged entity
                        summary: "\(current.summary) \(card.summary)",
                        detailedSummary: "\(current.detailedSummary) Then: \(card.detailedSummary)",
                        day: current.day,
                        distractions: mergedDistractions,
                        videoSummaryURL: accumulatedVideoURLs.first, // Primary is the first collected URL
                        otherVideoSummaryURLs: accumulatedVideoURLs.count > 1 ? Array(accumulatedVideoURLs.dropFirst()) : nil
                    )
                } else {
                    // Finalize the previous accumulated card and add it to results
                    result.append(current)
                    // Start a new accumulation with the current card
                    currentCardAccumulator = card
                    accumulatedVideoURLs = [card.videoSummaryURL].compactMap { $0 } + (card.otherVideoSummaryURLs ?? [])
                }
            } else {
                // This is the very first card, start accumulation
                currentCardAccumulator = card
                accumulatedVideoURLs = [card.videoSummaryURL].compactMap { $0 } + (card.otherVideoSummaryURLs ?? [])
            }
        }
        
        // Add the last accumulated card if it exists
        if let lastCard = currentCardAccumulator {
            result.append(lastCard)
        }
        
        return result
    }
    
    /// Helper to combine distractions from two cards
    private func combineDistractions(_ distractions1: [Distraction]?, _ distractions2: [Distraction]?) -> [Distraction]? {
        // If both are nil, result is nil
        if distractions1 == nil && distractions2 == nil {
            return nil
        }
        
        // Start with non-nil array or empty
        var combined = distractions1 ?? []
        
        // Add second array if it exists
        if let distractions2 = distractions2 {
            combined.append(contentsOf: distractions2)
        }
        
        // If combined is empty, return nil instead of empty array
        return combined.isEmpty ? nil : combined
    }
}

// MARK: – Time scale -----------------------------------------------------------

struct TimeScale: View {
    let pxPerMin: CGFloat
    let hoverX: CGFloat?
    let startMin: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ── base hour ticks ───────────────────────────────
            HStack(spacing: 0) {
                        ForEach(Array(stride(from: startMin,
                                             through: endMin,
                                             by: 60)), id: \.self) { t in
                            ZStack {
                                // 1) pin the tick to the **leading** edge, at the bottom
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.5))
                                    .frame(width: 1, height: 4)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            
                                // 2) center the label *over* that tick by shifting it left ½ cell
                                Text(timeString(t))
                                    .font(.caption2)
                                    .offset(x: -0.5 * 60 * pxPerMin)
                            }
                            .frame(width: 60 * pxPerMin)
                        }
                    }
            // ── cursor vertical line & live-time pill ─────────
            if let x = hoverX {
                        let lblMin = startMin + minutes(at: x, pxPerMin: pxPerMin)
                        Text(timeString(lblMin))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(appBG)
                                    .shadow(radius: 1)
                            )
                            // center the pill exactly on the hairline (x)
                            // and vertically in the middle of the header (headerH/2)
                            .position(x: x, y: headerH / 2)
                            .allowsHitTesting(false)
                    }
        }.background(appBG)
    }
}

// MARK: – Sidebar --------------------------------------------------------------

struct Sidebar: View {
    @Binding var groups: [CategoryGroup]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups.indices, id: \.self) { i in
                let group = groups[i]
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(group.category).font(.system(size: 16, weight: .semibold))
                    }
                    .frame(height: rowH)
                    .padding(.horizontal, 12)
                    
                    ForEach(group.subcategories, id: \.self) { subcatName in
                        Text(subcatName)
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                                .frame(height: rowH)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
                }
            }
            Color.clear.frame(height: scrollerH)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: – Canvas ---------------------------------------------------------------

struct Canvas: View {
    let groups: [CategoryGroup]
    let pxPerMin: CGFloat
    @Binding var hoverX: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {

            // live vertical hair-line
            if let x = hoverX {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 0.5)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: x)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    CategoryLane(group: group, pxPerMin: pxPerMin)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(height: 0.5)
                        }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(appBG)
        .background(HoverSensor(hoverX: $hoverX))
    }
}

// MARK: – Hover sensor ---------------------------------------------------------

private struct HoverSensor: NSViewRepresentable {
    @Binding var hoverX: CGFloat?
    func makeCoordinator() -> NSView { TrackingView(hoverX: $hoverX) }
    func makeNSView(context: Context) -> NSView { context.coordinator }
    func updateNSView(_: NSView, context: Context) {}

    final class TrackingView: NSView {
        @Binding var hoverX: CGFloat?
        init(hoverX: Binding<CGFloat?>) {
            self._hoverX = hoverX
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            let opts: NSTrackingArea.Options = [.mouseMoved,
                                                .mouseEnteredAndExited,
                                                .activeInKeyWindow,
                                                .inVisibleRect]
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: opts,
                                           owner: self,
                                           userInfo: nil))
        }
        override func mouseMoved(with e: NSEvent) {
            let loc = convert(e.locationInWindow, from: nil)
            hoverX = max(0, loc.x)
        }
        override func mouseExited(with _: NSEvent) { hoverX = nil }
    }
}

// MARK: – Lanes & cards --------------------------------------------------------

struct CategoryLane: View {
    let group: CategoryGroup
    let pxPerMin: CGFloat
    var body: some View {
        // Calculate height: 1 row for Category header + 1 row for each Subcategory (no longer depends on isExpanded)
        let totalRows = 1 + group.subcategories.count
        
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: CGFloat(totalRows) * rowH)

            ForEach(Array(group.subcategories.enumerated()), id: \.element) { subcategoryIndex, subcategoryName in
                let cardsInSubcategory = group.cards.filter { $0.subcategory == subcategoryName }
                    .sorted { card1, card2 in
                        guard let start1 = parseTimeHMMA(timeString: card1.startTimestamp),
                              let start2 = parseTimeHMMA(timeString: card2.startTimestamp) else {
                            return false
                        }
                        return start1 < start2
                    }
                let cardRowIndex = subcategoryIndex + 1
                
                ForEach(Array(cardsInSubcategory.enumerated()), id: \.element.id) { index, card in
                    let nextCard = index + 1 < cardsInSubcategory.count ? cardsInSubcategory[index + 1] : nil
                    TimelineCardView(card: card,
                                     rowIndex: cardRowIndex,
                                     pxPerMin: pxPerMin,
                                     nextCard: nextCard)
                }
            }
        }
        .frame(width: CGFloat(endMin - startMin) * pxPerMin,
               height: CGFloat(totalRows) * rowH,
               alignment: .topLeading)
    }
}

struct TimelineCardView: View {
    let card: TimelineCard
    let rowIndex: Int
    let pxPerMin: CGFloat
    let nextCard: TimelineCard?
    @State private var hover = false
    @State private var avPlayer: AVPlayer? = nil
    @State private var popoverID = UUID() // Forces popover refresh

    // State for auto-cycling videos
    @State private var videoURLsForPlayback: [String] = []
    @State private var currentPlayerItemIndex: Int = 0
    @State private var playerObserver: Any? // For .AVPlayerItemDidPlayToEndTime

     private var startMinute: Int? {
         parseTimeHMMA(timeString: card.startTimestamp).map(adjustedMinute)
     }
     private var endMinute: Int?   {
         parseTimeHMMA(timeString: card.endTimestamp).map(adjustedMinute)
     }
    
    private var width: CGFloat {
        guard let startM = startMinute, let endM = endMinute, endM > startM else { return 0 }
        return CGFloat(endM - startM) * pxPerMin
    }
    private var xOffset: CGFloat {
        guard let startM = startMinute else { return 0 }
        return CGFloat(max(0, startM - startMin)) * pxPerMin 
    }
    private var yOffset: CGFloat {
        CGFloat(rowIndex) * rowH + 4
    }
    
    private var shouldAllowTextOverflow: Bool {
        guard let nextCard = nextCard,
              let nextCardStart = parseTimeHMMA(timeString: nextCard.startTimestamp).map(adjustedMinute) else {
            return true // No next card, allow overflow
        }
        
        let nextCardXOffset = CGFloat(max(0, nextCardStart - startMin)) * pxPerMin
        let currentCardEndX = xOffset + width
        let gapToNextCard = nextCardXOffset - currentCardEndX
        
        // Estimate text width (rough approximation)
        let estimatedTextWidth = CGFloat(card.title.count) * 8 // ~8px per character
        let textOverflow = max(0, estimatedTextWidth - width)
        
        // Allow overflow only if text won't reach the next card
        return gapToNextCard > textOverflow + 20 // 20px safety margin
    }

    var body: some View {
        if let cardStartMinute = self.startMinute, 
           let cardEndMinute = self.endMinute, 
           cardEndMinute > cardStartMinute, 
           width > 0 {
            
            ZStack(alignment: .topLeading) {
                // Group for the card visual, its hover interaction, and popover
                Group {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color(red: 0.90, green: 0.90, blue: 0.90), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
                        // Title overlay directly on the RoundedRectangle is fine
                        .overlay(alignment: .leading) { 
                            Text(card.title)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                                .if(shouldAllowTextOverflow) { view in
                                    view.fixedSize(horizontal: true, vertical: false)
                                }
                                .if(!shouldAllowTextOverflow) { view in
                                    view.truncationMode(.tail)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        // Hover text for card's start/end time, also fine here
                        .overlay( 
                            Text("\(card.startTimestamp) – \(card.endTimestamp)")
                                .font(.caption2)
                                .padding(4)
                                .background(Color.white.opacity(0.9))
                                .cornerRadius(4)
                                .shadow(radius: 1)
                                .opacity(hover ? 1 : 0)
                                .offset(x: 0, y: -22) 
                                .animation(.easeInOut(duration: 0.1), value: hover)
                        )
                }
                .frame(width: width, height: rowH - 8) // Frame applied to the Group
                .onHover { hover = $0 } // .onHover applied to the Group
                .popover(isPresented: $hover, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { // .popover applied to the Group
                    VStack(alignment: .leading, spacing: 8) {
                        // Added full title to popover
                        Text(card.title)
                            .font(.headline)
                        Text("\(card.startTimestamp) – \(card.endTimestamp)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(card.summary)
                            .font(.callout)
                        
                        if let videoPath = card.videoSummaryURL,
                           !videoPath.isEmpty {
                            if let player = avPlayer {
                                VideoPlayer(player: player)
                                    .frame(width: 300, height: 168)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Text("Loading video...")
                                    .frame(width: 300, height: 168)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        } else if card.videoSummaryURL != nil && (card.videoSummaryURL?.isEmpty ?? true) {
                            Text("Video summary URL is empty.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .frame(width: 300, alignment: .center)
                        } 
                        // Removed the 'else' for no video URL to simply show nothing if no video
                    }
                    .padding()
                    .frame(width: 320)
                }
                .id(popoverID) // Force NSPopover to reload when ID changes
                .onChange(of: hover) { _, newValue in
                    if newValue { // Hover started
                        setupVideoPlayback()
                    } else { // Hover ended
                        cleanupVideoPlayback()
                    }
                }
                .offset(x: self.xOffset, y: self.yOffset) // Offset the entire Group

                // Distraction Markers - their positioning logic is relative to the ZStack and should still be correct
                if let distractions = card.distractions {
                    ForEach(distractions, id: \.id) { distraction in 
                        if let distractionStartAbsMinute = parseTimeHMMA(timeString: distraction.startTime) {
                            let emojiCenterX = CGFloat(distractionStartAbsMinute - startMin) * pxPerMin
                            let totalTimelineWidth = CGFloat(endMin - startMin) * pxPerMin
                            if emojiCenterX >= 0 && emojiCenterX <= totalTimelineWidth {
                                let emojiCenterY = self.yOffset - 8 
                                Text("!")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color.orange)
                                    .padding(3) 
                                    .background(
                                        Circle()
                                            .fill(Color.white.opacity(0.85))
                                            .shadow(color: Color.black.opacity(0.4), radius: 1.5, x: 0, y: 1)
                                    )
                                    .frame(width: 16, height: 16) 
                                    .position(x: emojiCenterX, y: emojiCenterY) 
                                    .zIndex(10) 
                            }
                        }
                    }
                }
            }
        } else {
            EmptyView()
                .onAppear {
                    print("Warning: Could not render card '\(card.title)' due to invalid time: Start='\(card.startTimestamp)', End='\(card.endTimestamp)'")
                }
        }
    }

    private func setupVideoPlayback() {
        var urls: [String] = []
        if let primaryURL = card.videoSummaryURL, !primaryURL.isEmpty {
            urls.append(primaryURL)
        }
        if let otherURLs = card.otherVideoSummaryURLs {
            urls.append(contentsOf: otherURLs.filter { !$0.isEmpty })
        }
        
        self.videoURLsForPlayback = urls.map { $0.hasPrefix("file://") ? $0 : "file://" + $0 }
        self.currentPlayerItemIndex = 0
        
        playVideo(at: self.currentPlayerItemIndex)
    }

    private func cleanupVideoPlayback() {
        self.avPlayer?.pause()
        self.avPlayer = nil
        if let observer = self.playerObserver {
            NotificationCenter.default.removeObserver(observer)
            self.playerObserver = nil
        }
        self.videoURLsForPlayback = []
        self.currentPlayerItemIndex = 0
        // self.popoverID = UUID() // Refresh popover if needed on close, debatable
    }

    private func playVideo(at index: Int) {
        guard index < self.videoURLsForPlayback.count else {
            print("TimelineCardView: All videos played or no video at index \(index).")
            // Optionally loop here by setting index to 0 and calling playVideo(at: 0)
            // For now, it will just stop. Player will be nilled out on hover end.
            self.avPlayer?.pause() // Pause if it was the last video
            // To visually clear the player or show "end of playlist":
            // self.avPlayer = nil // This would clear the VideoPlayer view if it shows "Loading..." for nil player
            // self.popoverID = UUID() 
            return
        }

        let videoPath = self.videoURLsForPlayback[index]
        guard let videoURL = URL(string: videoPath) else {
            print("TimelineCardView: Invalid video URL string: \(videoPath) at index \(index).")
            // Attempt to play next video if current one is invalid
            playNextVideo()
            return
        }
        
        print("TimelineCardView: Playing video \(index + 1)/\(self.videoURLsForPlayback.count): \(videoURL.absoluteString) for card '\(card.title)'")
        
        let playerItem = AVPlayerItem(url: videoURL)
        
        if self.avPlayer == nil {
            self.avPlayer = AVPlayer(playerItem: playerItem)
        } else {
            self.avPlayer?.replaceCurrentItem(with: playerItem)
        }
        
        // Remove previous observer before adding a new one
        if let observer = self.playerObserver {
            NotificationCenter.default.removeObserver(observer)
            self.playerObserver = nil
        }
        
        self.playerObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            print("TimelineCardView: Video finished, trying next.")
            self.playNextVideo()
        }
        
        self.popoverID = UUID() // Refresh popover to ensure it picks up new player/item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // Slight delay for setup
            if self.hover { // Play only if still hovering
                 self.avPlayer?.play()
            }
        }
    }
    
    private func playNextVideo() {
        self.currentPlayerItemIndex += 1
        playVideo(at: self.currentPlayerItemIndex)
    }
}

// MARK: – Preview --------------------------------------------------------------

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState.shared)
    }
}
