import Foundation

@MainActor
final class RetryCoordinator: ObservableObject {
    enum Status: Equatable {
        case queued(position: Int, total: Int)
        case running(step: LLMProcessingStep)
        case failed
        case stopped
        case done
    }

    @Published private(set) var statuses: [Int64: Status] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var activeBatchId: Int64? = nil
    @Published private var dotTick: Int = 0

    private var dotTimer: Timer?

    func statusLine(for batchId: Int64?) -> String? {
        guard let batchId, let status = statuses[batchId] else { return nil }

        switch status {
        case .queued(let position, let total):
            return "Status: Queued (\(position) of \(total))"
        case .running(let step):
            return "Status: Reprocessing - Step: \(stepLabel(step))\(dots)"
        case .failed:
            return "Status: Failed - retry stopped"
        case .stopped:
            return "Status: Stopped - earlier batch failed"
        case .done:
            return "Status: Reprocessed"
        }
    }

    func isActive(batchId: Int64?) -> Bool {
        guard let batchId else { return false }
        return activeBatchId == batchId
    }

    func startRetry(for dayString: String, onBatchCompleted: @escaping (Int64) -> Void) {
        guard !isRunning else { return }
        isRunning = true

        Task.detached {
            let batchIds = Self.failedBatchIds(for: dayString)
            await MainActor.run {
                self.beginQueue(batchIds: batchIds, onBatchCompleted: onBatchCompleted)
            }
        }
    }

    func reset() {
        statuses = [:]
        activeBatchId = nil
        isRunning = false
        stopDotTimer()
    }

    nonisolated private static func failedBatchIds(for dayString: String) -> [Int64] {
        let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
        var seen = Set<Int64>()
        var ordered: [Int64] = []

        for card in cards {
            guard card.title == "Processing failed", let batchId = card.batchId else { continue }
            guard !seen.contains(batchId) else { continue }
            seen.insert(batchId)
            ordered.append(batchId)
        }

        return ordered
    }

    private func beginQueue(batchIds: [Int64], onBatchCompleted: @escaping (Int64) -> Void) {
        statuses = [:]
        activeBatchId = nil
        guard !batchIds.isEmpty else {
            isRunning = false
            return
        }

        let total = batchIds.count
        for (index, batchId) in batchIds.enumerated() {
            statuses[batchId] = .queued(position: index + 1, total: total)
        }

        processNext(index: 0, batchIds: batchIds, onBatchCompleted: onBatchCompleted)
    }

    private func processNext(index: Int, batchIds: [Int64], onBatchCompleted: @escaping (Int64) -> Void) {
        guard index < batchIds.count else {
            finishRun()
            return
        }

        let batchId = batchIds[index]
        activeBatchId = batchId
        statuses[batchId] = .running(step: .transcribing)
        startDotTimerIfNeeded()

        AnalysisManager.shared.reprocessBatch(
            batchId,
            stepHandler: { [weak self] step in
                self?.statuses[batchId] = .running(step: step)
            },
            completion: { [weak self] result in
                guard let self else { return }

                switch result {
                case .success:
                    self.statuses[batchId] = .done
                    onBatchCompleted(batchId)
                    self.processNext(index: index + 1, batchIds: batchIds, onBatchCompleted: onBatchCompleted)
                case .failure:
                    self.statuses[batchId] = .failed
                    self.markRemainingStopped(from: index + 1, batchIds: batchIds)
                    self.finishRun()
                }
            }
        )
    }

    private func markRemainingStopped(from index: Int, batchIds: [Int64]) {
        guard index < batchIds.count else { return }
        for i in index..<batchIds.count {
            statuses[batchIds[i]] = .stopped
        }
    }

    private func finishRun() {
        activeBatchId = nil
        isRunning = false
        stopDotTimer()
    }

    private func startDotTimerIfNeeded() {
        guard dotTimer == nil else { return }
        dotTick = 0
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dotTick = (self.dotTick + 1) % 3
        }
    }

    private func stopDotTimer() {
        dotTimer?.invalidate()
        dotTimer = nil
        dotTick = 0
    }

    private var dots: String {
        String(repeating: ".", count: (dotTick % 3) + 1)
    }

    private func stepLabel(_ step: LLMProcessingStep) -> String {
        switch step {
        case .transcribing:
            return "Transcribing"
        case .generatingCards:
            return "Generating cards"
        }
    }
}
