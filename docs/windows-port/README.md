# Windows Port Documentation

This directory contains comprehensive planning documentation for porting Dayflow from macOS to Windows.

## Overview

Dayflow is currently a macOS-native application built with Swift, SwiftUI, and ScreenCaptureKit. This port aims to bring the same functionality to Windows using C# and WinUI 3.

## Documentation Index

### 📋 [Main Tracking Document](../../WINDOWS_PORT.md)
The central tracking document for the entire Windows port project. Contains:
- Current status and progress
- Phase-by-phase implementation plan
- Timeline estimates
- Decision tracking
- Change log

### 🎥 [Screen Recording Strategy](SCREEN_RECORDING_STRATEGY.md)
Detailed migration plan for the core screen capture functionality.
- **macOS**: ScreenCaptureKit
- **Windows**: Windows.Graphics.Capture API + DXGI fallback
- **Priority**: P0 - CRITICAL PATH

Topics covered:
- API comparison and evaluation
- Video encoding options (Media Foundation vs FFmpeg)
- Multi-monitor support
- Error handling and retry logic
- Performance optimization
- Implementation roadmap

### 🎨 [UI Migration Strategy](UI_MIGRATION_STRATEGY.md)
Complete UI framework migration from SwiftUI to WinUI 3.
- **macOS**: SwiftUI
- **Windows**: WinUI 3 with XAML
- **Priority**: P0 - CRITICAL

Topics covered:
- Component-by-component mapping
- MVVM architecture with CommunityToolkit
- Navigation patterns
- Data binding
- Custom controls
- Theming and animations
- Recommended libraries

### 💾 [Storage & Security Strategy](STORAGE_SECURITY_STRATEGY.md)
Data persistence and credential management migration.
- **Database**: GRDB (Swift) → Microsoft.Data.Sqlite (C#)
- **Keychain**: macOS Keychain → Windows Credential Manager
- **Preferences**: UserDefaults → ApplicationDataContainer
- **Priority**: P1 - HIGH

Topics covered:
- File storage locations and structure
- SQLite database migration
- Configuration management
- Secure credential storage
- Storage cleanup automation
- Performance optimization

## Quick Start

If you're contributing to the Windows port, start here:

1. **Read the main tracking document**: [`claude.md`](../../claude.md)
2. **Understand your component**: Read the relevant strategy document
3. **Check current status**: Review the phase plan in the tracking doc
4. **Pick a task**: Choose an uncompleted checklist item
5. **Update progress**: Mark tasks complete and update `claude.md`

## Project Structure (Planned)

```
Dayflow.Windows/
├── Dayflow.sln
├── Dayflow/                    # Main application
│   ├── Core/                   # Business logic
│   │   ├── Recording/          # Screen capture
│   │   ├── AI/                 # LLM integration
│   │   ├── Analysis/           # Timeline generation
│   │   ├── Storage/            # Database & file management
│   │   └── Security/           # Credential management
│   ├── Services/               # System services
│   ├── Views/                  # XAML UI
│   ├── ViewModels/             # MVVM view models
│   └── Assets/                 # Images, fonts, etc.
└── Dayflow.Tests/              # Unit tests
```

## Key Technologies

| Component | macOS | Windows |
|-----------|-------|---------|
| **UI Framework** | SwiftUI | WinUI 3 |
| **Language** | Swift | C# (.NET 8) |
| **Screen Capture** | ScreenCaptureKit | Windows.Graphics.Capture |
| **Video Encoding** | AVFoundation | Media Foundation / FFmpeg |
| **Database** | GRDB (SQLite) | Microsoft.Data.Sqlite |
| **Secure Storage** | Keychain | Credential Manager |
| **Auto-Updates** | Sparkle | WinSparkle |
| **System Tray** | NSStatusBar | H.NotifyIcon |

## Development Phases

1. **Phase 1: Foundation** (1-2 weeks)
   - Project setup
   - Storage layer
   - Security & configuration

2. **Phase 2: Screen Recording** (2-3 weeks) ⚠️ CRITICAL
   - Windows.Graphics.Capture integration
   - Video encoding pipeline
   - Error handling & permissions

3. **Phase 3: AI Analysis** (1-2 weeks)
   - LLM service ports (HTTP-based, straightforward)
   - Timeline generation
   - Batch processing

4. **Phase 4: User Interface** (3-4 weeks)
   - Main window & navigation
   - Timeline view
   - Onboarding flow
   - Settings panel

5. **Phase 5: System Integration** (1-2 weeks)
   - System tray
   - Auto-updates
   - Launch at login

6. **Phase 6: Testing & Deployment** (1-2 weeks)
   - Testing
   - Installer creation
   - Distribution setup

**Total Estimate**: 9-15 weeks (1 developer, full-time)

## Critical Blockers

### 🔴 Screen Recording API
**Issue**: Windows.Graphics.Capture requires user permission per session (no persistent permission like macOS)

**Mitigation**:
- Research AppCapability for persistent capture
- Implement DXGI Desktop Duplication as fallback
- Clear user communication about limitations

### 🟡 UI/UX Parity
**Issue**: SwiftUI and WinUI 3 have different paradigms

**Mitigation**:
- Focus on functional parity first
- Adapt to Windows conventions where appropriate
- Polish UI after core features work

## Contributing

When working on this port:

1. **Update progress regularly** in `claude.md`
2. **Document decisions** in the relevant strategy doc
3. **Test thoroughly** on different Windows versions
4. **Follow C# coding conventions** (Microsoft style guide)
5. **Write tests** for critical functionality

## Questions & Support

- **Technical decisions**: Document in the relevant strategy doc
- **Blockers**: Add to the "Questions & Decisions Needed" section in `claude.md`
- **Progress updates**: Commit regularly with clear messages

## References

### Official Documentation
- [Windows.Graphics.Capture API](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture)
- [WinUI 3 Documentation](https://learn.microsoft.com/en-us/windows/apps/winui/winui3/)
- [Media Foundation SDK](https://learn.microsoft.com/en-us/windows/win32/medfound/microsoft-media-foundation-sdk)
- [Windows Credential Manager](https://learn.microsoft.com/en-us/windows/win32/secauthn/credential-manager)

### Sample Code
- [WinUI 3 Gallery](https://github.com/microsoft/WinUI-Gallery) - Official samples
- [Simple Screen Recorder](https://github.com/microsoft/Windows-universal-samples/tree/main/Samples/SimpleScreenRecorder)

### Libraries
- [CommunityToolkit.Mvvm](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/mvvm/)
- [H.NotifyIcon.WinUI](https://github.com/HavenDV/H.NotifyIcon)
- [WinSparkle](https://winsparkle.org/)

---

**Created**: 2025-11-17
**Status**: Planning Phase Complete
**Next Steps**: Begin Phase 1 - Foundation & Core Infrastructure
