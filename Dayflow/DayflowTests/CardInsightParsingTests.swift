//
//  CardInsightParsingTests.swift
//  DayflowTests
//
//  Best-effort extraction of the model's `reasoning` field from a raw
//  card-generation response — bare JSON, code-fenced JSON, and the OpenAI /
//  Gemini envelope shapes — plus graceful nils for junk.
//

import XCTest

@testable import Dayflow

@MainActor
final class CardInsightParsingTests: XCTestCase {

  private func reasoning(_ raw: String?) -> String? {
    CardInsight.extractReasoning(fromModelResponse: raw)
  }

  func testExtractsFromBareJSONObject() {
    XCTAssertEqual(reasoning(#"{"reasoning": "grouped by app"}"#), "grouped by app")
  }

  func testExtractsFromCodeFencedJSON() {
    let raw = "```json\n{\"reasoning\": \"fenced value\"}\n```"
    XCTAssertEqual(reasoning(raw), "fenced value")
  }

  func testExtractsFromOpenAIEnvelope() {
    let raw = #"{"choices":[{"message":{"content":"{\"reasoning\":\"from openai\"}"}}]}"#
    XCTAssertEqual(reasoning(raw), "from openai")
  }

  func testExtractsFromGeminiEnvelope() {
    let raw = #"{"candidates":[{"content":{"parts":[{"text":"{\"reasoning\":\"from gemini\"}"}]}}]}"#
    XCTAssertEqual(reasoning(raw), "from gemini")
  }

  func testReturnsNilForNilOrEmpty() {
    XCTAssertNil(reasoning(nil))
    XCTAssertNil(reasoning(""))
  }

  func testReturnsNilWhenNoReasoningField() {
    XCTAssertNil(reasoning(#"{"title": "Something"}"#))
    XCTAssertNil(reasoning("not json at all"))
  }

  func testReturnsNilForWhitespaceOnlyReasoning() {
    XCTAssertNil(reasoning(#"{"reasoning": "   "}"#))
  }
}
