import XCTest

@testable import Dayflow

final class CodexStreamingConfigurationTests: XCTestCase {
  func testStreamingPreservesUserConfiguration() async throws {
    try await assertStreamingPreservesUserConfiguration(sessionId: nil)
  }

  func testStreamingResumePreservesUserConfiguration() async throws {
    try await assertStreamingPreservesUserConfiguration(sessionId: "session-123")
  }

  private func assertStreamingPreservesUserConfiguration(sessionId: String?) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexStreamingConfigurationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("codex")
    // Advertise the flag that triggered the regression, without contacting a
    // provider or reading any real Codex configuration or credentials.
    let script = #"""
      #!/bin/sh
      for argument in "$@"; do
        if [ "$argument" = "--help" ]; then
          printf '%s\n' '--ignore-user-config'
          exit 0
        fi
      done
      if [ "$1" = "mcp" ]; then
        printf '%s\n' '[{"name":"example","enabled":true},{"name":"already_disabled","enabled":false}]'
        exit 0
      fi
      printf '%s\n' "$@" > arguments.txt
      for argument in "$@"; do
        if [ "$argument" = "--ignore-user-config" ]; then
          printf '%s\n' '{"type":"error","message":"Custom provider configuration was discarded"}'
          exit 1
        fi
      done
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Configured provider preserved"}}'
      """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let resolver = CodexExecutableResolver(
      candidateProvider: { [.init(executableURL: executable, source: .path)] },
      versionProbe: { _ in "codex-cli 0.145.0" }
    )
    let runner = ChatCLIProcessRunner(codexExecutableResolver: resolver)
    var text = ""
    for try await event in runner.runStreaming(
      tool: .codex,
      prompt: "Generate cards",
      workingDirectory: directory,
      model: "test-model",
      sessionId: sessionId
    ) {
      if case .textDelta(let delta) = event { text += delta }
    }

    XCTAssertEqual(text, "Configured provider preserved")
    let arguments = try String(
      contentsOf: directory.appendingPathComponent("arguments.txt"), encoding: .utf8
    ).components(separatedBy: .newlines)
    XCTAssertFalse(arguments.contains("--ignore-user-config"))
    XCTAssertTrue(arguments.contains("mcp_servers.example.enabled=false"))
    XCTAssertFalse(arguments.contains("mcp_servers.already_disabled.enabled=false"))
    if let sessionId {
      XCTAssertEqual(Array(arguments.prefix(3)), ["exec", "resume", sessionId])
    } else {
      XCTAssertEqual(Array(arguments.prefix(2)), ["exec", "--skip-git-repo-check"])
    }
  }
}
