# Dayflow — Go 重构 Agent 指令

Dayflow 是一个 macOS 后台 Agent：截取当前活跃显示器，分批交给用户配置的 LLM，并将结果呈现为时间线。

## 当前目标

**本仓库当前主线是将 Dayflow 重构为 Go Core + Wails + Vue，并保留一个最小 Swift helper 承载 Apple 平台能力。**

这不是一次在原 Swift 架构上继续扩展功能的常规维护。除非任务明确要求修复已发布版本，否则：

- 新业务逻辑优先写入 Go；新 UI 优先写入 Vue/TypeScript。
- Swift 仅用于 ScreenCaptureKit、AVFoundation、VideoToolbox、TCC、Keychain、状态栏、系统事件与 Sparkle 等原生适配。
- 不要把可移植业务逻辑新增到 Swift helper。
- 不要为了“重构”直接删除旧 Swift 实现；它是迁移期的参考实现和可回退版本。
- 不做大爆炸式切换。按阶段共存、对照、验证，再转移所有权。

`docs/plan/README.md` 是重构入口，`docs/plan/01`–`09` 是当前设计规格。开始迁移任务前，先阅读与任务直接相关的文档；若实现发现计划与代码事实冲突，以可复现实验和当前代码为准，并同步修正文档。

目前 `docs/plan/` 是设计，不代表其中目标已经实现。不要把规划中的目录、接口、命令或行为描述成现状。

---

## 执行顺序与阶段门禁

遵循 `docs/plan/06-migration-roadmap.md`：

| 阶段 | 目标 | 退出门槛 |
|---|---|---|
| 0 | 建立匿名 fixtures 与 Swift/Go 差分基线 | 关键行为可重复比较 |
| 1 | Go、Wails、Vue 骨架和平台接口 | 证明 Wails 可承载无窗口后台 Agent |
| 2 | Go 只读现有数据库 | 时间线与现有 CLI 输出一致 |
| 3 | Vue v1 UI | 可作为只读查看器日常使用 |
| 4 | Go 分析与派生视图，shadow/canary 写入 | 连续 7 天结果符合已批准的一致性标准 |
| 5 | Go + Swift helper 接管捕获 | 连续 14 天无数据缺口 |
| 6 | 退役 Swift 业务代码 | Swift 仅剩 `native/darwin` 原生适配 |

除非用户明确改变范围，不要跳过当前阶段的退出门槛。尤其不要在只读兼容性尚未证明前写入真实用户数据库，也不要在后台生命周期探索失败时投入完整 Vue 重写。

首个实施任务以 `docs/plan/09-first-task.md` 为准：构建只读 Go 兼容性测试框架。该阶段不包含 Wails、Vue、helper、AI provider 或任何 Go 写入路径。

---

## 目标架构与依赖方向

目标结构详见 `docs/plan/04-target-architecture.md`：

```text
Vue 3 + TypeScript
        ↓ generated Wails bindings
internal/app                 仅此层知道 Wails
        ↓
Go services                 analysis / ai / insight / chat
        ↓
Go foundation               storage / settings / domain / timeutil
        ↓ interfaces
internal/platform
        ↓ versioned NDJSON over Unix socket
native/darwin Swift helper  Apple frameworks only
```

必须保持以下依赖规则：

1. foundation 不依赖 service、app、Wails 或 Swift helper 实现。
2. service 通过消费者侧接口协作，不导入其他 service 的内部实现。
3. 只有 `internal/app` 可以依赖 Wails；Go Core 必须能无 GUI 测试。
4. 只有 `internal/platform` 可以构造 helper IPC 消息。
5. `internal/storage` 是 Go 侧唯一允许包含 SQL 和打开业务数据库连接的包。
6. Vue 只通过生成的绑定和薄 API wrapper 访问 Go，不直接访问数据库、文件系统或 helper。

如果实际落盘目录仍为 `dayflow-go/`，在该目录内应用上述结构。不要仅为匹配设计图而移动已验证代码；目录调整应独立提交并保持可构建。

---

## 构建与测试

### 当前 Swift 参考实现

```bash
xcodebuild -project legacy/dayflow/Dayflow.xcodeproj -scheme Dayflow -configuration Debug build
xcodebuild -project legacy/dayflow/Dayflow.xcodeproj -scheme Dayflow \
  -destination 'platform=macOS' test

cd legacy/dayflow-cli
swift build
swift run dayflow status
```

Xcode 工程使用 `PBXFileSystemSynchronizedRootGroup`（Xcode 16+）。位于 `legacy/dayflow/Dayflow/` 与 `legacy/dayflow/DayflowTests/` 的文件会自动加入对应 target；不要为了注册文件手动编辑 `project.pbxproj`。

### Go 迁移代码

在 Go module 所在目录运行：

```bash
gofmt -w <changed-go-files>
go test ./...
go vet ./...
CGO_ENABLED=0 go build ./...
```

阶段 0–4 的 Go Core 必须保持 `CGO_ENABLED=0` 可构建。Darwin 能力通过 `platform` 接口和 fake 实现隔离；不要把 Apple framework 或 Wails 引入核心包。

前端建立后，以其锁文件和 `package.json` scripts 为准。不要混用 npm、pnpm、yarn，也不要在未确认现有工具链前生成新锁文件。

验证应与风险匹配：纯函数跑单元测试；存储变更跑 fixture/差分测试；IPC 变更跑双方协议测试；捕获或生命周期变更必须在真实 macOS 上集成测试。

---

## 代码约定

### Go

- 始终 `gofmt`；包名简短、小写，避免无意义的 `util`、`common`、`manager`。
- 接口定义在使用方一侧，并保持最小化。
- 阻塞 I/O 和长任务接收 `context.Context` 并传播取消。
- goroutine 必须有明确所有者、退出条件和错误通道；禁止无法停止的后台 goroutine。
- 错误包含操作与对象上下文，并保留 `%w` 错误链；不要通过字符串匹配判断错误类型。
- 业务日期必须走 `internal/timeutil` 的凌晨 4 点边界。
- 不用全局可变单例承载数据库、调度器或 recorder 状态。

### Vue / TypeScript

- 保持严格类型检查，不使用 `any` 绕过 Wails 边界。
- Wails payload 使用显式、稳定的 DTO；领域转换放在薄 wrapper 或 store。
- 组件负责呈现与交互，数据查询、轮询和业务聚合放在 store/service。
- 不把 SwiftUI 页面逐行翻译成 Vue；以用户可观察行为和视觉基线为迁移对象。

### Swift helper 与旧实现

- 使用 2 个空格缩进并匹配 `swift-format` 和周围代码。
- 新 Swift 文件保留项目文件头；使用 `// MARK: -` 划分章节。
- helper 只做平台适配、进程协议和必要的短期缓冲，不拥有业务 schema 或分析规则。
- 注释解释“为什么”，尤其保留硬件、系统 API 和兼容性限制。

---

## 不可破坏的行为与数据契约

### 数据库所有权

- 迁移期始终只能有一个业务写入方，并且**恰好一个进程持有捕获所有者锁**。
- 阶段 0–3 的 Go 数据库访问必须在连接层只读：`SQLITE_OPEN_READONLY` 加 `PRAGMA query_only`。
- 保持 `journal_mode = WAL`、`synchronous = NORMAL`、`busy_timeout = 5000`。
- 不在真实安装数据库上跑测试、schema 探测写入或破坏性迁移；只使用匿名副本/fixtures。
- 当前 `PRAGMA user_version = 0`。在迁移设计明确批准前，不擅自引入版本化 migration chain。

Go 接管写入后，`internal/storage` 是唯一 schema owner 和 SQLite writer。所有操作必须经过统一的可观测读写封装，以保留慢查询、争用和故障诊断能力。

### 凌晨 4 点逻辑日

一天从本地时间凌晨 4 点开始，而不是午夜。Go 实现必须复现 `Date.getDayInfoFor4AMBoundary()`，并覆盖 DST、半小时和 45 分钟时区。禁止用 `time.Truncate(24*time.Hour)` 或简单午夜计算替代。

### 时间线卡片

`start`/`end` 是本地化时钟字符串；`start_ts`/`end_ts` 是派生 Unix 时间。移植 `replaceTimelineCardsInRange` 时必须共同保留并测试：

- 在锚点前一天、当天、后一天中选择最接近窗口中点的解析结果；
- `end < start` 时按跨午夜处理；
- 使用凌晨 4 点边界计算 `day`；
- 保留其他批次写入且 `category = 'System'` 的卡片。

不要把当前裸 `continue` 导致的静默丢卡复制为默认新行为；若修正它，必须作为显式行为变更加入指标和测试。

### 设置不是只存在 SQLite

分类名称在 `timeline_cards.category` 中，颜色、描述、顺序、`isIdle` 等位于 `~/Library/Preferences/teleportlabs.com.Dayflow.plist` 的 `colorCategories`。兼容读取必须同时覆盖数据库和 plist；Keychain service 仍为 `com.teleportlabs.dayflow.apikeys.<provider>`。

### 帧和 segment

- `frame_index != nil` 表示 HEVC segment 中的帧；`frame_index == nil` 是旧版独立 JPEG。两种格式都必须可读。
- 像素读取必须经统一 media/platform 接口，不能让业务层直接读取 `file_path`。
- 未完成收尾的 MP4 没有 moov atom。睡眠、锁定、屏保、更新、helper 重启、宿主退出和关机路径都必须完成或安全移交当前 segment。
- 清理以完整 segment 为单位，从不删除活跃 segment，也不能单独删除 HEVC 流中的一帧。
- `screenshots.file_size` 是 segment 总大小平均分摊到每帧的值；逐行求和才还原实际占用。

### 并发与状态

- 转录可以并行，但 timeline card 的 read → generate → replace 序列必须按重叠范围串行化，等价于现有 `timelineCardGenerationGate`。
- 旧数据中 `completed` 与 `analyzed` 都表示成功；读取方必须兼容两者。是否统一新写入状态属于产品行为变更。
- recorder 的 `idle`、`starting`、`capturing`、`paused` 不可互换。`paused` 会自动恢复，`idle` 表示用户关闭。
- 唤醒后恢复延迟为 5 秒，解锁后为 0.5 秒，避免 `SCShareableContent` 返回过时显示器列表。

### 原生捕获决策

- 捕获继续使用 `SCScreenshotManager`，不改为持续 `SCStream`；后者会持续显示 macOS 屏幕录制指示器。
- Apple 框架能力保留在 Swift helper，通过带版本协商的 NDJSON Unix socket 暴露。
- helper 崩溃、断连和宿主重启必须可恢复；协议破坏性变更需要版本升级和双端兼容测试。

---

## 隐私与安全

- 屏幕数据只允许发给用户明确配置的 LLM provider。
- bundle identifier blocklist 和“前台应用被屏蔽时写入脱敏占位帧”两层保护都必须保留。
- 分析与崩溃上报保持 opt-in。禁止记录或上报屏幕内容、窗口标题、文件路径、API key、LLM payload 或可还原用户活动的内容。
- 密钥只存 Keychain 或 gitignore 的本地配置。绝不写入被 Git 跟踪的文件、fixture、日志或快照。
- fixture 必须匿名化并验证不可逆；绝不提交真实数据库、录制、延时摄影或用户 plist。
- Unix socket 权限保持 `0600`；所有 IPC 输入都视为不可信并做大小限制与结构校验。

---

## 对外兼容契约

| 契约 | 当前参考位置 | 要求 |
|---|---|---|
| `dayflow-cli` 命令与 JSON | `legacy/dayflow-cli/` | 输出兼容，继续支持 `DAYFLOW_DB`；连接层只读 |
| Agent bridge | `Core/AgentAccess/AgentBridgeServer.swift` | `0600` Unix socket、NDJSON、现有 6 项操作兼容 |
| 分析事件 | `legacy/dayflow/Dayflow/AnalyticsEventDictionary.md` | 名称、属性和采样概率不变 |
| 更新链路 | `Info.plist`、`docs/appcast.xml` | 保持 Sparkle appcast 与 EdDSA 信任链 |
| Bundle ID | `project.pbxproj` | 保持 `teleportlabs.com.Dayflow`，避免丢失 TCC 与 Keychain 身份 |

Go/Wails 版本不能以技术栈变化为理由改变这些契约。需要变化时，先加入兼容层、迁移测试和回滚方案。

---

## 生命周期

Dayflow 是常驻后台 Agent，不是“关闭最后一个窗口即退出”的普通桌面应用。

- 关闭窗口后捕获必须继续，状态栏可重新打开窗口。
- Cmd+Q、窗口关闭、更新重启、helper 退出和系统关机是不同事件，必须分别建模。
- 不要假定退出 UI 等于用户要求停止录制。
- Wails 的无窗口常驻、accessory 激活策略、状态栏和 Sparkle 更新是阶段 1 硬门禁；验证失败时停止 UI 扩张并重新评估宿主架构。

---

## 工作方式

1. 先确认任务属于哪个迁移阶段，阅读相应 `docs/plan/` 文档与 Swift 参考实现。
2. 写出可观察的兼容标准或失败条件，再实现最小垂直切片。
3. 优先添加 fixture、黄金测试或差分测试；不要用“看起来等价”代替证明。
4. 若 Go 与 Swift 不同，先保留差异并定位原因，不要立即修改黄金结果。
5. 每次只转移一个明确所有权边界，并保留可回退路径。
6. 不在无关迁移中顺手清理旧代码、统一状态、替换重试策略或修改 schema。

完成迁移任务时报告：实现内容、对应阶段门禁、运行命令及结果、未验证风险和回退方式。

---

## 已知旧实现陷阱

- `legacy/unlinked-tests/` 不属于 target；有效 Swift 测试位于 `legacy/dayflow/DayflowTests/`。
- `chunks` 与 `batch_chunks` 已废弃，只为读取兼容保留；不要在 Go 新功能中使用。
- `completed` 与 `analyzed` 都是成功终态。
- 无法解析的卡片时钟字符串目前会被静默丢弃。
- provider 重试策略当前不一致；统一策略是独立、用户可观察的行为变更。
- `AnalysisManager.isProcessing` 是跨上下文访问的普通 `Bool`；不要在 Go 中照搬。

---

## 提交与发布

提交格式：`<area>: <lowercase imperative summary>`，每个 commit 只处理一个关注点。迁移相关可使用 `go:`、`frontend:`、`native:`、`migration:`、`compat:`。

除非用户明确要求，否则不要运行 `scripts/release.sh`。它会递增版本、签名、公证、更新 appcast 并发布 GitHub release。
