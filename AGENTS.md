# AGENTS.md

给在本仓库工作的 AI 助手与新成员的工程规范。UI 设计规范见 [docs/DESIGN.md](docs/DESIGN.md)。

## 项目概览

DogSC：macOS 原生录屏 + 轻量剪辑工具（SwiftUI + AppKit，无 UI 第三方依赖）。

- Swift 6 严格并发（`swiftLanguageModes: [.v6]`）
- 最低 macOS 14，仅 Apple Silicon
- 唯一依赖：Sparkle（自动更新）

## 架构分层

两个 target（见 `Package.swift`）：

- `Sources/RecorderCore` — 无 UI 的领域库：时间线模型、导出策略、投影/运镜计算、校验。核心算法与数据模型放这里，不 import UI。
- `Sources/DogSCApp` — 可执行目标：界面、采集、渲染管线、系统集成。

文件按功能域前缀分层，单文件单主题：

| 前缀 | 域 |
|---|---|
| `Editor*` | 编辑器界面 |
| `Recorder*` | 录制器界面 |
| `App*` | 跨界面共享（设置、本地化、对话框、焦点） |
| `Shared*` | 采集/预览/导出共享渲染件 |
| `Capture*` | 采集设备与会话 |

状态约定：会话级 UI 状态用 `@StateObject`（如 `EditorStore`、`EditorPlaybackController`）；项目持久化走 `ProjectStore` / `ProjectDocument`；跨界面共享走显式单例（`AppLocalization.shared`、`RecorderPopoverPresenter.shared`）。

## 构建与运行

- **完整构建必须走 `bash build-app.sh`**（需 `DOGSC_SIGNING_IDENTITY`）。裸 `swift build` 的产物不是可用 App——缺 bundle、字体、Sparkle、签名。
- 开发版标识 `cn.laogou.dogsc.dev`（`DogSC Dev.app`），与正式版的偏好、系统权限、更新通道完全隔离；改 `InfoPlist.strings` 时不得覆盖此身份。
- 改动验证的最小闭环：`swift build` 过编译 → 涉及 UI/采集/导出时用 `build-app.sh` 出包手测。

## 并发约定

- UI 与主线程逻辑用 `@MainActor`。
- 采集/导出/预览管线的跨线程对象用 `final class X: @unchecked Sendable`，内部自管同步，并注释说明锁保护范围——这是显式决策，不是省事。
- 长时操作用 `Task` 并检查 `Task.isCancelled`（参考 `EditorView.performWorkspaceReflow` 的防抖模式）。
- **MainActor 红线**：大文件包（`*.dogscproject`）的移动/删除禁止在 MainActor 执行（APFS 元数据、外置卷、Finder 废纸篓都可能阻塞）——统一走 `ProjectPackageDisposal`。录制期恢复清单的写入同理，全部经 `RecordingRecoveryJournal`（actor）离开主线程；该 actor 同时排序心跳与终态写入，防止在途心跳覆盖 `complete` / `failed` / `discarded` 清单。

## 文件事务与崩溃安全

导出与产出文件遵循"绝不留半成品"的事务模式（见 `ExportFileTransaction.swift`）：

- 先写临时文件（`.dogsc-export-*.tmp`），成功后原子 promote 到最终路径（`replaceItemAt` / `moveItem`）。
- 发布前必须做输入/输出路径碰撞校验（`collides(outputURL:inputURLs:)`），防止导出覆盖源素材。
- 新增产出文件的代码路径（导出、字幕、恢复清单等）沿用该模式，不要直接写最终路径。


## 代码风格与注释

- 注释写**设计意图与权衡**（为什么），不写代码在做什么；注释用英文。
- 文件头部用 doc comment 声明职责边界与不变量。
- **决策编号追溯**：关键设计决策在注释中标注编号（`EDT-xxx`、`FOC-xxx`），跨提交可检索。新决策沿用该格式并保持编号唯一。
- 遵循文件内既有风格；不做顺手重构，不引入编辑器全文件重排（格式化）噪音。

## UI 改动

- **先读 [docs/DESIGN.md](docs/DESIGN.md)**，使用既有令牌（`EditorTheme`、`EditorTypography`、`EditorInterfaceSpacing`、`EditorInterfaceRadius`、`SpringMotion` 等），禁止在视图里硬编码颜色与数值。
- 状态水洗、圆角、动效参数是全局一致的体系，不为单个控件开特例。
- 新增图标优先复用 `EditorSymbolCatalog` 线稿体系；无对应字形时才用系统符号。

## 本地化

- 界面语言：简体中文（源字面量）/ English，两份 `Localizable.strings` 必须同步更新。
- 原生（AppKit）窗口标题经 `appLocalizeWindowTitle` 绑定 key；用户创建的数据（如项目名）不进翻译 key。
- 语言切换即时生效，勿在启动路径外缓存解析结果（参考 `AppLocalization` 的快照机制）。

## 版本与提交

- 提交信息：英文祈使句单行（如 `Refine editor and settings UI, motion, and interactions`）。
- 发布走 git tag（`v0.1.x`），tag 触发 `.github/workflows/release.yml`；每个版本的 release notes 放 `.github/release-notes/`。

## 测试现状

- 仓库无单元测试 target。改动 `RecorderCore` 算法（时间线、导出、投影）时必须手动验证时间线与导出路径；不虚报"已验证"。
