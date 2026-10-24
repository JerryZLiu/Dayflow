# Plan 004: Add Flow subsystem characterization tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 274c059..HEAD -- Dayflow/Dayflow/Core/Flow/`
> Compare excerpts on mismatch — STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001-ci-verification-baseline.md
- **Category**: tests
- **Planned at**: commit `274c059`, 2026-08-29

## Why this matters

The Flow feature (focus sessions, distraction agent, desktop overlay) landed in a burst of recent commits (`flow:` prefix in git log from `b3b38c9` through `da5a1b2`) with zero unit tests. `FlowDistractionAgent` parses model JSON verdicts, drives overlay nudges, and updates session state via `FlowSessionMirror`. A flaky parse or wrong default could fire bogus nudges or miss off-task detection — high user visibility, no regression safety.

## Current state

**FlowDistractionAgent** (`FlowDistractionAgent.swift:36-43`):

```swift
  /// Model replies (and turn failures) for the DEBUG log panel in FlowView.
  @Published private(set) var transcript: [TranscriptEntry] = []

  /// The model's per-turn reply. Anything unparseable is treated as
  /// on-task/no-action so a flaky turn can never fire a bogus nudge.
  private struct Verdict: Decodable {
    let status: String?
    let action: String?
    let message: String?
    let reason: String?
  }
```

**FlowNativeSnapshot** — codable session state (`FlowNativeState.swift:28+`).

**FlowSessionMirror** — bridges web session phase to native overlay (`FlowSessionMirror.swift`).

**Existing test patterns**:
- Pure logic tests without UI: `TimelineActivityLoaderTests.swift`
- CLI/process tests with injection: `ChatCLIProcessRunnerTests.swift` in `DayflowTests/`

**No tests** matching `Flow*` in test directories.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Run Flow tests only | `xcodebuild test -project Dayflow/Dayflow.xcodeproj -scheme Dayflow -destination 'platform=macOS' -only-testing:DayflowTests/FlowVerdictInterpreterTests` | exit 0 |
| Full unit suite | `xcodebuild test ... -only-testing:DayflowTests` | exit 0 |

## Scope

**In scope**:
- Extract verdict parsing from `FlowDistractionAgent` into testable enum/function (e.g. `FlowVerdictInterpreter.parse(json:)` → `FlowAgentDecision`)
- `Dayflow/DayflowTests/FlowVerdictInterpreterTests.swift`
- `Dayflow/DayflowTests/FlowNativeSnapshotTests.swift` — encode/decode round-trip
- Optional: `FlowSessionMirrorTests` with mock `FlowBridgeForwarding`

**Out of scope**:
- Live Codex CLI integration tests
- ScreenCaptureKit / overlay window tests
- Rewriting FlowDistractionAgent tick loop

## Git workflow

- Branch: `advisor/004-flow-characterization-tests`
- Commits: `tests: cover Flow verdict parsing and session snapshot`

## Steps

### Step 1: Extract pure verdict interpreter

Create `Dayflow/Dayflow/Core/Flow/FlowVerdictInterpreter.swift`:

```swift
enum FlowAgentDecision: Equatable {
  case onTask
  case offTask(message: String?)
  case nudge(message: String)
  case praise(message: String)
}

enum FlowVerdictInterpreter {
  static func parse(_ data: Data) -> FlowAgentDecision
  static func parse(_ string: String) -> FlowAgentDecision
}
```

Move decoding logic from `FlowDistractionAgent` private `Verdict` struct. Agent calls interpreter; unparseable input → `.onTask` (preserve fail-safe comment behavior).

**Verify**: project compiles; Flow feature manually smoke-tested on Mac if possible.

### Step 2: Add characterization tests

Test cases (minimum):

| Input JSON | Expected decision |
|------------|-------------------|
| `{"status":"on_task"}` | `.onTask` |
| `{"status":"off_task","message":"Slack"}` | `.offTask(message: "Slack")` |
| `{"action":"nudge","message":"Back to PR"}` | `.nudge(message: "Back to PR")` |
| `{invalid}` | `.onTask` (fail-safe) |
| `{}` | `.onTask` |

Add snapshot tests for `FlowNativeSnapshot` phase transitions if `Codable` enums change.

**Verify**: `-only-testing:DayflowTests/FlowVerdictInterpreterTests` passes.

### Step 3: Mock-based mirror test (optional but recommended)

```swift
final class MockFlowBridge: FlowBridgeForwarding { ... }
```

Assert `FlowSessionMirror` publishes correct `FlowOverlayPresentation` when phase moves `.focusing` → `.distracted`.

**Verify**: tests pass without network or Codex.

## Test plan

- Model after `AgentWriteHandlersTests.swift` — `@MainActor` only where required.
- No snapshot files of full JSON transcripts (brittle); assert enum cases only.

## Done criteria

- [ ] Verdict parsing covered by ≥5 unit tests including fail-safe path
- [ ] `FlowDistractionAgent` delegates parsing to `FlowVerdictInterpreter`
- [ ] All Flow tests run in CI via plan 001 workflow
- [ ] `plans/README.md` row 004 → DONE

## STOP conditions

- Verdict JSON schema is not stable / undocumented — STOP and capture 3 real samples from debug transcript before extracting.
- Extraction requires `@MainActor` throughout — STOP and propose alternative pure parser input type.
- Tests require Codex binary — STOP; use fixture strings only.

## Maintenance notes

- When model prompt changes output schema, update interpreter + tests together.
- Architecture review candidate "Deepen FlowDistractionAgent verdict module" aligns with this extraction — further splits welcome after tests exist.
