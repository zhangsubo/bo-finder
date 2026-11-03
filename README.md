# 桌边 · DeskSide — macOS 原生个人工具箱

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)]()

`DeskSide` 是一款运行在个人 Mac 上的原生工具箱（SwiftUI + AppKit），由 BoFinder 演进而来，沿用原有 logo。已承接文件工具，并加入会议助手首版；安全网关仍为占位。

主窗口采用固定全局侧边栏，「设置与关于」在所有页面均可访问。菜单栏常驻，关闭窗口后继续运行，支持隐藏 Dock 图标、开机启动和跟随系统／浅色／深色外观。

## 从 BoFinder 升级

- 构建产物为 `build/DeskSide.app`，日常使用建议安装到 `/Applications/DeskSide.app`。
- 保留 `com.bofinder.app`、Finder 扩展标识、IPC 通道和 `~/Library/Application Support/BoFinder/state.json`，直接沿用已有全部设置，不重置为默认值。代码目录和兼容类型仍保留旧名称。
- 启动时先正常退出旧 BoFinder，无法退出则停止启动；防止新旧版本同时处理文件。DeskSide 自身使用进程锁避免重复运行。
- 开机启动配置沿用旧标识并更新为当前安装路径。
- 使用本地 ad-hoc 签名，升级后 macOS 可能要求重新授予辅助功能权限。在「文件工具 → 权限与诊断」中查看；应用不会自动清除已有授权。
- 两个 logo 源文件和图标生成方式保持不变。

## 会议助手（首版）

- 原生主窗口管理会议，手动录制麦克风和系统音频，支持暂停、结束、分段保存及中断恢复。
- 本地 X-ASR 常驻进程提供准实时文字；会后用 pyannote segmentation + 3D-Speaker 分离说话人，再生成带时间和 A/B/C 标签的转录。支持按会议统一改名、修改文字、导出 Markdown。
- macOS 26+ 可在「会议设置 → 转录 → 会中实时识别」选择实验性的 Apple 原生转录（SpeechAnalyzer / SpeechTranscriber）。支持普通话和英语选项，先检查并准备系统语言模型；音频在本机识别，不依赖 Apple Intelligence 总结功能。原有配置继续默认 X-ASR。
- 使用可配置的 OpenAI 兼容 Chat Completions 接口和默认模板生成纪要，修改转录后可重新生成。API Key 保存在 macOS Keychain。
- 可选 MiMo 风格的 `input_audio` 云端转录；该适配器不等同于通用 `/audio/transcriptions`，目前没有实时预览、稳定说话人标签和精确时间。
- 腾讯会议、微信通话自动识别使用 CoreAudio 活动和窗口信号，需要 macOS 14.2+，**尚待真实通话验证**。首次默认关闭，手动录音完成系统授权后再开启。

本地环境准备（Python 3.11+，需联网下载模型；当前已验证环境为 Apple Silicon / Python 3.14）：

```bash
python3 scripts/setup_meeting_runtime.py
./build.sh
# 可选：本机模拟模型接口测试，不访问云端
python3 scripts/test_meeting_cloud.py
```

从 `build/DeskSide.app` 启动时会识别相邻的 `meeting-runtime`、`meeting-models`。安装到其他位置后，在「会议设置 → 转录」中指定 Python 可执行文件和模型目录。模型未就绪时仍可保存录音，会后补做转录。当前本地实现使用 X-ASR；Whisper、Gemma 尚未接入。

Apple 选项目前只替换会中预览，会后完整转录与说话人分离仍需上述 Python / X-ASR 环境；本地纪要模型尚未接入。Apple 模型检查不下载资源，「下载并准备」会请求系统安装语言模型。选择不可用的模型时会提示原因并继续保存录音，不自动上传或切换识别引擎。录音期间不能更换实时引擎与 Apple 语言。

开发者可用已有的 16 kHz 单声道 WAV 比较两种实时引擎（不访问麦克风；构建需 macOS 26+ SDK）：

```bash
xcrun swiftc -parse-as-library -target arm64-apple-macos13.0 \
  BoFinderApp/MeetingModels.swift BoFinderApp/MeetingAppleSpeech.swift \
  scripts/benchmark_apple_speech.swift -o build/benchmark_apple_speech
build/benchmark_apple_speech --check
# 首次需要时：build/benchmark_apple_speech --install
build/benchmark_apple_speech --audio /path/to/fixture.wav --realtime
build/meeting-runtime/bin/python scripts/benchmark_meeting_stream.py \
  --audio /path/to/fixture.wav --models build/meeting-models --realtime
```

两种测试都把同一音频复制为 mic/system 双路，首字墙钟时间可以比较；Apple 的异步结果回调与 X-ASR 的逐片段响应不是相同延迟指标。测试不包含真实设备采集、原生 UI 渲染或人工标注的讲话结束时刻。

Apple 使用优先响应的快速模式。当前中文样本虽能更早显示首字，但仍有漏句，尚不足以替换 X-ASR 默认值；完整会议结果应以会后转录和人工校对为准。

会议音频和文字存于 `~/Library/Application Support/DeskSide/Meetings/`。默认本地转录；选择云端 ASR 会发送音频，配置云端总结会发送转录文字。每次最多录制四小时。点时间戳仅回放对应短音频片段；旧转录和纪要保留在本地，当前界面只展示最新结果。重新转录会重新分配说话人标签，需重新确认姓名。

说话人数量自动估计可能错误拆分，支持指定预计人数并人工校对。实时输出用于跟进会议，会后结果仍需校对。自动录音、双音源回声和原生 UI 尚需实机验收；不能仅凭编译通过认定可稳定用于所有会议。

## 文件工具

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

3. **右键在此处打开终端 & 在 Orca 中打开**：
   - 在文件夹上右键，直接**在该文件夹地址上打开终端**（在文件夹空白处或文件上右键则在当前所在目录打开终端）。
   - 支持自由设置默认终端：**iTerm2**、**Ghostty**、**系统自带终端 (`Terminal.app`)**、**Orca**。
   - **Orca (`Orca.app`) 深度集成**：支持一键将任意 Git 仓库或普通文件夹导入并激活到 Orca 工作区，同时自动创建/聚焦该目录的终端面板；可与默认终端并存显示，实现「终端 + Orca」双入口一键直达。

4. **显示 / 隐藏系统与点文件（`.` 开头隐藏文件）**：
   - 在「文件工具 → 显示与增强」及顶部状态栏右键菜单中一键显示或隐藏 `.git`、`.env`、`.zshrc` 等隐藏文件，自动写入系统配置并保持重启持久化。
   - 支持在 Finder 前台通过可自定义录制的快捷键（默认 `⌘ + ⇧ + .`，并提供 `⌃ + H`、`⌥ + .` 等预设）零闪烁快速切换，自动避让重命名与搜索输入焦点并附带 HUD 状态提示。

5. **Finder 右键扩展冲突诊断器**：
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
│   ├── AppDelegate.swift              # 状态栏菜单、快捷复制与 DeskSide 生命周期管理
│   ├── EventTapManager.swift          # CGEventTap 监听 Finder 中剪切粘贴、隐藏文件快捷键与右键事件
│   ├── HiddenFilesManager.swift       # Finder 隐藏文件状态读写、零闪烁快捷键切换与同步管理
│   ├── CutPasteManager.swift          # 剪切状态机、跨进程动作分发与文件移动冲突处理
│   ├── TerminalLauncher.swift         # iTerm2 / Ghostty / 系统终端 / Orca.app 终端与工作区启动器
│   ├── CloudQuickBarController.swift  # 右键菜单顶部置顶快捷栏（兼顾 iCloud 云盘目录支持）
│   ├── QuickPopupMenuController.swift # ⌥+右键 / ⌃+⌥+C 独立快捷弹出菜单
│   ├── FinderSelectionHelper.swift    # 基于 Accessibility 读取 Finder 选中项、光标命中项与当前目录
│   ├── FinderExtensionDoctor.swift    # 基于 pluginkit 的 FinderSync 扩展注册与冲突管理
│   ├── HUDWindowController.swift      # 毛玻璃悬浮提示窗 (HUD Toast)
│   ├── SettingsWindow.swift           # SwiftUI 全局侧边栏、文件工具、设置与未来模块占位
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
# 运行单元测试并编译打包生成 build/DeskSide.app
./build.sh
# 可选：仅需手动注册扩展时使用 ./build.sh --register

# 启动应用
open build/DeskSide.app
```

构建默认仅测试、编译、打包和签名；不会改变当前 Finder 扩展选择。DeskSide 启动时注册自身扩展。

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
