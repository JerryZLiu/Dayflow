import XCTest

@testable import Dayflow

final class CodexExecutableResolverTests: XCTestCase {
  func testSelectsNewestWorkingCandidate() throws {
    let brokenURL = URL(fileURLWithPath: "/tmp/broken-codex")
    let olderURL = URL(fileURLWithPath: "/tmp/older-codex")
    let newestURL = URL(fileURLWithPath: "/tmp/newest-codex")
    let versions = [
      olderURL: "codex-cli 0.144.2",
      newestURL: "codex-cli 0.145.0",
    ]
    let resolver = CodexExecutableResolver(
      candidateProvider: {
        [
          .init(executableURL: brokenURL, source: .path),
          .init(executableURL: olderURL, source: .chatGPTApp),
          .init(executableURL: newestURL, source: .codexApp),
        ]
      },
      versionProbe: { versions[$0] }
    )

    let resolution = try XCTUnwrap(resolver.resolve())
    XCTAssertEqual(resolution.executableURL.path, newestURL.path)
    XCTAssertEqual(resolution.version, "0.145.0")
    XCTAssertEqual(resolution.source, .codexApp)
  }

  func testSemanticVersionComparisonUsesNumericComponents() throws {
    let lowerURL = URL(fileURLWithPath: "/tmp/codex-0.144.2")
    let higherURL = URL(fileURLWithPath: "/tmp/codex-0.144.10")
    let versions = [
      lowerURL: "codex-cli 0.144.2",
      higherURL: "codex-cli 0.144.10",
    ]
    let resolver = CodexExecutableResolver(
      candidateProvider: {
        [
          .init(executableURL: lowerURL, source: .path),
          .init(executableURL: higherURL, source: .chatGPTApp),
        ]
      },
      versionProbe: { versions[$0] }
    )

    XCTAssertEqual(try XCTUnwrap(resolver.resolve()).executableURL.path, higherURL.path)
  }

  func testCachesResolutionUntilInvalidated() {
    let executableURL = URL(fileURLWithPath: "/tmp/codex")
    var candidateProviderCalls = 0
    var versionProbeCalls = 0
    let resolver = CodexExecutableResolver(
      candidateProvider: {
        candidateProviderCalls += 1
        return [.init(executableURL: executableURL, source: .path)]
      },
      versionProbe: { _ in
        versionProbeCalls += 1
        return "codex-cli 0.144.2"
      }
    )

    XCTAssertNotNil(resolver.resolve())
    XCTAssertNotNil(resolver.resolve())
    XCTAssertEqual(candidateProviderCalls, 1)
    XCTAssertEqual(versionProbeCalls, 1)

    resolver.invalidate()
    XCTAssertNotNil(resolver.resolve())
    XCTAssertEqual(candidateProviderCalls, 2)
    XCTAssertEqual(versionProbeCalls, 2)
  }

  func testUnavailableCandidateUsesNextNewest() throws {
    let newestURL = URL(fileURLWithPath: "/tmp/newest-codex")
    let fallbackURL = URL(fileURLWithPath: "/tmp/fallback-codex")
    var versions = [
      newestURL: "codex-cli 0.145.0",
      fallbackURL: "codex-cli 0.144.2",
    ]
    let resolver = CodexExecutableResolver(
      candidateProvider: {
        [
          .init(executableURL: newestURL, source: .path),
          .init(executableURL: fallbackURL, source: .chatGPTApp),
        ]
      },
      versionProbe: { versions[$0] }
    )

    let initialResolution = try XCTUnwrap(resolver.resolve())
    XCTAssertEqual(initialResolution.executableURL.path, newestURL.path)

    versions[newestURL] = nil
    let replacement = try XCTUnwrap(resolver.replacementIfUnavailable(initialResolution))
    XCTAssertEqual(replacement.executableURL.path, fallbackURL.path)
    XCTAssertEqual(try XCTUnwrap(resolver.resolve()).executableURL.path, fallbackURL.path)
  }

  func testInternalENOENTDoesNotReplaceWorkingExecutable() throws {
    let executableURL = URL(fileURLWithPath: "/tmp/codex")
    let resolver = CodexExecutableResolver(
      candidateProvider: {
        [.init(executableURL: executableURL, source: .path)]
      },
      versionProbe: { _ in "codex-cli 0.145.0" }
    )
    let runner = ChatCLIProcessRunner(codexExecutableResolver: resolver)
    let initialResolution = try XCTUnwrap(resolver.resolve())

    XCTAssertTrue(
      runner.shouldRetryCodexExecutableResolution(
        tool: .codex,
        terminationStatus: 1,
        stderr: "Internal operation failed with ENOENT",
        hasRetried: false
      )
    )
    XCTAssertNil(resolver.replacementIfUnavailable(initialResolution))
    XCTAssertEqual(try XCTUnwrap(resolver.resolve()).executableURL.path, executableURL.path)
  }

  func testUnavailableCandidateCanRecoverOnLaterResolution() throws {
    let executableURL = URL(fileURLWithPath: "/tmp/codex")
    var version: String? = "codex-cli 0.145.0"
    let resolver = CodexExecutableResolver(
      candidateProvider: {
        [.init(executableURL: executableURL, source: .path)]
      },
      versionProbe: { _ in version }
    )
    let initialResolution = try XCTUnwrap(resolver.resolve())

    version = nil
    XCTAssertNil(resolver.replacementIfUnavailable(initialResolution))
    XCTAssertNil(resolver.resolve())

    version = "codex-cli 0.145.0"
    XCTAssertEqual(try XCTUnwrap(resolver.resolve()).executableURL.path, executableURL.path)
  }
}
