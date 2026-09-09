# Daygo

[简体中文](README.md) · **English**

Daygo is a private, local-first work journal for macOS. It captures screen activity at intervals, uses an AI provider chosen by the user to understand that activity, and turns it into a searchable daily timeline, standup summary, and review.

> **Project status:** Daygo is being rebuilt with a Go core, Wails, and Vue. The repository still contains the production Swift application inherited from Dayflow, which serves as the reference implementation and rollback path. The new Go application is not ready for general installation yet.

## Why Daygo

Conventional time trackers usually know which application was active. Daygo aims to preserve the context of the work itself: what was being built, investigated, discussed, or reviewed.

- Automatic activity timeline without manually starting timers
- Daily summaries and standup preparation
- Weekly review and distraction analysis
- Natural-language questions grounded in your work history
- Local-first storage and configurable retention
- Local or cloud AI providers selected by the user

## Privacy model

Privacy is an architectural constraint, not an optional mode:

- Recordings, timeline data, and the database remain on the Mac by default.
- Screen data may leave the device only when it is sent to an AI provider explicitly configured by the user.
- Local models can be used to keep analysis on-device.
- Blocked applications are excluded from capture, with a redacted placeholder used when necessary.
- Analytics and crash reporting are opt-in and must never contain screen content, window titles, file paths, credentials, or LLM payloads.

The legacy application stores its data under:

```text
~/Library/Application Support/Dayflow/
```

This path intentionally remains unchanged during migration to preserve existing user data.

## Rebuild architecture

```text
Vue 3 + TypeScript
        ↓ Wails bindings
Go core
  ├── storage and settings
  ├── analysis and AI providers
  ├── timeline, daily, and weekly insights
  └── lifecycle orchestration
        ↓ versioned NDJSON over a Unix socket
Swift helper
  └── ScreenCaptureKit, AVFoundation, TCC, Keychain, status item, Sparkle
```

Go owns portable business logic and, after cutover, becomes the single SQLite writer. Swift remains only where Apple frameworks or macOS identity requirements make it necessary.

The migration is incremental: establish compatibility fixtures, ship a read-only Go viewer, compare derived results, and only then transfer analysis and capture ownership. See the [migration plan](docs/plan/README.md) for the design, risks, testing strategy, and phase gates.

## Current repository layout

```text
cmd/                        Go command entry points (future phase)
internal/                   Go core (future phase)
frontend/                   Vue/Wails frontend (future phase)
native/darwin/              macOS Swift helper (future phase)
testdata/                   anonymized compatibility fixtures (phase 0)
docs/plan/                  Go/Wails/Vue migration design
legacy/dayflow/             current Swift reference application
legacy/dayflow-cli/         current read-only Swift CLI
legacy/unlinked-tests/      historical tests outside the Xcode target
scripts/                    build and release scripts for the current app
```

The planned Go paths under `docs/plan/` are target state and may not exist yet. `legacy/` is retained only for migration comparisons and rollback; new business logic must not be added there.

## Build the current reference application

Requirements:

- macOS 14 or later
- Xcode 16 or later
- Screen & System Audio Recording permission when running the app

```bash
git clone https://github.com/Jwz-git/Dayflow.git
cd Dayflow
open legacy/dayflow/Dayflow.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project legacy/dayflow/Dayflow.xcodeproj \
  -scheme Dayflow \
  -configuration Debug build
```

Local builds read `legacy/dayflow/Config/LocalSecrets.xcconfig`, which is intentionally ignored by Git. Copy the example file and provide local values when needed. Never commit API keys or other credentials.

## Tests

```bash
xcodebuild -project legacy/dayflow/Dayflow.xcodeproj \
  -scheme Dayflow \
  -destination 'platform=macOS' test

cd legacy/dayflow-cli
swift build
swift run dayflow status
```

Go commands will be documented here once the Go module lands. Until then, commands in the migration plan describe completion criteria rather than an already available build.

## Contributing

Work should follow the staged migration plan and preserve the current database, CLI, privacy, capture, updater, and macOS identity contracts. Read [AGENTS.md](AGENTS.md) before making implementation changes.

For substantial changes, open an issue first and state which migration phase and verification gate the work addresses.

## License

Daygo is licensed under the [MIT License](LICENSE).
