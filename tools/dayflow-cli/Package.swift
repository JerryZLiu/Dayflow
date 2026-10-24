// swift-tools-version:5.9
import PackageDescription

// Phase 1 of the Dayflow CLI: a standalone, read-only executable.
//
// It deliberately has no third-party package dependencies. SQLite comes from
// the system SDK on macOS and from libsqlite3 via a system-library target on
// Linux. Argument parsing is hand-rolled, so this builds with `swift build`
// alone and can later be folded into Dayflow.app as an Xcode target without
// dragging any package resolution along with it.
#if os(Linux)
let targets: [Target] = [
  .systemLibrary(
    name: "CSQLite",
    pkgConfig: "sqlite3",
    providers: [.apt(["libsqlite3-dev"]), .yum(["sqlite-devel"])]
  ),
  .executableTarget(
    name: "dayflow",
    dependencies: ["CSQLite"],
    path: "Sources/dayflow"
  ),
]
#else
let targets: [Target] = [
  .executableTarget(
    name: "dayflow",
    path: "Sources/dayflow"
  ),
]
#endif

let package = Package(
  name: "dayflow-cli",
  platforms: [.macOS(.v13)],
  targets: targets
)
