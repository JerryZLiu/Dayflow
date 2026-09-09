# 14. 建议的首个实现任务

## 14.1 任务

> **构建兼容性测试框架：一个读取现有 Dayflow SQLite 数据库和分类 plist、复现日期边界与空闲分类逻辑，并通过与已发布的 Swift `dayflow-cli` 对比证明输出逐字节完全一致的 Go package。**

不使用 Wails。不使用 Vue。不使用 helper。不执行写入。只需一个 Go module、一组 fixture 语料库，以及一个结果非通过即失败的差分测试。

## 14.2 为什么选择这个任务

考虑了四个候选方案：

| 候选方案 | 获得的信息 | 浪费工作的风险 | 可解锁 |
|-----------|--------------------|---------------------|----------|
| **数据库兼容性测试框架** | 高——验证计划的核心前提 | **无**——每项产物都会复用 | 阶段 2、4、7 |
| Wails 外壳可行性探索 | **最高**——检验一项前提风险 | 低 | 所有阶段 |
| Swift helper 提取 | 中 | 中——依赖尚未验证的决策 | 阶段 5 |
| Vue 时间线原型 | 低——没有任何存疑之处 | **高**——没有可供绑定的数据层 | 无 |

可以说，Wails 可行性探索能提供更多信息，而且绝对应该执行——但应当将其作为一个并行、有严格时间限制的探索，而不是作为首个任务，原因有三：

1. 它的结果是二元的，而且能快速得出。一周的专注工作即可回答这个问题，不需要整个团队参与。
2. 即使成功，它也不会产生任何可复用的产物——只有一个绿灯信号。
3. 它没有依赖项，因此可以与实际工作并行执行，而不必阻塞实际工作。

相比之下，兼容性测试框架：

- **直接验证既定的阶段 2 目标。**“旧版 Dayflow 数据库 → Go 应用程序 → 兼容”是整个共存策略所依赖的前提。其他所有内容都以此为假设。
- **没有任何一次性工作。**fixtures 将成为阶段 0 的语料库。storage reader 将成为 `internal/storage`。plist reader 将成为 `internal/settings`。差分 runner 将成为阶段 2、4 和 5 的 CI 门禁。
- **不触及任何生产代码。**仅针对副本进行只读操作，不可能破坏任何内容。
- **迫使棘手问题尽早暴露。**`colorCategories` 中的 `Date` 是如何编码的？在 DST 边界上，`time.Local` 是否与 `Calendar.current` 一致？当存在活动 writer 并启用 WAL 时，`modernc.org/sqlite` 的行为如何？这些问题现在发现的成本很低，而到阶段 4 才发现则代价高昂。
- **在需要之前构建好判定基准。**后续每个阶段的信心都来自差分测试。先构建 differ，意味着第一次出现真正的差异时，它已经可用。

决定性理由是：这个任务把项目最大的结构性优势——一个可以在相同数据上运行的有效参考实现——从一个不错的想法转化为可运行的基础设施，而且整个过程发生在任何一行生产代码被修改之前。

## 14.3 范围

### 包含

```
dayflow-go/                          new, alongside the existing project
├── go.mod                           module dayflow, CGO_ENABLED=0
├── internal/
│   ├── timeutil/
│   │   ├── dayboundary.go            4 AM logical day
│   │   ├── dayboundary_test.go
│   │   ├── clock.go                  "h:mm a" parse and format
│   │   └── clock_test.go
│   ├── domain/
│   │   ├── screenshot.go
│   │   ├── card.go                   incl. TimelineMetadata envelope
│   │   ├── observation.go
│   │   ├── batch.go
│   │   └── category.go
│   ├── storage/
│   │   ├── db.go                     open read-only, matching PRAGMAs
│   │   ├── schema.go                 ensure-schema, asserted to be a no-op
│   │   ├── timeline.go               card reads
│   │   ├── screenshots.go
│   │   ├── observations.go
│   │   ├── batches.go
│   │   └── *_test.go
│   ├── settings/
│   │   ├── plist_darwin.go           legacy preference reader
│   │   ├── categories.go             colorCategories decode
│   │   └── *_test.go
│   ├── analysis/
│   │   ├── idle.go                   IdleBatchClassifier port
│   │   ├── batcher.go                createScreenshotBatches port
│   │   └── *_test.go
│   └── insight/
│       ├── timeline.go               TimelineActivityLoader port
│       └── timeline_test.go
├── cmd/
│   └── dayflow-compat/
│       └── main.go                   the differential runner
└── testdata/
    ├── databases/                    5 fixtures per docs/plan/07 section 12.2
    ├── preferences/                  anonymised plists
    └── fixtures/                     idle, batching, dayboundary, cardreplace
```

此外，在现有项目中添加一个临时 Swift target：

```
legacy/dayflow/DayflowFixtureExport/ temporary, deleted after Phase 0
├── ExportIdleFixtures.swift
├── ExportBatchingFixtures.swift
├── ExportDayBoundaryFixtures.swift
├── ExportCardReplaceFixtures.swift
└── Anonymize.swift                   database and plist scrubbing
```

### 不包含

Wails、Vue、helper、任何 Go **写入**路径、任何 AI provider、帧解码、`cmd/dayflow-cli`。

尽管缩略图直观可见且容易带来成就感，但帧解码被刻意排除：它需要 helper，而 helper 又要求先验证 bridge 决策，这属于另一项任务。让本任务保持纯 Go 且只读，正是它没有风险的原因。

## 14.4 完成定义

共七项检查，必须全部通过。

| # | 检查项 | 方法 |
|---|-------|--------|
| 1 | **Schema 未被改动** | 在全部五个 fixtures 上，分别计算 Go ensure-schema 执行前后的 `sqlite_master` 哈希值。两者完全相同。 |
| 2 | **CLI 输出完全一致** | 对 `v2.4.0-typical` 中的每一天执行：`diff <(swift-cli timeline --json) <(go-compat timeline --json)` → 无输出。对 `today`、`card`、`categories`、`search` 执行同样检查。 |
| 3 | **Categories 往返转换一致** | 从三个真实 plist 解码 `colorCategories`；名称、`colorHex`、details、顺序、`isSystem`、`isIdle` 和时间戳均与正在运行的 Swift 应用完全一致。 |
| 4 | **空闲分类一致** | 所有 `testdata/fixtures/idle/*.json` 均通过，包括七个阈值各自的一个边界案例。 |
| 5 | **分批逻辑一致** | 所有 `testdata/fixtures/batching/*.json` 均通过，包括丢弃最后一个 batch 的规则和 2 分钟间隔拆分规则。 |
| 6 | **跨时区的日期边界一致** | 所有 `dayboundary` fixtures 在 `TZ` = `UTC`、`America/Los_Angeles`、`Asia/Kolkata`、`Australia/Lord_Howe`、`Pacific/Chatham` 下均通过。 |
| 7 | **并发访问安全** | 当 Swift 应用持续捕获和分析，且 `dayflow-cli` 同时读取时，Go 连续读取 1 小时。`SQLITE_BUSY` 为零、损坏为零，CLI 不受影响。 |

以及一项 CI 门禁：

```bash
CGO_ENABLED=0 go build ./... && CGO_ENABLED=0 go test ./internal/...
```

必须在 Linux 上通过。如果未通过，则 [05 §10.5](05-native-bridge.md#完全不使用-cgo) 中的“无 cgo 核心”前提不成立，需要重新审视 [07](07-testing-strategy.md) 中的测试策略。

## 14.5 建议顺序

每个步骤都会产出下一步所需的内容。

| 步骤 | 工作 | 为何安排在此处 |
|-----:|------|----------|
| 1 | `internal/timeutil` + fixtures | 零依赖，而且*所有内容*都依赖凌晨 4 点的边界。建立 fixture 格式。 |
| 2 | `Anonymize.swift`，生成五个数据库 | 任何 storage 工作开始前都需要这些数据库。立即暴露引用完整性约束。 |
| 3 | `internal/storage/db.go` + `schema.go` | 回答 M-1（WAL）和 DC-1（schema no-op）——本任务中风险最高的两个未知项。 |
| 4 | `internal/domain` + `storage` 读取路径 | 大部分机械性工作，此时已建立在经过验证的基础之上。 |
| 5 | `internal/settings` plist + categories | 最可能成为阻塞项。应在 differ 需要它之前完成，而不是之后。 |
| 6 | `internal/analysis/idle.go` + `batcher.go` | 纯函数；fixtures 已采用步骤 1 建立的格式。 |
| 7 | `internal/insight/timeline.go` | 实现 CLI 输出一致性所必需。 |
| 8 | `cmd/dayflow-compat` 差分 runner | 将所有部分连接起来；成为 CI 门禁。 |
| 9 | 1 小时并发浸泡测试 | 最后执行，因为它需要其他所有部分均正常工作。 |

步骤 3 必须先于步骤 4，这是关键的顺序安排。如果 `modernc.org/sqlite` 在存在活动外部 writer 的 WAL 环境下行为异常，就必须在针对它编写 3,000 行 repository 代码之前得知。

步骤 5 必须先于步骤 8，这是第二项关键顺序。`colorCategories` 是一个包含已编码 `Date` 和 `UUID` 值的二进制 plist；如果它无法被顺利解码，CLI 一致性检查就无法通过——`categories` 是参与差分比较的命令之一。

## 14.6 并行探索：Wails 外壳可行性

并发执行。由一名工程师负责，**严格限制在一周内完成。**

**问题。**Wails v2 应用程序能否在没有窗口的情况下作为常驻托盘的后台 agent 运行，并托管 Sparkle？

**交付物。**一个一次性 repository 加一份书面结论。不是生产代码。

**检查项。**

| # | 检查项 |
|---|-------|
| 1 | Wails 应用启动，并显示一个包含 Vue “hello”的窗口 |
| 2 | 关闭窗口**不会**终止进程 |
| 3 | 窗口关闭 10 分钟后，后台 goroutine 仍在持续 tick |
| 4 | 由子 helper 进程安装的 `NSStatusItem` 在没有打开窗口时仍可工作 |
| 5 | 可以从状态菜单重新打开窗口 |
| 6 | `NSApp.setActivationPolicy(.accessory)` 会移除 Dock 图标，且进程继续存活 |
| 7 | 可以阻止 Cmd+Q |
| 8 | 子 helper 中的 Sparkle 可以检查 appcast 并重新启动宿主 bundle |
| 9 | 嵌套 helper 可在 `.app` 内完成签名和公证；`spctl -a -vvv` 通过 |

**结果。**

- **全部通过** → [风险 C-2](08-risk-analysis.md#c-2wails-无法承载后台代理) 关闭。按计划继续。
- **1–7 通过，8–9 失败** → 外壳没有问题；自动更新需要不同的宿主。只需重新审视 [C-4](08-risk-analysis.md#c-4自动更新连续性)。
- **2–3 或 6 失败** → **在阶段 3 前停止并重新评估。**先评估 Wails v3，然后评估一个托管 WebView 的轻量 ObjC `NSApplication` 外壳。在问题解决之前，不要开始 Vue 重写。

第三种结果正是这项探索需要限制时间并提前执行的原因。在阶段 3 才发现这一问题，意味着要在完成项目中最大的一笔投入后才发现它。

## 14.7 本任务刻意不回答的问题

明确列出这些问题，以免将本任务的完成误认为取得了超出实际范围的进展：

| 待解决问题 | 解决阶段 |
|---------------|------------|
| Wails 能否托管后台 agent？ | 并行探索 |
| helper 是否继承 TCC 和 Keychain identity？ | 阶段 1 |
| IPC 帧解码对缩略图条而言是否足够快？ | 阶段 2 |
| Vue 重写是否能控制在合理预算内？ | 阶段 3 |
| Go providers 能否生成等效的 LLM 结果？ | 阶段 4 shadow mode |
| helper 生成的 HEVC 是否与 Swift 生成的 HEVC 一致？ | 阶段 5 |
| Sparkle 能否将 Go build 交付给现有用户？ | 阶段 6 |

本任务*确实*会建立所有这些问题共同依赖的基础：一种可证明与已发布应用所用数据表示完全一致的 Dayflow 数据 Go 表示，以及在移植过程中持续证明这种一致性的差分测试机制。
