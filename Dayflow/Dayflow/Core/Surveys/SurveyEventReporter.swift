//
//  SurveyEventReporter.swift
//  Dayflow
//
//  Sends survey events to the Dayflow backend. Events are saved on disk until
//  the backend accepts them, so answers given offline aren't lost. Every event
//  has its own id, which makes resending after a failure safe.
//

import Foundation

struct SurveyEvent: Codable, Equatable {
  let clientEventId: String
  let surveyId: String
  let event: String
  let questionId: String?
  let answer: SurveyJSONValue?
  let context: [String: SurveyJSONValue]
  let occurredAt: Date
}

@MainActor
final class SurveyEventReporter {
  static let shared = SurveyEventReporter()

  private static let pendingEventsKey = "surveyPendingEvents"
  private static let failedSurveyIdsKey = "surveyFailedSurveyIds"
  private static let deviceIdKey = "surveyDeviceId"
  private static let maxPendingEvents = 300
  private static let batchSize = 50

  private var isFlushing = false

  /// A random id just for surveys, separate from the PostHog id, so survey
  /// answers can't be joined to analytics for people who turned analytics off.
  var deviceId: String {
    if let existing = UserDefaults.standard.string(forKey: Self.deviceIdKey) {
      return existing
    }
    let newId = UUID().uuidString.lowercased()
    UserDefaults.standard.set(newId, forKey: Self.deviceIdKey)
    return newId
  }

  func record(_ event: SurveyEvent) {
    var pending = loadPendingEvents()
    pending.append(event)
    savePendingEvents(Self.trimmed(pending))
    Task { await flush() }
  }

  /// If the backend is unreachable for a long time, drop the least useful
  /// events first so answers are the last thing to go.
  private static func trimmed(_ events: [SurveyEvent]) -> [SurveyEvent] {
    var kept = events
    for expendable in ["failed", "eligible", "shown"] {
      while kept.count > maxPendingEvents,
        let index = kept.firstIndex(where: { $0.event == expendable })
      {
        kept.remove(at: index)
      }
    }
    if kept.count > maxPendingEvents {
      kept.removeFirst(kept.count - maxPendingEvents)
    }
    return kept
  }

  func flush() async {
    guard !isFlushing, let url = SurveyBackend.url(path: "/v1/surveys/events") else { return }
    isFlushing = true
    defer { isFlushing = false }

    addFailureEventsIfNeeded()

    while true {
      let batch = Array(loadPendingEvents().prefix(Self.batchSize))
      guard !batch.isEmpty else { return }

      do {
        try await send(batch, to: url)
      } catch {
        rememberFailure(for: batch)
        AnalyticsService.shared.capture(
          "survey_submit_failed", ["pending_events": loadPendingEvents().count])
        return
      }

      let sentIds = Set(batch.map(\.clientEventId))
      savePendingEvents(loadPendingEvents().filter { !sentIds.contains($0.clientEventId) })
    }
  }

  private func send(_ batch: [SurveyEvent], to url: URL) async throws {
    struct Body: Encodable {
      let deviceId: String
      let events: [SurveyEvent]
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try SurveyBackend.encoder.encode(Body(deviceId: deviceId, events: batch))

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
  }

  // MARK: - Failures

  /// Remembers which surveys had events stuck, so the backend can show that
  /// devices hit errors once the events finally go through.
  private func rememberFailure(for batch: [SurveyEvent]) {
    var failed = Set(UserDefaults.standard.stringArray(forKey: Self.failedSurveyIdsKey) ?? [])
    failed.formUnion(batch.map(\.surveyId))
    UserDefaults.standard.set(Array(failed), forKey: Self.failedSurveyIdsKey)
  }

  private func addFailureEventsIfNeeded() {
    let failed = UserDefaults.standard.stringArray(forKey: Self.failedSurveyIdsKey) ?? []
    guard !failed.isEmpty else { return }
    UserDefaults.standard.removeObject(forKey: Self.failedSurveyIdsKey)

    var pending = loadPendingEvents()
    // One queued "failed" per survey is enough, however many retries fail.
    let alreadyQueued = Set(pending.filter { $0.event == "failed" }.map(\.surveyId))
    for surveyId in failed where !alreadyQueued.contains(surveyId) {
      pending.append(
        SurveyEvent(
          clientEventId: UUID().uuidString.lowercased(),
          surveyId: surveyId,
          event: "failed",
          questionId: nil,
          answer: nil,
          context: ["source": .string("submit")],
          occurredAt: Date()
        ))
    }
    savePendingEvents(Self.trimmed(pending))
  }

  // MARK: - Storage

  private func loadPendingEvents() -> [SurveyEvent] {
    guard let data = UserDefaults.standard.data(forKey: Self.pendingEventsKey) else { return [] }
    return (try? SurveyBackend.decoder.decode([SurveyEvent].self, from: data)) ?? []
  }

  private func savePendingEvents(_ events: [SurveyEvent]) {
    if events.isEmpty {
      UserDefaults.standard.removeObject(forKey: Self.pendingEventsKey)
    } else if let data = try? SurveyBackend.encoder.encode(events) {
      UserDefaults.standard.set(data, forKey: Self.pendingEventsKey)
    }
  }
}

/// Where the survey endpoints live, and how their JSON is shaped.
enum SurveyBackend {
  static func url(path: String) -> URL? {
    guard
      let base = DayflowBackendConfiguration.endpoint(
        legacySavedEndpoint: DayflowEndpointPreferences.load())
    else { return nil }
    return URL(string: base + path)
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
