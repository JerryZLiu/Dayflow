// swift-tools-version:5.9
import PackageDescription

// Phase 1 of the Dayflow CLI: a standalone, read-only executable.
//
// It deliberately has no dependencies. SQLite comes from the system SDK, and
// argument parsing is hand-rolled, so this builds with `swift build` alone and
// can later be folded into Dayflow.app as an Xcode target without dragging any
// package resolution along with it.
let package = Package(
  name: "dayflow-cli",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "dayflow",
      path: "Sources/dayflow"
    )
  ]
)
