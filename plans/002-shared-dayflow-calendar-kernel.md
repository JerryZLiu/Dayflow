# Plan 002: Extract shared Dayflow calendar kernel

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 274c059..HEAD -- tools/dayflow-cli/Sources/dayflow/DayBoundary.swift Dayflow/Dayflow/Core/Recording/StorageDateHelpers.swift Dayflow/Dayflow/Core/Weekly/WeeklyDateRange.swift tools/dayflow-cli/Sources/dayflow/Categories.swift`
> Compare "Current state" excerpts on mismatch — STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-ci-verification-baseline.md
- **Category**: tech-debt
- **Planned at**: commit `274c059`, 2026-08-29

## Why this matters

The bundled `dayflow` CLI reads timeline data using its own copies of day-boundary and category logic. The CLI source explicitly states these mirror app files and should eventually be shared. If the copies drift, MCP/agent queries return activities for the wrong Dayflow day (days start at 4 AM) or resolve categories differently from the UI — breaking trust in the agent integration path.

## Current state

**CLI duplication (acknowledged in code):**

```7:8:tools/dayflow-cli/Sources/dayflow/DayBoundary.swift
//  the app; when the CLI becomes an Xcode target these files should be
//  replaced by the app's own, compiled into both.
```

**App day boundary:**

```22:39:Dayflow/Dayflow/Core/Recording/StorageDateHelpers.swift
  func getDayInfoFor4AMBoundary() -> (dayString: String, startOfDay: Date, endOfDay: Date) {
    let calendar = Calendar.current
    guard let fourAMToday = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: self) else {
      // ... fallback to calendar startOfDay
    }
    // ... before 4 AM → previous day
  }
```

**App week boundary** uses `WeeklyDateRange.mondayBoundary` with `firstWeekday = 2` and Monday 4 AM rules (`WeeklyDateRange.swift:50-61`).

**CLI categories** read `teleportlabs.com.Dayflow` UserDefaults directly (`Categories.swift:35-40`), duplicating `CategoryStore` default categories (`Categories.swift:24-33`).

**Convention exemplar for tests:** pure functions tested without UI — see `Dayflow/DayflowTests/WeeklyDashboardBuilderTests.swift` using `WeeklyDateRange.containing(...)`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Unit tests | `xcodebuild test -project Dayflow/Dayflow.xcodeproj -scheme Dayflow -destination 'platform=macOS' -only-testing:DayflowTests` | exit 0 |
| CLI build | `cd tools/dayflow-cli && swift build` | exit 0 |

## Scope

**In scope**:
- New shared Swift sources (either `Dayflow/Dayflow/Core/Shared/` compiled into app + CLI Xcode target, or a local SPM package under `tools/dayflow-kernel/`)
- Refactor `StorageDateHelpers`, `WeeklyDateRange`, CLI `DayBoundary.swift`, CLI `Categories.swift` to call shared functions
- New unit tests for edge cases: before-4-AM day roll, Monday-before-4-AM week roll, empty/missing category preferences

**Out of scope**:
- Changing the 4 AM rule itself
- MCP protocol or bridge socket changes
- Migrating all of `CategoryStore` into the kernel (only the read-path category list used by CLI)

## Git workflow

- Branch: `advisor/002-shared-calendar-kernel`
- Commit messages: `refactor: share day boundary logic between app and cli`

## Steps

### Step 1: Add characterization tests for current behavior

Before moving code, add tests that lock current CLI + app agreement:

- Test case: date at 2026-08-12 03:30 local → day key `2026-08-11`
- Test case: explicit day key `2026-08-12` → start at 4 AM Aug 12, end at 4 AM Aug 13
- Test case: week containing a Monday 03:00 → prior week

Place tests in `Dayflow/DayflowTests/DayflowCalendarKernelTests.swift` (new).

**Verify**: `xcodebuild test ... -only-testing:DayflowTests/DayflowCalendarKernelTests` passes against *current* duplicated logic (copy expected values from both implementations and assert they match).

### Step 2: Extract shared kernel module

Create shared types:

```swift
struct DayWindow: Equatable { let dayKey: String; let start: Date; let end: Date }
struct WeekWindow: Equatable { let start: Date; let end: Date }

enum DayflowCalendar {
  static func dayWindow(containing date: Date, calendar: Calendar = .current) -> DayWindow
  static func dayWindow(forKey key: String, calendar: Calendar = .current) -> DayWindow?
  static func weekWindow(containing date: Date, calendar: Calendar = .current) -> WeekWindow
}
```

Move logic from `StorageDateHelpers.getDayInfoFor4AMBoundary` and `WeeklyDateRange.mondayBoundary` into `DayflowCalendar`. Keep thin wrappers in existing files for backward compatibility during migration.

**Verify**: all existing `WeeklyDashboardBuilderTests` still pass.

### Step 3: Wire CLI to shared module

Replace body of `tools/dayflow-cli/Sources/dayflow/DayBoundary.swift` with calls to shared sources. Options (pick one):

- **A (preferred long-term):** Add CLI as an Xcode target in `Dayflow.xcodeproj` sharing the kernel folder.
- **B (interim):** Add local SPM package `tools/dayflow-kernel` depended on by both CLI `Package.swift` and Xcode project.

Update `Categories.swift` to use a shared `DayflowCategories.load(from defaultsDomain:)` function with the same default list.

**Verify**: `cd tools/dayflow-cli && swift build` exit 0; manual `dayflow timeline --json` on a fixture DB (if available) returns same day keys as before.

### Step 4: Delete duplicated logic

Remove redundant implementations once wrappers delegate entirely to `DayflowCalendar`. Leave one-line comments pointing to the kernel.

**Verify**: `grep -rn "when the CLI becomes an Xcode target" tools/dayflow-cli/` returns no matches (comment removed or updated).

## Test plan

- New file: `DayflowCalendarKernelTests.swift` — minimum 6 cases covering 4 AM boundary, explicit day key, week boundary, category defaults, stored categories JSON decode.
- Extend with table-driven tests if timezone edge cases arise — use fixed `Calendar` with explicit `TimeZone(identifier: "America/Los_Angeles")!` in tests.

## Done criteria

- [ ] Single source of truth for day/week windows used by app timeline queries and CLI `fetchActivities`
- [ ] Characterization tests pass on CI (plan 001 workflow)
- [ ] No duplicate `dayWindow` implementation bodies in CLI and app
- [ ] `plans/README.md` row 002 → DONE

## STOP conditions

- Characterization tests reveal CLI and app already disagree on week boundaries — STOP and report both outputs before consolidating.
- Shared module cannot be linked from both Xcode and SPM without major project restructuring — STOP and propose Option A vs B with file list.
- Tests require changing observable user-facing day labels — STOP (product decision).

## Maintenance notes

- Any future change to day start time (currently 4 AM) must update `DayflowCalendar` only.
- MCP tool descriptions referencing "days start at 4 AM" remain accurate automatically if kernel is shared.
