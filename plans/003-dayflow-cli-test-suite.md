# Plan 003: Add dayflow-cli test suite

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 274c059..HEAD -- tools/dayflow-cli/`
> Compare excerpts on mismatch — STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001-ci-verification-baseline.md
- **Category**: tests
- **Planned at**: commit `274c059`, 2026-08-29

## Why this matters

The `dayflow` CLI ships embedded in Dayflow.app and exposes an MCP server with read and (when enabled) write tools. It parses JSON-RPC on stdin, queries SQLite read-only, and forwards writes over a Unix socket. There is no test target — regressions in argument parsing, JSON envelopes, or MCP tool schemas would reach agents without detection.

## Current state

- **Package manifest** — executable only:

```10:18:tools/dayflow-cli/Package.swift
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
```

- **MCP server** (`MCPServer.swift:18-57`) — JSON-RPC loop on stdin; write tools gated by `AgentBridge.editsEnabled`.
- **Database** opens read-only with `SQLITE_OPEN_READONLY` + `PRAGMA query_only` (`Database.swift:68-79`).
- **Test override**: `DAYFLOW_DB` env var for database path (`Database.swift:53-55`).
- **Fixture data**: `tools/dayflow-cli/fixtures/` exists (untracked in git at audit time — add a minimal fixture as part of this plan).
- **App test pattern**: XCTest with `@testable import` — for CLI use Swift Testing or XCTest in a `.testTarget`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd tools/dayflow-cli && swift build` | exit 0 |
| Test | `cd tools/dayflow-cli && swift test` | exit 0, all tests pass |
| CI | extends plan 001 workflow with `swift test` | green job |

## Scope

**In scope**:
- `tools/dayflow-cli/Package.swift` — add `.testTarget`
- `tools/dayflow-cli/Tests/` — unit tests
- `tools/dayflow-cli/fixtures/minimal.sqlite` (or SQL seed script) — committed test database
- `.github/workflows/ci.yml` — add `swift test` step (or extend plan 001)
- Refactor (minimal) to expose testable pure functions from `main.swift` if needed (e.g. `resolveDay`, JSON envelope builders)

**Out of scope**:
- Integration tests requiring a live Dayflow.app socket
- Linux port of CLI

## Git workflow

- Branch: `advisor/003-dayflow-cli-tests`
- Commits: `cli: add unit tests for timeline queries and MCP tools`

## Steps

### Step 1: Add test target to Package.swift

```swift
.testTarget(
  name: "dayflowTests",
  dependencies: ["dayflow"],
  path: "Tests"
)
```

If `@testable import dayflow` requires internal access, mark pure functions `internal` in a `DayflowCLIKit.swift` file extracted from `main.swift` / `JSONOut.swift`.

**Verify**: `swift test` compiles (empty test OK).

### Step 2: Commit minimal fixture database

Create `tools/dayflow-cli/fixtures/minimal.sqlite` with:
- At least one `timeline_cards` row (match schema from `Queries.swift`)
- Timestamps spanning a known Dayflow day window

Document fixture creation script in `tools/dayflow-cli/fixtures/README.md` (one paragraph).

**Verify**: `DAYFLOW_DB=fixtures/minimal.sqlite .build/debug/dayflow timeline --json` prints valid JSON.

### Step 3: Write core unit tests

**DayBoundaryTests** (if not fully covered by plan 002):
- `dayWindow(containing:)` before 4 AM
- `dayWindow(forKey:)` invalid key → nil

**JSONOutTests**:
- `timelineEnvelope` shape keys stable for MCP clients

**MCPServerTests** (use subprocess or extracted `callTool`):
- `tools/list` includes read tools always
- `tools/list` excludes write tools when `editsEnabled` false (mock UserDefaults or inject flag)

**QueriesTests**:
- `fetchActivities` returns expected count for fixture window

Model test structure after `Dayflow/DayflowTests/AgentWriteHandlersTests.swift` — table-driven `XCTAssertEqual`.

**Verify**: `cd tools/dayflow-cli && swift test` exit 0.

### Step 4: Wire CI

Extend `.github/workflows/ci.yml`:

```yaml
      - name: Test dayflow-cli
        run: cd tools/dayflow-cli && swift test
```

**Verify**: workflow file valid YAML.

## Test plan

- Minimum 8 test methods across 3 test files.
- One test asserts MCP `untrustedNote` string present in tool descriptions (`MCPServer.swift:83-84`) — prevents accidental removal of prompt-injection guardrail text.

## Done criteria

- [ ] `swift test` passes locally on macOS
- [ ] Fixture database committed and documented
- [ ] CI runs CLI tests on every PR
- [ ] No write tests require running Dayflow.app (use mocks for `AgentBridge.send`)
- [ ] `plans/README.md` row 003 → DONE

## STOP conditions

- Fixture schema does not match production DB — STOP and dump schema from app migration before seeding.
- `main.swift` cannot be tested without large refactor — STOP after Step 1 with list of functions needing extraction.
- SwiftPM test target cannot link `@testable` executable — STOP and propose library + executable split.

## Maintenance notes

- When adding MCP tools, update `toolDefinitions()` tests to assert schema shape.
- Write-tool tests should mock the bridge — never enable real edits in CI.
