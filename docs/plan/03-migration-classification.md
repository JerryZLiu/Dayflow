# 5. 迁移分类

## 5.1 操作定义

| 操作 | 含义 |
|--------|---------|
| **KEEP** | 在发布产品中继续保留为 Swift，基本不变。 |
| **REWRITE** | 使用 Go 或 Vue/TS 重新实现。保留行为，不保留代码。 |
| **BRIDGE** | 继续保留为 Swift，移入 `dayflow-helper`，并通过平台端口向 Go 暴露。 |
| **REPLACE** | 改用不同机制（库、平台功能或 Web 等价方案）。 |
| **DELETE** | 移除。属于死代码，或已被其他方案涵盖。 |
| **DEFER** | 明确不纳入 v1 范围。在 Go 应用发布后重新评估。 |

## 5.2 摘要

| 操作 | 文件数 | 约计 LOC | 占比 |
|--------|------:|------------:|------:|
| REWRITE (→ Vue) | ~215 | 62,000 | 56% |
| REWRITE (→ Go) | ~95 | 31,000 | 28% |
| DEFER | ~28 | 12,000 | 11% |
| BRIDGE | ~14 | 3,200 | 3% |
| REPLACE | ~8 | 1,400 | 1% |
| KEEP | 3 | 400 | <1% |
| DELETE | ~5 | 500 | <1% |

---

## 5.3 应用层

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `App/DayflowApp.swift` | SwiftUI 场景、窗口配置、菜单命令 | `cmd/dayflow/main.go` + `wails.json` | REWRITE |
| `App/AppDelegate.swift` | 启动序列、拒绝退出、前台状态跟踪 | `internal/app/lifecycle.go` + 用于托盘/激活策略的 helper | REWRITE + BRIDGE |
| `App/AppState.swift` | 带持久化的 `isRecording` 标志 | `internal/app/state.go` | REWRITE |
| `App/PauseManager.swift` | 定时暂停录制 | `internal/app/pause.go` | REWRITE |
| `App/InactivityMonitor.swift` | 应用内空闲 → UI 重置提示 | Vue：浏览器 `visibilitychange` + 空闲计时器 | REPLACE |
| `App/AppDeepLinkRouter.swift` | `dayflow://` URL scheme | `internal/app/deeplink.go`，URL 由 helper 传递 | REWRITE + BRIDGE |
| `App/ScreenshotShortcutTracker.swift` | 全局 `cmd-shift-3/4/5` 分析启发式检测 | — | DELETE |
| `App/RecordingControl.swift` | 录制切换门面 | 合并到 `internal/app/state.go` | REWRITE |

有意将 `ScreenshotShortcutTracker` 归为 DELETE 而非 BRIDGE：它安装全局按键监视器，纯粹为了猜测用户何时截取了系统屏幕截图，以记录一个分析事件。在新架构中，全局事件 tap 带来的隐私与权限成本不值得用于一项指标。

---

## 5.4 捕获与媒体——原生核心

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/Recording/ScreenRecorder.swift` | 捕获循环、状态机、系统事件 | `native/darwin/Sources/DayflowHelper/Capture/ScreenRecorder.swift` | **BRIDGE** |
| `Core/Recording/FrameStore.swift` | HEVC 分段写入/读取 | `native/darwin/.../Capture/FrameStore.swift` | **BRIDGE** |
| `Core/Recording/VideoProcessingService.swift` | 用于延时视频和 Gemini 的 mp4 合成 | `native/darwin/.../Media/VideoEncoder.swift` | **BRIDGE** |
| `Core/Recording/ActiveDisplayTracker.swift` | 光标所在显示器，带防抖 | `native/darwin/.../Capture/DisplayTracker.swift` | **BRIDGE** |
| `Core/Recording/ScreenshotImageLoading.swift` | 帧像素的单一入口 | `internal/platform/media.go`（接口）+ helper 实现 | **BRIDGE** |
| `Core/Recording/RecordingPrivacyPreferences.swift` | 屏蔽应用列表 + `SCContentFilter` 构造 | 拆分：列表放在 Go，过滤器放在 helper | REWRITE + BRIDGE |
| `Core/Recording/RecordingPrivacyPlaceholder.swift` | 脱敏占位图像 | `native/darwin/.../Capture/Placeholder.swift` | **BRIDGE** |
| `Core/Recording/RecordingPreferences.swift` | 间隔和高度设置 | `internal/settings/capture.go` | REWRITE |
| `Core/Thumbnails/ThumbnailCache.swift` | `NSImage` 缩略图缓存 | Vue：`<img>` + 基于 Wails 资源处理器的 HTTP 缓存 | REPLACE |
| `Core/Thumbnails/ScreenshotThumbnailCache.swift` | 帧缩略图缓存 | `internal/media/cache.go`（字节） | REWRITE |

这十一个文件是 BRIDGE 决策的核心。`ScreenRecorder` + `FrameStore` + `VideoProcessingService` 共 1,570 LOC，几乎可以原样迁移。为何此处迁移优于重写，请参阅[文档 05](05-native-bridge.md)。

请注意 `RecordingPrivacyPreferences` 的拆分：*策略*（屏蔽哪些 bundle ID、默认密码管理器种子列表）属于数据，应放在 Go 中；*执行*（`SCContentFilter(display:excludingApplications:)` 和最前台应用检查）需要 ScreenCaptureKit，应放在 helper 中。

---

## 5.5 存储

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/Recording/StorageManaging.swift` | 仓储协议 | `internal/storage/repository.go`——拆分为 8 个聚焦接口 | REWRITE |
| `Core/Recording/StorageManager.swift` | 连接池、schema、检测 | `internal/storage/db.go` + `schema.go` + `observe.go` | REWRITE |
| `Core/Recording/StorageManager+TimelineCards.swift` | 卡片 CRUD、范围替换 | `internal/storage/timeline.go` | REWRITE |
| `Core/Recording/StorageManager+Screenshots.swift` | 帧记录、批次关联 | `internal/storage/screenshots.go` | REWRITE |
| `Core/Recording/StorageManager+Observations.swift` | 观察记录 | `internal/storage/observations.go` | REWRITE |
| `Core/Recording/StorageManager+Journal.swift` | 日志条目 | `internal/storage/journal.go` | REWRITE |
| `Core/Recording/StorageManager+DayGoals.swift` | 每日目标 + 类别分配 | `internal/storage/goals.go` | REWRITE |
| `Core/Recording/StorageManager+DailyStandup.swift` | 每日回顾 blob | `internal/storage/standup.go` | REWRITE |
| `Core/Recording/StorageManager+ChatHistory.swift` | 对话 + 消息 | `internal/storage/chat.go` | REWRITE |
| `Core/Recording/StorageManager+TimelineReview.swift` | 回顾评分 | `internal/storage/review.go` | REWRITE |
| `Core/Recording/StorageManager+Reprocessing.swift` | 重处理的重置/删除 | `internal/storage/reprocess.go` | REWRITE |
| `Core/Recording/StorageManager+Maintenance.swift` | 恢复、备份、清理、检查点 | `internal/storage/maintenance.go` | REWRITE |
| `Core/Recording/StorageManager+Migrations.swift` | 旧版路径重写 | `internal/storage/legacy.go` | REWRITE |
| `Core/Recording/StorageManager+Chunks.swift` | 旧版视频块 | — | **DELETE** |
| `Core/Recording/StorageModels.swift` | 行结构体 | `internal/storage/models.go` | REWRITE |
| `Core/Recording/StorageDateHelpers.swift` | 凌晨 4 点日界线 | `internal/timeutil/dayboundary.go` | REWRITE |
| `Core/Recording/StorageFileManagerExtensions.swift` | 目录大小 | `internal/storage/diskusage.go` | REWRITE |
| `Core/Recording/StoragePreferences.swift` | 大小限制 | `internal/settings/storage.go` | REWRITE |
| `Core/Recording/TimelapseStorageManager.swift` | 延时视频清理 | `internal/storage/timelapse.go` | REWRITE |
| `Core/Recording/TimelapsePreferences.swift` | 保存到磁盘开关 | `internal/settings/timelapse.go` | REWRITE |
| `Utilities/StoragePathMigrator.swift` | 沙盒 → 非沙盒迁移 | 保留一个版本，然后移除 | REWRITE |
| `Utilities/UserDefaultsMigrator.swift` | 沙盒默认值迁移 | 合并到设置导入 | REWRITE |

`chunks` 和 `batch_chunks` 在实际安装中均为零行，视频块捕获路径已被屏幕截图取代。为保持读取兼容性，**数据表保留**；删除的是*代码*。共存期间不要删除这些表。

---

## 5.6 分析

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/Analysis/AnalysisManager.swift` | 调度、批处理、重处理 | `internal/analysis/scheduler.go` + `batcher.go` + `reprocess.go` | REWRITE |
| `Core/Analysis/IdleBatchClassifier.swift` | 纯空闲检测 | `internal/analysis/idle.go` | REWRITE |
| `Core/Analysis/TimeParsing.swift` | `"9:30 AM"` → 分钟数 | `internal/timeutil/clock.go` | REWRITE |
| `Core/AI/TimelineFailureClassifier.swift` | 错误 → 面向用户的类别 | `internal/analysis/failure.go` | REWRITE |
| `Core/AI/TimelineOutputSupport.swift` | 共享卡片后处理 | `internal/analysis/cards.go` | REWRITE |

`internal/analysis/idle.go` 应是所有 Go 代码中**最先**编写的。它是一个具有已公布阈值且无依赖的纯函数，因此是搭建其他所有部分所需黄金夹具测试框架成本最低的方式。

---

## 5.7 AI 提供商

### HTTP 提供商——直接移植到 Go

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/AI/GeminiDirectProvider.swift` + 10 个扩展 | Gemini 上传、转录、卡片、聊天 | `internal/ai/gemini/` | REWRITE |
| `Core/AI/GemmaBackupProvider.swift` + 3 个扩展 | Gemini 基于帧的回退方案 | `internal/ai/gemini/gemma.go` | REWRITE |
| `Core/AI/OllamaProvider.swift` + 3 个扩展 | 本地 Ollama | `internal/ai/ollama/` | REWRITE |
| `Core/AI/OpenAICompatibleProvider.swift` | 通用 OpenAI 形态端点 | `internal/ai/openaicompat/` | REWRITE |
| `Core/AI/OpenAICompatibleConfiguration.swift` | 端点配置 | `internal/ai/openaicompat/config.go` | REWRITE |
| `Core/AI/DayflowBackendProvider.swift` | 托管提供商 | `internal/ai/dayflow/` | REWRITE |
| `Core/AI/DayflowEndpointPreferences.swift` | 端点覆盖 | `internal/settings/providers.go` | REWRITE |
| `Core/AI/LocalEndpointUtilities.swift`, `LocalEngine.swift`, `LocalModelPreset.swift` | 本地模型发现 | `internal/ai/ollama/discovery.go` | REWRITE |
| `Utilities/GeminiAPIHelper.swift` | 密钥验证 | `internal/ai/gemini/keycheck.go` | REWRITE |

### CLI 提供商——谨慎移植

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/AI/ChatCLIProcessRunner.swift` (1,454) | 登录 shell 子进程、JSONL 流 | `internal/ai/cli/runner.go` | REWRITE |
| `Core/AI/LoginShellRunner.swift` | `$SHELL -lc` 环境发现 | `internal/ai/cli/loginshell.go` | REWRITE |
| `Core/AI/ChatCLIConfigManager.swift` | 工作目录 | `internal/ai/cli/workdir.go` | REWRITE |
| `Core/AI/ChatCLIRunner.swift` | 运行器门面 | 合并到 `runner.go` | REWRITE |
| `Core/AI/ClaudeProvider.swift` + 4 个扩展 | Claude Code 提供商 | `internal/ai/claude/` | REWRITE |
| `Core/AI/ClaudeStrictJSONParser.swift` (454) | 畸形 JSON 修复 | `internal/ai/jsonrepair/` | REWRITE |
| `Core/AI/ClaudeOutputValidator.swift` (533) | 卡片区间验证 | `internal/ai/claude/validate.go` | REWRITE |
| `Core/AI/ClaudeTranscriptionInputBuilder.swift` (605) | 帧 → 提示输入 | `internal/ai/claude/input.go` | REWRITE |
| `Core/AI/CodexProvider.swift` + 4 个扩展 | Codex CLI 提供商 | `internal/ai/codex/` | REWRITE |
| `Core/AI/CodexExecutableResolver.swift` | 二进制文件发现 | `internal/ai/codex/resolve.go` | REWRITE |
| `Core/AI/AgentCLISupport.swift` + 2 个扩展 | 共享 CLI 辅助功能 | `internal/ai/cli/support.go` | REWRITE |
| ↳ `AgentCLISupport` 中的图像缩小 | 通过 `NSBitmapImageRep` 准备 720p JPEG | `platform.Media.EncodeJPEG` | **BRIDGE** |

有意将 `jsonrepair` 设为独立包而非放在 `claude/` 下：每个本地模型提供商都会遇到相同的畸形 JSON 问题，而当前代码只为 Claude 解决了这个问题。

### 编排

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/AI/LLMService.swift` (1,309) | 路由、门控、回退、批次编排 | `internal/ai/registry.go` + `internal/analysis/pipeline.go` | REWRITE |
| `Core/AI/LLMProviderRouting.swift` | 路由存储，schema v2 | `internal/ai/routing.go` | REWRITE |
| `Core/AI/LegacyLLMProviderMigration.swift` | v1 → v2 路由迁移 | `internal/ai/routing_legacy.go` | REWRITE |
| `Core/AI/LLMTypes.swift` | 共享 AI 类型 | `internal/ai/types.go` | REWRITE |
| `Core/AI/LLMLogger.swift` | `llm_calls` 写入器 | `internal/storage/llmcalls.go` | REWRITE |
| `Core/AI/LLMOutputLanguagePreferences.swift` | 输出语言覆盖 | `internal/settings/language.go` | REWRITE |
| `Core/AI/*PromptPreferences.swift`（4 个文件） | 各 provider 的提示词覆盖 | `internal/ai/prompts/` | REWRITE |
| `Core/AI/ActivityCardPromptOverrides.swift`, `ClaudePromptDefaults.swift` | 默认提示词 | `internal/ai/prompts/defaults.go` | REWRITE |
| `Core/AI/GeminiModelPreference.swift` | 模型选择 | `internal/settings/providers.go` | REWRITE |

有意将 `LLMService` 拆成两部分。它目前承担两项互不相关的工作：解析并包装 provider（→ `ai.Registry`），以及运行转录 → 生成 → 替换序列（→ `analysis.Pipeline`）。批次流水线不属于 provider 层。

### 聊天与回顾

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/AI/ChatService.swift` | 聊天编排、工具循环 | `internal/chat/service.go` | REWRITE |
| `Core/AI/ChatPromptBuilder.swift` | 聊天提示词组装 | `internal/chat/prompt.go` | REWRITE |
| `Core/AI/ChatToolExecutor.swift` | `fetchTimeline` / `fetchObservations` 工具 | `internal/chat/tools.go` | REWRITE |
| `Core/AI/ChatMetadataParser.swift`, `ChatModels.swift` | 聊天类型 | `internal/chat/types.go` | REWRITE |
| `Core/AI/DashboardChatMemoryStore.swift` | 聊天记忆 blob | `internal/chat/memory.go` | REWRITE |
| `Core/AI/DailyRecapGenerator.swift` (744) | 每日站会生成 | `internal/insight/recap.go` | REWRITE |
| `Core/AI/DailyRecapModels.swift` | 回顾类型 | `internal/insight/recap_types.go` | REWRITE |
| `Core/AI/DailyRecapScheduler.swift` | 每 5 分钟检查回顾 | `internal/insight/recap_scheduler.go` | REWRITE |

---

## 5.8 派生视图——轻松取得的 Go 成果

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/Weekly/WeeklyDashboardBuilder.swift` + 3 个扩展 | 卡片 → 仪表盘 view model | `internal/insight/weekly/` | REWRITE |
| `Core/Weekly/WeeklyDashboardModels.swift` | 仪表盘类型 | `internal/insight/weekly/models.go` | REWRITE |
| `Core/Weekly/WeeklyDonutBuilder.swift`, `WeeklyOverviewBuilder.swift` | 图表数据 | `internal/insight/weekly/` | REWRITE |
| `Core/Weekly/WeeklyDateRange.swift` | ISO 周范围 | `internal/timeutil/week.go` | REWRITE |
| `Views/UI/MainView/TimelineActivityLoader.swift` | 卡片 → 时间线分段、失败分组 | `internal/insight/timeline.go` | REWRITE |
| `Views/UI/DailyWorkflowComputation.swift` | 每日工作流聚合 | `internal/insight/daily.go` | REWRITE |
| `Core/Recording/JournalDayManager.swift` | 日志日期状态 | `internal/insight/journal.go` | REWRITE |
| `Models/TimelineCategory.swift`（struct 部分） | 类别模型 | `internal/domain/category.go` | REWRITE |
| `Models/TimelineCategory.swift`（`CategoryStore`） | 分类体系持久化 | `internal/settings/categories.go` | REWRITE |
| `Models/DayGoalPlan.swift` | 每日目标模型 | `internal/domain/goal.go` | REWRITE |
| `Models/ChatMessage.swift` | 聊天消息模型 | `internal/chat/types.go` | REWRITE |
| `Models/AnalysisModels.swift` | `Screenshot`、`RecordingChunk` | `internal/domain/screenshot.go` | REWRITE |
| `Utilities/TimelineClipboardFormatter.swift` | 将时间线复制为文本 | `internal/insight/clipboard.go` | REWRITE |

请注意，`TimelineActivityLoader` 和 `DailyWorkflowComputation` 当前位于 `Views/` 下。它们是被错误归入 UI 的纯数据转换；将其移入 Go 核心是真正的架构改进，而非横向移植。

---

## 5.9 系统集成

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `System/UpdaterManager.swift` | Sparkle 更新器 | `native/darwin/.../Update/Updater.swift` | **KEEP** |
| `System/SilentUserDriver.swift` | 静默 Sparkle UI 驱动器 | `native/darwin/.../Update/SilentDriver.swift` | **KEEP** |
| `System/StatusBarController.swift` | `NSStatusItem` | `native/darwin/.../UI/StatusItem.swift` | **KEEP** |
| `Menu/StatusMenuView.swift` | 状态菜单内容 | 由 Go 状态驱动、helper 渲染的菜单 | REWRITE |
| `System/LaunchAtLoginManager.swift` | `SMAppService` 登录项 | `native/darwin/.../System/LoginItem.swift` | **BRIDGE** |
| `System/ScreenRecordingPermissionNotice.swift` | TCC 预检 + 设置深层链接 | `native/darwin/.../System/Permissions.swift` | **BRIDGE** |
| `Core/Notifications/NotificationService.swift` | `UNUserNotificationCenter` | `native/darwin/.../System/Notifications.swift` | **BRIDGE** |
| `Core/Notifications/NotificationBadgeManager.swift` | Dock 徽标 | `native/darwin/.../System/Badge.swift` | **BRIDGE** |
| `Core/Notifications/NotificationPreferences.swift` | 提醒计划 | `internal/settings/notifications.go` | REWRITE |
| `Core/Security/KeychainManager.swift` | API 密钥存储 | `native/darwin/.../System/Keychain.swift` | **BRIDGE** |
| `System/DayflowAuthManager.swift` (1,007) | 托管账户、权益 | `internal/account/auth.go` | REWRITE |
| `System/DayflowBackendConfiguration.swift` | 后端端点 | `internal/account/config.go` | REWRITE |
| `System/AnalyticsService.swift` | PostHog + 采样 | `internal/telemetry/analytics.go` | REWRITE |
| `System/ProcessCPUMonitor.swift` | 自身 CPU 采样 | `internal/telemetry/cpu.go` | REWRITE |
| `Utilities/SentryHelper.swift` | Sentry 门面 | `internal/telemetry/sentry.go` + helper 中的原生处理器 | REWRITE |
| `System/TimelineFailureToast.swift` | 失败 toast 状态 | Vue store | REWRITE |
| `Core/Net/FaviconService.swift` | 应用/站点图标获取 | `internal/net/favicon.go` | REWRITE |
| `Core/Access/FeatureAccessRequirements.swift` | 功能门控 | `internal/account/access.go` | REWRITE |

`KeychainManager` 是 BRIDGE 而非 REWRITE，原因很具体：Keychain ACL 受创建项目的代码签名约束。现有用户的密钥由已签名的 `Dayflow.app` 写入。从使用相同身份签名的 bundle 内 helper 读取可静默工作；从单独签名的 Go 二进制读取会提示用户或直接失败。参见[风险 C-3](08-risk-analysis.md#c-3tcc-和-keychain-身份丢失)。

`UpdaterManager`、`SilentUserDriver` 和 `StatusBarController` 是仅有的三个 KEEP。三者都是没有可行 Go 等价方案的轻量 Apple 生态绑定；尤其是 Sparkle，必须继续为已通过公开 appcast 安装的现有用户群工作。

---

## 5.10 Agent 访问

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Core/AgentAccess/AgentBridgeServer.swift` | NDJSON 写入 socket | `internal/agentbridge/server.go` | REWRITE |
| `Core/AgentAccess/AgentWriteHandlers.swift` | 6 项写入操作 | `internal/agentbridge/handlers.go` | REWRITE |
| `Core/AgentAccess/AgentClientRegistration.swift` | MCP 客户端配置修复 | `internal/agentbridge/registration.go` | REWRITE |
| `Core/AgentAccess/CodexMCPRegistration.swift` | Codex MCP 注册 | `internal/agentbridge/codex.go` | REWRITE |
| `Core/AgentAccess/AgentUsageTelemetryQueue.swift` | 离线遥测 spool | `internal/telemetry/queue.go` | REWRITE |
| `legacy/dayflow-cli/` (2,308) | 只读 CLI + MCP server | Go 中的 `cmd/dayflow-cli/` | REWRITE |

CLI 是**兼容性关键**的重写：其命令面（`status`、`timeline`、`today`、`yesterday`、`card`、`daily`、`weekly`、`categories`、`goal`、`search`、`link`、`unlink`、`mcp`）及 JSON 输出形态是公开契约，用户已通过 MCP 将其接入 Claude Code 和 Codex。输出必须逐字节可比较，且 `DAYFLOW_DB` 环境覆盖必须继续工作。

一个有用的顺序推论是：由于 Go CLI 和 Swift CLI 可以针对同一数据库运行，**Swift CLI 是整个 Go 读取路径的免费差分 oracle。**尽早构建 Go CLI 获得的是测试基础设施，而不只是一项功能。

---

## 5.11 UI——v1 范围

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Views/UI/MainView/` (7,135) | 时间线外壳、日期导航、周网格 | `frontend/src/views/Timeline/` | REWRITE |
| `Views/UI/DailyView*.swift`, `Daily*.swift` (~3,500) | 每日回顾与站会 | `frontend/src/views/Daily/` | REWRITE |
| `Views/UI/Settings/` (6,060) | 设置标签页与 view model | `frontend/src/views/Settings/` | REWRITE |
| `Views/UI/Chat*.swift` (~4,000) | 聊天面板、Markdown、工具气泡 | `frontend/src/views/Chat/` | REWRITE |
| `Views/UI/Journal*.swift` (~3,000) | 每日与每周日志视图 | `frontend/src/views/Journal/` | REWRITE |
| `Views/UI/TimelineReview*.swift` (~2,500) | 回顾 overlay、scrubber | `frontend/src/views/Review/` | REWRITE |
| `Views/Components/` (9,113) | 共享控件、选择器、图表 | `frontend/src/components/` | REWRITE |
| `Views/Onboarding/` (7,599) | provider 设置、权限流程 | `frontend/src/views/Onboarding/` | REWRITE |
| `Utilities/DayflowTheme.swift`, `LightWindowGradient.swift`, `Color+Luminance.swift` | 主题 | `frontend/src/styles/`（CSS 自定义属性） | REPLACE |
| `Utilities/Localization.swift` | i18n | `vue-i18n` | REPLACE |
| `Views/UI/VideoPlayerModal.swift`, `WhiteBGVideoPlayer.swift`, `VideoThumbnailView.swift` | `AVKit` 播放 | 通过 Wails 资源处理器提供的 `<video>` | REPLACE |
| `Views/UI/SupportChatWebView.swift`, `Flow/FlowWebView.swift` | `WKWebView` 宿主 | 原生 `<iframe>` | REPLACE |
| `Views/Components/SplashWindow.swift`, `Views/Onboarding/VideoLaunchView.swift` | 启动动画 | Vue splash | REWRITE |
| `Fonts/*.ttf`（6 个文件） | Figtree、Instrument Serif、Nunito | 通过 `@font-face` 放入 `frontend/src/assets/fonts/` | KEEP（资源） |
| `Assets.xcassets/` | 图标、favicon、预览 | `frontend/src/assets/` | KEEP（资源） |

REPLACE 条目是 Web 平台明显更好的地方：CSS 自定义属性胜过手写主题环境，`vue-i18n` 胜过定制本地化 shim，`<video>` 胜过 `AVKit` 胶水代码。约 3,000 LOC 会消失而不是迁移。

## 5.12 UI——推迟项

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `Views/UI/Weekly/` (9,855) | Treemap、Sankey、热力图、交互图 | `frontend/src/views/Weekly/` | **DEFER** |
| `Views/UI/Agents/` (3,066) | Agent 简报、回放、回顾 | `frontend/src/views/Agents/` | **DEFER** |
| `Views/UI/Flow/` (845) + `Core/Flow/` (1,054) | 专注 overlay 生物 | — | **DEFER** |
| `Views/UI/WhatsNewView.swift`, `GitHubStarPromptCard.swift`, `BugReportView.swift`, `ReferralSurveyView.swift` | 增长界面 | — | **DEFER** |
| `Views/Onboarding/Prototype/` | 未发布的引导原型 | — | **DELETE** |
| `Views/UI/Weekly/Sections/WeeklyInteractionGraphPrototypeSection.swift`, `*Fixtures.swift`, `WeeklyTreemapPreview.swift`, `WeeklyTreemapSnapshots.swift` | 原型/预览脚手架 | — | **DELETE** |

具体推迟这三项的原因：

- **Weekly** 是 9,855 LOC 的自定义图表渲染——占整个 UI 的 15%——却只服务一个标签页。Go builder（`internal/insight/weekly/`）仍应尽早移植，因为它便宜且可测试；只有*渲染*等待。
- **Agents** 依赖外部 CLI session 回放和托管权益检查。集成面广，用户群小。
- **Flow** 需要一个不激活应用且始终置顶的 `NSPanel`。Wails 没有等价能力，因此需要定制 helper 窗口——这是项目中投入产出比最差的部分。

推迟期间，这些标签页在 Go 构建中隐藏。需要它们的用户保留 Swift 应用；两者读取同一数据库。

---

## 5.13 测试

| 当前模块 | 职责 | 新位置 | 操作 |
|----------------|----------------|--------------|--------|
| `DayflowTests/TimeParsingTests.swift` | 时钟解析 | `internal/timeutil/clock_test.go` | REWRITE |
| `DayflowTests/WeeklyDashboardBuilderTests.swift` | 每周 builder | `internal/insight/weekly/builder_test.go` | REWRITE |
| `DayflowTests/TimelineActivityLoaderTests.swift` | 时间线分段 | `internal/insight/timeline_test.go` | REWRITE |
| `DayflowTests/LLMProviderRoutingTests.swift` | 路由存储 | `internal/ai/routing_test.go` | REWRITE |
| `DayflowTests/Claude*Tests.swift`（3 个文件） | Claude 解析与边界 | `internal/ai/claude/*_test.go` | REWRITE |
| `DayflowTests/Codex*Tests.swift`（2 个文件） | Codex 解析 | `internal/ai/codex/*_test.go` | REWRITE |
| `DayflowTests/OpenAICompatible*Tests.swift`（2 个文件） | 端点配置 | `internal/ai/openaicompat/*_test.go` | REWRITE |
| `DayflowTests/Agent*Tests.swift`（4 个文件） | Agent bridge | `internal/agentbridge/*_test.go` | REWRITE |
| `DayflowTests/ProviderPromptPreferencesTests.swift`, `ProvidersSettingsViewModelTests.swift` | 提示词覆盖 | `internal/ai/prompts/*_test.go` | REWRITE |
| `DayflowTests/GeminiAPIHelperTests.swift` | 密钥验证 | `internal/ai/gemini/keycheck_test.go` | REWRITE |
| `DayflowTests/DaySummaryLoadTokenTests.swift`, `DailyRecapGeneratorTests.swift` | 回顾 | `internal/insight/recap_test.go` | REWRITE |
| `DayflowUITests/` | XCUITest 启动测试 | 针对 Wails 构建的 Playwright | REPLACE |

现有 21 个测试文件应视为**需要满足的规范，而不是待翻译的产物**。移植每个测试前，先针对 Swift 构建运行它，并将输入输出捕获为 JSON fixture；随后 Go 测试针对捕获的 fixture 断言，而不是重新手写期望值。这样每个测试都会成为跨语言契约，而不是对正确行为的两次独立猜测。这正是 [07 §12.3](07-testing-strategy.md#123-行为测试) 所述的机制。