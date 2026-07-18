import XCTest

@testable import Dayflow

final class ClaudeCLIExecutionProfileTests: XCTestCase {
  private let runner = ChatCLIProcessRunner()

  func testOptimizedTranscriptionUsesRestrictedSafeModeAndExplicitLowEffort() throws {
    let parts = runner.buildClaudeCommandParts(
      prompt: "Transcribe the contact sheet",
      imagePaths: ["/tmp/contact-sheet.jpg"],
      model: "claude-sonnet",
      reasoningEffort: "low",
      disableTools: false,
      profile: ClaudeCLIExecutionProfile.optimizedTranscription.allowingRead(
        at: "/tmp/contact-sheet.jpg"
      )
    )

    XCTAssertEqual(
      Array(parts.prefix(6)),
      ["claude", "-p", "--output-format", "json", "--verbose", "--safe-mode"]
    )
    XCTAssertEqual(try argument(after: "--model", in: parts), "claude-sonnet")
    XCTAssertEqual(try argument(after: "--effort", in: parts), "low")
    XCTAssertEqual(try argument(after: "--tools", in: parts), "Read")
    XCTAssertEqual(
      try argument(after: "--allowedTools", in: parts),
      LoginShellRunner.shellEscape("Read(/tmp/contact-sheet.jpg)")
    )
    XCTAssertEqual(try argument(after: "--name", in: parts), "dayflow-transcription")
    XCTAssertEqual(
      try argument(after: "--settings", in: parts),
      LoginShellRunner.shellEscape(#"{"alwaysThinkingEnabled":false,"effortLevel":"low"}"#)
    )
    XCTAssertTrue(parts.contains("--disable-slash-commands"))
    XCTAssertTrue(parts.contains("--no-session-persistence"))
    XCTAssertFalse(parts.contains("--dangerously-skip-permissions"))
    XCTAssertFalse(parts.joined(separator: " ").contains("Transcribe the contact sheet"))
    let payload = try XCTUnwrap(
      runner.standardInputPayload(
        tool: .claude,
        prompt: "Transcribe the contact sheet",
        imagePaths: ["/tmp/contact-sheet.jpg"],
        claudeProfile: .optimizedTranscription
      )
    )
    XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("/tmp/contact-sheet.jpg"))
  }

  func testOptimizedTranscriptionNeverAutoApprovesGlobalRead() {
    let parts = runner.buildClaudeCommandParts(
      prompt: "Transcribe",
      imagePaths: [],
      model: "claude-sonnet",
      reasoningEffort: "low",
      disableTools: false,
      profile: .optimizedTranscription
    )

    XCTAssertTrue(parts.contains("--tools"))
    XCTAssertFalse(parts.contains("--allowedTools"))
    XCTAssertFalse(parts.contains("--dangerously-skip-permissions"))
  }

  func testOptimizedCardsDisableToolsAndUseNormalAuthSafeMode() throws {
    let safeParts = runner.buildClaudeCommandParts(
      prompt: "Generate cards",
      imagePaths: [],
      model: "claude-sonnet",
      reasoningEffort: "low",
      disableTools: false,
      profile: .optimizedCardGeneration
    )
    XCTAssertTrue(safeParts.contains("--safe-mode"))
    XCTAssertFalse(safeParts.contains("--bare"))
    XCTAssertEqual(try argument(after: "--tools", in: safeParts), LoginShellRunner.shellEscape(""))
    XCTAssertEqual(try argument(after: "--name", in: safeParts), "dayflow-card-generation")
    XCTAssertFalse(safeParts.contains("--allowedTools"))
    XCTAssertFalse(safeParts.contains("--dangerously-skip-permissions"))
  }

  func testResumableTurnsOmitNoPersistenceAndUseExactSession() throws {
    let sessionID = "9A80C2D7-B988-4F70-A61C-EAAB8C591E1C"
    let initial = runner.buildClaudeCommandParts(
      prompt: "Transcribe",
      imagePaths: [],
      model: "claude-sonnet",
      reasoningEffort: "low",
      disableTools: false,
      profile: ClaudeCLIExecutionProfile.optimizedTranscription.allowingRead(
        at: "/tmp/contact-sheet.jpg"
      ),
      sessionMode: .start(id: sessionID)
    )
    let correction = runner.buildClaudeCommandParts(
      prompt: "Correct the JSON",
      imagePaths: [],
      model: "claude-sonnet",
      reasoningEffort: "low",
      disableTools: false,
      profile: ClaudeCLIExecutionProfile.optimizedTranscriptionCorrection.allowingRead(
        at: "/tmp/contact-sheet.jpg"
      ),
      sessionMode: .resume(id: sessionID)
    )

    XCTAssertEqual(try argument(after: "--session-id", in: initial), sessionID)
    XCTAssertFalse(initial.contains("--resume"))
    XCTAssertFalse(initial.contains("--no-session-persistence"))
    XCTAssertEqual(try argument(after: "--resume", in: correction), sessionID)
    XCTAssertFalse(correction.contains("--session-id"))
    XCTAssertFalse(correction.contains("--no-session-persistence"))
    XCTAssertEqual(try argument(after: "--tools", in: correction), "Read")
    XCTAssertEqual(
      try argument(after: "--allowedTools", in: correction),
      LoginShellRunner.shellEscape("Read(/tmp/contact-sheet.jpg)")
    )
    XCTAssertFalse(correction.contains("--disallowedTools"))
    XCTAssertEqual(
      try argument(after: "--system-prompt", in: correction),
      try argument(after: "--system-prompt", in: initial)
    )
    XCTAssertEqual(
      try argument(after: "--settings", in: correction),
      try argument(after: "--settings", in: initial)
    )
    XCTAssertEqual(try argument(after: "--name", in: correction), "dayflow-transcription")
  }

  func testExistingClaudeCommandOnlyAddsRequestedReasoningEffort() throws {
    let parts = runner.buildClaudeCommandParts(
      prompt: "Hello",
      imagePaths: [],
      model: "sonnet",
      reasoningEffort: "medium",
      disableTools: false
    )

    XCTAssertEqual(
      Array(parts.prefix(7)),
      ["claude", "-p", "--model", "sonnet", "--effort", "medium", "--dangerously-skip-permissions"]
    )
    XCTAssertFalse(parts.contains("--output-format"))
    XCTAssertFalse(parts.contains("--safe-mode"))
    XCTAssertFalse(parts.contains("--bare"))
  }

  func testOptimizedProfileAddsThinkingLimitOnlyToClaudeEnvironment() {
    let base = [
      "EXISTING": "value",
      "CLAUDE_CONFIG_DIR": "/tmp/dayflow-claude-session",
      "MAX_THINKING_TOKENS": "99",
    ]

    XCTAssertEqual(
      runner.mergedProcessEnvironment(
        tool: .claude,
        processEnvironment: base,
        claudeProfile: .optimizedTranscription
      ),
      [
        "EXISTING": "value",
        "CLAUDE_CONFIG_DIR": "/tmp/dayflow-claude-session",
        "MAX_THINKING_TOKENS": "0",
      ]
    )
    XCTAssertEqual(
      runner.mergedProcessEnvironment(
        tool: .claude,
        processEnvironment: base,
        claudeProfile: nil
      ),
      base
    )
    XCTAssertEqual(
      runner.mergedProcessEnvironment(
        tool: .codex,
        processEnvironment: base,
        claudeProfile: .optimizedTranscription
      ),
      base
    )
  }

  func testStandardInputWriteHandlesClosedPeerWithoutSIGPIPE() throws {
    let pipe = Pipe()
    try pipe.fileHandleForReading.close()

    XCTAssertFalse(
      ChatCLIProcessRunner.writeStandardInput(
        Data("prompt".utf8),
        to: pipe.fileHandleForWriting
      )
    )
  }

  func testClaudeJSONArrayEnvelopeExtractsFinalResultUsageAndSession() throws {
    let raw = #"""
      [
        {"type":"system","subtype":"init","session_id":"session-123"},
        {"type":"assistant","message":{"content":[]}},
        {
          "type":"result",
          "session_id":"session-123",
          "result":"{\"segments\":[]}",
          "usage":{
            "input_tokens":12,
            "cache_creation_input_tokens":40,
            "cache_read_input_tokens":34,
            "output_tokens":56
          }
        }
      ]
      """#

    let parsed = try XCTUnwrap(runner.parseClaudeJSONEnvelope(raw))

    XCTAssertEqual(parsed.text, #"{"segments":[]}"#)
    XCTAssertEqual(parsed.sessionId, "session-123")
    XCTAssertEqual(parsed.usage?.input, 12)
    XCTAssertEqual(parsed.usage?.cachedInput, 34)
    XCTAssertEqual(parsed.usage?.cacheCreationInput, 40)
    XCTAssertEqual(parsed.usage?.output, 56)
  }

  func testClaudeEnvelopeSurvivesLeadingAndTrailingLoginShellOutput() throws {
    let raw = #"""
      shell startup banner
      {"type":"result","session_id":"session-noisy","result":"{\"segments\":[{\"description\":\"kept {verbatim}\"}]}","usage":{"input_tokens":3,"output_tokens":7}}
      shell shutdown note
      """#

    let parsed = try XCTUnwrap(runner.parseClaudeJSONEnvelope(raw))

    XCTAssertEqual(parsed.text, #"{"segments":[{"description":"kept {verbatim}"}]}"#)
    XCTAssertEqual(parsed.sessionId, "session-noisy")
    XCTAssertEqual(parsed.usage?.input, 3)
    XCTAssertEqual(parsed.usage?.output, 7)
  }

  func testClaudeJSONObjectEnvelopeIsDecodedButBareUserJSONIsNotMistakenForEnvelope() throws {
    let envelope = #"{"type":"result","result":"ok","usage":{"input_tokens":2,"output_tokens":3}}"#
    let parsed = try XCTUnwrap(runner.parseClaudeJSONEnvelope(envelope))
    XCTAssertEqual(parsed.text, "ok")
    XCTAssertEqual(parsed.usage?.input, 2)
    XCTAssertEqual(parsed.usage?.cachedInput, 0)
    XCTAssertEqual(parsed.usage?.cacheCreationInput, 0)
    XCTAssertEqual(parsed.usage?.output, 3)

    let userJSON = #"{"cards":[]}"#
    XCTAssertNil(runner.parseClaudeJSONEnvelope(userJSON))
    XCTAssertEqual(runner.parseAssistant(tool: .claude, raw: userJSON).text, userJSON)
  }

  func testTokenUsageAggregationIncludesBothClaudeCacheBuckets() {
    let initial = TokenUsage(input: 10, cachedInput: 20, cacheCreationInput: 30, output: 40)
    let correction = TokenUsage(input: 1, cachedInput: 2, cacheCreationInput: 3, output: 4)

    let total = initial.adding(correction)

    XCTAssertEqual(total.input, 11)
    XCTAssertEqual(total.cachedInput, 22)
    XCTAssertEqual(total.cacheCreationInput, 33)
    XCTAssertEqual(total.output, 44)
  }

  func testOptimizedClaudePromptIsPassedViaStdinAndExcludedFromDebugCommand() throws {
    let sensitivePrompt = "OCR secret: customer@example.com ordered 42 widgets"
    let imagePath = "/tmp/private contact sheet.jpg"
    let parts = runner.buildClaudeCommandParts(
      prompt: sensitivePrompt,
      imagePaths: [imagePath],
      model: "claude-sonnet",
      reasoningEffort: "low",
      disableTools: false,
      profile: .optimizedTranscription
    )
    let shellCommand = parts.joined(separator: " ")
    let payload = try XCTUnwrap(
      runner.standardInputPayload(
        tool: .claude,
        prompt: sensitivePrompt,
        imagePaths: [imagePath],
        claudeProfile: .optimizedTranscription
      )
    )
    let standardInput = try XCTUnwrap(String(data: payload, encoding: .utf8))

    XCTAssertFalse(shellCommand.contains(sensitivePrompt))
    XCTAssertFalse(shellCommand.contains("customer@example.com"))
    XCTAssertTrue(standardInput.contains(sensitivePrompt))
    XCTAssertTrue(standardInput.contains(imagePath))
  }

  func testLegacyClaudeAndCodexPromptDeliveryIsUnchanged() {
    let prompt = "ordinary prompt"
    let legacyClaudeParts = runner.buildClaudeCommandParts(
      prompt: prompt,
      imagePaths: [],
      model: "sonnet",
      disableTools: false
    )

    XCTAssertTrue(legacyClaudeParts.joined(separator: " ").contains(prompt))
    XCTAssertNil(
      runner.standardInputPayload(
        tool: .claude, prompt: prompt, imagePaths: [], claudeProfile: nil
      )
    )
    XCTAssertNil(
      runner.standardInputPayload(
        tool: .codex,
        prompt: prompt,
        imagePaths: [],
        claudeProfile: .optimizedCardGeneration
      )
    )
  }

  private func argument(after flag: String, in parts: [String]) throws -> String {
    let index = try XCTUnwrap(parts.firstIndex(of: flag))
    let valueIndex = parts.index(after: index)
    XCTAssertLessThan(valueIndex, parts.endIndex)
    return parts[valueIndex]
  }
}
