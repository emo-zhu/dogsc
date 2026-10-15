# DogSC 设计规范

本规范从现有 UI 代码逆向提炼，是后续改动界面的对照基准。所有令牌均已存在，改 UI 时先查这里的语义，不要在视图里硬编码颜色和数值。

令牌定义位于：

- `Sources/DogSCApp/EditorDesignTokens.swift` — 颜色、字阶、间距、圆角、动效
- `Sources/DogSCApp/AppTypography.swift` — 全局字体注册
- `Sources/DogSCApp/RecorderSurfaceStyle.swift` — 录制器/设置共享表面与动效
- `Sources/DogSCApp/EditorWorkspaceSurface.swift` — 舞台背景、选中样式、滚动淡出
- `Sources/DogSCApp/AppLineIcon.swift` — 自绘线稿图标
- `Sources/DogSCApp/AppSettingsComponents.swift` — 设置页 Tile/Island 体系

## 1. 设计原则

1. **媒体保真，chrome 跟随外观**。视频/画面像素永不被重新着色；覆盖在媒体上的控件自带对比背板（`RecorderStyle.mediaOverlay`）。
2. **岛屿隐喻**。每个浮动工具表面共享同一材质：实心填充 + 顶缘高光 + 外描边 + 双层阴影（接触阴影 + 环境阴影）。
3. **圆角描述嵌套角色**，不描述具体屏幕。控件在组内用小圆角，只有脱离工作区的表面用最大圆角。
4. **一套状态水洗全局通用**。hover/open/pressed 对所有控件一致，不做控件级特例。
5. **动效不许弹跳**。关键弹簧 damping 全部为 1；悬停上的可见回弹"reads as a toy"。
6. **强调色纪律**。界面交互统一用铂金（近黑/近白）；橙/红/绿只表达内容身份与录制状态。

## 2. 颜色

所有颜色经 `EditorTheme.adaptive(light:dark:)` 双态注册，切换外观时在屏面板实时更新。

**chrome 墨水体系**是层级的基础：浅色模式为黑、深色模式为白，用不透明度阶梯表达层级（`EditorTheme.chrome(_:)`）。

| 用途 | 令牌 | 值（浅色 / 深色） |
|---|---|---|
| 工作区底 / 舞台 | `backgroundDeep`、`stage` | 0.925 / 0.028（石墨） |
| 面板 / 岛屿面 | `panelSurface` | 0.992 / 0.063 |
| 面板凸起层 | `panelRaised` | 0.955 / 0.10 |
| 分隔 hairline | `chrome(0.06)` | 1pt |
| 控件边框 | `controlBorder`（chrome 0.085） | |
| 组内填充 | `cardFill`（chrome 0.045） | 平铺、无描边 |
| 凹槽轨道 | `controlWell`、`EditorChoiceStyle.track` | chrome 0.05–0.08 |
| 选中水洗 | `selectionWash` / `railSelectionWash` | 黑 7.5% / 白 14% |
| 状态水洗 | `EditorStateWash` | hover 0.07 · open 0.10 · pressed 0.12 |

**文本三阶**（辅助小字必须用完整色值，不许 opacity 凑合）：

| 阶 | 令牌 | 浅 / 深 |
|---|---|---|
| primary | `primaryText` | 0.1 / 0.96 |
| secondary | `secondaryText` | 0.36 / 0.66 |
| tertiary | `tertiaryText` | 0.52 / 0.46 |

**语义色**：

| 名称 | 令牌 | 值 |
|---|---|---|
| 铂金强调 | `platinumAccent` + `onAccent` | 0.12 / 0.97（反色前景） |
| 成功（"活着/开着"） | `success` / `RecorderStyle.mint` | rgb(0.30, 0.85, 0.55) |
| 录制中 | `recording` | rgb(1.0, 0.27, 0.23) |
| 警示琥珀 | `amberAccent` / `amberInk` | rgb(0.95, 0.68, 0.28) |

**岛屿阴影**：`islandOutline`（外缘轮廓）→ `contactShadow`（紧贴工作区的紧阴影）→ `ambientShadow`（浮动岛屿下的宽而淡的衰减）→ `softShadow`（公共柔和阴影）。

## 3. 字体与字阶

- 唯一界面字体：**阿里普惠体 PuHuiTi 3**（55-Regular / 65-Medium / 75-SemiBold），进程内注册；资源缺失回退系统字体。等宽设计（数值/时间码）永远用系统等宽字体。
- 统一入口：`.appUI(size:weight:)` 或 `.appUI(_ textStyle:)`。
- **五档字阶**：10 micro（徽标、坐标轴）→ 11 caption → 12 label → 13 body → 14+ 标题。数值一律 `monospacedDigit`。
- 编辑器具名样式（`EditorTypography`）：panelTitle 15 semibold · sectionTitle 12 semibold · controlLabel/Value 12 · helper 12 · caption 11 medium · eyebrow 11 semibold。

## 4. 几何

**圆角阶梯（`EditorInterfaceRadius`，按嵌套角色）**：

```
compact 8 → control 10 → group 12 → card 14 → tile 18 → floating 20
```

- 设置页 island 26（`SettingsLayout.islandRadius`，内缩 8pt 后 tile 18 保持同心）。
- 录制器胶囊条用 `Capsule`。
- 所有圆角使用 `style: .continuous`。

**间距（`EditorInterfaceSpacing`）**：headingGap 6 · controlGap 8 · inspectorInset / tileInset 14 · sectionGap 16。

**高度（`EditorInterfaceHeight` + 各面板常量）**：compact 30 · selection / action 32 · 录制条 56（模式轮 40、录制钮 44）· 编辑器工具栏 72（压缩后 56）。

**滑块**：轨道 3pt、滑块 14pt 纸色，拖动时浮出铂金胶囊数值（见 `EditorSlider`）。

## 5. 布局

- **编辑器**（`EditorView`）：停靠式四段 —
  工具栏 → 1pt hairline → [舞台（点阵背景 `EditorWorkspaceGrid`）｜右停靠 Inspector 384–432pt] → hairline → 全宽时间线。
  面板相接处只用 hairline，不用阴影分隔。
- **录制器**：透明窗口 + 独立画阴影的浮动岛屿（`RecorderSurface`），56pt 胶囊条布局。
- **设置**：Island（圆角 26）内由 Tile（圆角 18）拼装页面（`SettingsIsland` / `SettingsTile`）。
- **响应式**（`EditorWorkspaceLayout`）：
  - `compression`（0→1，按窗口与屏幕压力计算）统一插值所有 chrome 尺寸；
  - `chromeScale` 1→0.86 整体缩放 chrome（自定义 `EditorChromeScaleLayout`），内容坐标系（预览渲染、时间线文档）永不缩放；
  - 断点：<1320 收纳时间线控件文字、<1120 纯图标；
  - 最小窗口 840×600。

## 6. 动效

统一入口 `SpringMotion`（编辑器）与 `RecorderMotion`（录制器/设置），参数已对齐。

| 名称 | 参数（spring response / damping） | 用途 |
|---|---|---|
| snappy | 0.24 / 1 | 小型即时反馈 |
| interactive | 0.3 / 1 | 控件按压落定 |
| settle | 0.38 / 1 | 选择块、指示器滑移 |
| lift | 0.28 / 1 | 小幅抬升、拖动值胶囊 |
| fluid | 0.45 / 1 | 大面板 |
| gentle | 0.55 / 1 | 工作区重排 |
| hover | easeOut 0.15 | 悬停进入 |

规则：

- **Reduce Motion 开启时所有空间动画置 nil**（hover 退化为 0.01s linear）。
- hover 到达快、离开稍快。
- 文本变化用 crossfade（0.16s easeOut），不缩放字形、不移动基线。
- AppKit 卡片过渡（`RecorderMotion.morphSpring`）与 SwiftUI 共用同一套弹簧参数。

## 7. 图标

- 自绘线稿体系 `AppLineIcon`：**18pt 网格、圆头圆角（round cap/join）、开放轮廓**。
- 单一线重：`strokeWidth = size/12` 钳制在 1.2–1.55；小图标不变细成 hairline，工具栏图标不变重。
- 尺寸档位固定：**12 / 14 / 16 / 18 / 20**（`EditorSymbol` 自动吸附最近档）。
- 调用侧仍写 SF Symbol 名（`EditorSymbol` / `EditorSymbolCatalog` 映射到自绘字形）；映射缺失时回退系统符号。
- 不混用线重：设置页与录制器的小操作图标共用同一体系。

## 8. 组件配方

- **岛屿表面**：实心 fill + 顶缘 0.5pt 渐变高光（`topHighlight`）+ `islandOutline` + contactShadow + ambientShadow。
- **轨道/滑块**（`EditorSlider`）：凹槽轨道 + 浮起滑块（顶缘 bevel + 1pt 投影）；拖动时浮出铂金胶囊数值。
- **浮起选择块**（`EditorRaisedThumb`）：纸面（浅）/ 受光石墨板（深）+ 顶缘 bevel + 1pt 2pt 投影；Inspector 内的当前选择改为任务色平铺（`consolePalette`），无描边无光晕。
- **Tile**（`SettingsTile`）：chrome 0.045 平铺、无描边无阴影；携带状态时染色 0.11（hover 0.15）。
- **滚动边缘淡出**（`EditorScrollEdgeFade`）代替硬裁切；分隔线用 `EditorFadingHairline`（中间实、两端消散）。
- **Popover 内选择**：原生 popover 背景更亮，选中用 `popoverSelectionSurface`，辅助小字用 `popoverSecondaryText`，保证可读性。

## 9. 无障碍

- 自定义手势控件必须提供 `accessibilityLabel` / `accessibilityValue` 与 `accessibilityAdjustableAction` 替代操作。
- 纯装饰元素标记 `accessibilityHidden(true)`。
- 动效尊重系统 Reduce Motion（见第 6 节）。

## 10. 任务色系统（EditorConsole）

Inspector / 画布 / 时间线中的对象按"任务"着色，选中对象永远不止"默认黑"。定义在 `EditorInspectorPalette.swift`，经环境 `consolePalette` 注入——**只**在 Inspector、画布/时间线中选择对象及其控件内生效，其余界面保持安静的铂金外观。

| 任务 | fill（色相） | 覆盖对象 |
|---|---|---|
| 画面 | `frame` 0x5AAEFF 蓝 | 画布、屏幕、主片段、裁切 |
| 开场/贴片 | `opening` 0xFF8550 橙 | 开场动效、马赛克、贴纸 |
| 运镜 | `zoom` 0xFFB830 黄 | 缩放、屏幕运镜 |
| 光标 | `cursor` 0xB5E655 黄绿 | 光标 |
| 摄像头 | `camera` 0xFF6B92 粉 | 摄像头及其运动 |
| 音频 | `audio` 0x3DDBB0 青 | 音频 |
| 字幕 | `subtitle` 0x8F7CF6 紫 | 字幕 |

每个色相是**六角色结构**（`EditorConsolePalette`）：

| 角色 | 用途 | 规则 |
|---|---|---|
| `fill` | 选中滑块、实心条 | 永远配 `ink` 做前景 |
| `stroke` | 线、弧、描边 | 浅色模式取比 fill 更深一档的色 |
| `ink` | fill 上的前景 | 同色相深色调，不用黑（对比 5.6–8.5:1） |
| `soft` / `softInk` | 大面积淡洗（时间线片段）及其文字 | 深 4.5:1，深色模式文字向白提亮至 5.7:1 |
| `text` | 面板上的色相文字 | 浅色用深色版，深色用色相本身 |

规则：**扁平填充，无渐变、无光晕、无染色背景**；滑轨/描边在任务色上下文中改用 `palette.stroke`（如 `EditorSlider`）。

## 11. 键盘焦点（自绘焦点环）

系统焦点效果被禁用（`focusEffectDisabled`），由 `AppControlFocusAppearance.swift` 全权接管：

- 焦点环 = **1.5pt `chrome(0.40)` 内嵌描边，形状与控件匹配**（`appButtonKeyboardFocus(in:)` / `appKeyboardFocus(in:)`）。
- **只在键盘导航模式显示**：`AppKeyboardFocusVisibility` 只监听导航键（Tab、方向键、空格）触发显示，任何鼠标按下立即隐藏——指针点击不留焦点环。
- `appControlFocusAppearance()` 应用于每个应用拥有的 presentation **根视图**，不逐个 label 应用；文本编辑、响应链、无障碍保持原生。
- 焦点控件自动滚动到可视区（`appKeyboardFocusScrollTarget`）。

## 12. 按钮配方

- **主操作**（`EditorPrimaryPillButtonStyle`）：全窗口唯一实心动作，用任务蓝 `EditorConsole.frame.fill` 而非黑板；前景用 `frame.ink`（深海军蓝）；hover 白 12% 提亮 + fill 0.35 光晕，press 0.97 缩放 + 0.82 透明度；禁用一律 0.4 透明度。
- **工具栏图标钮**（`EditorToolbarIconSurface`）：30×30 圆形热区，16pt 线稿，`secondaryText` 色；激活态 `selectionWash` 圆形底。
- **工具栏文字控件**（`EditorToolbarControlSurface`）：高 30 胶囊，12pt medium，激活态 `selectionWash`。
- **工具栏分隔**（`EditorToolbarDivider`）：1×16 hairline，左右 6pt。
- **软凸起按钮**（`EditorSoftRaisedButtonStyle`）：安静胶囊，仅播放持有主墨水填充。
- **原生操作钮**（`RecorderNativeActionButton`）：录制器内 AppKit 级按钮，44×44 圆形红录制钮等。
- 标题栏高度 46pt（`EditorChromeMetrics.titleBarHeight`）。

## 13. 对话框（AppDialog）

定义在 `AppDialog.swift`。文件选择器、macOS 权限提示保留系统 UI，不走应用对话框。

- **决策卡**（`AppDialogCard`）：圆角 28，宽 360，左对齐；"决策直说"——问题是什么、作用于什么、答案有哪些，无图标砖、无内嵌框。
- 答案是 pill 按钮；**多于两个时堆叠，重要的在前**。
- **Return 永不选中破坏性动作**：默认动作 = primary，否则 cancel。
- 输入必填时（`requiresInput`），空白输入禁用对应动作。

## 14. 本地化

- 界面语言支持简体中文 / English，设置切换**即时生效**。
- 源码字面量写中文，经 `appLocalized(_:)` 包裹输出；SwiftUI 环境注入 `locale`。
- `AppLocalization` 维护单一不可变语言快照，SwiftUI 与原生（AppKit）控件共用；原生窗口标题经 `appLocalizeWindowTitle` 用 key 绑定。
- 用户创建的项目名等用户数据**不进**翻译 key（`AppWindowLocalization` 只跟踪应用显式提供的标题）。

---

工程与开发规范（架构分层、并发、构建、提交、决策编号追溯）见仓库根目录的 [AGENTS.md](../AGENTS.md)。


