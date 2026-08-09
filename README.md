<div align="center">

<img src="https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple" />
<img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift" />
<img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" />
<img src="https://img.shields.io/github/v/release/framecy/KeysMirror?style=flat-square&label=latest" />

# KeysMirror

**按键，即点击。**

将任意键盘快捷键映射为应用窗口内的指定位置点击。光标停在原地，无需修改目标应用，游戏技能与工具栏按钮一键直达。

[下载最新版本](https://github.com/framecy/KeysMirror/releases/latest) · [查看落地页](https://framecy.github.io/KeysMirror) · [反馈问题](https://github.com/framecy/KeysMirror/issues)

</div>

---

## 为什么需要 KeysMirror？

很多应用——尤其是移植自 iOS 的游戏——没有提供键盘快捷键支持。你只能反复将手从键盘移到鼠标去点击技能、道具或按钮。KeysMirror 解决的就是这个问题：**让键盘代替鼠标，精准点击窗口内的任意位置。**

```
按下 Q  →  在 (1047, 853) 触发左键点击  →  技能释放  →  光标位置不变
```

---

## 功能特性

| 功能 | 说明 |
|---|---|
| **按键 → 点击映射** | 支持 ⌘ ⇧ ⌥ ⌃ Fn 等任意修饰键组合 |
| **光标静止** | 模拟点击时鼠标指针停在原地。原生 macOS 应用完全不触碰光标；iOS-on-Mac 游戏受系统限制，点击瞬间指针会被隐藏约 40ms 再原位恢复（位置不变，但有短暂消失）——详见[已知限制](#已知限制) |
| **鼠标侧键支持** | 右键、侧键均可作为触发器 |
| **可视位置指示器** | 半透明红点实时标记每个映射位置，支持透明度调节 |
| **多应用独立配置** | 各应用拥有独立映射组，随前台切换自动激活 |
| **窗口缩放跟随** | v1.3 起新录制的映射会记录窗口尺寸快照，窗口被放大/缩小后点击位置按比例自动跟随 |
| **文字输入智能保护** | 通过 AX API 检测焦点元素类型，输入控件（聊天框、搜索栏等）获焦时自动静默映射，离焦后即刻恢复 |
| **睡眠唤醒自动恢复** | 合盖重开或屏幕唤醒后，键盘监听自动重建，无需手动重启应用 |
| **逐条映射开关** | v1.4 起每条映射可独立启停，调试时不必删除即可临时禁用 |
| **配置导入导出** | v1.4 起支持导出 JSON 配置（带 schema 版本号），跨设备导入时可选合并或追加 |
| **全局开关快捷键** | v1.4 起可绑定全局 hotkey（默认 ⌃⇧K）一键启用 / 禁用映射 |
| **组合按键宏** | v1.5 新增：一个触发键执行多步点击，每步可设秒/分延迟，按 N 次循环或无限循环；运行中再按触发键随时停止 |
| **iOS-on-Mac 兼容** | 支持通过 Apple Silicon 运行的 iPhone / iPad 游戏 |
| **Chromium 兼容** | 对 Edge、Chrome 等浏览器采用专属投递方案，无副作用 |
| **完全离线** | 不联网，不收集数据，配置存储于本地 |

---

## 系统要求

- **macOS 13.0 Ventura** 或更高版本
- Apple Silicon 或 Intel Mac
- **辅助功能权限**（首次启动时引导授权，仅此一项）

---

## 安装

### 方式一：下载 DMG（推荐）

1. 前往 [Releases](https://github.com/framecy/KeysMirror/releases/latest) 下载最新 `KeysMirror.dmg`
2. 打开 DMG，将 `KeysMirror.app` 拖入 **应用程序** 文件夹
3. 首次启动时，按提示前往 **系统设置 → 隐私与安全性 → 辅助功能** 授权

### 方式二：从源码编译

```bash
git clone https://github.com/framecy/KeysMirror.git
cd KeysMirror
open KeysMirror.xcodeproj
# Xcode → Product → Build (⌘B)
```

---

## 快速上手

### 第一步：添加应用配置

菜单栏图标 → **打开配置** → **添加应用** → 从运行中的应用列表选择目标。

### 第二步：新建映射

点击 **新建映射**，依次完成：

1. **标签名称** — 给这条映射起一个易识别的名字（如"技能1"）
2. **录制触发** — 点击后按下想要绑定的键盘按键或鼠标侧键
3. **录制位置** — 点击后程序切换到目标应用，在目标窗口内**点击一次**想要触发点击的坐标
4. 点击 **保存映射**

### 第三步：使用

切换到目标应用，按下绑定按键，菜单栏图标短暂变绿表示触发成功。

---

## 界面说明

### 状态栏图标

| 图标状态 | 含义 |
|---|---|
| `⌨️` 正常显示 | 映射已启用，正常运行 |
| `⌨️` 变暗 | 映射已手动禁用 |
| 短暂绿色闪烁 | 映射触发成功 |

### 覆盖层指示器

在配置界面为每个应用开启 **显示快捷键指示器** 后，当该应用处于前台时，会在每个映射坐标处叠加显示半透明红点，便于核对位置是否准确。

---

## 权限说明

KeysMirror 仅申请 **辅助功能（Accessibility）** 一项权限，用于：

- 监听全局键盘 / 鼠标事件（拦截触发键）
- 读取目标应用窗口位置（计算绝对点击坐标）
- 向目标应用注入鼠标事件（模拟点击）

**不会访问网络，不读取屏幕内容，不上传任何数据。** 所有配置保存在本地：

```
~/Library/Application Support/KeysMirror/mappings.json
```

---

## 常见问题

**Q：快捷键触发了但点击没效果？**

打开配置 → 运行日志，确认是否出现「执行动作」日志。若已出现说明坐标偏移，建议重新录制映射位置（窗口位置变化后需重新录制）。

**Q：在游戏聊天框打字时，已映射的按键无法正常输入字符？**

KeysMirror 通过 Accessibility API 实时检测目标应用的焦点元素类型。当焦点落在文字输入控件（`AXTextField`、`AXTextArea`、`AXComboBox`、`AXSearchField`）时，键盘映射自动静默，按键原样传递给应用；离开输入框后映射即刻恢复，无需任何手动操作。若遇到极少数 AX 不兼容的应用，可临时通过菜单栏「禁用映射」手动关闭。

**Q：Microsoft Edge / Chrome 映射不生效？**

请确认使用的是最新版本（v1.1+）。旧版本对 Chromium 系应用采用了会导致副作用的投递方案，新版本已专项修复。

**Q：iOS 游戏不生效？**

确认游戏已在 Apple Silicon Mac 上正常运行，并在 KeysMirror 配置中重新录制映射位置。

**Q：Mac 从睡眠唤醒后映射失效？**

macOS 在系统睡眠期间可能销毁 CGEventTap。KeysMirror 已监听屏幕唤醒（`screensDidWakeNotification`）与系统恢复（`didWakeNotification`）通知，唤醒后自动重建键盘拦截，通常无需手动操作。若仍失效，可在菜单栏点击一次「禁用」再「启用」映射来手动触发重建。

**Q：应用窗口移动或调整大小后映射偏了？**

- **移动**：映射坐标以**窗口为参照**，移动窗口时点击位置自动跟随，不需要重新录制。
- **缩放**：v1.3 起新录制的映射会保存当时的窗口尺寸快照，窗口被等比放大/缩小后点击位置按比例换算（适合大多数游戏的等比缩放场景）。
- **旧映射**：v1.2 及以下录制的映射没有窗口尺寸快照，缩放后会偏；在配置中"编辑"并重新"录制位置"即可启用缩放跟随。
- **布局重排**：若窗口内 UI 自身布局发生变化（如全屏/窗口化切换、自适应布局重排），仍需重新录制。

---

## 已知限制

这些是 macOS 事件模型本身的边界，不是待修的 bug。写在这里是为了让你在遇到时知道「就是这样」，而不是以为自己配错了。

### iOS-on-Mac 游戏的点击必须经过系统 session 层

「设计给 iPad」的 App Store 游戏（问道手游、阴阳师等）和 PlayCover 侧载的游戏，它们的触摸事件由系统框架层从 session 级鼠标事件流翻译而来。绕过这一层的 `postToPid` 送进去的事件没人翻译，实测**完全无响应**。所以这类目标只能走 session 投递，并因此带来下面两条代价。

**代价一：点击瞬间光标会短暂消失（约 40ms）。**
Window Server 会按事件携带的坐标去挪指针，我们只能先把指针藏起来、投递完再 warp 回原位。指针的物理位置始终没变，但你会看到它闪一下。40ms 是能稳定触发按帧轮询输入（Unity / UE）的下限附近——再短，游戏可能整个漏掉这次按下。

**代价二：后台点击会把游戏窗口切到前台。**
session 层事件按「点到了谁的窗口」路由，被点到的后台窗口会被系统激活。这一点无法从应用侧阻止（`eventTargetUnixProcessID` 标记实测拦不住）。因此宏的默认策略是**仅在目标处于前台时执行**：目标不在前台就跳过这一步，你切回去它自动续跑。

如果你确实需要「一边干别的一边挂机」，可以在设置里把后台宏策略改成「允许抢焦点」——代价是每跑一步游戏窗口都可能翻到最前面。这个开关默认关闭。

> 原生 macOS 应用不受以上任何一条影响：走 `postToPid`，全程不触碰光标，也不会激活窗口。

### 窗口内 UI 布局重排后需要重新录制

映射记录的是「窗口内的相对位置」。窗口移动、等比缩放都能自动跟随；但如果游戏自身把界面重新排布了（全屏/窗口化切换、自适应布局），原来的坐标就不再指向那个按钮了。

---

## 技术实现

- **事件拦截**：`CGEventTap` 在 `.cgSessionEventTap` 全局监听键盘与鼠标侧键事件；收到 `tapDisabledByTimeout` / `tapDisabledByUserInput` 时自动重建 tap（此类事件底层 CGEvent 指针为 null，已专项处理）
- **睡眠唤醒恢复**：监听 `NSWorkspace.screensDidWakeNotification` 与 `NSWorkspace.didWakeNotification`，唤醒后自动调用 `keyInterceptor.start()` 重建 tap
- **点击模拟**：原生 macOS 应用使用 `CGEvent.postToPid`（绕过 Window Server，全程不触碰光标）；iOS-on-Mac 游戏必须走 `cgSessionEventTap`——该运行时靠订阅 session 级鼠标移动事件流合成 UITouch，`postToPid` 送进去的事件没人翻译，实测完全无响应。因此这条路径只能「冻结光标 → 隐藏 → 投递 → warp 回原位 → 取消隐藏」，指针物理位置不变，但点击瞬间会短暂消失
- **窗口定位**：通过 Accessibility API（`kAXPositionAttribute` / `kAXSizeAttribute`）获取目标窗口实时坐标
- **文字输入检测**：每次键盘事件命中 profile 后，先查询 `kAXFocusedUIElementAttribute` 并读取其 `kAXRoleAttribute`，匹配到 `AXTextField` / `AXTextArea` / `AXComboBox` / `AXSearchField` 时放行按键；AX 查询失败时默认放行映射，保证功能不因权限异常而静默失效
- **日志系统**：通过 `os_log` 写入 Console.app（可用 `log stream` 实时查看），同时追加写入 `~/Library/Caches/KeysMirror/keysmirror.log`（可 `tail -f` 跟踪）；UI 内日志面板支持折叠
- **坐标系**：内部统一使用 AX 坐标（左上原点，Y 向下），与 AppKit 坐标（左下原点）通过 `CoordinateConverter` 互转
- **窗口缩放跟随**：`KeyMapping` 在录制时保存 `referenceWidth/referenceHeight` 窗口尺寸快照，触发时按当前窗口尺寸比例换算偏移；旧版本数据无快照时退化为固定像素偏移

---

## 更新日志

### v1.7.1

**这一版主要在收回 v1.7.0 后台宏许下的、系统其实做不到的承诺，并把闪退防线焊死。**

- **修复**：宏在目标已处于前台时不再屏蔽物理鼠标、也不再重复抢焦点。v1.7.0 对所有宏步一律 `suppressLocalInput` + 点完 `activate`，边玩边跑宏时表现为「鼠标闪 / 顿」和「宏把游戏窗口又激活了一遍」
- **修复**：后台宏还原前台改为 150ms 防抖，并改走 `AppResolver.activate`（新 API + `openApplication` 兜底）。原先每步点完立刻还原，而宏主循环不等点击结束，第 N 步的还原会和第 N+1 步的点击迎面撞上——表现为前台在游戏和用户窗口之间来回横跳；旧的 `activate(options:)` 在 macOS 14+ 还经常静默失败
- **修复**：导入配置不再丢失设置。`importProfiles` 原先逐字段手工构造 `AppProfile`，每新增一个字段就静默漏一个——游戏内 HUD 的四项设置和每应用按压时长都因此在「导出再导入」后被重置。现改为整份复制、只替换 id
- **新增**：后台宏策略开关（菜单栏面板 / 主窗设置菜单），默认**仅前台执行**。iOS-on-Mac 游戏的后台点击必然被 Window Server 切到前台，这是系统限制、应用侧无法阻止（`eventTargetUnixProcessID` 实测拦不住），因此默认不再替用户承担这个代价；需要挂机的可切到「允许后台执行」
- **新增**：每应用可调按压时长（30 / 40 / 60 / 80ms）。这个值同时决定「点得稳不稳」与「光标闪多久」，不同游戏底线不同，40ms 只是共用折中值
- **体验**：光标与点击点距离在 20 点以内时不再隐藏光标。隐藏本身要让指针消失整个按压时长，比那点位移更扎眼——这是「鼠标闪烁」的主要来源
- **工程**：`MainActor.assumeIsolated` 全部替换为 `assumingMainActor`（`Utilities/MainActorAssumption.swift`），修 macOS 26/27 上 `swift_task_isCurrentExecutor` 解引用野指针导致的闪退
- **工程**：崩溃防线门禁（`scripts/verify_crash_guard.sh`）接入 CI 与 Release，本地 / CI / 发版三处共用同一份。源码不得出现 `MainActor.assumeIsolated`，二进制不得出现 `swift_task_isCurrentExecutor`，两项均要求严格为 0。此前这道防线只存在于本机脚本
- **性能**：配置写盘改为 300ms 防抖，拖拽排序 / 连续开关不再每次同步写盘；退出、切换到后台、导入三个时机强制落盘
- **安全**：菜单栏「重置权限」（`tccutil reset`）增加二次确认与失败提示。此前一点即执行且失败静默——用户会以为重置过了，实际根本没成功
- **文档**：README 新增「已知限制」章节，明确 iOS-on-Mac 的两条系统级代价；新增 [docs/RELEASE.md](docs/RELEASE.md) 说明 Developer ID 签名与公证的配置方法（Release 流程在 secrets 配齐时自动启用，未配置则退回 ad-hoc）
- **测试**：179 个测试全过。新增覆盖宏前台/后台分支、`ClickSimulator` completion 回调与光标隐藏阈值、按压时长夹取、写盘防抖、导入字段保全

### v1.7.0
- **界面重构**：全面替换旧的单窗口配置界面（`ConfigurationWindow`/`MappingEditorView`/`MacroEditorView` 已删除），新增独立的主窗口（`MainWindow`/`MainWindowController`）、侧栏 + Inspector 布局（`AppSidebar`/`MappingInspector`/`MacroInspector`）、独立宏编辑窗口（`MacroEditorWindowController`）、统一设计系统（`Theme`）、首次运行引导（`OnboardingView`）、菜单栏下拉面板（`MenuBarPanel`/`MacroMarqueeView`）与诊断窗口（`DiagnosticsWindow`）
- **新增**：录制体验升级——目标窗口描边高亮（`TargetWindowHighlight`）、录制会话状态管理（`RecordingSession`）、录制 HUD 独立化
- **新增**：全局撤销/重做（`UndoCoordinator`），删除映射/宏/Profile 均可 `⌘Z` 撤销
- **新增**：触发键占用可视化（`TriggerOccupancy`），保存时提示按键冲突
- **新增**：启动活跃度审计（`ActivationAuditor`）与宏步骤序列录制器（`MacroSequenceRecorder`）
- **设计规范**：全局不使用材质/毛玻璃与常驻半透明；间距、圆角、字号统一收敛到 `Theme.Metrics` token
- **测试**：新增 Inspector、MainWindow、UndoCoordinator、MacroSequenceRecorder 等测试覆盖（154/154 全过）
- 详见 [docs/UI-Redesign.md](docs/UI-Redesign.md) 完整设计文档与落地后自查记录

### v1.6.7
- **修复**：PlayCover 部分 iOS-on-Mac 应用（如阴阳师 `com.netease.onmyoji`）因 `Info.plist` 缺少 `LSRequiresIPhoneOS` 字段而被误判为原生 Mac App 导致点击无响应。现增加 `DTPlatformName` 及 `UIDeviceFamily` 后备检测
- **构建**：`build.sh` 增加固定自签名证书支持（`KeysMirror Dev`），避免每次重新编译导致的 macOS 辅助功能权限丢失
- **界面**：菜单栏下拉菜单与配置窗口标题栏增加版本号展示
- **宏系统**：宏步骤新增 `driftPercent`（区域随机漂移）支持与完整单元测试覆盖

### v1.6.6
- **修复**：PlayCover 等 iOS-on-Mac 应用点击完全无响应。根因是 iOS-on-Mac 判定只探 `Foo.app/Contents/Info.plist`（macOS 布局），而 PlayCover 安装的是扁平布局（`Info.plist` 在 bundle 根目录）——读不到就退化到 `.ios` 后缀判断，`com.miHoYo.hkrpg` 这类 bundleId 被误判为原生 App 走 `postToPid`，事件投递不到目标。现同时探两种布局
- **修复**：iOS-on-Mac 投递路径重写。① `mouseDown` 前先补一个同点 `mouseMoved`——PlayCover 靠追踪鼠标移动事件流维护指针位置，缺了这步触摸落在旧位置；② `mouseDown`/`mouseUp` 之间加入 50ms 按压时长——按帧轮询输入的目标（Unity/UE）会漏掉零时长按下；③ 整段序列改在后台串行队列上同步执行——光标 disassociate 期间让出 run loop 会导致按下/抬起配对失效。光标依旧全程冻结，「光标纹丝不动」不受影响
- **测试**：新增 iOS-on-Mac 投递与 bundle 布局探测相关用例（73/73 全过）

### v1.6
- **性能**：iOS-on-Mac 判定（每次点击都要读 `Info.plist`）按 bundleId 缓存——首次点击之后零磁盘 I/O；目标 App 退出时对应缓存失效
- **性能**：聚焦窗口 frame 缓存——同一 App 期间 keyDown / 宏每步零 AX IPC，窗口移动 / 缩放由 AXObserver 实时失效
- **性能**：`MappingStore.enabledProfile` 由线性扫描升级为 bundleId 字典 O(1) 查询
- **资源**：覆盖层兜底定时器降级为看门狗——空闲 / overlay 隐藏时不再消耗 AX IPC
- **资源**：`AppLogger` 文件写入由「每条 syscall」改为 250ms 或 16KB 批量合并；ERROR/WARN 仍立即落盘，崩溃前可见
- **生命周期**：新增 `applicationWillTerminate` 对称清理（tap / overlay / 宏 / Carbon hotkey handler / 观察者 / 日志同步刷盘）；前台切换 + 配置变更通知合并到 50ms 去抖窗口
- **测试**：新增 27 条测试覆盖以上缓存与触发匹配（55/55 全过）

### v1.5
- **新增**：组合按键宏（Macros）——一个触发键即可顺序执行多步点击，每步独立设置延迟（秒/分）；可重复 N 次或无限循环；运行中再按触发键即刻停止
- **新增**：宏步骤位置支持「引用现有映射」与「现场录制」两种来源；引用映射的步骤会随被引用映射的位置/缩放参考一起变更，无需重录
- **新增**：菜单栏图标在宏运行期间变红（`record.circle.fill`），菜单暴露「停止运行的宏」入口；切走前台 app / 系统唤醒会自动停止宏
- **新增**：触发器去重扩展到「映射 ∪ 宏」全集——同一 profile 内不允许两条 trigger 冲突，避免运行时优先级歧义
- **存储**：`AppProfile` 新增 `macros` 字段，导出 schema 升级到 v2；旧 v1 配置兼容读取（macros 默认空数组）

### v1.4
- **性能**：以 AXObserver 推送替代 v1.3 的 50ms 焦点查询节流——keyDown 热路径上 AX IPC 几乎清零
- **性能**：覆盖层位置 / 尺寸更新由 AXObserver 触发，0.5Hz 轮询降级为 5 秒兜底——窗口拖动 / 缩放即刻跟随
- **性能**：智能 tap 暂停——前台应用没有可用 profile 时事件 tap 自动停用，避免每次全局按键的进程间唤醒成本
- **新增**：逐条映射启用 / 禁用开关，调试时无需删除即可临时关闭
- **新增**：编辑器加入「拦截原始按键」开关（绑定到 `blockInput`），关闭后按键既触发点击也透传给目标应用
- **新增**：映射列表正确显示鼠标右键 / 侧键触发器；新增「缩放跟随」/「v1.2 旧映射」徽标提示
- **新增**：导入 / 导出 JSON 配置，带 schema 版本号；导入支持「合并（同 bundleId 覆盖）」与「全部新建」两种模式
- **新增**：可配置的全局开关快捷键（默认 ⌃⇧K），按下即启用 / 禁用映射；持久化到独立的 `preferences.json`
- **改进**：GitHub Actions CI（push / PR 自动跑测试）+ Release 流水线（tag `v*` 自动 build / sign / 打包 / 创建 draft release）

### v1.3
- **新增**：窗口缩放跟随——新录制的映射会记录当时窗口尺寸，目标窗口被等比放大/缩小后点击位置自动按比例换算（旧映射重新录制即可启用）
- **修复**：覆盖层（指示器红点）窗口移动后不刷新——旧版本只在切换前台应用时才更新位置，移动/缩放游戏窗口期间 overlay 停在旧位置；现每个 tick 重查窗口 frame
- **修复**：覆盖层在编辑映射后不刷新——旧版本判定"是否需要重绘"只看映射数量与透明度，编辑位置/标签/按键不会触发刷新；现按完整 profile 比对
- **修复**：`mappings.json` 解析失败时被静默清空——旧版本会用空数组覆盖损坏文件导致永久数据丢失；现自动备份为 `mappings.json.bak.{时间戳}`
- **新增**：同 profile 内重复触发器检测——保存映射时若已存在相同按键/鼠标键的映射，给出明确提示而不是静默冲突
- **性能**：`AppLogger` 文件写入移到后台串行队列，不再阻塞主线程上的 CGEventTap 回调；`DateFormatter` 改为静态实例避免每次新建
- **性能**：每次 keyDown 都做 AX 焦点查询的开销在 50ms 内做缓存，覆盖快速连按场景
- **性能**：移除热路径上的 TRACE 日志（之前每个全局按键都会触发一次同步磁盘 I/O）
- **改进**：日志启动时归档为 `keysmirror.log.1`（保留上一次会话日志，便于崩溃后排查）
- **改进**：录制点击位置时只隐藏配置窗口而非应用全部窗口；清理 `PermissionHelper` 中未执行的 AppleScript 死代码

### v1.2
- **修复**：长时间后台再次打开编辑器时，录制触发键 / 录制位置闪退——`TriggerRecorder` 与 `PointRecorder` 在收到 `tapDisabledByTimeout` / `tapDisabledByUserInput` 事件时，底层 CGEvent 指针为 null，对其调用 `Unmanaged.passRetained` 导致崩溃；现与 `KeyInterceptor` 对齐，统一改为 Optional 安全处理
- **新增**：睡眠唤醒自动恢复——合盖重开或屏幕唤醒后，键盘监听自动重建，无需手动重启
- **改进**：日志系统升级，新增文件落盘（`~/Library/Caches/KeysMirror/keysmirror.log`）与 `os_log` 支持，日志面板支持折叠

### v1.1
- 新增文字输入智能保护（Accessibility API 焦点检测）
- 修复 Chromium 系浏览器映射副作用

### v1.0
- 初始版本：按键到鼠标点击映射、光标静止、多应用配置、iOS-on-Mac 支持

---

## License

[MIT](LICENSE) © 2026 KeysMirror
