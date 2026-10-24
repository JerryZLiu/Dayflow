# Plan 001: Add CI verification baseline

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 274c059..HEAD -- .github/`
> If any workflow file changed since this plan was written, compare steps
> against the live workflow before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `274c059`, 2026-08-29

## Why this matters

Dayflow has ~20 XCTest files under `Dayflow/DayflowTests/` and `DayflowTests/`, plus a Swift CLI under `tools/dayflow-cli/`, but `.github/` contains only an issue template — no workflow runs tests on push or PR. Without a verification baseline, every other improvement plan in this directory lacks an automated gate. This is the highest-leverage unblocker.

## Current state

- **Test targets** (from `Dayflow/Dayflow.xcodeproj/project.pbxproj`):
  - `DayflowTests` — unit tests (e.g. `AgentWriteHandlersTests.swift`, `LLMProviderRoutingTests.swift`)
  - `DayflowUITests` — UI tests (may require macOS display; gate separately)
- **CLI package**: `tools/dayflow-cli/Package.swift` — executable target only, builds with `swift build` on macOS 13+.
- **Build entry point** (from `README.md:125-131`): open `Dayflow/Dayflow.xcodeproj` in Xcode — no documented `xcodebuild` one-liner yet.
- **Existing convention**: release commits use prefixes like `release:`, `cli:`, `agents:` (see `git log --oneline -10`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| List schemes | `xcodebuild -list -project Dayflow/Dayflow.xcodeproj` | Lists `Dayflow`, `DayflowTests`, `DayflowUITests` |
| Unit tests | `xcodebuild test -project Dayflow/Dayflow.xcodeproj -scheme Dayflow -destination 'platform=macOS' -only-testing:DayflowTests` | exit 0, tests pass |
| CLI build | `cd tools/dayflow-cli && swift build` | exit 0, `.build/debug/dayflow` exists |

(These require a macOS runner with Xcode — GitHub `macos-14` or `macos-15`.)

## Scope

**In scope**:
- `.github/workflows/ci.yml` (create)
- `README.md` — add a "CI" subsection under Contributing with the same commands (optional but recommended)

**Out of scope**:
- Fixing failing tests (if any fail on CI, file issues — do not disable tests silently)
- DayflowUITests in CI v1 (flaky/display-dependent — document as follow-up)
- Linux CI for dayflow-cli (CLI targets macOS only per `Package.swift:12`)

## Git workflow

- Branch: `advisor/001-ci-verification-baseline`
- Commit message style: `ci: add macOS unit test workflow` (matches repo prefixes)

## Steps

### Step 1: Confirm local xcodebuild works

On a Mac with Xcode:

```bash
xcodebuild -list -project Dayflow/Dayflow.xcodeproj
xcodebuild test -project Dayflow/Dayflow.xcodeproj -scheme Dayflow \
  -destination 'platform=macOS' \
  -only-testing:DayflowTests \
  -resultBundlePath /tmp/dayflow-test-results
```

**Verify**: exit 0; result bundle contains passing tests.

### Step 2: Add GitHub Actions workflow

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  unit-tests:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Run DayflowTests
        run: |
          xcodebuild test \
            -project Dayflow/Dayflow.xcodeproj \
            -scheme Dayflow \
            -destination 'platform=macOS' \
            -only-testing:DayflowTests \
            -resultBundlePath TestResults
      - name: Build dayflow-cli
        run: cd tools/dayflow-cli && swift build
```

**Verify**: `yamllint .github/workflows/ci.yml` if available, or manual review — valid YAML, triggers on PR.

### Step 3: Document verification commands in README

Under `## Contributing`, add:

```markdown
### CI

Pull requests run `DayflowTests` on macOS via GitHub Actions. Locally:

\`\`\`bash
xcodebuild test -project Dayflow/Dayflow.xcodeproj -scheme Dayflow \
  -destination 'platform=macOS' -only-testing:DayflowTests
cd tools/dayflow-cli && swift build
\`\`\`
```

**Verify**: `grep -n "xcodebuild test" README.md` returns a match.

## Test plan

- No new unit tests required — this plan adds the infrastructure to run existing tests.
- After workflow lands, open a trivial PR and confirm the Actions tab shows green `unit-tests`.

## Done criteria

- [ ] `.github/workflows/ci.yml` exists and triggers on `pull_request` to `main`
- [ ] Workflow runs on `macos-14` (or newer) and invokes `-only-testing:DayflowTests`
- [ ] Workflow includes `swift build` for `tools/dayflow-cli`
- [ ] README documents local verification commands
- [ ] `plans/README.md` status row for 001 updated to DONE

## STOP conditions

- `xcodebuild test` fails locally with compile errors unrelated to this workflow file — stop and report the failure output.
- Repository uses a different default scheme name than `Dayflow` — stop and update the workflow to match `-list` output.
- GitHub Actions macOS minutes are unavailable for this org — stop and report; suggest self-hosted macOS runner.

## Maintenance notes

- When adding `DayflowUITests` to CI, use a separate job with `-only-testing:DayflowUITests` and document display requirements.
- Plans 002–004 depend on this workflow — extend CI when new test targets are added (CLI tests, Flow tests).
