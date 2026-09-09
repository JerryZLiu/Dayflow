# Daygo

**简体中文** · [English](README.en.md)

Daygo 是一款面向 macOS 的隐私优先、本地优先工作日志。它定时采集屏幕活动，使用用户选择的 AI 服务理解工作内容，并将结果整理为可检索的每日时间线、站会摘要和复盘记录。

> **项目状态：**Daygo 正在重构为 Go Core + Wails + Vue。仓库目前仍包含继承自 Dayflow 的 Swift 生产版本，它是迁移期间的参考实现和回退路径。新的 Go 版本尚未达到公开安装条件。

## 为什么做 Daygo

普通时间追踪工具通常只能判断哪个应用处于前台。Daygo 希望保留工作的真实上下文：你在构建什么、调查什么、讨论什么，以及审查什么。

- 无需手动启停计时器的自动活动时间线
- 每日总结与站会内容整理
- 每周回顾与分心活动分析
- 基于工作历史的自然语言问答
- 本地优先存储与可配置的数据保留策略
- 由用户选择本地或云端 AI provider

## 隐私模型

隐私是架构约束，而不是可选模式：

- 录制、时间线和数据库默认保存在本机。
- 只有发送给用户明确配置的 AI provider 时，屏幕数据才可以离开设备。
- 可以使用本地模型，让分析过程完全留在设备上。
- 被屏蔽的应用会从采集中过滤；必要时使用脱敏占位帧。
- 分析和崩溃报告必须由用户主动选择加入，且不得包含屏幕内容、窗口标题、文件路径、凭据或 LLM payload。

旧版应用的数据目录为：

```text
~/Library/Application Support/Dayflow/
```

迁移期间会刻意保留该路径，以兼容已有用户数据。项目更名不等于立即迁移 bundle identifier、Keychain service 或数据目录。

## 重构架构

```text
Vue 3 + TypeScript
        ↓ Wails bindings
Go Core
  ├── 存储与设置
  ├── 分析与 AI providers
  ├── 时间线、每日与每周洞察
  └── 生命周期编排
        ↓ 带版本的 NDJSON / Unix socket
Swift helper
  └── ScreenCaptureKit、AVFoundation、TCC、Keychain、状态栏、Sparkle
```

Go 负责可移植的业务逻辑，并在切换完成后成为 SQLite 的唯一写入方。Swift 只保留 Apple framework 和 macOS 身份约束所需的原生适配。

迁移采用渐进方式：先建立兼容 fixtures，再交付只读 Go 查看器，对派生结果进行差分验证，最后才转移分析与捕获所有权。完整设计、风险、测试策略和阶段门禁见[迁移计划](docs/plan/README.md)。

## 当前仓库结构

```text
cmd/                        Go 命令入口（后续阶段落盘）
internal/                   Go Core（后续阶段落盘）
frontend/                   Vue/Wails 前端（后续阶段落盘）
native/darwin/              macOS Swift helper（后续阶段落盘）
testdata/                   匿名兼容性 fixtures（阶段 0 落盘）
docs/plan/                  Go/Wails/Vue 重构设计
legacy/dayflow/             当前 Swift 参考应用
legacy/dayflow-cli/         当前只读 Swift CLI
legacy/unlinked-tests/      未加入 Xcode target 的历史测试
scripts/                    当前应用的构建和发布脚本
```

`docs/plan/` 中描述的 Go 目录和接口属于目标状态，不保证当前已经存在。`legacy/` 只用于迁移期对照与回退，新业务代码不得写入其中。

## 构建当前参考版本

环境要求：

- macOS 14 或更高版本
- Xcode 16 或更高版本
- 运行时授予“屏幕与系统音频录制”权限

```bash
git clone https://github.com/Jwz-git/Dayflow.git
cd Dayflow
open legacy/dayflow/Dayflow.xcodeproj
```

也可以使用命令行构建：

```bash
xcodebuild -project legacy/dayflow/Dayflow.xcodeproj \
  -scheme Dayflow \
  -configuration Debug build
```

本地构建会读取被 Git 忽略的 `legacy/dayflow/Config/LocalSecrets.xcconfig`。需要时请从示例文件复制并填写本地配置，绝不要提交 API Key 或其他凭据。

## 测试

```bash
xcodebuild -project legacy/dayflow/Dayflow.xcodeproj \
  -scheme Dayflow \
  -destination 'platform=macOS' test

cd legacy/dayflow-cli
swift build
swift run dayflow status
```

Go module 落盘后会在此补充 Go 构建命令。在此之前，迁移计划中的命令是阶段完成标准，不代表仓库当前已经具备对应构建入口。

## 参与贡献

实现工作应遵循分阶段迁移方案，并保持现有数据库、CLI、隐私、捕获、更新和 macOS 身份契约。开始修改前请阅读 [AGENTS.md](AGENTS.md)。

计划进行较大改动时，请先创建 Issue，并说明改动所属的迁移阶段及其验证门禁。

## 许可证

Daygo 使用 [MIT License](LICENSE)。
