//
//  SurveyModels.swift
//  Dayflow
//
//  In-app surveys are queued from Slack and served by the Dayflow backend
//  (GET /v1/surveys/live). These types mirror that response.
//

import Foundation

struct SurveyQueue: Decodable {
  let surveys: [Survey]
  /// At most one survey every this many days, unless a survey is marked "ask now".
  let pacingDays: Int
  /// No surveys until this many days after someone's first timeline card
  /// (the "everyone" audience; the new-user audience is exempt).
  let newUserProtectionDays: Int
}

struct Survey: Decodable, Identifiable, Equatable {
  let id: String
  let questions: [SurveyQuestion]
  let audience: String
  let provider: String
  let askNow: Bool

  /// False when the backend sent a question type this app version can't show.
  var isSupported: Bool {
    !questions.isEmpty && questions.allSatisfy { $0.type != .unsupported }
  }
}

struct SurveyQuestion: Decodable, Identifiable, Equatable {
  enum Kind: String, Decodable {
    case single
    case multi
    case rating
    case open
    case unsupported

    init(from decoder: Decoder) throws {
      let raw = try decoder.singleValueContainer().decode(String.self)
      self = Kind(rawValue: raw) ?? .unsupported
    }
  }

  let id: String
  let type: Kind
  let prompt: String
  let choices: [String]?
  let optional: Bool?

  var isOptional: Bool { optional ?? false }
}

/// One answer, in the JSON shape the backend stores: a string for pick-one
/// and written answers, a list for pick-several, a number for ratings.
enum SurveyAnswer: Equatable {
  case choice(String)
  case choices([String])
  case rating(Int)
  case text(String)

  var jsonValue: SurveyJSONValue {
    switch self {
    case .choice(let value), .text(let value): return .string(value)
    case .choices(let values): return .array(values.map { .string($0) })
    case .rating(let value): return .int(value)
    }
  }

  /// What goes to PostHog. Written answers are only counted there; the text
  /// itself goes to the backend, which the Dayflow team reads in Slack.
  var analyticsProperties: [String: Any] {
    switch self {
    case .choice(let value): return ["answer": value]
    case .choices(let values): return ["answer": values.joined(separator: ", ")]
    case .rating(let value): return ["answer": value]
    case .text(let value): return ["answer_length": value.count]
    }
  }
}

/// The few JSON shapes survey events carry.
enum SurveyJSONValue: Codable, Equatable {
  case string(String)
  case int(Int)
  case bool(Bool)
  case array([SurveyJSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      self = .array(try container.decode([SurveyJSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .array(let values): try container.encode(values)
    }
  }
}
