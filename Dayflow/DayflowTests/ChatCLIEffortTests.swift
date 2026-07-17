import XCTest

@testable import Dayflow

final class ChatCLIEffortTests: XCTestCase {
  private let runner = ChatCLIProcessRunner()

  func testClaudeStreamingCommandIncludesExplicitEffort() {
    let parts = runner.buildClaudeStreamingCommandParts(
      prompt: "Generate cards",
      model: "sonnet",
      reasoningEffort: "medium",
      sessionId: nil
    )

    XCTAssertEqual(
      Array(parts.prefix(10)),
      [
        "claude", "-p", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--model", "sonnet", "--effort", "medium",
      ]
    )
  }

  func testClaudeStreamingResumeKeepsExplicitEffort() {
    let parts = runner.buildClaudeStreamingCommandParts(
      prompt: "Fix the cards",
      model: "sonnet",
      reasoningEffort: "medium",
      sessionId: "session-123"
    )

    XCTAssertEqual(
      Array(parts.prefix(12)),
      [
        "claude", "-p", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--resume", "session-123", "--model", "sonnet",
        "--effort", "medium",
      ]
    )
  }

  func testClaudeActivityCardsUseConfiguredSonnetAtLowEffort() {
    let configuration = ClaudeProvider.activityCardModelConfiguration()

    XCTAssertEqual(configuration.model, "claude-sonnet-5")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }
}
