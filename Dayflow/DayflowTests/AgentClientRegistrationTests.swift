import XCTest

@testable import Dayflow

final class AgentClientRegistrationTests: XCTestCase {
  private let executableURL = URL(fileURLWithPath: "/tmp/codex")
  private let cliPath = "/Applications/Dayflow.app/Contents/Helpers/dayflow"

  func testCodexIsTheFirstVisibleClient() {
    XCTAssertEqual(AgentClient.allCases.first, .codex)
    XCTAssertEqual(AgentClient.codex.displayName, "Codex")
  }

  func testStatusReportsNotInstalledWithoutAnExecutable() {
    let registration = CodexMCPRegistration(
      cliPath: cliPath,
      resolveExecutable: { nil },
      runCommand: { _, _ in
        XCTFail("The command should not run")
        return self.missingResult
      }
    )

    XCTAssertEqual(registration.status(), .notInstalled)
  }

  func testStatusVerifiesTheExpectedCommandAndArguments() {
    let registration = makeRegistration { arguments in
      XCTAssertEqual(arguments, ["mcp", "get", "dayflow", "--json"])
      return self.connectedResult()
    }

    XCTAssertEqual(registration.status(), .connected)
  }

  func testConnectReenablesADisabledDayflowRegistration() {
    var getCount = 0
    var commands: [[String]] = []
    let registration = makeRegistration { arguments in
      commands.append(arguments)
      if arguments == ["mcp", "get", "dayflow", "--json"] {
        getCount += 1
        return getCount == 1 ? self.connectedResult(enabled: false) : self.connectedResult()
      }
      return .init(stdout: "Added global MCP server 'dayflow'.", stderr: "", exitCode: 0)
    }

    XCTAssertEqual(registration.connect(), .connected)
    XCTAssertEqual(
      commands,
      [
        ["mcp", "get", "dayflow", "--json"],
        ["mcp", "add", "dayflow", "--", cliPath, "mcp"],
        ["mcp", "get", "dayflow", "--json"],
      ]
    )
  }

  func testConnectRunsAddThenVerifiesTheResult() {
    var commands: [[String]] = []
    var getCount = 0
    let registration = makeRegistration { arguments in
      commands.append(arguments)
      if arguments == ["mcp", "get", "dayflow", "--json"] {
        getCount += 1
        return getCount == 1 ? self.missingResult : self.connectedResult()
      }
      return .init(stdout: "Added global MCP server 'dayflow'.", stderr: "", exitCode: 0)
    }

    XCTAssertEqual(registration.connect(), .connected)
    XCTAssertEqual(
      commands,
      [
        ["mcp", "get", "dayflow", "--json"],
        ["mcp", "add", "dayflow", "--", cliPath, "mcp"],
        ["mcp", "get", "dayflow", "--json"],
      ]
    )
  }

  func testConnectPreservesAnUnknownExistingRegistration() {
    var commands: [[String]] = []
    let registration = makeRegistration { arguments in
      commands.append(arguments)
      return self.configurationResult(command: "/usr/local/bin/dayflow-wrapper", args: ["serve"])
    }

    XCTAssertEqual(
      registration.connect(),
      .failed("Codex already has a custom MCP server named dayflow. Dayflow left it unchanged.")
    )
    XCTAssertEqual(commands, [["mcp", "get", "dayflow", "--json"]])
  }

  func testConnectRepairsAStaleBundledHelperPath() {
    var getCount = 0
    var commands: [[String]] = []
    let registration = makeRegistration { arguments in
      commands.append(arguments)
      if arguments == ["mcp", "get", "dayflow", "--json"] {
        getCount += 1
        return getCount == 1
          ? self.configurationResult(
            command: "/Applications/Old/Dayflow.app/Contents/Helpers/dayflow",
            args: ["mcp"]
          )
          : self.connectedResult()
      }
      return .init(stdout: "Added global MCP server 'dayflow'.", stderr: "", exitCode: 0)
    }

    XCTAssertEqual(registration.connect(), .connected)
    XCTAssertTrue(commands.contains(["mcp", "add", "dayflow", "--", cliPath, "mcp"]))
  }

  func testDisconnectRunsRemoveThenVerifiesItIsGone() {
    var getCount = 0
    var commands: [[String]] = []
    let registration = makeRegistration { arguments in
      commands.append(arguments)
      if arguments == ["mcp", "get", "dayflow", "--json"] {
        getCount += 1
        return getCount == 1 ? self.connectedResult() : self.missingResult
      }
      return .init(stdout: "Removed global MCP server 'dayflow'.", stderr: "", exitCode: 0)
    }

    XCTAssertEqual(registration.disconnect(), .disconnected)
    XCTAssertEqual(
      commands,
      [
        ["mcp", "get", "dayflow", "--json"],
        ["mcp", "remove", "dayflow"],
        ["mcp", "get", "dayflow", "--json"],
      ]
    )
  }

  func testDisconnectRemovesADisabledDayflowRegistration() {
    var getCount = 0
    var commands: [[String]] = []
    let registration = makeRegistration { arguments in
      commands.append(arguments)
      if arguments == ["mcp", "get", "dayflow", "--json"] {
        getCount += 1
        return getCount == 1 ? self.connectedResult(enabled: false) : self.missingResult
      }
      return .init(stdout: "Removed global MCP server 'dayflow'.", stderr: "", exitCode: 0)
    }

    XCTAssertEqual(registration.disconnect(), .disconnected)
    XCTAssertEqual(
      commands,
      [
        ["mcp", "get", "dayflow", "--json"],
        ["mcp", "remove", "dayflow"],
        ["mcp", "get", "dayflow", "--json"],
      ]
    )
  }

  func testConnectSurfacesCodexFailureDetails() {
    let registration = makeRegistration { arguments in
      if arguments == ["mcp", "get", "dayflow", "--json"] {
        return self.missingResult
      }
      return .init(stdout: "", stderr: "permission denied", exitCode: 1)
    }

    XCTAssertEqual(
      registration.connect(),
      .failed("Codex couldn't connect the Dayflow connection: permission denied")
    )
  }

  private var missingResult: CodexMCPRegistration.CommandResult {
    .init(
      stdout: "",
      stderr: "Error: No MCP server named 'dayflow' found.",
      exitCode: 1
    )
  }

  private func makeRegistration(
    runner: @escaping ([String]) -> CodexMCPRegistration.CommandResult
  ) -> CodexMCPRegistration {
    CodexMCPRegistration(
      cliPath: cliPath,
      resolveExecutable: { self.executableURL },
      runCommand: { url, arguments in
        XCTAssertEqual(url, self.executableURL)
        return runner(arguments)
      }
    )
  }

  private func connectedResult(enabled: Bool = true) -> CodexMCPRegistration.CommandResult {
    configurationResult(command: cliPath, args: ["mcp"], enabled: enabled)
  }

  private func configurationResult(
    command: String,
    args: [String],
    enabled: Bool = true
  ) -> CodexMCPRegistration.CommandResult {
    let configuration: [String: Any] = [
      "name": "dayflow",
      "enabled": enabled,
      "transport": [
        "type": "stdio",
        "command": command,
        "args": args,
      ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: configuration)
    return .init(stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: 0)
  }
}
