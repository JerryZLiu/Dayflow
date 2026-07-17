import Foundation

enum ClaudeStrictJSONParserError: Error, Equatable, LocalizedError {
  case noActivityCards
  case noSegments
  case invalidActivityCard(index: Int, field: String)
  case duplicateJSONKey(String)
  case conflictingActivityCardTimestampAliases(index: Int, first: String, second: String)
  case ambiguousActivityCardPayloads
  case ambiguousSegmentPayloads
  case undecodableActivityCards
  case undecodableSegments

  var errorDescription: String? {
    switch self {
    case .noActivityCards:
      return "Claude returned an empty activity-card list."
    case .noSegments:
      return "Claude returned an empty transcription segment list."
    case .invalidActivityCard(let index, let field):
      return "Claude activity card \(index + 1) is missing or has an invalid \(field)."
    case .duplicateJSONKey(let key):
      return "Claude returned a JSON object with the duplicate key '\(key)'."
    case .conflictingActivityCardTimestampAliases(let index, let first, let second):
      return
        "Claude activity card \(index + 1) contains both '\(first)' and '\(second)'. Return exactly one timestamp field."
    case .ambiguousActivityCardPayloads:
      return "Claude returned more than one activity-card JSON payload."
    case .ambiguousSegmentPayloads:
      return "Claude returned more than one transcription JSON payload."
    case .undecodableActivityCards:
      return "Failed to decode Claude activity-card JSON."
    case .undecodableSegments:
      return "Failed to decode Claude transcription JSON."
    }
  }
}

/// Retired strict parser retained for reference and isolated tooling. Production Claude and
/// ChatGPT generation intentionally use the tolerant parsers in `AgentCLISupporting` instead.
extension ClaudeProvider {
  func parseClaudeCardsStrict(from output: String, stderr: String) throws -> [ActivityCardData] {
    do {
      return try Self.parseStrictActivityCards(from: output)
    } catch {
      if let cliError = extractCLIError(stdout: output, stderr: stderr) {
        throw NSError(
          domain: "ClaudeProvider",
          code: -33,
          userInfo: [NSLocalizedDescriptionKey: cliError]
        )
      }
      throw error
    }
  }

  func parseClaudeSegmentsStrict(from output: String, stderr: String) throws
    -> [SegmentMergeResponse.Segment]
  {
    do {
      return try Self.parseStrictSegments(from: output)
    } catch {
      if let cliError = extractCLIError(stdout: output, stderr: stderr) {
        throw NSError(
          domain: "ClaudeProvider",
          code: -33,
          userInfo: [NSLocalizedDescriptionKey: cliError]
        )
      }
      throw error
    }
  }

  /// Decodes Claude's card response without rewriting its JSON or semantic fields.
  ///
  /// The raw response is attempted first. If Claude surrounds an otherwise valid response with
  /// prose, one enclosing Markdown fence, or terminal OSC text, balanced JSON candidates are
  /// decoded byte-for-byte. Characters inside the JSON payload are never stripped or escaped.
  static func parseStrictActivityCards(from output: String) throws -> [ActivityCardData] {
    // Preserve the exact fast path: a bare response is decoded before any extraction is attempted.
    if let cards = try decodeStrictActivityCards(output) {
      return cards
    }

    var recognized: [Result<[ActivityCardData], ClaudeStrictJSONParserError>] = []
    for candidate in balancedJSONValues(in: output) {
      do {
        if let cards = try decodeStrictActivityCards(candidate) {
          recognized.append(.success(cards))
        }
      } catch let error as ClaudeStrictJSONParserError {
        recognized.append(.failure(error))
      } catch {
        recognized.append(.failure(.undecodableActivityCards))
      }
    }

    guard !recognized.isEmpty else {
      throw ClaudeStrictJSONParserError.undecodableActivityCards
    }
    guard recognized.count == 1 else {
      throw ClaudeStrictJSONParserError.ambiguousActivityCardPayloads
    }
    return try recognized[0].get()
  }

  /// Decodes Claude's transcription response without rewriting descriptions or timestamps.
  static func parseStrictSegments(from output: String) throws -> [SegmentMergeResponse.Segment] {
    // Preserve the exact fast path: a bare response is decoded before any extraction is attempted.
    if let segments = try decodeStrictSegments(output) {
      return segments
    }

    var recognized: [Result<[SegmentMergeResponse.Segment], ClaudeStrictJSONParserError>] = []
    for candidate in balancedJSONValues(in: output) {
      do {
        if let segments = try decodeStrictSegments(candidate) {
          recognized.append(.success(segments))
        }
      } catch let error as ClaudeStrictJSONParserError {
        recognized.append(.failure(error))
      } catch {
        recognized.append(.failure(.undecodableSegments))
      }
    }

    guard !recognized.isEmpty else { throw ClaudeStrictJSONParserError.undecodableSegments }
    guard recognized.count == 1 else {
      throw ClaudeStrictJSONParserError.ambiguousSegmentPayloads
    }
    return try recognized[0].get()
  }
}

extension ClaudeProvider {
  private static func decodeStrictActivityCards(_ candidate: String) throws
    -> [ActivityCardData]?
  {
    let data = Data(candidate.utf8)
    let decoder = JSONDecoder()

    if let cards = try? decoder.decode([ActivityCardData].self, from: data) {
      try validateUniqueJSONKeys(in: candidate, fallbackError: .undecodableActivityCards)
      try validateCardTimestampAliasPresence(in: data)
      guard !cards.isEmpty else { throw ClaudeStrictJSONParserError.noActivityCards }
      return cards
    }

    guard let envelope = try? decoder.decode(AgentCLICardsEnvelope.self, from: data) else {
      return nil
    }

    try validateUniqueJSONKeys(in: candidate, fallbackError: .undecodableActivityCards)
    try validateCardTimestampAliasPresence(in: data)
    guard !envelope.cards.isEmpty else { throw ClaudeStrictJSONParserError.noActivityCards }

    return try envelope.cards.enumerated().map { index, item in
      guard let start = item.normalizedStart,
        !start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ClaudeStrictJSONParserError.invalidActivityCard(index: index, field: "start time")
      }
      guard let end = item.normalizedEnd,
        !end.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ClaudeStrictJSONParserError.invalidActivityCard(index: index, field: "end time")
      }
      guard let detailedSummary = item.detailedSummary else {
        throw ClaudeStrictJSONParserError.invalidActivityCard(
          index: index,
          field: "detailed summary"
        )
      }

      return ActivityCardData(
        startTime: start,
        endTime: end,
        category: item.category,
        subcategory: item.subcategory,
        title: item.title,
        summary: item.summary,
        detailedSummary: detailedSummary,
        distractions: item.distractions,
        appSites: item.appSites
      )
    }
  }

  private static func decodeStrictSegments(_ candidate: String) throws
    -> [SegmentMergeResponse.Segment]?
  {
    let data = Data(candidate.utf8)
    let decoder = JSONDecoder()
    let segments: [SegmentMergeResponse.Segment]

    if let response = try? decoder.decode(SegmentMergeResponse.self, from: data) {
      segments = response.segments
    } else if let array = try? decoder.decode([SegmentMergeResponse.Segment].self, from: data) {
      segments = array
    } else {
      return nil
    }

    try validateUniqueJSONKeys(in: candidate, fallbackError: .undecodableSegments)
    guard !segments.isEmpty else { throw ClaudeStrictJSONParserError.noSegments }
    return segments
  }

  private static func validateUniqueJSONKeys(
    in candidate: String,
    fallbackError: ClaudeStrictJSONParserError
  ) throws {
    do {
      var scanner = StrictJSONDuplicateKeyScanner(bytes: Array(candidate.utf8))
      if let duplicate = try scanner.firstDuplicateKey() {
        throw ClaudeStrictJSONParserError.duplicateJSONKey(duplicate)
      }
    } catch let error as ClaudeStrictJSONParserError {
      throw error
    } catch {
      throw fallbackError
    }
  }

  private static func validateCardTimestampAliasPresence(in data: Data) throws {
    guard let root = try? JSONSerialization.jsonObject(with: data) else {
      throw ClaudeStrictJSONParserError.undecodableActivityCards
    }

    let rawItems: [Any]
    if let array = root as? [Any] {
      rawItems = array
    } else if let envelope = root as? [String: Any], let cards = envelope["cards"] as? [Any] {
      rawItems = cards
    } else {
      throw ClaudeStrictJSONParserError.undecodableActivityCards
    }

    for (index, rawItem) in rawItems.enumerated() {
      guard let item = rawItem as? [String: Any] else {
        throw ClaudeStrictJSONParserError.undecodableActivityCards
      }
      let keys = Set(item.keys)
      if keys.contains("start"), keys.contains("startTime") {
        throw ClaudeStrictJSONParserError.conflictingActivityCardTimestampAliases(
          index: index,
          first: "start",
          second: "startTime"
        )
      }
      if keys.contains("end"), keys.contains("endTime") {
        throw ClaudeStrictJSONParserError.conflictingActivityCardTimestampAliases(
          index: index,
          first: "end",
          second: "endTime"
        )
      }
    }
  }

  /// Finds balanced JSON objects/arrays while respecting JSON string escaping. The scan only
  /// identifies byte ranges; it does not remove OSC sequences, Markdown, or control characters.
  private static func balancedJSONValues(in output: String) -> [String] {
    let bytes = Array(output.utf8)
    var values: [String] = []
    var start = 0

    while start < bytes.count {
      guard bytes[start] == UInt8(ascii: "{") || bytes[start] == UInt8(ascii: "[") else {
        start += 1
        continue
      }

      if let end = balancedJSONEnd(in: bytes, startingAt: start) {
        values.append(String(decoding: bytes[start...end], as: UTF8.self))
        start = end + 1
      } else {
        start += 1
      }
    }

    return values
  }

  private static func balancedJSONEnd(in bytes: [UInt8], startingAt start: Int) -> Int? {
    var stack: [UInt8] = []
    var isInsideString = false
    var isEscaped = false

    for index in start..<bytes.count {
      let byte = bytes[index]
      if isInsideString {
        if isEscaped {
          isEscaped = false
        } else if byte == UInt8(ascii: "\\") {
          isEscaped = true
        } else if byte == UInt8(ascii: "\"") {
          isInsideString = false
        }
        continue
      }

      if byte == UInt8(ascii: "\"") {
        isInsideString = true
      } else if byte == UInt8(ascii: "{") {
        stack.append(UInt8(ascii: "}"))
      } else if byte == UInt8(ascii: "[") {
        stack.append(UInt8(ascii: "]"))
      } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
        guard stack.last == byte else { return nil }
        stack.removeLast()
        if stack.isEmpty { return index }
      }
    }

    return nil
  }
}

private enum StrictJSONScanError: Error {
  case invalidJSON
}

/// A non-rewriting JSON grammar scan used only after the typed decoder recognizes a payload.
/// JSON string tokens are decoded independently so escaped-equivalent object keys compare equal.
private struct StrictJSONDuplicateKeyScanner {
  let bytes: [UInt8]
  private var index = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  mutating func firstDuplicateKey() throws -> String? {
    skipWhitespace()
    let duplicate = try parseValue()
    if duplicate != nil { return duplicate }
    skipWhitespace()
    guard index == bytes.count else { throw StrictJSONScanError.invalidJSON }
    return nil
  }

  private mutating func parseValue() throws -> String? {
    skipWhitespace()
    guard index < bytes.count else { throw StrictJSONScanError.invalidJSON }

    switch bytes[index] {
    case UInt8(ascii: "{"):
      return try parseObject()
    case UInt8(ascii: "["):
      return try parseArray()
    case UInt8(ascii: "\""):
      _ = try parseString()
      return nil
    default:
      try parsePrimitive()
      return nil
    }
  }

  private mutating func parseObject() throws -> String? {
    try consume(UInt8(ascii: "{"))
    skipWhitespace()
    if consumeIfPresent(UInt8(ascii: "}")) { return nil }

    var keys = Set<String>()
    while true {
      skipWhitespace()
      let key = try parseString()
      skipWhitespace()
      try consume(UInt8(ascii: ":"))
      if !keys.insert(key).inserted { return key }
      if let duplicate = try parseValue() { return duplicate }
      skipWhitespace()
      if consumeIfPresent(UInt8(ascii: "}")) { return nil }
      try consume(UInt8(ascii: ","))
    }
  }

  private mutating func parseArray() throws -> String? {
    try consume(UInt8(ascii: "["))
    skipWhitespace()
    if consumeIfPresent(UInt8(ascii: "]")) { return nil }

    while true {
      if let duplicate = try parseValue() { return duplicate }
      skipWhitespace()
      if consumeIfPresent(UInt8(ascii: "]")) { return nil }
      try consume(UInt8(ascii: ","))
    }
  }

  private mutating func parseString() throws -> String {
    let start = index
    try consume(UInt8(ascii: "\""))
    var isEscaped = false

    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if isEscaped {
        isEscaped = false
      } else if byte == UInt8(ascii: "\\") {
        isEscaped = true
      } else if byte == UInt8(ascii: "\"") {
        let token = Data(bytes[start..<index])
        guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
          throw StrictJSONScanError.invalidJSON
        }
        return decoded
      }
    }

    throw StrictJSONScanError.invalidJSON
  }

  private mutating func parsePrimitive() throws {
    let start = index
    while index < bytes.count {
      let byte = bytes[index]
      if isWhitespace(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]")
        || byte == UInt8(ascii: "}")
      {
        break
      }
      index += 1
    }
    guard index > start else { throw StrictJSONScanError.invalidJSON }
  }

  private mutating func consume(_ expected: UInt8) throws {
    guard index < bytes.count, bytes[index] == expected else {
      throw StrictJSONScanError.invalidJSON
    }
    index += 1
  }

  private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == expected else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, isWhitespace(bytes[index]) {
      index += 1
    }
  }

  private func isWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n")
      || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
  }
}
