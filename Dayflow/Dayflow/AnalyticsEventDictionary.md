# Dayflow Analytics Event Dictionary (PostHog)

This document lists manual events, properties, and code locations. All events respect opt-in and are PII-free. Durations and sizes are bucketed.

## Conventions
- Event names: snake_case
- Screens: `screen_viewed` with `screen`
- Common super properties (registered on boot): `app_version`, `build_number`, `os_version`, `device_model`, `locale`, `time_zone`
- Person properties (identify): `analytics_opt_in`, `onboarding_status`, `current_llm_provider`, `recording_enabled`, `install_ts` (set once)

## Lifecycle
- app_opened
  - props: `cold_start: bool`
  - file: App/AppDelegate.swift
- app_updated
  - props: `from_version: string`, `to_version: string`
  - file: App/AppDelegate.swift
- app_terminated
  - file: App/AppDelegate.swift
- screen_viewed
  - props: `screen: string`
  - files: Views/* (various)

## Onboarding
- onboarding_started
  - file: Views/Onboarding/OnboardingFlow.swift (welcome appear)
- onboarding_step_completed
  - props: `step: welcome|how_it_works|llm_selection|llm_setup|categories|screen_recording|completion`
  - file: Views/Onboarding/OnboardingFlow.swift
- llm_provider_selected
  - props: `provider: gemini|ollama|dayflow`
  - file: Views/Onboarding/OnboardingFlow.swift
- screen_permission_granted / screen_permission_denied
  - file: Views/Onboarding/ScreenRecordingPermissionView.swift
- connection_test_started / connection_test_succeeded / connection_test_failed
  - props: `provider: gemini`, `error_code?: enum|string`
  - files: Views/Onboarding/TestConnectionView.swift
- onboarding_completed
  - file: Views/Onboarding/OnboardingFlow.swift
- onboarding_abandoned
  - props: `last_step: string`
  - file: App/AppDelegate.swift (willTerminate)
- terminal_command_copied
  - props: `title: string`
  - file: Views/Onboarding/TerminalCommandView.swift

## Settings & Privacy
- settings_opened
  - file: Views/UI/SettingsView.swift
- analytics_opt_in_changed
  - props: `enabled: bool`
  - file: Views/UI/SettingsView.swift
- provider_switch_initiated
  - props: `from: string`, `to: string`
  - file: Views/UI/SettingsView.swift
- provider_setup_completed
  - props: `provider: gemini|ollama|dayflow`
  - file: Views/UI/SettingsView.swift

## Navigation & Timeline
- tab_selected
  - props: `tab: timeline|dashboard|journal|settings`
  - file: Views/UI/MainView.swift
- timeline_viewed
  - props: `date_bucket: yyyy-MM-dd`
  - file: Views/UI/MainView.swift
- date_navigation
  - props: `method: prev|next|picker`, `from_day: yyyy-MM-dd`, `to_day: yyyy-MM-dd`
  - file: Views/UI/MainView.swift
- activity_card_opened
  - props: `activity_type: string`, `duration_bucket: string`, `has_video: bool`
  - file: Views/UI/MainView.swift
- timeline_copied
  - props: `timeline_day: yyyy-MM-dd`, `activity_count: int`
  - file: Views/UI/MainView.swift

## Video
- video_modal_opened
  - props: `source: activity_card|unknown`, `duration_bucket: string`
  - file: Views/UI/VideoPlayerModal.swift
- video_play_started
  - props: `speed: string`
  - file: Views/UI/VideoPlayerModal.swift
- video_paused, video_resumed
  - file: Views/UI/VideoPlayerModal.swift
- seek_performed (throttled)
  - props: `from_s_bucket: string`, `to_s_bucket: string`
  - file: Views/UI/VideoPlayerModal.swift
- video_completed
  - props: `watch_time_bucket: string`, `completion_pct_bucket: string`
  - file: Views/UI/VideoPlayerModal.swift (onDisappear)

## Recording
- recording_toggled
  - props: `enabled: bool`, `reason: user|auto`
  - file: App/AppDelegate.swift (observation) and AppDelegate auto-start
- recording_started
  - file: Core/Recording/ScreenRecorder.swift (startStream)
- recording_stopped
  - props: `stop_reason: user|system_sleep|lock|screensaver`
  - file: Core/Recording/ScreenRecorder.swift
- recording_error
  - props: `code: int`, `retryable: bool`
  - file: Core/Recording/ScreenRecorder.swift
- recording_auto_recovery
  - props: `outcome: restarted|gave_up`
  - file: Core/Recording/ScreenRecorder.swift
- chunk_created (sampled ~1%)
  - props: `duration_bucket: string`, `resolution_bucket: string`
  - file: Core/Recording/ScreenRecorder.swift

## AI / LLM / Analysis
- analysis_job_started
  - props: `provider: gemini|ollama|dayflow|unknown`
  - file: App/AppDelegate.swift
- llm_api_call (sampled ~10%)
  - props: `provider: string`, `model: string`, `latency_ms_bucket: <500ms|0.5-1.5s|>=1.5s`, `outcome: success|error`, `error_code?: int`
  - file: Core/AI/LLMLogger.swift

<!-- Storage-related events intentionally removed -->
