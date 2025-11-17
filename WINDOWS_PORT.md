# Dayflow Windows Port - Progress Tracker

**Project**: Port Dayflow from macOS to Windows
**Started**: 2025-11-17
**Branch**: `claude/port-to-windows-01WL5b7VV77fYCGzk253NCKv`
**Status**: 🟡 Planning Phase

---

## Overview

Dayflow is currently a macOS-native application built with Swift, SwiftUI, and ScreenCaptureKit. This document tracks the progress of porting it to Windows using C# and WinUI 3.

### Key Statistics
- **91 Swift source files** in original codebase
- **35-40 files** with direct macOS AppKit dependencies
- **~15,000 lines** of macOS-specific code requiring translation

---

## Current Status: Planning & Analysis Complete ✅

### Completed Steps

1. ✅ **Comprehensive Dependency Analysis** (2025-11-17)
   - Identified all macOS frameworks and APIs in use
   - Mapped 43 files with macOS-specific imports
   - Catalogued system integrations (Keychain, Sparkle, ServiceManagement, etc.)
   - Created Windows replacement mapping for each component

2. ✅ **Architecture Analysis** (2025-11-17)
   - Screen recording: ScreenCaptureKit → Windows.Graphics.Capture API
   - UI framework: SwiftUI → WinUI 3 / XAML
   - Storage: GRDB (portable) → Can be reused
   - Security: Keychain → Windows Credential Manager
   - Updates: Sparkle → WinSparkle

---

## Port Strategy & Architecture

### Phase 1: Foundation & Core Infrastructure (CURRENT)
**Goal**: Set up Windows project structure and core services

#### 1.1 Project Setup
- [ ] Create WinUI 3 solution in Visual Studio
- [ ] Set up project structure matching macOS architecture
- [ ] Configure NuGet dependencies
- [ ] Implement basic app shell and window management

#### 1.2 Storage Layer (Portable)
- [ ] Port SQLite database schema
- [ ] Migrate GRDB code to EntityFramework Core or raw SQLite
- [ ] Implement storage manager for Windows paths
- [ ] Create data models matching Swift originals

#### 1.3 Security & Configuration
- [ ] Implement Windows Credential Manager wrapper (replaces Keychain)
- [ ] Port UserDefaults → Windows.Storage.ApplicationData
- [ ] Configuration file management
- [ ] API key storage and retrieval

### Phase 2: Screen Recording (CRITICAL PATH)
**Goal**: Implement core screen capture functionality

#### 2.1 Windows Graphics Capture API Integration
- [ ] Research Windows.Graphics.Capture.GraphicsCapturePicker
- [ ] Implement screen/window picker UI
- [ ] Set up capture session at 1 FPS (matching macOS)
- [ ] Handle multi-monitor scenarios

#### 2.2 Video Encoding & Storage
- [ ] Implement H.264 encoding using Media Foundation
- [ ] 15-second chunk management (matching macOS behavior)
- [ ] Video file writer with proper cleanup
- [ ] Auto-delete recordings after 3 days

#### 2.3 Error Handling & Permissions
- [ ] Windows permission request flow
- [ ] Handle display disconnection scenarios
- [ ] Sleep/wake recording pause/resume
- [ ] Graceful failure and retry logic

### Phase 3: AI Analysis Pipeline
**Goal**: Port LLM integration and analysis

#### 3.1 LLM Service Layer (Mostly Portable)
- [ ] Port Gemini API client (HTTP, should be straightforward)
- [ ] Port Ollama provider (HTTP, should be straightforward)
- [ ] Implement local model endpoint utilities
- [ ] LLM logger and response parsing

#### 3.2 Video Analysis
- [ ] Frame extraction from video chunks
- [ ] Batch processing every 15 minutes
- [ ] Timeline card generation
- [ ] Category detection and tagging

#### 3.3 Analysis Manager
- [ ] Port analysis scheduling logic
- [ ] Batch creation and status tracking
- [ ] Timeline card storage and retrieval
- [ ] Merge/update logic for cards

### Phase 4: User Interface
**Goal**: Rebuild UI with WinUI 3

#### 4.1 Main Window & Navigation
- [ ] Main window with timeline view
- [ ] Navigation sidebar (Home, Settings, Journal, Dashboard)
- [ ] Window state persistence
- [ ] Dark/light theme support

#### 4.2 Timeline View
- [ ] Scrollable timeline with cards
- [ ] Card rendering (title, time, category, color)
- [ ] Video thumbnail integration
- [ ] Hover states and interactions

#### 4.3 Onboarding Flow
- [ ] Welcome screens
- [ ] LLM provider selection (Gemini vs Local)
- [ ] API key input
- [ ] Permission request (screen recording)
- [ ] Test connection verification

#### 4.4 Settings Panel
- [ ] LLM provider configuration
- [ ] Recording preferences
- [ ] Storage management
- [ ] Privacy settings
- [ ] About/version info

#### 4.5 Video Player
- [ ] Timelapse playback modal
- [ ] Video scrubber/timeline
- [ ] Playback controls
- [ ] Full-screen support

#### 4.6 Journal & Dashboard (Future)
- [ ] Weekly summary view
- [ ] Reminders configuration
- [ ] Custom dashboard tiles
- [ ] Analytics and trends

### Phase 5: System Integration
**Goal**: Windows system features and polish

#### 5.1 System Tray
- [ ] Tray icon with menu
- [ ] Quick start/stop recording
- [ ] Show/hide main window
- [ ] Open recordings folder

#### 5.2 Auto-Updates
- [ ] Integrate WinSparkle or custom updater
- [ ] Appcast feed configuration
- [ ] Background update checks
- [ ] Update installation flow

#### 5.3 Launch at Login
- [ ] Windows registry integration OR
- [ ] Task Scheduler registration
- [ ] User preference toggle

#### 5.4 Deep Links
- [ ] Register `dayflow://` protocol handler
- [ ] Handle start-recording and stop-recording commands
- [ ] Integration with Windows shortcuts

### Phase 6: Testing & Deployment
**Goal**: Package and distribute Windows version

#### 6.1 Testing
- [ ] Unit tests for core services
- [ ] Integration tests for recording pipeline
- [ ] UI automation tests
- [ ] Multi-monitor testing
- [ ] High DPI testing

#### 6.2 Installer
- [ ] MSIX packaging OR
- [ ] WiX installer setup
- [ ] Code signing certificate
- [ ] Installation wizard
- [ ] Uninstaller

#### 6.3 Distribution
- [ ] GitHub releases
- [ ] Microsoft Store submission (optional)
- [ ] Auto-update feed hosting
- [ ] Documentation updates

---

## Technical Mapping: macOS → Windows

### Critical Dependencies

| macOS Component | Windows Replacement | Status | Priority |
|----------------|---------------------|---------|----------|
| **ScreenCaptureKit** | Windows.Graphics.Capture API | 🔴 Not Started | P0 - CRITICAL |
| **SwiftUI** | WinUI 3 / XAML | 🔴 Not Started | P0 - CRITICAL |
| **Keychain** | Windows Credential Manager | 🔴 Not Started | P1 - HIGH |
| **Sparkle** | WinSparkle | 🔴 Not Started | P2 - MEDIUM |
| **AVFoundation** | Media Foundation / FFmpeg | 🔴 Not Started | P1 - HIGH |
| **NSStatusBar** | System Tray (Win32 API) | 🔴 Not Started | P2 - MEDIUM |
| **ServiceManagement** | Registry / Task Scheduler | 🔴 Not Started | P3 - LOW |
| **GRDB** | EntityFramework Core / SQLite | 🔴 Not Started | P1 - HIGH |
| **UserDefaults** | ApplicationData | 🔴 Not Started | P2 - MEDIUM |
| **NSWorkspace** | WinRT APIs | 🔴 Not Started | P3 - LOW |

### Portable Components (Minimal Changes)

| Component | Notes |
|-----------|-------|
| **Gemini API Client** | HTTP-based, easy to port |
| **Ollama Provider** | HTTP-based, easy to port |
| **Database Schema** | SQLite is cross-platform |
| **Analytics (PostHog)** | Cross-platform SDK available |
| **Crash Reporting (Sentry)** | Cross-platform SDK available |

---

## File Structure Plan (Windows)

```
Dayflow.Windows/
├── Dayflow.sln
├── Dayflow/
│   ├── Dayflow.csproj
│   ├── App.xaml
│   ├── App.xaml.cs
│   ├── MainWindow.xaml
│   ├── MainWindow.xaml.cs
│   ├── Core/
│   │   ├── Recording/
│   │   │   ├── ScreenRecorder.cs
│   │   │   ├── VideoEncoder.cs
│   │   │   ├── ChunkManager.cs
│   │   │   └── StorageManager.cs
│   │   ├── AI/
│   │   │   ├── ILLMProvider.cs
│   │   │   ├── GeminiProvider.cs
│   │   │   ├── OllamaProvider.cs
│   │   │   └── LLMService.cs
│   │   ├── Analysis/
│   │   │   ├── AnalysisManager.cs
│   │   │   ├── BatchProcessor.cs
│   │   │   └── TimelineCardGenerator.cs
│   │   ├── Storage/
│   │   │   ├── Database.cs
│   │   │   ├── Models/
│   │   │   │   ├── Chunk.cs
│   │   │   │   ├── Batch.cs
│   │   │   │   └── TimelineCard.cs
│   │   │   └── Repositories/
│   │   └── Security/
│   │       └── CredentialManager.cs
│   ├── Services/
│   │   ├── UpdateService.cs
│   │   ├── AnalyticsService.cs
│   │   ├── ConfigurationService.cs
│   │   └── SystemTrayService.cs
│   ├── Views/
│   │   ├── MainPage.xaml
│   │   ├── OnboardingPages/
│   │   ├── SettingsPage.xaml
│   │   ├── TimelinePage.xaml
│   │   ├── JournalPage.xaml
│   │   └── DashboardPage.xaml
│   ├── ViewModels/
│   │   ├── MainViewModel.cs
│   │   ├── TimelineViewModel.cs
│   │   └── SettingsViewModel.cs
│   └── Assets/
│       ├── Images/
│       └── Fonts/
├── Dayflow.Tests/
│   └── UnitTests/
└── README_WINDOWS.md
```

---

## Known Challenges & Risks

### 🔴 Critical Blockers

1. **Screen Recording API Differences**
   - macOS ScreenCaptureKit is very mature and feature-rich
   - Windows.Graphics.Capture API has limitations:
     - Requires user permission per session (no persistent permission)
     - May have performance differences
     - Multi-monitor handling may differ
   - **Mitigation**: Research alternatives (DXGI Desktop Duplication, DirectShow filters)

2. **Video Encoding Pipeline**
   - macOS uses AVFoundation (very mature)
   - Windows Media Foundation learning curve
   - **Mitigation**: Consider FFmpeg as portable alternative

### 🟡 Medium Risks

3. **UI/UX Parity**
   - SwiftUI and WinUI 3 have different design paradigms
   - Custom components need complete rewrite
   - **Mitigation**: Focus on functional parity first, polish later

4. **System Integration**
   - macOS has unified APIs; Windows requires mix of Win32/WinRT
   - **Mitigation**: Abstract platform-specific code behind interfaces

### 🟢 Low Risks

5. **Database Migration**
   - SQLite is portable
   - **Mitigation**: Use existing schema, straightforward port

---

## Timeline Estimate

| Phase | Estimated Duration | Status |
|-------|-------------------|---------|
| Phase 1: Foundation | 1-2 weeks | 🔴 Not Started |
| Phase 2: Screen Recording | 2-3 weeks | 🔴 Not Started |
| Phase 3: AI Analysis | 1-2 weeks | 🔴 Not Started |
| Phase 4: User Interface | 3-4 weeks | 🔴 Not Started |
| Phase 5: System Integration | 1-2 weeks | 🔴 Not Started |
| Phase 6: Testing & Deployment | 1-2 weeks | 🔴 Not Started |
| **TOTAL** | **9-15 weeks** | **Planning** |

**Note**: This is a conservative estimate assuming 1 developer working full-time.

---

## Next Steps

1. **Immediate** (This Session):
   - ✅ Create this tracking document
   - [ ] Commit planning documentation
   - [ ] Create detailed screen recording API research doc
   - [ ] Set up initial Windows project structure

2. **Short-term** (Next Session):
   - [ ] Implement basic WinUI 3 application shell
   - [ ] Port database models and storage layer
   - [ ] Create credential manager wrapper
   - [ ] Proof-of-concept screen capture

3. **Medium-term**:
   - [ ] Complete screen recording pipeline
   - [ ] Port LLM integration
   - [ ] Build basic timeline UI

---

## Resources & References

### Windows APIs Documentation
- [Windows.Graphics.Capture API](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture)
- [Media Foundation](https://learn.microsoft.com/en-us/windows/win32/medfound/microsoft-media-foundation-sdk)
- [Windows Credential Manager](https://learn.microsoft.com/en-us/windows/win32/secauthn/credential-manager)
- [WinUI 3 Documentation](https://learn.microsoft.com/en-us/windows/apps/winui/winui3/)

### Third-party Libraries
- [WinSparkle](https://winsparkle.org/) - Auto-update framework
- [Sentry .NET SDK](https://docs.sentry.io/platforms/dotnet/)
- [PostHog .NET SDK](https://posthog.com/docs/libraries/dotnet)

### Original macOS Codebase
- Main entry point: `/home/user/Dayflow/Dayflow/Dayflow/App/DayflowApp.swift`
- Screen recorder: `/home/user/Dayflow/Dayflow/Dayflow/Core/Recording/ScreenRecorder.swift`
- Storage manager: `/home/user/Dayflow/Dayflow/Dayflow/Core/Recording/StorageManager.swift`

---

## Change Log

### 2025-11-17 - Initial Planning
- Created tracking document
- Completed comprehensive macOS dependency analysis
- Identified 35-40 files requiring Windows-specific rewrites
- Mapped all critical framework replacements
- Established 6-phase port strategy
- Estimated 9-15 week timeline for complete port

---

## Questions & Decisions Needed

1. **Screen Recording API Choice**
   - Should we use Windows.Graphics.Capture exclusively?
   - Or implement fallback to DXGI Desktop Duplication?
   - **Decision needed before Phase 2**

2. **Video Encoding**
   - Media Foundation (native) vs FFmpeg (portable)?
   - **Decision needed before Phase 2**

3. **UI Framework**
   - WinUI 3 (modern, limited docs) vs WPF (mature, more resources)?
   - **Decision needed before Phase 4**

4. **Distribution**
   - Microsoft Store submission?
   - MSIX vs traditional installer?
   - **Decision needed before Phase 6**

---

**Last Updated**: 2025-11-17
**Next Review**: After Phase 1 completion
