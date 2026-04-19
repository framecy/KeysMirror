# KeysMirror - macOS 键盘映射工具

## 功能概述

KeysMirror 是一款 macOS 菜单栏应用，用于在指定应用中通过按键映射实现鼠标左键点击效果。

### 核心功能

1. **按键映射** - 将键盘按键映射为鼠标点击
2. **相对坐标** - 基于目标窗口位置的百分比定位
3. **键位拦截控制** - 可选择是否阻止原始按键传递到应用

## 技术方案

### 核心技术栈
- **Swift 5.9+** + AppKit
- **CGEventTap** - 全局键盘拦截
- **CGEvent** - 鼠标点击模拟
- **AXUIElement** - 窗口位置获取

### 最低要求
- macOS 13.0 (Ventura)
- Apple Silicon (M1+)
- 辅助功能权限

## 项目结构

```
KeysMirror/
├── KeysMirror/
│   ├── App/                  # 应用入口
│   │   ├── KeysMirrorApp.swift
│   │   └── AppDelegate.swift
│   ├── Models/              # 数据模型
│   │   ├── AppProfile.swift
│   │   ├── KeyMapping.swift
│   │   └── MappingStore.swift
│   ├── Services/            # 核心服务
│   │   ├── KeyInterceptor.swift    # 按键拦截
│   │   ├── ClickSimulator.swift     # 鼠标模拟
│   │   ├── WindowLocator.swift    # 窗口定位
│   │   └── PermissionChecker.swift # 权限管理
│   ├── Views/               # UI界面
│   └── Utilities/           # 工具类
├── project.yml             # XcodeGen 配置
└── KeysMirror.xcodeproj
```

## 配置格式

配置文件位置: `~/Library/Application Support/KeysMirror/mappings.json`

```json
[
  {
    "id": "uuid",
    "bundleIdentifier": "com.example.app",
    "appName": "应用名称",
    "isEnabled": true,
    "overlayOpacity": 0.5,
    "showOverlay": true,
    "mappings": [
      {
        "id": "mapping-uuid",
        "keyCode": 6,
        "modifiers": 0,
        "triggerType": "keyboard",
        "mouseButtonNumber": null,
        "relativeX": 0.5,
        "relativeY": 0.5,
        "label": "Q",
        "blockInput": true
      }
    ]
  }
]
```

## 按键码参考

| 按键 | KeyCode |
|------|---------|
| A-Z | 0x00-0x1F |
| 0-9 | 0x12-0x1D |
| F1-F12 | 0x7A-0x6F |
| Space | 0x31 |
| Esc | 0x35 |

## 使用说明

### 1. 权限授权
首次运行需要授权辅助功能权限（系统偏好设置 → 隐私与安全性 → 辅助功能）

### 2. 添加应用映射
1. 点击菜单栏 KeysMirror 图标
2. 选择 "Configuration..."
3. 点击 "Add App" 选择目标应用
4. 添加按键映射

### 3. blockInput 选项
- `blockInput: true` - 按键触发点击，但原始按键不传递到应用（推荐）
- `blockInput: false` - 按键既触发点击，也传递到应用（可能导致重复输入）

## 技术限制

### 鼠标移动
使用 CGEvent 模拟鼠标点击时，光标会移动到目标位置。这是 macOS 原生 API 的限制，无法完全避免。

**解决方案**：可选择是否在点击后恢复鼠标位置。

### 键位冲突
- 同一应用同一按键只能添加一次映射
- 如果游戏有内置快捷键保护，可能需要设置 `blockInput: false`

## 构建与运行

```bash
# 生成 Xcode 项目
xcodegen generate

# 构建
xcodebuild -project KeysMirror.xcodeproj -scheme KeysMirror -configuration Debug build

# 运行
open ~/Library/Developer/Xcode/DerivedData/KeysMirror-*/Build/Products/Debug/KeysMirror.app
```

## 问题排查

### 点击不生效
1. 检查辅助功能权限是否授权
2. 检查目标应用的窗口是否能被��取
3. 尝试以管理员权限运行

### 游戏无法输入
- 设置 `blockInput: false` 允许按键传递到游戏
- 某些游戏有反作弊保护，可能需要额外处理

## 更新日志

### v1.0
- 初始版本
- 支持按键到鼠标点击映射
- 浮动面板显示
- 相对窗口坐标定位