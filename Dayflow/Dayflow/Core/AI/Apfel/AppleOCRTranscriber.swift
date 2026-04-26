//
//  AppleOCRTranscriber.swift
//  Dayflow
//
//  On-device OCR over batch screenshots using the Vision framework.
//  Emits Observations with real-world timestamps so downstream card generation
//  can treat them interchangeably with vision-LLM transcription output.
//

import AppKit
import Foundation
import Vision

enum AppleOCRError: Error, LocalizedError {
  case imageDecodeFailed(path: String)
  case noTextRecognized

  var errorDescription: String? {
    switch self {
    case .imageDecodeFailed(let path):
      return "Failed to decode screenshot at \(path)"
    case .noTextRecognized:
      return "OCR produced no text for any screenshot in this batch"
    }
  }
}

struct AppleOCRTranscriber {
  /// Max characters of OCR text we keep per frame before truncating.
  /// Keeps downstream prompts bounded in worst case (dense docs, IDE on 4K).
  var maxCharsPerFrame: Int = 1500

  /// Minimum per-word recognition confidence (0...1). Below this we drop the word.
  var minWordConfidence: Float = 0.3

  /// Target number of screenshots to sample per batch.
  /// OCR is cheap locally, but card prompts grow with frame count.
  var targetFrameSamples: Int = 30

  /// Recognition languages. Empty = Vision uses its automatic detection.
  var recognitionLanguages: [String] = []

  func transcribe(
    screenshots: [Screenshot],
    batchStartTime: Date,
    batchId: Int64?
  ) async throws -> (observations: [Observation], log: LLMCall) {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "AppleOCRTranscriber", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
    }

    let callStart = Date()
    let sorted = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    let sampled = downsample(sorted, target: targetFrameSamples)

    var frameTexts: [(screenshot: Screenshot, text: String)] = []
    frameTexts.reserveCapacity(sampled.count)

    for screenshot in sampled {
      let text = (try? recognizeText(at: screenshot.fileURL)) ?? ""
      let trimmed = String(text.prefix(maxCharsPerFrame))
      frameTexts.append((screenshot, trimmed))
    }

    let nonEmpty = frameTexts.filter { !$0.text.isEmpty }
    guard !nonEmpty.isEmpty else {
      throw AppleOCRError.noTextRecognized
    }

    let observations = buildObservations(from: nonEmpty, batchId: batchId)

    let latency = Date().timeIntervalSince(callStart)
    let log = LLMCall(
      timestamp: callStart,
      latency: latency,
      input: "Apple OCR: \(screenshots.count) screenshots (\(sampled.count) sampled)",
      output: "Produced \(observations.count) observations in \(String(format: "%.2f", latency))s"
    )
    return (observations, log)
  }

  // MARK: - Vision OCR

  private func recognizeText(at url: URL) throws -> String {
    guard let image = NSImage(contentsOf: url),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
      throw AppleOCRError.imageDecodeFailed(path: url.path)
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if !recognitionLanguages.isEmpty {
      request.recognitionLanguages = recognitionLanguages
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])

    guard let observations = request.results else { return "" }

    var lines: [String] = []
    lines.reserveCapacity(observations.count)
    for obs in observations {
      guard let candidate = obs.topCandidates(1).first,
        candidate.confidence >= minWordConfidence
      else { continue }
      let cleaned = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      if !cleaned.isEmpty {
        lines.append(cleaned)
      }
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Sampling + merging

  private func downsample(_ screenshots: [Screenshot], target: Int) -> [Screenshot] {
    guard screenshots.count > target, target > 0 else { return screenshots }
    let stride = Double(screenshots.count) / Double(target)
    var picked: [Screenshot] = []
    picked.reserveCapacity(target)
    var cursor: Double = 0
    while Int(cursor) < screenshots.count && picked.count < target {
      picked.append(screenshots[Int(cursor)])
      cursor += stride
    }
    return picked
  }

  /// Collapse consecutive frames whose text is nearly identical into one Observation
  /// spanning their combined time range. Keeps prompts small without losing timing.
  private func buildObservations(
    from frames: [(screenshot: Screenshot, text: String)],
    batchId: Int64?
  ) -> [Observation] {
    var result: [Observation] = []
    var groupStart: Int? = nil
    var groupEnd: Int? = nil
    var groupText: String = ""

    for frame in frames {
      let ts = frame.screenshot.capturedAt
      if groupStart == nil {
        groupStart = ts
        groupEnd = ts
        groupText = frame.text
        continue
      }

      if isSimilar(groupText, frame.text) {
        groupEnd = ts
      } else {
        result.append(
          makeObservation(
            batchId: batchId,
            startTs: groupStart!,
            endTs: groupEnd ?? ts,
            text: groupText
          ))
        groupStart = ts
        groupEnd = ts
        groupText = frame.text
      }
    }

    if let start = groupStart, let end = groupEnd {
      result.append(
        makeObservation(batchId: batchId, startTs: start, endTs: end, text: groupText))
    }
    return result
  }

  private func makeObservation(batchId: Int64?, startTs: Int, endTs: Int, text: String)
    -> Observation
  {
    Observation(
      id: nil,
      batchId: batchId ?? 0,
      startTs: startTs,
      endTs: max(endTs, startTs + 1),
      observation: text,
      metadata: nil,
      llmModel: "apple-ocr",
      createdAt: nil
    )
  }

  /// Cheap similarity test: share at least 60% of tokens. OCR output is noisy
  /// so an exact equality test would split every frame into its own observation.
  private func isSimilar(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let aTokens = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
    let bTokens = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
    guard !aTokens.isEmpty, !bTokens.isEmpty else { return false }
    let intersection = aTokens.intersection(bTokens).count
    let union = aTokens.union(bTokens).count
    return Double(intersection) / Double(union) >= 0.6
  }
}
