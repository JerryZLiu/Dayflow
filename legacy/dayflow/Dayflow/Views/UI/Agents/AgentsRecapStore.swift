//
//  AgentsRecapStore.swift
//  Dayflow
//
//  Owns the Agents tab data: loads the cached recap JSON for today, and runs
//  the headless Fable sweep (via ChatCLIProcessRunner) when the user asks.
//  Runs are strictly user-initiated — there is no auto-run.
//

import Foundation

@MainActor
final class AgentsRecapStore: ObservableObject {
  static let shared = AgentsRecapStore()

  enum RunState: Equatable {
    case idle
    case running(startedAt: Date)
    case failed(String)
  }

  @Published private(set) var recap: AgentsDayRecap?
  @Published private(set) var runState: RunState = .idle
  /// Days that have a recap file on disk, oldest → newest (yyyy-MM-dd strings
  /// sort chronologically).
  @Published private(set) var availableDays: [String] = []

  /// Filename day of the recap currently loaded (kept separately from
  /// recap.day in case the model mislabeled the day inside the JSON).
  private var loadedDay: String?

  /// How long the headless sweep may take before we give up. A heavy day of
  /// sessions has been observed to exceed 15 minutes, so allow 30.
  private static let runTimeoutSeconds: TimeInterval = 1800
  private static let model = "claude-fable-5"

  struct RecapRunError: Error, Sendable {
    let message: String
  }

  private init() {
    loadCachedRecap()
  }

  var isRunning: Bool {
    if case .running = runState { return true }
    return false
  }

  // MARK: - Day + file locations

  static func currentDayString() -> String {
    DateFormatter.yyyyMMdd.string(from: Date())
  }

  static func recapDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/Dayflow/agents", isDirectory: true)
  }

  static func recapFileURL(for day: String) -> URL {
    recapDirectory().appendingPathComponent("agents-recap-\(day).json")
  }

  // MARK: - Cached recaps

  func loadCachedRecap() {
    refreshAvailableDays()
    loadBestAvailableDay()
  }

  /// Re-checks the disk when the tab appears: recap files may have been
  /// written by another process (or an earlier run) after this store was
  /// initialized. Prefers today's recap the moment one exists.
  func loadCachedRecapIfNeeded() {
    guard !isRunning else { return }
    refreshAvailableDays()
    if recap == nil {
      loadBestAvailableDay()
    } else if loadedDay != Self.currentDayString(),
      availableDays.contains(Self.currentDayString())
    {
      loadDay(Self.currentDayString())
    }
  }

  /// Shows the recap for a specific day (driven by the ‹ › day toggles).
  func selectDay(_ day: String) {
    loadDay(day)
  }

  /// Nearest older/newer days with a recap on disk, for the day toggles.
  var previousAvailableDay: String? {
    guard let current = loadedDay else { return nil }
    return availableDays.last { $0 < current }
  }

  var nextAvailableDay: String? {
    guard let current = loadedDay else { return nil }
    return availableDays.first { $0 > current }
  }

  /// Today's file if it exists, otherwise the most recent day on disk.
  private func loadBestAvailableDay() {
    let today = Self.currentDayString()
    guard let day = availableDays.contains(today) ? today : availableDays.last else {
      recap = nil
      loadedDay = nil
      return
    }
    loadDay(day)
  }

  private func loadDay(_ day: String) {
    guard
      let data = try? Data(contentsOf: Self.recapFileURL(for: day)),
      let decoded = Self.decodeRecap(from: data)
    else { return }
    recap = decoded
    loadedDay = day
  }

  private func refreshAvailableDays() {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: Self.recapDirectory().path)) ?? []
    availableDays = names.compactMap { name -> String? in
      guard name.hasPrefix("agents-recap-"), name.hasSuffix(".json") else { return nil }
      return String(name.dropFirst("agents-recap-".count).dropLast(".json".count))
    }
    .sorted()
  }

  // MARK: - Generation

  func generate() {
    guard !isRunning else { return }

    let day = Self.currentDayString()
    let outputURL = Self.recapFileURL(for: day)
    let prompt = AgentsRecapPrompt.build(day: day, outputPath: outputURL.path)
    let startedAt = Date()
    runState = .running(startedAt: startedAt)
    AnalyticsService.shared.capture("agents_recap_run_started", ["day": day])

    Task.detached(priority: .userInitiated) {
      let result = AgentsRecapStore.executeRecapRun(
        prompt: prompt, outputURL: outputURL, startedAt: startedAt)
      await MainActor.run {
        AgentsRecapStore.shared.completeRun(startedAt: startedAt, day: day, result: result)
      }
    }
  }

  private func completeRun(
    startedAt: Date, day: String, result: Result<AgentsDayRecap, RecapRunError>
  ) {
    let durationSeconds = Int(Date().timeIntervalSince(startedAt))
    switch result {
    case .success(let newRecap):
      recap = newRecap
      loadedDay = day
      refreshAvailableDays()
      runState = .idle
      AnalyticsService.shared.capture(
        "agents_recap_run_completed",
        [
          "day": day,
          "duration_seconds": durationSeconds,
          "workstreams": newRecap.workstreams.count,
          "threads": newRecap.workstreams.reduce(0) { $0 + $1.threads.count },
        ])
    case .failure(let error):
      runState = .failed(error.message)
      AnalyticsService.shared.capture(
        "agents_recap_run_failed",
        [
          "day": day,
          "duration_seconds": durationSeconds,
        ])
    }
  }

  /// Blocking; runs on a detached background task. Spawns the Claude CLI in
  /// headless mode and then reads the JSON file the run was asked to write.
  private nonisolated static func executeRecapRun(
    prompt: String, outputURL: URL, startedAt: Date
  ) -> Result<AgentsDayRecap, RecapRunError> {
    try? FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let runner = ChatCLIProcessRunner()
    let home = URL(fileURLWithPath: NSHomeDirectory())

    let runResult: ChatCLIRunResult
    do {
      runResult = try runner.run(
        tool: .claude,
        prompt: prompt,
        workingDirectory: home,
        model: model,
        timeoutSeconds: runTimeoutSeconds
      )
    } catch {
      // The run may have written a complete recap and then hung (or the
      // timeout may have fired between the write and process exit). If the
      // output file appeared after this run started, salvage it.
      if let salvaged = decodeRecapFile(at: outputURL, writtenAfter: startedAt) {
        return .success(salvaged)
      }
      return .failure(RecapRunError(message: error.localizedDescription))
    }

    guard let data = try? Data(contentsOf: outputURL) else {
      let detail = String(runResult.stderr.suffix(300))
      let stdoutTail = String(runResult.stdout.suffix(300))
      let context = detail.isEmpty ? stdoutTail : detail
      return .failure(
        RecapRunError(
          message: "The run finished but no recap file was written."
            + (context.isEmpty ? "" : "\n\n\(context)")))
    }

    guard let decoded = decodeRecap(from: data) else {
      return .failure(RecapRunError(message: "The recap file could not be parsed as valid JSON."))
    }
    return .success(decoded)
  }

  private nonisolated static func decodeRecapFile(at url: URL, writtenAfter cutoff: Date)
    -> AgentsDayRecap?
  {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let modified = attributes[.modificationDate] as? Date,
      modified > cutoff,
      let data = try? Data(contentsOf: url)
    else { return nil }
    return decodeRecap(from: data)
  }

  /// Lenient decode: tolerates markdown fences in case the model wrapped the
  /// JSON despite instructions.
  private nonisolated static func decodeRecap(from data: Data) -> AgentsDayRecap? {
    if let recap = try? JSONDecoder().decode(AgentsDayRecap.self, from: data) {
      return recap
    }
    guard var text = String(data: data, encoding: .utf8) else { return nil }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      text =
        text
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let cleaned = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(AgentsDayRecap.self, from: cleaned)
  }
}
