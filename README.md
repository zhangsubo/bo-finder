# BoFinder — macOS Finder 右键路径复制与原生剪切增强工具

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)]()

`BoFinder` 是一款轻量、原生的 macOS Finder 增强工具（Menu Bar App + Finder Sync Extension），**100% 兼容 SIP（无需关闭系统完整性保护）**，核心解决 macOS Finder 的两大高频痛点：

## 核心特性

1. **右键多格式复制路径 (Copy Path)**：
   - **右键顶部置顶快捷栏 (`CloudQuickBarController`)**：右键文件时，直接在原生右键菜单正上方（鼠标指尖处）弹出置顶快捷操作栏，无需长距离下滑鼠标；同时彻底突破 macOS 14+ 对 **iCloud 云盘 (`iCloud Drive`)** 目录禁用第三方 `FinderSync` 扩展的限制。
   - **原生 Finder 右键菜单扩展 (`FinderSync`)**：支持「复制路径 ▸」二级子菜单模式与一级菜单平铺模式实时切换。
   - **支持 7 种常用路径格式**：
     - **POSIX 路径** (`/Users/name/file.txt`)
     - **URL 路径** (`file:///Users/name/file.txt`)
     - **Windows 路径** (`\Users\name\file.txt` / `C:\...` / `\\mac\...`)
     - **终端转义路径** (`Terminal` 自动转义空格、括号与特殊字符，多文件以空格拼接)
     - **家目录缩写路径** (`~/Documents/file.txt`)
     - **纯文件名** (`file.txt`)
     - **Markdown 链接** (`[file.txt](file:///...)`)

2. **原生剪切与粘贴移动 (`⌘ + X` & `⌘ + V`)**：
   - 在 Finder 中选中文件直接按 `⌘ + X` 进入剪切状态，在目标文件夹（含 iCloud 云盘目录）按 `⌘ + V` 直接完成文件移动（支持同名文件保留两者 / 替换 / 跳过询问）。
   - **完美兼容第三方剪贴板工具**：直接拦截 `⌘ + V` 执行文件级移动，不合成 `⌥ + ⌘ + V` 按键，避免与 `Parallels Toolbox Clipboard History`、`Paste`、`Maccy` 等剪贴板历史工具快捷键冲突。
   - **智能识别文本编辑状态**：自动检测 Finder 中的**文件重命名、右上角搜索框、`⌘ + ⇧ + G` 路径跳转框**等输入焦点，绝不干扰正常文字剪切与粘贴。
   - 按 `Esc` 键或重新按 `⌘ + C` 自动取消剪切状态。
   - 右键菜单与顶部置顶栏同步提供「剪切」与「粘贴移动」按钮，支持纯鼠标操作。
   - 内置轻量级毛玻璃 HUD 悬浮提示与状态栏剪切计数角标。

3. **Finder 右键扩展冲突诊断器**：
   - 针对 macOS Finder 同一目录仅激活一个 `FinderSync` 扩展的系统限制，内置扩展冲突管理面板，支持一键关闭抢占根目录的冲突扩展（自动保留坚果云、百度网盘等网盘侧边栏扩展）。

---

## 目录结构

```text
bo-finder/
├── build.sh                           # 一键单元测试、图标生成、编译、打包、签名脚本
├── LICENSE                            # MIT 开源协议
├── Shared/
│   ├── Models.swift                   # 路径格式、应用配置、运行时状态与 IPC 数据模型
│   ├── PathFormatter.swift            # 多格式路径格式化与终端转义实现
│   └── SharedStore.swift              # 跨沙盒命名剪贴板 (NSPasteboard) 与磁盘状态同步
├── BoFinderApp/
│   ├── main.swift                     # 主程序入口
│   ├── AppDelegate.swift              # 状态栏菜单、快捷复制与生命周期管理
│   ├── EventTapManager.swift          # CGEventTap 监听 Finder 中 ⌘+X / ⌘+V / Esc / 右键事件
│   ├── CutPasteManager.swift          # 剪切状态机、跨进程动作分发与文件移动冲突处理
│   ├── CloudQuickBarController.swift  # 右键菜单顶部置顶快捷栏（兼顾 iCloud 云盘目录支持）
│   ├── QuickPopupMenuController.swift # ⌥+右键 / ⌃+⌥+C 独立快捷弹出菜单
│   ├── FinderSelectionHelper.swift    # 基于 Accessibility 读取 Finder 选中项、光标命中项与当前目录
│   ├── FinderExtensionDoctor.swift    # 基于 pluginkit 的 FinderSync 扩展注册与冲突管理
│   ├── HUDWindowController.swift      # 毛玻璃悬浮提示窗 (HUD Toast)
│   ├── SettingsWindow.swift           # SwiftUI 偏好设置与诊断窗口
│   ├── Info.plist                     # 主应用配置
│   └── BoFinder.entitlements          # 主应用权限配置
├── BoFinderSync/
│   ├── FinderSync.swift               # FIFinderSync 右键菜单扩展实现
│   ├── Info.plist                     # 扩展配置
│   └── BoFinderSync.entitlements      # 扩展标准沙盒配置
├── scripts/
│   └── generate_icon.swift            # 自动生成 AppIcon.icns 应用图标脚本
└── Tests/
    └── PathFormatterTests.swift       # 路径格式化单元测试
```

---

## 编译与运行

```bash
# 运行单元测试并编译打包生成 build/BoFinder.app
./build.sh

# 启动应用
open build/BoFinder.app
```

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
