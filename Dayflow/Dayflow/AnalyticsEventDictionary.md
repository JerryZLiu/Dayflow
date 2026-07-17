# Dayflow Analytics Event Dictionary (PostHog)

This document lists manual events, properties, and code locations. All events respect opt-in and are PII-free. Durations and sizes are bucketed.

## Conventions
- Event names: snake_case
- Screens: `screen_viewed` with `screen`
- Common super properties (registered on boot): `app_version`, `build_number`, `os_version`, `device_model`, `locale`, `time_zone`
- Person properties (identify): `analytics_opt_in`, `onboarding_status`, `current_llm_provider` (provider family), `current_llm_provider_id` (`dayflow|gemini|chatgpt|claude|openai_compatible|local`), `recording_enabled`, `install_ts` (set once)

## Lifecycle
- app_opened
  - props: `cold_start: bool`
  - file: App/AppDelegate.swift
- app_updated
  - props: `from_version: string`, `to_version: string`
  - file: App/AppDelegate.swift
- app_heartbeat
  - props: `session_hours: number`, `cpu_current_pct_bucket?: 0-5%|5-20%|20-50%|50-100%|100-150%|150-200%|>200%`, `cpu_avg_pct_bucket?: 0-5%|5-20%|20-50%|50-100%|100-150%|150-200%|>200%`, `cpu_peak_pct_bucket?: 0-5%|5-20%|20-50%|50-100%|100-150%|150-200%|>200%`, `cpu_sample_count?: int`, `cpu_sampler_interval_s?: int`, `current_tab?: timeline|daily|weekly|dashboard|journal|bug_report|settings`, `timeline_mode?: day|week`
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
  - props: `step: intro_video|role_selection|download_reason|referral|preferences|llm_selection|llm_setup|categories|category_colors|screen_recording|completion`
  - file: Views/Onboarding/OnboardingFlow.swift
- onboarding_download_reason
  - props: `reasons: string[] (automatic_log|proof_of_work|cut_distractions|productive_focused|automated_manual_tracking|open_source_private|other)`, `surface: onboarding_download_reason`, `other_detail?: string`
  - file: Views/Onboarding/OnboardingFlow.swift
- onboarding_referral
  - props: `source: hacker_news|x|friend|youtube|newsletter_blog|chatgpt_claude_ai|other`, `surface: onboarding_referral`, `detail?: string`
  - file: Views/Onboarding/OnboardingFlow.swift
- llm_provider_selected
  - props: `provider: dayflow|gemini|chat_cli|openai_compatible|ollama`, `provider_id: dayflow|gemini|chatgpt|claude|openai_compatible|local`, `local_engine?: ollama|lmstudio|custom`
  - file: Views/Onboarding/OnboardingFlow.swift
- dayflow_pro_selected
  - props: `surface: onboarding_dayflow_pro`, `flow_id: string`, `flow_variant: string`, `has_paid_ai: bool`, `selection_stage: started_sign_in|continued`
  - file: Views/Onboarding/Prototype/OnboardingPrototypeFlow.swift
- dayflow_pro_onboarding_step_viewed
  - props: `surface: onboarding_dayflow_pro`, `flow_id: string`, `flow_variant: string`, `has_paid_ai: bool`, `dayflow_pro_step: email|code|referral_code|free_month_active|trial_offer|trial_active`
  - file: Views/Onboarding/Prototype/OnboardingPrototypeFlow.swift
- dayflow_pro_auth_code_requested / dayflow_pro_auth_code_verified / dayflow_pro_referral_code_submitted / dayflow_pro_trial_started
  - props: `surface: onboarding_dayflow_pro`, `flow_id: string`, `flow_variant: string`, `has_paid_ai: bool`, `dayflow_pro_step: string`, `action: auth_code_request|auth_code_verify|referral_code_submit|trial_start`, `outcome: success|failure`, `endpoint?: string`, `http_status?: int`, `error_type?: invalid_email|invalid_code|missing_email|invalid_referral_code|not_signed_in|endpoint_not_found|bad_request|unauthorized|conflict|server_error|http_error|timeout|network_error|non_http_response|request_in_progress|client_error|unknown_error`, `backend_detail_bucket?: not_found|referral_code_not_found|own_referral_code|referral_already_used|trial_already_used|other_backend_error`
  - file: Views/Onboarding/Prototype/OnboardingPrototypeFlow.swift, System/DayflowAuthManager.swift
- screen_permission_granted / screen_permission_denied
  - file: Views/Onboarding/ScreenRecordingPermissionView.swift
- connection_test_started / connection_test_succeeded / connection_test_failed
  - props: `provider: gemini`, `error_code?: enum|string`
  - files: Views/Onboarding/TestConnectionView.swift
- chat_cli_test_started / chat_cli_test_succeeded / chat_cli_test_failed
  - props: `provider: chat_cli`, `provider_id: chatgpt|claude`, `tool: codex|claude`, `setup_step: test`, `duration_ms?: int`, `exit_code?: int`, `failure_reason?: auth_error|nonzero_exit_no_stderr|nonzero_exit_with_stderr|empty_response|unexpected_output|cli_not_found|execution_error`, `error_code?: int`, `error_domain?: string`
  - file: Views/Onboarding/ChatCLITestView.swift
- chat_cli_detection_checked / chat_cli_tool_selected
  - props: `provider_id: chatgpt|claude`, `source: initial|manual_recheck|detection_step`, `setup_step: detect`, `selected_tool: codex|claude|none`, CLI availability/status fields
  - file: Views/Onboarding/ProviderSetupState.swift
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
  - props: `provider: dayflow|gemini|chat_cli|openai_compatible|ollama`, `provider_id: dayflow|gemini|chatgpt|claude|openai_compatible|local`, provider-specific non-secret configuration metadata
  - file: Views/UI/Settings/ProvidersSettingsViewModel.swift
- provider_primary_updated / provider_secondary_updated / provider_backup_updated
  - props: exact provider IDs in `provider_id` and role-specific fields (`provider_id: none` when clearing backup); `swapped_with_secondary?: bool`, `mode?: set|swap_with_primary`
  - file: Views/UI/Settings/ProvidersSettingsViewModel.swift
- llm_provider_routing_save_failed
  - props: `provider_id: dayflow|gemini|chatgpt|claude|openai_compatible|local`, `surface: onboarding`
  - file: Views/Onboarding/OnboardingFlow.swift

## Navigation & Timeline
- tab_selected
  - props: `tab: timeline|daily|weekly|dashboard|journal|bug_report|settings`
  - file: Views/UI/MainView.swift
- timeline_viewed
  - props: `date_bucket: yyyy-MM-dd`
  - file: Views/UI/MainView.swift
- timeline_mode_changed
  - props: `from_mode: day|week`, `to_mode: day|week`, `selected_day: yyyy-MM-dd`
  - file: Views/UI/MainView/Support.swift
- date_navigation
  - props: `method: prev|next|picker`, `timeline_mode: day|week`, `from_day: yyyy-MM-dd`, `to_day: yyyy-MM-dd`
  - file: Views/UI/MainView.swift
- activity_card_opened
  - props: `activity_type: string`, `duration_bucket: string`, `has_video: bool`
  - file: Views/UI/MainView.swift
- timeline_copied
  - props: `timeline_mode: day|week`, `timeline_day?: yyyy-MM-dd`, `week_start?: yyyy-MM-dd`, `week_end?: yyyy-MM-dd`, `activity_count: int`
  - file: Views/UI/MainView.swift
- timeline_exported
  - props: `start_day: yyyy-MM-dd`, `end_day: yyyy-MM-dd`, `day_count: int`, `activity_count: int`, `skipped_activity_count: int`, `format: markdown|ics`, `file_extension: string`
  - file: Views/UI/Settings/OtherSettingsViewModel.swift
- dayflow_backup_exported
  - props: `size_bytes: int`, `includes_recordings: bool`, `includes_timelapses: bool`, `includes_preferences: bool`
  - file: Views/UI/Settings/OtherSettingsViewModel.swift
- dayflow_backup_import_queued
  - props: `size_bytes: int`, `includes_recordings: bool`, `includes_timelapses: bool`, `includes_preferences: bool`
  - file: Views/UI/Settings/OtherSettingsViewModel.swift

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
  - props: compatibility family in `provider: gemini|ollama|dayflow|chat_cli|openai_compatible|unknown`, exact provider in `provider_id`
  - file: App/AppDelegate.swift
- analysis_batch_started / analysis_batch_completed / analysis_batch_failed
  - props: compatibility provider family in `llm_provider`, exact primary provider in `provider_id`, exact effective provider in `effective_provider_id` on completion, and exact configured backup in `backup_provider_id` on failure
  - privacy: failures include a classified failure kind, never a raw error message
  - file: Core/AI/LLMService.swift
- llm_timeline_fallback_attempted / llm_timeline_fallback_succeeded / llm_timeline_fallback_failed
  - props: compatibility provider families plus exact `primary_provider_id` and `backup_provider_id`; safe error domain/code metadata only
  - file: Core/AI/LLMService.swift
- llm_decode_failed / llm_validation_failed
  - props: compatibility family in `provider`, exact provider in `provider_id`, operation/validation type, attempt, and output/detail presence or length metadata
  - privacy: raw model output, stderr, validation text, and generated card content are never sent to analytics
  - files: Core/AI/ChatCLIProvider+Parsing.swift, Core/AI/ChatCLIProvider+Transcription.swift, System/AnalyticsService.swift
- llm_api_call (sampled ~10%)
  - props: `provider: string`, `provider_id?: dayflow|gemini|chatgpt|claude|openai_compatible|local`, `model: string`, `operation: string`, `latency_ms: int`, `outcome: success|error`, `error_domain?: string`, `error_code?: int`, `http_status?: int`, `has_response_body?: bool`, `response_body_bytes?: int`
  - privacy: request bodies, response bodies, and raw error messages stay local and are never sent to analytics
  - file: Core/AI/LLMLogger.swift

<!-- Storage-related events intentionally removed -->
