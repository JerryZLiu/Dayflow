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
- app_heartbeat
  - props: `session_hours: number`, `cpu_current_pct_bucket?: 0-5%|5-20%|20-50%|50-100%|100-150%|150-200%|>200%`, `cpu_avg_pct_bucket?: 0-5%|5-20%|20-50%|50-100%|100-150%|150-200%|>200%`, `cpu_peak_pct_bucket?: 0-5%|5-20%|20-50%|50-100%|100-150%|150-200%|>200%`, `cpu_sample_count?: int`, `cpu_sampler_interval_s?: int`
  - file: App/AppDelegate.swift
- app_cpu_spike
  - props: `cpu_current_pct_bucket: 0-5%|5-20%|20-50%|50-100%|100-150%|150-200%|>200%`, `cpu_hour_peak_pct_bucket: 0-5%|5-20%|20-50%|50-100%|100-150%|150-200%|>200%`, `cpu_threshold_pct: number`, `cpu_sampler_interval_s: int`
  - file: System/ProcessCPUMonitor.swift
- app_terminated
  - file: App/AppDelegate.swift
- screen_viewed
  - props: `screen: string`
  - files: Views/* (various)

## Onboarding
- onboarding_started
  - file: Views/Onboarding/OnboardingFlow.swift (intro video appear)
- onboarding_step_completed
  - props: `step: intro_video|role_selection|referral|preferences|llm_selection|llm_setup|categories|category_colors|screen_recording|completion`
  - file: Views/Onboarding/OnboardingFlow.swift
- llm_provider_selected
  - props: `provider: chatgpt_claude|gemini|ollama`, `local_engine?: ollama|lmstudio|custom`
  - file: Views/Onboarding/OnboardingFlow.swift
- screen_permission_granted / screen_permission_denied
  - file: Views/Onboarding/ScreenRecordingPermissionView.swift
- connection_test_started / connection_test_succeeded / connection_test_failed
  - props: `provider: gemini`, `error_code?: enum|string`
  - files: Views/Onboarding/TestConnectionView.swift
- chat_cli_test_started / chat_cli_test_succeeded / chat_cli_test_failed
  - props: `provider: chatgpt_claude`, `tool: codex|claude`, `setup_step: test`, `duration_ms?: int`, `exit_code?: int`, `failure_reason?: auth_error|nonzero_exit_no_stderr|nonzero_exit_with_stderr|empty_response|unexpected_output|cli_not_found|execution_error`, `error_code?: int`, `error_domain?: string`
  - file: Views/Onboarding/LLMProviderSetupView.swift
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

## Dashboard Chat
- chat_question_asked
  - props: `question: string`, `conversation_id: uuid`, `is_new_conversation: bool`, `message_index: int`, `provider: gemini|codex|claude`, `chat_runtime: gemini_function_calling|chat_cli`
  - file: Views/UI/ChatView.swift
- chat_answer_copied
  - props: `conversation_id: uuid`, `message_id: uuid`, `message_index: int`, `provider: gemini|codex|claude`, `chat_runtime: gemini_function_calling|chat_cli`, `assistant_message_length: int`, `assistant_has_chart: bool`, `assistant_message_preview: string`
  - file: Views/UI/ChatView.swift
- chat_answer_rated
  - props: `conversation_id: uuid`, `message_id: uuid`, `message_index: int`, `provider: gemini|codex|claude`, `chat_runtime: gemini_function_calling|chat_cli`, `thumb_direction: up|down`, `assistant_message_length: int`, `assistant_has_chart: bool`, `assistant_message_preview: string`, `share_logs_default: bool`
  - file: Views/UI/ChatView.swift
- chat_answer_feedback_submitted
  - props: `provider: gemini|codex|claude`, `chat_runtime: gemini_function_calling|chat_cli`, `thumb_direction: up|down`, `share_logs_default: bool`, `share_logs_enabled: bool`, `feedback_message_length: int`, `feedback_message?: string`; when `share_logs_enabled=true`, also include `conversation_id: uuid`, `message_id: uuid`, `message_index: int`, `assistant_message_length: int`, `assistant_has_chart: bool`, `assistant_message_preview: string`
  - file: Views/UI/ChatView.swift

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
  - props: `enabled: bool`, `reason: auto|unknown|onboarding|deeplink|menu_bar|main_app|user_menu_bar|user_main_app|timer_expired|wake_from_sleep`
  - file: App/AppDelegate.swift (observation) and AppDelegate auto-start
- recording_paused
  - props: `source: menu_bar|main_app|deeplink`, `pause_type: 15_mins|30_mins|1_hour|indefinite`
  - file: App/PauseManager.swift
- recording_resumed
  - props: `source: user_menu_bar|user_main_app|timer_expired|wake_from_sleep`, `was_timed: bool`, `original_pause_type: 15_mins|30_mins|1_hour|indefinite|unknown`
  - file: App/PauseManager.swift
- timeline_paused_card_clicked
  - props: `action: resume_recording`
  - file: Views/UI/CanvasTimelineDataView.swift
- timeline_stopped_card_clicked
  - props: `action: start_recording`
  - file: Views/UI/CanvasTimelineDataView.swift
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
  - props: `provider: gemini|ollama|dayflow|chat_cli|unknown`
  - file: App/AppDelegate.swift
- llm_api_call (sampled ~10%)
  - props: `provider: string`, `model: string`, `latency_ms_bucket: <500ms|0.5-1.5s|>=1.5s`, `outcome: success|error`, `error_code?: int`
  - file: Core/AI/LLMLogger.swift

<!-- Storage-related events intentionally removed -->
