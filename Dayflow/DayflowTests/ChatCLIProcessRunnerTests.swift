import XCTest

@testable import Dayflow

final class ChatCLIProcessRunnerTests: XCTestCase {
  private let runner = ChatCLIProcessRunner()

  func testInvalidTransportLongFormExtractsExplicitConfigPath() throws {
    let tempDirectory = try makeTempDirectory()
    let configURL =
      tempDirectory
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("config.toml")
      .standardizedFileURL
    let stderr = """
      Error: failed to load configuration

      Caused by:
          0: \(configURL.path):1:1: invalid transport
          1: invalid transport
             in `mcp_servers.computer-use`
      """

    XCTAssertEqual(
      runner.invalidTransportConfigURL(from: stderr)?.path,
      configURL.path
    )
  }

  func testInvalidTransportShortFormsUseFallbackConfigPath() throws {
    let fallbackConfigURL = try makeFallbackConfigURL()
    let cases = [
      """
      Error loading config.toml: invalid transport
      in `mcp_servers.computer-use`
      """,
      """
      Error loading config.toml: invalid transport
      in `mcp_servers.cloudflare-api`
      """,
      """
      (anon):setopt:7: can't change option: monitor

      [ERROR]: gitstatus failed to initialize.

      Error loading config.toml: invalid transport
      in `mcp_servers.computer-use`
      """,
      """
      (anon):setopt:7: can't change option: monitor
      (eval):1: can't change option: zle

      Error loading config.toml: invalid transport
      in `mcp_servers.computer-use`
      """,
    ]

    for stderr in cases {
      let configURL = runner.invalidTransportConfigURL(
        from: stderr,
        fallbackConfigURL: fallbackConfigURL
      )
      XCTAssertEqual(
        configURL?.path,
        fallbackConfigURL.path
      )
    }
  }

  func testInvalidTransportDetectionIsCaseInsensitive() {
    XCTAssertTrue(
      runner.containsInvalidTransportError("Error loading config.toml: Invalid Transport")
    )
  }

  func testFallbackRetryDoesNotCarryUserMCPDisableOverrides() {
    XCTAssertTrue(runner.shouldDisableConfiguredCodexMCPServers(processEnvironment: [:]))
    XCTAssertFalse(
      runner.shouldDisableConfiguredCodexMCPServers(
        processEnvironment: ["CODEX_HOME": "/tmp/dayflow-codex-home"]
      )
    )
  }

  func testFallbackContextCopiesAuthIntoTemporaryCodexHome() throws {
    let tempDirectory = try makeTempDirectory()
    let sourceCodexHome = tempDirectory.appendingPathComponent(
      "source-codex-home",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: sourceCodexHome,
      withIntermediateDirectories: true
    )

    let configURL = sourceCodexHome.appendingPathComponent("config.toml")
    let authURL = sourceCodexHome.appendingPathComponent("auth.json")
    try #"{"token":"secret"}"#.write(to: authURL, atomically: true, encoding: .utf8)

    let fallback = try XCTUnwrap(
      runner.makeCodexFallbackContext(
        fromInvalidTransportStderr: """
          Error loading config.toml: invalid transport
          in `mcp_servers.computer-use`
          """,
        workingDirectory: tempDirectory,
        fallbackConfigURL: configURL
      )
    )
    defer { fallback.cleanup() }

    let codexHome = try XCTUnwrap(fallback.environment["CODEX_HOME"])
    let copiedAuthURL = URL(fileURLWithPath: codexHome)
      .appendingPathComponent("auth.json")
    XCTAssertEqual(fallback.brokenConfigURL.path, configURL.standardizedFileURL.path)
    XCTAssertTrue(fallback.didCopyAuth)
    XCTAssertEqual(
      try String(contentsOf: copiedAuthURL, encoding: .utf8),
      #"{"token":"secret"}"#
    )
  }

  func testFallbackContextBypassesProjectScopedCodexConfig() throws {
    let tempDirectory = try makeTempDirectory()
    let repoURL = tempDirectory.appendingPathComponent("repo", isDirectory: true)
    let workingDirectory = repoURL.appendingPathComponent("subdir", isDirectory: true)
    let projectCodexHome = repoURL.appendingPathComponent(".codex", isDirectory: true)
    let projectConfigURL = projectCodexHome.appendingPathComponent("config.toml")

    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectCodexHome, withIntermediateDirectories: true)

    let stderr = """
      Error: failed to load configuration

      Caused by:
          0: \(projectConfigURL.path):1:1: invalid transport
          1: invalid transport
             in `mcp_servers.computer-use`
      """

    XCTAssertNotNil(
      runner.makeCodexFallbackContext(
        fromInvalidTransportStderr: stderr,
        workingDirectory: workingDirectory
      )
    )
  }

  private func makeFallbackConfigURL() throws -> URL {
    try makeTempDirectory()
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("config.toml")
      .standardizedFileURL
  }

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ChatCLIProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }
}
