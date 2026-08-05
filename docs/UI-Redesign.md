# KeysMirror 界面重构设计文档

版本 v1.3 · 2026-08-01 · 状态：**已评审通过，全阶段实施 + 落地后一轮自查修复**

> v1.1 变更（依据评审意见）
> 1. **映射与宏不合并**，保持两个独立列表（v1.3 里进一步收紧：宏改走独立窗口，见下）
> 2. Inspector **即时保存**确认采纳（见 6.3）
> 3. **新增游戏内 HUD**：目标 app 前台时在其窗口内叠加状态 + 最近 10 条日志（见 6.8）
> 4. P0–P5 全部实施
>
> v1.2（尺寸规范校准）
> 5. **最小字号 13pt、最小命中区 32×32**（见 4.4 / 4.6）；游戏画面上的浮层单独一档豁免
> 6. 位置指示器**只画点、不画文字标签**——标签要么小到违规，要么大到盖住它标记的按钮
> 7. ~~键位总览~~ 相关尺寸调整（该功能已在 v1.3 删除，历史记录见下）
>
> **v1.3（落地后自查，见 12.1）**——本节之前的正文是分阶段实施过程中写就的，
> 与当前实现有出入的地方，一律以本节为准：
> 8. **删除「键位总览」分段**：用户认为多余且干扰布局。触发冲突改由 Inspector 保存时的
>    「⌃⇧K 已被宏『连点』占用」提示解决，不再需要一个专门的可视化页面（见 12.1 #1）
> 9. **宏编辑器从 Inspector 挪到独立窗口**（`MacroEditorWindowController`）：
>    侧栏宽度无论怎么排都装不下一个宏的七八步 × 每步四组控件；映射仍在 Inspector 里（见 6.3 / 12.1）
> 10. 宏步骤的拖拽排序（`.onMove`）在 v1.3 里替换为**卡片 + 上下箭头**：卡片放进
>     `List` 会导致行手势吃掉展开点击，且 ScrollView 嵌 List 本身是错误结构（见 12.1 #5/#6/#7）
> 11. 搜索改用内联常驻的 `SearchField` 组件，而不是 `.searchable`——后者在工具栏变窄时会被
>     系统折叠到看不见，搜索又是高频操作
> 12. 头栏是**自绘的**（不是系统 `.toolbar`）：系统工具栏项会随侧栏折叠重新分配位置，
>     且系统侧栏开关和当时新加的 Inspector 开关图标几乎一样，混在一起分不清（见 12.1 顶部按钮乱跳的记录）
> 13. **全局不使用材质 / 毛玻璃**（`.ultraThinMaterial`、`.bar` 等一律不用），也不用
>     `.opacity()` 做常驻半透明——层级改靠 `Theme.Palette.blend()` 混出的不透明色区分（见 4.5）
> 14. 撤销 / 重做入口在头栏「更多」菜单里，不再单独占一块工具栏位置

目标读者：本项目的实现者。文档只描述界面 / 交互 / 动效层，**不改动**输入拦截、点击投递、坐标换算、宏执行等已验证的核心逻辑（`KeyInterceptor` / `ClickSimulator` / `CoordinateConverter` / `MacroRunner` / `WindowLocator`）。

**读法提示**：第 1–11 节按阶段（P0–P5）实施顺序写成，保留下来是因为里面的取舍理由仍然成立；
但其中提到「键位总览」「宏在 Inspector 里」「`.searchable`」「系统 Toolbar」「拖拽排序」的具体描述
**已被 v1.3 取代**，实现请以第 12 节「落地后自查」和上面的 v1.3 变更列表为准。

---

## 1. 现状盘点与问题诊断

当前界面由 7 个 SwiftUI 文件构成，功能齐全但形态是「功能堆叠」而非「产品设计」：

| 界面 | 位置 | 主要问题 |
| --- | --- | --- |
| 配置主窗 | [ConfigurationWindow.swift](../KeysMirror/Views/ConfigurationWindow.swift) | 860×560 的 `NavigationSplitView`，详情页里塞了 header 卡 + overlay 卡 + 4 段 segmented tab（映射/宏/触发记录/运行日志），信息密度失衡：**调试用的日志和配置平级**，首屏就把用户按在最不常用的东西前面 |
| 映射 / 宏列表 | [MappingListView.swift](../KeysMirror/Views/MappingListView.swift) | 行内直接放「编辑」「删除」两个文字按钮，40+ 条映射时视觉噪音极大；删除**无二次确认、无撤销**；没有搜索、排序、批量操作 |
| 映射编辑器 | [MappingEditorView.swift](../KeysMirror/Views/MappingEditorView.swift) | 520×400 固定尺寸模态 sheet。录制位置时要「隐藏配置窗 → 切到目标 app → 点击 → 切回来」，全程只有一行灰色小字反馈，**用户在目标 app 里完全看不到自己处于录制态** |
| 宏编辑器 | [MacroEditorView.swift](../KeysMirror/Views/MacroEditorView.swift) | 620×680 固定尺寸，步骤行里挤了延迟数值 + 单位 + 连击数 + stepper + 来源选择 + 坐标 + 漂移开关 + 漂移值 + 3 个图标按钮 ≈ 11 个控件；**一行装不下**，且步骤只能靠上下箭头逐格移动，不能拖拽 |
| 位置指示器 | [MappingIndicatorView.swift](../KeysMirror/Views/MappingIndicatorView.swift) | 硬编码红圈 + 黑底白字，无出入场动画，overlay 刷新时整体重建会闪 |
| 录制 HUD | [RecordingHUDController.swift](../KeysMirror/Views/RecordingHUDController.swift) | 新加的，只有静态文本，没有节拍反馈（用户不确定这一下点击到底记上没有） |
| 菜单栏 | [StatusBarController.swift](../KeysMirror/Views/StatusBarController.swift) | 纯 `NSMenu`；宏运行中只能看到一行「停止运行的宏（xxx）」，没有进度、没有快速启停常用宏 |

**跨界面的共性问题**

1. **没有设计系统**：`Color.gray.opacity(0.06)` / `0.08` / `0.12` / `0.18` 散落各处，圆角 4/6/8/10/12 五种并存，间距 2/3/4/6/8/10/12/14/16/18/20/24 十二种并存。
2. **零动效**：全 App 没有一处 `withAnimation`。列表增删是瞬间跳变，sheet 是系统默认的粗暴弹出，状态切换（启用/禁用、宏运行中）没有过渡。
3. **反馈弱**：保存成功、导入成功走 `Alert` 打断；录制失败只在 sheet 里留一行小字；点击真的发出去了只有菜单栏图标闪 0.25s 绿。
4. **模态成本高**：所有编辑都是 sheet，编辑第 3 条映射时看不到第 2 条，无法对照；关掉 sheet 才能看列表。
5. **不可撤销**：删除 profile / 映射 / 宏全部即时生效且不可逆。

---

## 2. 设计目标与原则

**目标**（按优先级）

1. **降低录制心智负担** — 新建一条映射从「打开 sheet → 录触发 → 录位置（跨 app 往返）→ 命名 → 保存」5 步降到「按 N → 按键 → 点位置」3 步，且全程在目标 app 里有明确的视觉状态。
2. **让配置可读** — 40 条映射时也能一眼找到目标：搜索、分组、键位可视化。
3. **让状态可感知** — 映射生效中 / 宏第 3/50 次循环 / 权限缺失，都要在不打开主窗的情况下可见。
4. **可逆** — 破坏性操作一律可撤销。

**原则**

- **原生优先**：用 macOS 惯用模式（Inspector、`.searchable`、`.contextMenu`、Undo、Toolbar），不发明控件。用户的直觉迁移成本 = 0。
- **动效服务于因果**：每个动画都必须回答「什么变成了什么」。禁止装饰性动画；全部尊重 `accessibilityReduceMotion`。
- **模态最小化**：只有「选择应用」和「破坏性确认」用模态，编辑一律 Inspector 内联。
- **渐进披露**：常用项（触发键、位置、启用）平铺；高级项（漂移、拦截原始按键、参考尺寸）折叠在「高级」里。
- **不回归**：重构不得降低现有能力（导入导出、日志、权限修复、缩放跟随徽标都要有归宿）。

---

## 3. 信息架构

```
菜单栏（常驻）
├── 状态胶囊：图标 + 当前 profile 名（可选）
└── 弹出面板（新，SwiftUI，替代纯 NSMenu）
    ├── 总开关 + 全局 hotkey 提示
    ├── 当前前台 app 的 profile 摘要（映射 N / 宏 M）
    ├── 宏快捷启停（列出该 profile 的宏，运行中显示进度）
    └── 打开配置 / 权限 / 退出

主窗（v1.3 现状：1180×720，可缩放，最小 1000×640；自绘头栏，不用系统 `.toolbar`）
├── 头栏（固定不动）：侧栏开关 · 标题 · ＋添加应用 · 「更多」菜单（撤销/重做、导入导出、全局热键、诊断、引导）
├── 左：应用侧栏（自绘 `ScrollView` 列表，非系统 `.sidebar` 样式，避免毛玻璃与双重选中高亮）
├── 中：内容区（分段：映射 | 宏），各自独立列表；~~键位总览~~ 已删（v1.3，用户认为多余且扰乱布局）
└── 右：Inspector（**只承载映射**）。宏改走独立窗口 `MacroEditorWindowController`，
      理由见 12.1 #13——一个宏七八步 × 每步四组控件，任何侧栏宽度都装不下

游戏内 HUD（新，目标 app 前台时叠加在其窗口内）
├── 状态区：映射开关 · profile · 宏运行进度 · 最近触发
└── 日志区：最近 10 条

底部状态条（新）：权限状态 · 拦截器开关 · 最近一次触发 · 「诊断」入口

诊断窗（独立窗口，⌘⇧D）
├── 触发记录
└── 运行日志（导出 / Finder / 清空）
```

**关键结构变更**

| 变更 | 理由 |
| --- | --- |
| 「触发记录」「运行日志」从主 tab 移到独立诊断窗 | 它们是调试面板，不该和配置抢首屏。保留全部功能与快捷入口 |
| 「映射」与「宏」**保持两个独立列表**（评审决议） | 二者概念差异大（单点 vs 序列），混排会稀释各自的信息密度。它们共享触发器空间（`hasDuplicateTrigger` 已跨类型查重），「这个键被谁占了」曾计划用一个「键位总览」分段回答，**v1.3 已删除该分段**（用户反馈：多余且干扰布局）——冲突改由保存时的内联提示承担：「⌃⇧K 已被宏『连点』占用」 |
| 宏改走**独立窗口**，不再共用 Inspector（v1.3） | 一个宏七八步、每步展开四组控件，Inspector 固定 380pt 宽怎么排都是挤的；独立窗口给足空间，也允许同时开着主窗对照 |
| 编辑 sheet → 右侧 Inspector | 编辑时仍能看到列表其余条目；关闭 Inspector 不丢状态 |
| profile 的 overlay 设置从详情页卡片移入 Inspector 的「应用设置」 | 详情区首屏留给动作列表 |

---

## 4. 设计语言（Design Tokens）

新建 `KeysMirror/Design/Theme.swift`，所有数值只在此定义，**视图里禁止再出现魔法数字**。

### 4.1 间距

`Spacing`: `xs=4` `sm=8` `md=12` `lg=16` `xl=24` `xxl=32`
栅格：所有间距必须是 4 的倍数。列表行内边距 `sm/md`，卡片内边距 `md/lg`，区块间距 `lg`。

### 4.2 圆角

`Radius`: `sm=6`（徽标、输入框） `md=10`（列表行、卡片） `lg=14`（面板、HUD） `pill=999`

### 4.3 颜色

全部走语义色，自动适配深浅色：

| Token | 值 | 用途 |
| --- | --- | --- |
| `surface` | `Color(nsColor: .controlBackgroundColor)` | 卡片 / 面板底 |
| `panel` | `Color(nsColor: .windowBackgroundColor)` | 头栏 / 侧栏 / Inspector / 状态条 / 浮层（**实色，不用材质**） |
| `separator` | `Color(nsColor: .separatorColor)` | 分隔线 |
| `accent` | `.accentColor` | 主操作、选中态 |
| `success` | `.green` | 已启用、缩放跟随、触发成功 |
| `warning` | `.orange` | 权限缺失、旧版映射 |
| `danger` | `.red` | 删除、录制中、宏运行中 |
| `keyCap` | `.primary.opacity(0.08)` + 1px `separator` 描边 | 键帽背景 |

状态底色统一用 `色.opacity(0.12)`，文字用色本身，**不再手写 0.06/0.08/0.18 三种灰**。

### 4.4 字体

**硬性下限：13pt。** macOS 语义字体里 `.caption/.caption2/.footnote` = 10pt、`.subheadline` = 11pt、
`.callout` = 12pt，**全部低于下限，一律禁用**。

因为 13 已是下限（只能往上），信息层级不再靠字号区分，改为靠**字重 + 颜色**：
主要 medium/primary → 次要 regular/secondary → 再次 tertiary。

| Token | 规格 | 用途 |
| --- | --- | --- |
| `title` | 17 semibold | 窗口 / 面板标题 |
| `section` | 13 semibold | 区块标题 |
| `label` | 13 medium | 列表行主标题、强调项 |
| `body` | 13 regular | 正文 |
| `caption` | 13 regular + `.secondary` | 辅助说明（**只降色不降号**） |
| `mono` / `monoCaption` | 13 monospaced | 坐标、快捷键、日志 |
| `keyCap` | 13 medium rounded | 键帽 |

所有数字展示加 `.monospacedDigit()`（坐标、计数、循环进度跳动时不抖）。

**唯一豁免：叠加在游戏画面上的浮层**（游戏内 HUD、录制 HUD、位置指示器）走单独的
`OverlayTypography`（12 / 11 / 10）。理由：它们不是交互界面，首要目标是尽量少遮挡游戏画面；
按 13pt 排，10 行日志的 HUD 高度会从约 220pt 涨到约 310pt。此档**不得**用于主窗、Inspector、
诊断窗、菜单栏面板。

### 4.6 尺寸与命中区

| Token | 值 | 说明 |
| --- | --- | --- |
| `minHitTarget` | **32×32** | 任何可点元素的命中区下限：图标按钮、状态点、开关、菜单、分段控件 |
| `iconVisual` | 15 | 图标的视觉尺寸（与命中区解耦：图标 15，命中区 32） |
| `rowHeight` | 44 | 列表行高 = 32 命中区 + 上下留白 |
| `listRowMinHeight` | 44 | 侧栏行、选择器行的最小高度 |
| `headerHeight` | 56 | 主窗头栏 |

- 所有图标操作统一走 `IconButton` 组件（32×32 + hover 背景反馈），不要再手写 `Button { Image(...) }`
- `.controlSize(.small)`（约 20pt 高）**禁用**；输入框 / 步进器需要 `.controlSize(.large)` 才够 32
- 视觉小、命中区大：状态点直径 10pt，但外层是 32×32 的按钮；列表行整行双击 = 编辑

### 4.5 材质与阴影

- **禁止使用材质 / 毛玻璃**（`.ultraThinMaterial`、`.bar`、`.regularMaterial` 等）。
  半透明层叠在游戏画面与深色背景上会显脏、文字对比度不稳，而且每一层都要额外合成。
  层级一律用三档实色底 + 1px `separator` 区分：`surface`（内容）/ `panel`（面板与浮层）/ `keyCapFill`（键帽）。
- 浮层（录制 HUD、游戏内 HUD、菜单栏面板、Toast）：`panel` 实色 + `Radius.lg` + 1px 描边 + 阴影
- 阴影只用一档：`.shadow(color: .black.opacity(0.18), radius: 12, y: 4)`，仅浮层使用；列表行、卡片一律无阴影

---

## 5. 组件库

新建 `KeysMirror/Views/Components/`，每个组件独立文件、可 Preview：

| 组件 | 说明 |
| --- | --- |
| `KeyCapView` | 把 `⌃⇧K` 渲染成分离的键帽（当前是等宽文本）。鼠标触发渲染成鼠标图形 + 按键号。列表、Inspector、HUD 共用 |
| `ActionRow` | 动作列表行：类型图标 · 名称 · 键帽 · 摘要 · 状态点。hover 才浮出操作按钮 |
| `StatusDot` | 启用/禁用/运行中三态小圆点，运行中带呼吸动画 |
| `Badge` | 胶囊徽标（「缩放跟随」「v1.2 旧映射」「宏」「连击 ×2」） |
| `Card` | `surface` + `Radius.md` + `Spacing.md` 内边距的容器 |
| `SectionHeader` | 区块标题 + 右侧操作位 |
| `RecordButton` | 录制按钮的三态机（待命 / 等待输入（脉冲）/ 已捕获（成功打勾一闪）） |
| `PositionCanvas` | **新**：窗口比例画布，红点可拖动微调坐标（见 6.4） |
| `Toast` | 右下角轻提示，替代成功类 `Alert`；支持「撤销」按钮 |
| `EmptyStateView` | 保留现有，补插画位与主操作按钮 |

---

## 6. 关键界面设计

### 6.1 主窗骨架

> 下图是 v1.3 现状（原方案里的系统 `.toolbar`、`.searchable`、键位总览分段均已替换/删除，见文首 v1.3 变更列表）。

```
┌────────────────────────────────────────────────────────────────┐
│[⧉]  KeysMirror                                        [+]  [⋯] │  ← 自绘头栏，位置固定
├───────────────┬──────────────────────────────┬─────────────────┤
│ 应用           │ [映射 12] [宏 3]  [🔍搜索…]     │ Inspector（仅映射）│
│ ● 星穹铁道 12   │ ┌──────────────────────────┐ │ ┌─────────────┐ │
│ ○ 阴阳师 3     │ │ ● [Q]    攻击    (412,880) │ │ │ 名称 攻击    │ │
│ ● Safari 1    │ │ ● [E]    技能    (520,880) │ │ │ 触发 [Q] 录制│ │
│               │ │ ● [⇧][Space] 闪避 (700,910)│ │ │ 位置 ┌─────┐│ │
│ [+][-]        │ └──────────────────────────┘ │ │      │画布 ●││ │
├───────────────┴──────────────────────────────┴─────────────────┤
│ ✅ 辅助功能已授权 · 映射启用中 (⌃⇧K) · 最近触发 Q → 攻击 12:04:31 · 诊断│
└────────────────────────────────────────────────────────────────┘
```

宏点「编辑」不出现在右侧 Inspector，而是弹出一扇独立窗口（`MacroEditorWindowController`，620×780）。

- 侧栏行：状态点 + 应用图标（`NSRunningApplication.icon`）+ 名称 + 动作数。**应用未运行时图标去饱和 + 「未运行」灰字**，解决「点录制才发现 app 没开」。自绘 `ScrollView` 而非系统 `.sidebar`（避免毛玻璃、避免系统选中高亮和自绘高亮叠加）；底部 `[+][-]` 管理配置。
- 内容区分段：`映射 (N)` / `宏 (M)`。两个列表结构一致（同一 `ActionRow` 组件的两种配置），但**各自独立、互不混排**；~~键位总览~~ 已删。
- 搜索：内容区顶部常驻的 `SearchField` 组件（不是 `.searchable`——那个在工具栏变窄时会被系统折叠到看不见）。行 hover 才显示「编辑 · 复制 · 删除」图标按钮；`.contextMenu` 提供全部操作；整行双击 = 编辑。
- 头栏是自绘的固定布局（红绿灯让位 72pt → 侧栏开关 → 标题 → ＋添加应用 → 「更多」菜单），不用系统 `.toolbar`——后者会随侧栏折叠重新分配按钮位置。撤销 / 重做在「更多」菜单里。
- 底部状态条常驻，权限缺失时整条变 `warning` 底色并给「去授权」按钮。

### 6.2 动作列表行

```
[图标] 名称                     [⌃][⇧][K]      (412, 880)  [缩放跟随]  ●
 ⌨/▶   宏则显示: 3 步 × 无限循环
```

- 左图标：映射 `keyboard`，宏 `play.rectangle`；宏运行中换成呼吸的红点。
- 键帽用 `KeyCapView`。
- 右侧状态点点击即切换启用（比现在的 switch 更省空间），tooltip 说明。
- 禁用态：整行 `opacity(0.5)` + 名称加删除线？→ **不加删除线**，只降透明度并把状态点变空心。

### 6.3 Inspector（替代两个编辑 sheet）

选中动作时右栏显示，分区渐进披露：

**映射**
1. 名称（自动从触发键生成占位）
2. 触发 — `KeyCapView` + `RecordButton`
3. 位置 — `PositionCanvas` + 坐标数字（可直接键入）
4. 高级（默认折叠）— 拦截原始按键 / 参考尺寸（只读展示 + 「重录以启用缩放跟随」）

**宏**
1. 名称 / 触发 / 重复次数（单次 · N 次 · 无限，用分段控件而不是 toggle + stepper）
2. 步骤列表 — **可拖拽排序**（`.onMove`），行折叠：默认只显示「① 延迟 1.2s → (412,880) ×2」，点开才露出延迟单位、连击、漂移、来源切换
3. 录制条 — 「开始录制」大按钮 + 已录步骤数
4. 高级 — 拦截原始按键

**保存策略变更（已确认采纳）**：Inspector 内**改动即时生效**（`MappingStore` 本来就每次写盘），不再有「保存/取消」按钮；破坏性变更（换触发键导致冲突）走内联红字校验 + 阻止写入。这样消除了「编辑到一半关掉 sheet 丢失」的问题。

> 触发器冲突提示要从现在的「已存在同触发的映射或宏，请更换按键」升级为**指名道姓**：「⌃⇧K 已被宏『连点』占用」并给「跳转到该动作」按钮。

### 6.4 录制体验（本次重构的核心）

现状：点「录制位置」→ 主窗消失 → 用户在目标 app 里裸奔 → 点一下 → 主窗回来。中间态零反馈。

**新流程**

1. 点击录制 → 主窗**淡出并缩到 92%**（0.18s），而不是瞬间消失，用户知道它去哪了
2. 目标 app 前台化，屏幕顶部落下 **录制 HUD**（已有 `RecordingHUDController`，升级为）：
   - 标题：`正在录制 · 崩坏：星穹铁道`
   - 副行：`点击窗口任意位置记录坐标 · Esc 取消`
   - 序列录制时：`已记录 7 次点击`，**每记录一次数字放大回弹 + 波纹**，解决「这一下到底记上没」
3. 目标窗口边缘绘制 **2px 呼吸描边**（复用 `OverlayController` 的 panel 机制），明确「点在这个窗口里才算数」；点到窗口外时 HUD 抖动一下并提示「点在 XX 窗口内才会被记录」
4. 完成 → HUD 收起 → 主窗淡入回来，**新录入的行以高亮闪一下**（`accent.opacity(0.25)` → 透明，0.6s）定位视线

**`PositionCanvas`**：录完之后不必再跑一趟目标 app 微调。画布按目标窗口宽高比绘制线框（有屏幕录制权限时可选贴窗口截图，见第 12 节），红点可拖动，拖动时实时显示坐标；同 profile 的其他映射以半透明灰点显示，**避免两个映射点重叠**。

### 6.5 Overlay 指示器

- 圆点：外圈描边 + 内芯填充，尺寸 14pt（现 12）
- **不显示文字标签**（v1.2 决议）：标签在 13pt 下会盖住它标记的游戏按钮，10pt 又违反字号下限。
  映射叫什么在配置窗里看，游戏里只需要知道「点在哪」；鼠标悬停有 tooltip 兜底
- **触发时反馈**：被触发的映射点扩散一圈 0.35s 的水波并回弹（现在只有菜单栏闪一下，游戏里根本看不见）
- 入场/出场 `opacity + scale(0.9→1)` 0.2s，避免 overlay 重建时的硬闪
- 位置指示器整体透明度仍受 `profile.overlayOpacity` 控制

### 6.6 菜单栏

`NSMenu` → `NSPopover` + SwiftUI 面板（保留 `NSMenu` 作为右键降级路径）：

- 顶部：总开关（大 toggle）+ 全局 hotkey 键帽
- 中部：当前前台 app 卡片（图标 + 名称 + 「映射 12 · 宏 3」+ 「本 app 未配置 → 添加」）
- 宏区：每个宏一行，右侧播放/停止按钮；**运行中显示 `12/50` 进度与环形进度条**（`MacroRunner` 目前只发状态变更通知，需补一个轻量进度 `@Published`，见 10.3）
- 图标状态：待命 / 已禁用 / 无权限 / 宏运行中（红色呼吸，替代现在的静态红）

### 6.7 游戏内 HUD（新增需求）

目标：**不切出游戏就能知道 KeysMirror 在做什么**。目标 app 前台时，在其窗口内叠加一块半透明面板，显示运行状态与最近 10 条日志。

```
┌─ 崩坏：星穹铁道 窗口 ──────────────────────────┐
│                              ┌───────────────┐│
│                              │● 映射启用 ⌃⇧K  ││  ← 状态区
│                              │▶ 连点 12/50 ▓▓░││
│                              │最近 Q → 攻击   ││
│                              ├───────────────┤│
│                              │12:04:31 Q→攻击 ││  ← 日志区
│                              │12:04:30 宏步骤2││     最近 10 条
│                              │12:04:29 宏启动 ││     新条目从顶部滑入
│                              │…（共 10 行）    ││
│         [游戏画面]             └───────────────┘│
│                                                │
│   ● 攻击      ● 技能        ← 已有的位置指示器    │
└────────────────────────────────────────────────┘
```

**行为规约**

| 项 | 规则 |
| --- | --- |
| 显示条件 | 前台 app 有 profile、profile 启用、`profile.showHUD == true`。切走立即隐藏（复用 `OverlayController` 的前台/frame 逻辑） |
| 定位 | 跟随目标窗口 frame，贴四角之一（默认右上），距边 `Spacing.md`；窗口移动/缩放实时跟随（AXObserver 推送 + 现有看门狗） |
| 尺寸 | 宽 280（窗口宽 < 700 时压到 220），高度自适应，最高 = 窗口高的 45% |
| 穿透 | `ignoresMouseEvents = true`、`nonactivatingPanel`、不进入 `Cmd-Tab`；**绝不能抢焦点或吃掉游戏的点击** |
| 日志内容 | 默认只显示 `ACTION / WARN / ERROR`（TRACE/INFO 太吵，会刷屏），可在设置切「全部」。取 `AppLogger.logs` 前 10 条 |
| 状态区 | 拦截器开关 + 全局 hotkey · 当前 profile 名 · 宏运行进度（`12/50` 或 `∞`）+ 进度条 · 最近一次触发（键位 → 名称） |
| 折叠 | 支持「仅状态条」紧凑模式（只留一行），给不想被日志遮挡的用户 |
| 快捷键 | 全局 `⌃⇧H` 在 完整 / 紧凑 / 隐藏 三态间循环（可在设置里改或关掉） |
| 性能 | 日志区**节流刷新**：`AppLogger.logs` 变化经 100ms 合并后再驱动 UI，避免高频触发时每条日志都重建视图；隐藏时不订阅 |

**视觉**：`.ultraThinMaterial` + `Radius.lg` + 整体透明度受新的 `profile.hudOpacity` 控制（独立于 `overlayOpacity`，因为指示器要淡、日志要看清）。日志按级别着色（ACTION 常规、WARN orange、ERROR red），时间戳等宽 `.tertiary`。

**动效**：新日志从顶部 8pt 滑入 + 淡入（`Motion.standard`），旧行下移，第 10 行淡出；宏进度条 `trim` 平滑推进；触发时状态区「最近触发」行闪一下 accent 底色。`reduceMotion` 下全部退化为直接替换。

**数据模型增量**（`AppProfile`，全部 `decodeIfPresent` 向后兼容）

```swift
var showHUD: Bool = true
var hudOpacity: Double = 0.85
var hudCorner: HUDCorner = .topTrailing   // topLeading / topTrailing / bottomLeading / bottomTrailing
var hudMode: HUDMode = .full              // full / compact / hidden
var hudLogFilter: HUDLogFilter = .actionsOnly  // actionsOnly / all
```

**实现**：新建 `Views/InGameHUD/InGameHUDController.swift`（panel 生命周期，与 `OverlayController` 并列，共用前台与 frame 事件）+ `InGameHUDView.swift`（SwiftUI 内容）+ `InGameHUDModel.swift`（节流后的日志/状态快照，纯逻辑可单测）。

> 注意：`OverlayController` 当前把 panel 铺满整个窗口且 `ignoresMouseEvents`；HUD 用**独立 panel**（不复用同一个），这样指示器与 HUD 的透明度、显示条件、刷新频率可以各自独立，也避免日志刷新导致整张指示器重建。

### 6.8 首次运行引导

三步全屏卡片（仅首次 + 可从菜单重开）：授予辅助功能 → 添加第一个应用 → 录制第一条映射（引导直接走 6.4 的流程）。现状是把权限横幅塞在详情页顶部，新用户看不懂要干嘛。

---

## 7. 动效规范

### 7.1 Token（`Theme.Motion`）

部署目标是 macOS 13，`.snappy` / `.smooth` 等语义动画需 14+，因此显式定义：

| Token | 定义 | 用途 |
| --- | --- | --- |
| `quick` | `.easeOut(duration: 0.12)` | hover、按下、色彩变化 |
| `standard` | `.spring(response: 0.32, dampingFraction: 0.86)` | 列表增删、面板展开、选中态 |
| `emphasis` | `.spring(response: 0.42, dampingFraction: 0.72)` | 录制捕获成功、触发水波（允许轻微回弹） |
| `ambient` | `.easeInOut(duration: 1.1).repeatForever(autoreverses: true)` | 录制中 / 宏运行中的呼吸 |

**统一规则**

- 时长上限 0.45s，超过就显得慢
- 位移不超过 12pt，缩放不超过 ±8%
- 所有 `repeatForever` 动画在 `reduceMotion` 下改为静态高对比样式（呼吸 → 常亮）
- 列表内容变化统一 `.animation(Motion.standard, value: items)`；不要给整棵子树套隐式动画

### 7.2 动效清单

| # | 触发 | 表现 | 属性 | Token |
| --- | --- | --- | --- | --- |
| 1 | 新增动作 | 从上方 8pt 滑入 + 淡入 | `offset/opacity` | standard |
| 2 | 删除动作 | 向右滑出 + 淡出 + 行高收拢 | `offset/opacity/height` | standard |
| 3 | 拖拽排序步骤 | 拾起放大 1.03 + 阴影，其余行让位 | `scale/shadow` | standard |
| 4 | 切换启用 | 状态点实心↔空心 + 行透明度 | `fill/opacity` | quick |
| 5 | 选中动作 | Inspector 内容交叉淡入（不整体重建） | `opacity` | standard |
| 6 | 进入录制 | 主窗 `scale 1→0.92` + 淡出；HUD 从顶部落下 | `scale/opacity/offset` | standard |
| 7 | 捕获一次点击 | HUD 计数 `scale 1→1.25→1` + 水波 | `scale` | emphasis |
| 8 | 录制中 | HUD 红点 + 目标窗描边呼吸 | `opacity 0.4↔1` | ambient |
| 9 | 录制完成 | HUD 收起，新行高亮闪 0.6s | `background` | standard |
| 10 | 映射触发 | overlay 对应点水波扩散 + 回弹 | `scale/opacity` | emphasis |
| 11 | 宏运行 | 列表行左侧红点呼吸 + 菜单栏环形进度 | `opacity/trim` | ambient |
| 12 | Toast | 右下角滑入 8pt + 淡入，3s 后淡出 | `offset/opacity` | standard |
| 13 | 权限恢复 | 状态条 warning→success 交叉淡变 | `color` | standard |
| 14 | 折叠「高级」 | 高度展开 + 内容淡入 | `height/opacity` | standard |
| 15 | 冲突校验失败 | 触发键区域左右抖动 3 次（±4pt） | `offset` | quick |

---

## 8. 键盘操作与无障碍

**全键盘可达**（当前几乎不可用）：

| 快捷键 | 动作 |
| --- | --- |
| `⌘N` | 新建映射（列表焦点在宏筛选时新建宏） |
| `⌘⇧N` | 新建宏 |
| `⌘F` | 搜索动作 |
| `⌘⌫` | 删除选中（带撤销 Toast） |
| `⌘D` | 复制选中动作 |
| `⌘R` | 录制选中动作的位置 |
| `⌘⌥I` | 显示/隐藏 Inspector |
| `⌘⇧D` | 诊断窗 |
| `Esc` | 取消当前录制 |
| `⌘Z` | 撤销（删除 / 排序 / 启停） |

**无障碍**

- 所有图标按钮补 `.accessibilityLabel`；状态点补 `.accessibilityValue("已启用")`
- 状态不能只靠颜色：启用=实心点、禁用=空心点、运行中=实心+呼吸（形状本身可辨）
- 对比度 ≥ 4.5:1，含 overlay 标签（改材质底就是为此）
- 尊重 `accessibilityReduceMotion`；因为全程实色、无材质，「减弱透明度」下无需额外分支
- 支持动态字体（除等宽坐标外不写死 size）

---

## 9. 撤销与破坏性操作

| 操作 | 现状 | 新方案 |
| --- | --- | --- |
| 删除动作 | 立即删，无提示 | 立即删 + Toast「已删除『攻击』 [撤销]」，5s 内可恢复 |
| 删除 profile | 立即删 | 确认弹窗（列出将丢失的 N 条映射 / M 个宏）+ 撤销 |
| 导入合并 | 直接覆盖同 bundleId | 预览差异（新增 X / 覆盖 Y）后确认 |
| 清空日志 / 触发记录 | 立即清 | 保持立即（无价值数据），但改为 Toast 提示 |

实现：`UndoCoordinator`（`Views/Main/UndoCoordinator.swift`）持有一个 `UndoManager`，所有破坏性 store 操作都走
`perform(name:do:undo:)`；Toast 上的「撤销」与 `⌘Z` 调用**同一个** `undo()`，因此不会出现「点了 Toast 撤销、
再按 ⌘Z 又恢复一次」的重复。撤销时自动登记反向操作，`⇧⌘Z` 重做。

> 注意：本 App 是 `LSUIElement` 菜单栏程序，**没有应用主菜单**，`⌘Z` 不会经由「编辑 ▸ 撤销」走响应链。
> 因此用局部 `NSEvent` 监听接管：仅配置窗口存在时安装，且第一响应者是文本控件时放行，
> 让输入框保留自己的打字撤销。工具栏左侧另有撤销 / 重做按钮（tooltip 显示动作名）。

删除的条目按**原索引**放回（`insertMapping/insertMacro/restoreProfile(at:)`），列表顺序不跳动；
重复撤销不会产生副本。

**覆盖范围**

| 层级 | 操作 |
| --- | --- |
| 列表 / 配置 | 删除映射 · 删除宏 · 删除配置 · 复制映射 · 复制宏 · 启停映射 / 宏 / 配置 |
| 宏步骤（Inspector 内） | 新增 · 删除 · 拖拽排序 · 复制 · 录制序列结果 · 录制步骤位置 · 字段编辑 |
| 映射字段（Inspector 内） | 改名 · 拦截开关 · 录制触发 · 录制位置 · 画布拖动微调 |

**输入合并**：字段级编辑不是一次输入一条记录——那样撤销栈会被每个字符淹没。
统一策略是停手 600ms 后把「编辑前 → 编辑后」合并成一条（宏步骤走
`MacroEditorViewModel.startStepsUndoTracking`，映射走 `MappingEditorViewModel.startUndoTracking`）。
**录制**这类离散动作则立刻单独压栈，不等防抖。

映射侧以整份 `EditableMapping` 快照为粒度，因为「录制触发」会同时改触发器和自动填的名称——
逐字段登记会把一次操作拆成两条撤销。

Inspector 级记录都以 view model 作为 `owner` 登记，编辑器关闭时用 `removeActions(for:)` 一并清掉——
否则会撤销到一个已经不在屏幕上的编辑器状态，用户看不到任何变化却改了数据。列表级记录不受影响。

---

## 10. 技术实现方案

### 10.1 文件结构

```
Views/
├── Design/Theme.swift              # 新：所有 token
├── Components/                     # 新：第 5 节组件
├── Main/
│   ├── MainWindow.swift            # 由 ConfigurationWindow 拆出的骨架
│   ├── AppSidebar.swift
│   ├── MappingListView.swift       # 重写：ActionRow 组件化
│   ├── MacroListView.swift         # 重写：同上，与映射列表并列而非合并
│   ├── KeyOccupancyView.swift      # 新：键位总览
│   ├── StatusBar.swift             # 新：底部状态条
│   └── Inspector/
│       ├── InspectorView.swift
│       ├── MappingInspector.swift  # 复用 MappingEditorViewModel
│       └── MacroInspector.swift    # 复用 MacroEditorViewModel
├── Recording/
│   ├── RecordingHUDController.swift  # 升级现有
│   └── TargetWindowHighlight.swift   # 新：目标窗描边
├── Diagnostics/DiagnosticsWindow.swift  # 触发记录 + 日志搬家
├── InGameHUD/                      # 新：6.7 游戏内 HUD
│   ├── InGameHUDController.swift
│   ├── InGameHUDView.swift
│   └── InGameHUDModel.swift        # 节流 + 状态快照，可单测
├── MenuBar/MenuBarPanel.swift      # 新：SwiftUI popover
└── Onboarding/OnboardingView.swift # 新
```

**保留不动**：`Services/` 全部、`Models/` 全部（除 10.3 的一个 `@Published`）、`MacroEditorViewModel` / `MappingEditorViewModel` 的业务方法（只改绑定方式，录制/校验/保存逻辑原样复用，已有单测继续有效）。

### 10.2 状态管理

- 主窗状态收敛到一个 `@MainActor final class MainWindowModel: ObservableObject`：`selectedProfileID` / `section`（映射/宏/键位总览）/ `mappingSelection` / `macroSelection` / `searchText` / `inspectorVisible`。现在这些散在 `ConfigurationWindow` 的 8 个 `@State` 里。
- 两个列表各自持有自己的选中集合，**不共用**；Inspector 依据当前分段决定渲染 `MappingInspector` 还是 `MacroInspector`。
- 仅在需要「跨类型」的地方（键位总览、冲突提示）用一个轻量只读投影：
  ```swift
  struct TriggerOccupancy: Hashable {  // 由 profile 计算得出，不持久化
      let trigger: TriggerKey          // 归一化后的触发器
      let ownerKind: OwnerKind         // .mapping / .macro
      let ownerId: UUID
      let ownerLabel: String
  }
  ```
  纯函数（排序、搜索匹配、占用表构建、冲突查找）→ **可单测**，按现有测试风格补 `TriggerOccupancyTests` / `ActionListFilterTests`。
- Undo：`MappingStore` 增加 `func delete(_ action: ActionItem, from: AppProfile, undo: UndoManager?)`，注册反向操作。

### 10.3 需要的非 UI 改动（最小）

1. `MacroRunner` 增加 `@Published private(set) var progress: (iteration: Int, total: Int)?`，供菜单栏与列表显示进度。当前 `run()` 已有 `iteration`，只需在每轮开始写入（注意：无限循环时 `total = nil`，UI 显示 `∞`）。
2. `MappingStore` 增加 Undo 支持（10.2）。
3. `AppResolver` 暴露 profile 对应的 `NSRunningApplication.icon` 与「是否在运行」，供侧栏显示。
4. 触发反馈：`KeyInterceptor` 命中时发一条带 `mappingId` 的通知，`OverlayController` 据此播放水波（现在只有 `StatusBarController.flashActivity()`）。
5. `AppProfile` 增加 5 个 HUD 字段（6.7），全部 `decodeIfPresent` 兜底，导入导出自动带上。
6. `GlobalHotkeyManager` 目前只支持**一个** hotkey（固定 `hotKeyID = 1`）：改造成按 id 注册多个，供 `⌃⇧H` 切换 HUD 使用。
7. HUD 日志节流：不改 `AppLogger`，在 `InGameHUDModel` 里订阅 `$logs` 后 `.throttle(0.1s)`，仅 HUD 可见时订阅。

### 10.4 兼容性

- 数据格式 **零变更**：`mappings.json` / `.playmap` / 导入导出全部不动
- macOS 13 兼容：不用 `.snappy`、`Table` 的新 API、`inspector()` modifier（macOS 14+）→ Inspector 用 `HSplitView` / 手写栏位实现
- 键盘快捷键用 `.keyboardShortcut`，macOS 13 可用

---

## 11. 实施计划

> **实施状态（2026-08-01）：P0–P5 全部已实现并落地到 `/Applications/KeysMirror.app`**，
> 118 项单测全绿（原 97 + 新增 21）。游戏内 HUD 已在 PlayCover 的《阴阳师》窗口上实机验证。
> 已知偏差：HUD 上方额外加了 24pt 标题栏补偿（AX frame 含标题栏，否则会压在标题栏上）。

| 阶段 | 内容 | 产出 | 预估 |
| --- | --- | --- | --- |
| **P0 地基** | `Theme.swift` + 组件库（KeyCapView / Card / Badge / StatusDot / Toast / EmptyState）；现有界面换用 token（视觉先统一，结构不动） | 可见的一致性提升，零功能风险 | 1 天 |
| **P1 主窗重构** | 新骨架 + 侧栏 + 映射/宏两个列表 + 键位总览 + Inspector（即时保存）；日志/触发记录搬去诊断窗；搜索、多选、右键菜单、快捷键 | 主要交互改善 | 2–3 天 |
| **P2 录制体验** | 录制 HUD 升级、目标窗描边、`PositionCanvas`、录制流程动效 | 核心差异化 | 2 天 |
| **P3 游戏内 HUD** | 6.7 全部：状态区 + 10 条日志、`AppProfile` 新字段、节流刷新、`⌃⇧H` 三态、设置项 | 新增需求 | 1–2 天 |
| **P4 动效与反馈** | 第 7.2 节 15 条清单、Toast、Undo、overlay 水波 | 打磨 | 1–2 天 |
| **P5 菜单栏与引导** | SwiftUI popover 面板、宏进度、首次运行引导 | 完整度 | 1–2 天 |

每阶段独立可交付、可回滚；P0 完成即可发一版。全部阶段实施，顺序如上。

**验收清单（每阶段）**

- [ ] `xcodebuild test` 全绿（现有 97 项 + 新增）
- [ ] 深色 / 浅色模式各截图核对
- [ ] 「减弱动态效果」「减弱透明度」下无异常
- [ ] 全键盘走通「新建映射 → 录制 → 删除 → 撤销」
- [ ] 40 条映射的 profile 下滚动无掉帧
- [ ] 旧 `mappings.json` 与 `.playmap` 正常读取

---

## 12. 风险与开放问题

**风险**

1. **`PositionCanvas` 的窗口截图**需要「屏幕录制」权限——这是本 App 目前**不需要**的权限，为了一个便利功能要求它可能劝退用户。
   → 默认实现为**线框画布（零新权限）**；截图作为可选增强，仅在用户主动点「显示窗口预览」时才请求。
2. **Inspector 即时保存**改变了心智模型（不再有「取消」）。缓解：所有修改进 Undo 栈，`⌘Z` 可回退。
3. 菜单栏 popover 替代 `NSMenu` 后，`NSMenu` 的键盘导航和辅助功能是免费的，popover 需要自己实现——保留右键出 `NSMenu` 作为降级。
4. 工作量总计约 7–10 天，建议按阶段发布而非一次性大爆炸。

5. **游戏内 HUD 遮挡**：HUD 贴在窗口角上必然盖住一小块游戏画面。缓解：可切四角、紧凑模式只留一行、`⌃⇧H` 一键隐藏。
   ~~透明度可调~~ 已在 v1.3 删除（`hudOpacity` 字段整个去掉，HUD 固定不透明，见 12.1 #3）——
   没有 UI 暴露过这个滑杆，一个默认值 0.85、谁都改不了的「透明度可调」名不副实。
6. **全屏游戏**：PlayCover 游戏进入原生全屏时，panel 需 `.canJoinAllSpaces + .fullScreenAuxiliary`（`OverlayController` 已验证该组合可用），HUD 沿用同一套。

**评审已决**

1. ~~映射与宏合并~~ → **不合并**，保持两个独立列表。~~冲突可见性由「键位总览」承担~~ ——
   该分段已在 v1.3 删除（用户认为多余且干扰布局），冲突改由 Inspector 保存时报错承担，见 12.1 #1。
2. Inspector **即时保存**，配 `⌘Z` 撤销。
3. 新增**游戏内 HUD**（6.7），含状态区与最近 10 条日志。
4. **P0–P5 全部实施**。
5. 窗口截图预览：仍按可选增强处理，默认线框画布，不引入屏幕录制权限。

---

## 12.1 落地后自查（v1.3，2026-08-01）

P0–P5 上线后按用户反馈做了两轮修复，另外做过一次系统性自查（不等用户报告，主动比对代码与本文档、
本文档与自己定的规则）。按类型归档，供以后同类问题参考。

**用户直接反馈修的问题**

| # | 问题 | 根因 | 修法 |
| --- | --- | --- | --- |
| 1 | 键位总览「多余且没有必要的干扰，还会扰乱页面布局」 | — | 整块删除 `KeyOccupancyView.swift`；内容区分段从「映射 / 宏 / 键位总览」减到「映射 / 宏」 |
| 2 | 打开宏布局错乱 | 就是 #1 的连带症状：从键位总览点键跳转时分段切到「宏」但内容区还在渲染键盘图 | 随 #1 一并解决 |
| 3 | 输入重复次数会自动切换「单次/N 次/无限」，显示还会跳 | `repeatMode` 是从 `repeatCountText <= 1` **反推**出来的派生状态，敲个 1 分段就跟着跳 | 改成 `MacroEditorViewModel.repeatMode` 独立 `@Published` 存储，次数只管次数 |
| 4 | 点「录制点击序列」不激活目标 App 窗口 | 双重原因：`NSRunningApplication.activate(options:)` macOS 14+ 已废弃且常返回 false；且紧挨着 `NSApp.deactivate()` 调用时前台切换会被系统合并掉 | 按系统版本走新 API + `NSWorkspace.openApplication` 兜底；延后 0.15s 再激活；重试到目标真的成为前台（而不是只看 API 返回值） |
| 5/6/7 | 宏步骤点不开、「高级」点不开、要求卡片式横向布局 | 步骤放在 `List` 里，`List` 的行手势吃掉了展开点击；`ScrollView` 里嵌可滚动 `List` 本身是错误结构 | 步骤列表从 `List` 改成 `VStack` 卡片，整张卡片可点展开；拖拽排序换成展开后的上下箭头 |
| 8 | 「侧边栏的玻璃效果需要删除」 | `.listStyle(.sidebar)` 会自动插一层 `NSVisualEffectView`（毛玻璃） | 侧栏改 `.plain` + `scrollContentBackground(.hidden)`，选中态自绘 |
| 9 | 侧边栏底部空白区域 | `VStack` 8pt 间距叠上 `List` 自带的底部留白 | 间距改 0，列表和 +/− 之间只留一条分隔线 |
| 10 | 头栏「两个侧边栏开关」、点开关后按钮跑到最右 | 系统 `.toolbar` 项会随侧栏折叠重新分配位置；系统侧栏开关图标和自定义 Inspector 开关图标几乎一样 | 整个 `.toolbar` 撤掉，换成自绘固定头栏（红绿灯让位 72pt + 侧栏开关 + 标题 + 右侧按钮），位置写死不随任何面板开合而动 |
| 11 | 侧边栏选中双重高亮 | 换成自绘头栏后仍用 `List(selection:)`：系统自己画一条通栏蓝，叠上自绘的圆角浅底 | 侧栏改 `ScrollView + LazyVStack`，选中态完全自绘，只剩一层 |
| 12 | 宏配置里的开关要放弹窗底部常驻 | 「拦截原始按键」折在「高级」里，每次调宏都要点开才看得到 | 移到宏窗口的常驻底栏，跟随开关状态换说明文字 |
| 13 | 「侧边栏地步不要用这么大的空间」「宏塞侧栏做不好」 | 宏一个七八步 × 每步四组控件，任何侧栏宽度都装不下 | 宏编辑整体挪到独立窗口（`MacroEditorWindowController`），Inspector 只留映射 |
| 14 | 「完全删掉 liquid glass 效果」「完全去除所有透明效果」 | 材质与 `.opacity()` 散落在面板底、卡片 hover、HUD、日志渐淡等处 | 见下方系统性自查 #3 |

**主动自查发现并修的问题**（未经用户反馈，比对代码与规则后自己找出来的）

| 分类 | # | 问题 | 修法 |
| --- | --- | --- | --- |
| Bug | 1 | 同一个宏可能被两扇窗口同时编辑：新建宏窗口的 key 是随机草稿 id，保存后不重绑，随后从列表点「编辑」同一条宏会另开一扇，两个 view model 互相覆盖 | `MacroEditorViewModel` 新增 `onFirstCommit` 回调，草稿第一次自动保存拿到真实 id 时触发；`MacroEditorWindowController` 收到回调把窗口从 draft key 重绑到 `macro-<id>`。回归测试见 `MacroEditorWindowControllerTests.testDraftRebindsToRealMacroIdOnFirstCommit` |
| Bug | 2 | 录制结束后把所有开着的宏窗口一起拽到最前 | `hideForRecording()`/`restoreFromRecording()` 只记住"当前 key window 那一扇"，不再对 `windows.values` 全体操作。回归测试见 `testHideForRecordingOnlyTouchesKeyWindow` |
| Bug | 3 | 游戏内 HUD 仍是半透明（`hudOpacity` 默认 0.85，日志行按 index 渐淡） | 没有任何 UI 暴露过这个滑杆，字段整个删除（`AppProfile` 不再有 `hudOpacity`，`decodeIfPresent` 兜底旧数据）；日志渐淡效果去掉，改为纯色 |
| Bug | 4 | `PanelActionCard` hover 态写了 `.opacity(isHovering ? 1.6 : 1)`——opacity 上限是 1，1.6 会被钳到 1，hover 视觉上没有任何反馈 | 改用 `Theme.Palette.blend()` 混更浓的不透明色，而不是叠透明度 |
| 规范 | 1 | 视图里散落约 30 处魔法数字，违反本文档 4 节自定的规则 | 新增 `Theme.Metrics`：`statusDotSize` / `sidebarWidth` / `inspectorWidth` / `dividerHeight` / `trafficLightGutter` / `keyCapColumnWidth` / `stepIndexBadgeSize` 等；各调用点改用 token |
| 规范 | 2 | 为方便截图加的 `--open-config` 启动参数留在了正式代码里 | 删除 |
| 规范 | 3 | 三处死代码：`KeyCapView.Size` 两档渲染已完全相同、`MacroEditorViewModel.isInfinite` 兼容 shim 零调用、`MainWindowModel.inspectorVisible` 只写不读、两个 view model 的 `save()` 兼容 shim 零调用 | 全部删除，`KeyCapView` 的 `size:` 参数一并去掉 |
| 规范 | 4 | `Theme.Typography.mono` 与 `monoCaption` 13pt 下限后渲染完全相同，两个 token 只会让后来者去找不存在的差异 | 合并为 `mono` 一个 |

**技术债 / 未覆盖**：`overlayOpacity`（位置指示器的透明度，默认 0.5）是 v1.2 之前就有的字段，目前也没有 UI 能改它——同类问题，但不在本轮反馈范围内，未动，留给下一轮。
