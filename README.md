<div align="center">

<img src="https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple" />
<img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift" />
<img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" />
<img src="https://img.shields.io/github/v/release/framecy/KeysMirror?style=flat-square&label=latest" />

# KeysMirror

**按键，即点击。**

将任意键盘快捷键映射为应用窗口内的指定位置点击。光标纹丝不动，无需修改目标应用，游戏技能与工具栏按钮一键直达。

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
| **光标静止** | 模拟点击时鼠标指针完全不移动 |
| **鼠标侧键支持** | 右键、侧键均可作为触发器 |
| **可视位置指示器** | 半透明红点实时标记每个映射位置，支持透明度调节 |
| **多应用独立配置** | 各应用拥有独立映射组，随前台切换自动激活 |
| **窗口缩放跟随** | v1.3 起新录制的映射会记录窗口尺寸快照，窗口被放大/缩小后点击位置按比例自动跟随 |
| **文字输入智能保护** | 通过 AX API 检测焦点元素类型，输入控件（聊天框、搜索栏等）获焦时自动静默映射，离焦后即刻恢复 |
| **睡眠唤醒自动恢复** | 合盖重开或屏幕唤醒后，键盘监听自动重建，无需手动重启应用 |
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

## 技术实现

- **事件拦截**：`CGEventTap` 在 `.cgSessionEventTap` 全局监听键盘与鼠标侧键事件；收到 `tapDisabledByTimeout` / `tapDisabledByUserInput` 时自动重建 tap（此类事件底层 CGEvent 指针为 null，已专项处理）
- **睡眠唤醒恢复**：监听 `NSWorkspace.screensDidWakeNotification` 与 `NSWorkspace.didWakeNotification`，唤醒后自动调用 `keyInterceptor.start()` 重建 tap
- **点击模拟**：原生 macOS 应用使用 `CGEvent.postToPid`（绕过 Window Server，光标不移动）；iOS-on-Mac 游戏使用 `cgSessionEventTap` 投递配合游标冻结
- **窗口定位**：通过 Accessibility API（`kAXPositionAttribute` / `kAXSizeAttribute`）获取目标窗口实时坐标
- **文字输入检测**：每次键盘事件命中 profile 后，先查询 `kAXFocusedUIElementAttribute` 并读取其 `kAXRoleAttribute`，匹配到 `AXTextField` / `AXTextArea` / `AXComboBox` / `AXSearchField` 时放行按键；AX 查询失败时默认放行映射，保证功能不因权限异常而静默失效
- **日志系统**：通过 `os_log` 写入 Console.app（可用 `log stream` 实时查看），同时追加写入 `~/Library/Caches/KeysMirror/keysmirror.log`（可 `tail -f` 跟踪）；UI 内日志面板支持折叠
- **坐标系**：内部统一使用 AX 坐标（左上原点，Y 向下），与 AppKit 坐标（左下原点）通过 `CoordinateConverter` 互转
- **窗口缩放跟随**：`KeyMapping` 在录制时保存 `referenceWidth/referenceHeight` 窗口尺寸快照，触发时按当前窗口尺寸比例换算偏移；旧版本数据无快照时退化为固定像素偏移

---

## 更新日志

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
