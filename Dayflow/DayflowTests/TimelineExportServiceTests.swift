import XCTest

@testable import Dayflow

final class TimelineExportServiceTests: XCTestCase {
  private let day = DateFormatter.yyyyMMdd.date(from: "2026-06-10")!
  private let rangeEnd = DateFormatter.yyyyMMdd.date(from: "2026-06-03")!
  private let rangeStart = DateFormatter.yyyyMMdd.date(from: "2026-06-01")!

  // MARK: - File name

  func testDefaultFileNameSingleDay() {
    let name = TimelineExportService.defaultFileName(startDay: day, endDay: day)
    XCTAssertEqual(name, "Dayflow timeline 2026-06-10.md")
  }

  func testDefaultFileNameRange() {
    let name = TimelineExportService.defaultFileName(startDay: rangeStart, endDay: rangeEnd)
    XCTAssertEqual(name, "Dayflow timeline 2026-06-01 to 2026-06-03.md")
  }

  // MARK: - Destination resolution

  func testNilPathUsesDownloadsDirectory() {
    let fm = StubFileManager(downloads: URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true))
    let url = TimelineExportService.resolveDestination(
      rawPath: nil, startDay: day, endDay: day, fileManager: fm)
    XCTAssertEqual(url.path, "/Users/test/Downloads/Dayflow timeline 2026-06-10.md")
  }

  func testTrailingSlashTreatedAsDirectory() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/tmp/exports/", startDay: day, endDay: day, fileManager: StubFileManager())
    XCTAssertEqual(url.path, "/tmp/exports/Dayflow timeline 2026-06-10.md")
  }

  func testExistingDirectoryGetsDerivedFileName() {
    let fm = StubFileManager(directories: ["/tmp/exports"])
    let url = TimelineExportService.resolveDestination(
      rawPath: "/tmp/exports", startDay: day, endDay: day, fileManager: fm)
    XCTAssertEqual(url.path, "/tmp/exports/Dayflow timeline 2026-06-10.md")
  }

  func testFilePathWithoutExtensionGetsMarkdownExtension() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/tmp/myexport", startDay: day, endDay: day, fileManager: StubFileManager())
    XCTAssertEqual(url.path, "/tmp/myexport.md")
  }

  func testFilePathWithExtensionUnchanged() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "/tmp/myexport.md", startDay: day, endDay: day, fileManager: StubFileManager())
    XCTAssertEqual(url.path, "/tmp/myexport.md")
  }

  func testTildeIsExpanded() {
    let url = TimelineExportService.resolveDestination(
      rawPath: "~/exp.md", startDay: day, endDay: day, fileManager: StubFileManager())
    XCTAssertFalse(url.path.hasPrefix("~"))
    XCTAssertTrue(url.path.hasSuffix("/exp.md"))
  }
}

/// Minimal `FileManager` stub: returns a fixed Downloads directory and reports a configured
/// set of paths as existing directories. Everything else falls through to the real manager.
private final class StubFileManager: FileManager {
  private let downloads: URL?
  private let directories: Set<String>

  init(downloads: URL? = nil, directories: [String] = []) {
    self.downloads = downloads
    self.directories = Set(directories)
    super.init()
  }

  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    if directory == .downloadsDirectory, let downloads {
      return [downloads]
    }
    return super.urls(for: directory, in: domainMask)
  }

  override func fileExists(
    atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?
  ) -> Bool {
    if directories.contains(path) {
      isDirectory?.pointee = ObjCBool(true)
      return true
    }
    isDirectory?.pointee = ObjCBool(false)
    return false
  }
}
