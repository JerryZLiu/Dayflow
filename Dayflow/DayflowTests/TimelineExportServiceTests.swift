import XCTest

@testable import Dayflow

final class TimelineExportServiceTests: XCTestCase {
  private let day = DateFormatter.yyyyMMdd.date(from: "2026-06-10")!
  /// Synthetic home so the allowed export roots are deterministic.
  private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

  private func fm(existingDirectories: [String] = []) -> StubFileManager {
    StubFileManager(home: home, existingDirectories: existingDirectories)
  }

  // MARK: - Allowed destinations

  func testNilPathUsesDownloadsDirectory() {
    let url = TimelineExportService.resolveDestination(
      rawPath: nil, startDay: day, endDay: day, fileManager: fm())
    XCTAssertEqual(url?.path, "/Users/test/Downloads/Dayflow timeline 2026-06-10.md")
  }

  func testTrailingSlashTreatedAsDirectoryWithinAllowedRoot() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/Users/test/Documents/exports/", startDay: day, endDay: day, fileManager: fm())
    XCTAssertEqual(url?.path, "/Users/test/Documents/exports/Dayflow timeline 2026-06-10.md")
  }

  func testExistingDirectoryGetsDerivedFileName() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/Users/test/Desktop/reports", startDay: day, endDay: day,
      fileManager: fm(existingDirectories: ["/Users/test/Desktop/reports"]))
    XCTAssertEqual(url?.path, "/Users/test/Desktop/reports/Dayflow timeline 2026-06-10.md")
  }

  func testFilePathWithoutExtensionGetsMarkdownExtension() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/Users/test/Documents/myexport", startDay: day, endDay: day, fileManager: fm())
    XCTAssertEqual(url?.path, "/Users/test/Documents/myexport.md")
  }

  func testFilePathWithExtensionUnchanged() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/Users/test/Downloads/myexport.md", startDay: day, endDay: day, fileManager: fm())
    XCTAssertEqual(url?.path, "/Users/test/Downloads/myexport.md")
  }

  func testTildeIsExpandedWithinDownloads() {
    // Tilde expansion uses the real home, so align the stub's roots to the real home.
    let realHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let stub = StubFileManager(home: realHome)
    let url = TimelineExportService.resolveDestination(
      rawPath: "~/Downloads/exp.md", startDay: day, endDay: day, fileManager: stub)
    XCTAssertEqual(url?.path, NSHomeDirectory() + "/Downloads/exp.md")
  }

  // MARK: - Rejected destinations (security: arbitrary-write guard)

  func testPathOutsideAllowedRootsIsRejected() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/tmp/evil.md", startDay: day, endDay: day, fileManager: fm())
    XCTAssertNil(url)
  }

  func testDotfileInHomeRootIsRejected() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/Users/test/.zshrc", startDay: day, endDay: day, fileManager: fm())
    XCTAssertNil(url)
  }

  func testParentTraversalEscapingAllowedRootIsRejected() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/Users/test/Documents/../../etc/passwd", startDay: day, endDay: day,
      fileManager: fm())
    XCTAssertNil(url)
  }
}

/// Minimal `FileManager` stub: derives Downloads/Documents/Desktop from a fixed home and reports
/// a configured set of paths as existing directories. Everything else falls through to the real
/// manager.
private final class StubFileManager: FileManager {
  private let home: URL
  private let existingDirectories: Set<String>

  init(home: URL, existingDirectories: [String] = []) {
    self.home = home
    self.existingDirectories = Set(existingDirectories)
    super.init()
  }

  override var homeDirectoryForCurrentUser: URL { home }

  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    switch directory {
    case .downloadsDirectory: return [home.appendingPathComponent("Downloads")]
    case .documentDirectory: return [home.appendingPathComponent("Documents")]
    case .desktopDirectory: return [home.appendingPathComponent("Desktop")]
    default: return super.urls(for: directory, in: domainMask)
    }
  }

  override func fileExists(
    atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?
  ) -> Bool {
    if existingDirectories.contains(path) {
      isDirectory?.pointee = ObjCBool(true)
      return true
    }
    isDirectory?.pointee = ObjCBool(false)
    return false
  }
}
