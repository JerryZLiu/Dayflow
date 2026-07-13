# Dayflow — Project Agent Notes

This file captures project-specific knowledge that any coding agent
(Mavis, Mavis, or anything else consuming the `AGENTS.md` spec) needs
to be productive inside this repo. Keep it terse, factual, and current.

## Repository topology

| Role  | Remote                                              | Default branch |
| ----- | --------------------------------------------------- | -------------- |
| fork  | `https://github.com/M3NT1/Dayflow_M3NT1.git`        | `main`         |
| upstream | `https://github.com/JerryZLiu/dayflow.git`       | `main`         |

- `origin`  → upstream (`JerryZLiu/dayflow`)
- `myfork`  → personal fork (`M3NT1/Dayflow_M3NT1`)
- All work-in-progress lives on `myfork/feat/*` branches, never on `main` directly.
- The active development branch right now is **`feat/minimax-m3-provider`**
  (MiniMax M3 cloud provider — added in commit `3bc167e`, then iterated
  to `23ff29f`). The fix described in
  `Dayflow/Dayflow/Views/UI/Settings/ProvidersSettingsViewModel.swift`
  (adding the `case "minimax":` branch to `isProviderConfigured`) is
  the latest patch on top of that branch.

## Build & run

- The project is a SwiftUI macOS app opened with Xcode 26
  (`/Applications/Xcode.app`).
- The user's `xcode-select` points to Command Line Tools, not Xcode.
  All `xcodebuild` invocations need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  in the environment, or build silently fails to find the toolchain.
- The user has no `Mac Development` signing certificate for the
  `L75WYD8X4Y` team, so every build must pass `CODE_SIGNING_ALLOWED=NO`
  (or equivalent) or it will fail with a signing error.
- Build products are NOT kept inside the repo. After every successful
  build, the freshly built `Dayflow.app` is copied from
  `~/Library/Developer/Xcode/DerivedData/Dayflow-*/Build/Products/Debug/Dayflow.app`
  into **`/Users/kasnyiklaszlo/Documents/MENTIFLOW/dist/Dayflow.app`**
  for the user to launch. Always use `mavis-trash` (not `rm`) for the
  old `dist/Dayflow.app` so it stays recoverable.
- `gh` CLI is available and authenticated. PRs targeting the upstream
  Dayflow repo are created with
  `gh pr create --repo JerryZLiu/dayflow --base main --head M3NT1:<branch>`.

## Project layout

```
Dayflow/
  Dayflow.xcodeproj
  Dayflow/
    App/             — AppDelegate, app lifecycle
    Config/          — Build-time configuration (LocalSecrets.xcconfig is gitignored)
    Core/            — Business logic
      AI/            — LLM provider implementations
        MiniMaxProvider*.swift    — MiniMax M3 provider
        GeminiProvider*.swift     — Gemini provider
        ChatCLIProvider*.swift    — OpenAI/Claude CLI providers
        OllamaProvider*.swift     — Local (Ollama / LM Studio) provider
        ModelCatalog.swift        — Curated + live model lists
        LLMService.swift          — Main dispatch, failover routing
    Models/          — Data models
    Recording/       — Screen recording, storage, timeline cards
    Utilities/       — Helpers (e.g. MiniMaxAPIHelper)
    Views/
      Onboarding/    — First-run flow
      UI/            — Main UI
        Settings/    — Preferences tabs
          SettingsProvidersTabView.swift       — Provider list UI
          ProvidersSettingsViewModel.swift      — Provider logic, routing
          ProvidersSettingsViewModel+PromptOverrides.swift
  DayflowTests/      — Unit tests (very sparse; only ChatCLI + DailyRecap)
  DayflowUITests/    — UI tests
  docs/              — Appcast, release notes
```

## LLM provider model

Each provider has a **canonical id** and a **display id** that may differ
when the underlying engine is swappable (e.g. `chatgpt` / `claude` ↔
`chatgpt_claude`). The provider's status is tracked by:

| Canonical id      | Keychain key            | Setup-complete flag        | Provider class            |
| ----------------- | ----------------------- | -------------------------- | ------------------------- |
| `gemini`          | `"gemini"`              | `geminiSetupComplete`      | GeminiProvider            |
| `minimax`         | `"minimax"`             | `minimaxSetupComplete`     | MiniMaxProvider           |
| `ollama`          | (UserDefaults only)     | `ollamaSetupComplete`      | OllamaProvider / custom   |
| `chatgpt_claude`  | (CLI binary)            | `chatgpt_claudeSetupComplete` | ChatCLIProvider        |
| `dayflow`         | (Dayflow Pro)           | (derived from Pro status)  | (hosted)                  |

**Critical gotcha — every new provider needs a `case` in three places:**

1. `ProvidersSettingsViewModel.isProviderConfigured(_:)` — otherwise the
   provider is never recognised as "set up" and the "Set primary" /
   "Set secondary" buttons loop the user back into the setup wizard
   (this is the bug fixed for MiniMax; copy the `gemini` branch as the
   template: check Keychain first, fall back to the
   `*SetupComplete` UserDefaults flag).
2. `ProvidersSettingsViewModel.canonicalProviderId(for:)` / `displayProviderId`
   — only needs touching if the provider has variant display ids.
3. `CompactProviderInfo.providerTableName` — only for custom table labels.

The MiniMax M3 fix added the missing `case "minimax":` to
`isProviderConfigured` and nothing else was needed.

## Routing logic (Settings → Providers tab)

- `routingProviders` is the list of cards in the "Failover routing"
  section. Each row shows: status badge, summary line, and an
  action row with one or more of `Setup` / `Edit configuration` /
  `Set primary` / `Set secondary` / `Unset secondary`.
- `isProviderConfigured` drives the "CONFIGURED" / "NOT SET" badge
  and whether the `Setup` button is shown.
- `canAssignSecondary` requires `isProviderConfigured == true` AND
  that the target is not the same canonical provider as the current
  primary. So **if `isProviderConfigured` lies, the secondary slot
  will never be assignable** even after a successful setup wizard.
- `beginProviderSetup(_:role:)` stores the intent (`pendingSetupRole`)
  before opening the modal. On `handleProviderSetupCompletion(_:)`,
  the stored role decides whether to call `assignPrimaryProvider` or
  `assignSecondaryProvider`.

## Conventions

- Commit messages follow Conventional Commits: `feat:`, `fix:`,
  `settings:`, `release:`, etc.
- New code goes through the user's personal fork first; MRs are
  opened against `JerryZLiu/dayflow: main`.
- The `CLAUDE.md` / `claude.md` files are git-ignored, so do not
  commit agent memory there. Use `AGENTS.md` (this file) instead.
- The `dist/` folder is rebuilt on every iteration; never edit files
  inside `Dayflow.app` directly — they will be overwritten.
