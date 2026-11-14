import XCTest

@testable import Dayflow

/// The Daily brief's `claude -p` runs: which model they use and which tools they get.
final class DailyBriefCommandOptionsTests: XCTestCase {
  private var runDirectory: URL!

  override func setUpWithError() throws {
    runDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DailyBriefCommandOptionsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: runDirectory)
  }

  private func options(_ part: DailyBriefGenerator.Part) throws
    -> ClaudeCLIStructuredOutputOptions
  {
    try DailyBriefGenerator.commandOptions(
      part: part, runDirectory: runDirectory,
      candidatesDirectory: runDirectory.appendingPathComponent("candidates"))
  }

  /// Both runs use Opus. Fable made the docket run most of a brief's cost.
  func testBriefRunsOnOpus() {
    XCTAssertEqual(DailyBriefGenerator.model, "opus")
  }

  /// Without ToolSearch, Claude Code puts every connector tool's full definition in every
  /// request, which made a brief cost about $13 for a user with many connectors.
  func testEveryPartCanUseToolSearch() throws {
    for part in DailyBriefGenerator.Part.allCases {
      let options = try options(part)
      let tools = options.tools.split(separator: ",").map(String.init)
      XCTAssertTrue(tools.contains("ToolSearch"), "\(part) run is missing ToolSearch in --tools")
      XCTAssertTrue(
        options.allowedTools.contains("ToolSearch"),
        "\(part) run is missing ToolSearch in --allowedTools")
    }
  }

  /// Tool search must not change what the runs could already do.
  func testEveryPartKeepsItsOtherTools() throws {
    for part in DailyBriefGenerator.Part.allCases {
      let options = try options(part)
      let tools = Set(options.tools.split(separator: ",").map(String.init))
      XCTAssertEqual(tools, ["Read", "WebSearch", "WebFetch", "ToolSearch"], "\(part)")
      XCTAssertTrue(options.loadsUserMCPServers, "\(part) run should load the user's connectors")
    }
  }
}
