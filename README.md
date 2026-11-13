# 桌边 · DeskSide — macOS 原生个人工具箱

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 26+](https://img.shields.io/badge/Platform-macOS%2026%2B-lightgrey.svg)]()

`DeskSide` 是一款运行在个人 Mac 上的原生工具箱（SwiftUI + AppKit），由 BoFinder 演进而来，沿用原有 logo。现已内置文件工具、环境变量维护与零 Python 依赖的本地实时会议助手；安全网关定位为「防止向大模型发送与向 GitHub 推送密钥及敏感凭证」的本地双出口守护控制台（详见 [安全网关设计文档](docs/security-gateway-design.md)）。

主窗口采用固定全局侧边栏，「设置与关于」在所有页面均可访问。菜单栏常驻，关闭窗口后继续运行，支持隐藏 Dock 图标、开机启动和跟随系统／浅色／深色外观。

## 从 BoFinder 升级

- 构建产物为 `build/DeskSide.app`，日常使用建议安装到 `/Applications/DeskSide.app`。
- 保留 `com.bofinder.app`、Finder 扩展标识、IPC 通道和 `~/Library/Application Support/BoFinder/state.json`，直接沿用已有全部设置，不重置为默认值。代码目录和兼容类型仍保留旧名称。
- 启动时先正常退出旧 BoFinder，无法退出则停止启动；防止新旧版本同时处理文件。DeskSide 自身使用进程锁避免重复运行。
- 开机启动配置沿用旧标识并更新为当前安装路径。
- 默认发布使用 ad-hoc 签名：未配置本机证书的设备升级后若辅助功能失效，应用会自动清理旧版失效授权记录并弹出引导浮层，直接将 DeskSide 胶囊卡片上拖即可生效（无需手动先删旧记录）；本机执行一次 `./scripts/setup_local_cert.sh` 配置自签名证书后，本地编译与自动更新均会自动重签并永久继承权限。
- 两个 logo 源文件和图标生成方式保持不变。

## 环境变量维护

- 可视化维护常规环境变量（`export`）、密码与 API Key（默认 `••••` 掩码防窥、一键复制明文）以及终端快捷别名（`alias`）。
- 独立生成托管脚本 `~/.config/deskside/env.zsh`（权限 `0600`），通过轻量钩子自动挂载到 `~/.zshrc`（首次自动备份 `~/.zshrc.deskside-backup`，绝不破坏原有复杂配置）。
- **保存后自动无感刷新**：每次新增、编辑、启停或删除条目后，自动通过 `SIGUSR1` + `precmd` 时间戳钩子刷新所有已打开的交互式 `zsh` 终端（含自动 `unset` / `unalias` 已停用或删除的条目），并同步 `launchctl setenv` 到 macOS 桌面图形应用环境。
- **可选系统钥匙串存储**：敏感项默认保存在权限 `0600` 的私有托管文件中（零耗时且支持 SSH）；同时支持按条目开启 macOS Keychain 存储（通过系统 `/usr/bin/security` 免授权弹窗通道读写，配置文件不留明文）。
- 支持从 `~/.zshrc`、`~/.zshenv`、`~/.zprofile`、`~/.bash_profile` 或任意 `.env` 文件扫描导入已有配置，并提供代理快捷命令、常用 Git 别名等一键模板及状态栏右键快捷菜单。

## 会议助手（macOS 26+ 原生零依赖架构）

- **开箱即用，零 Python 依赖**：
  - **双音源无感采集**：线上会议使用 Core Audio Process Tap（`CATapDescription`，自动排除本进程 PID）采集系统音频，仅需系统音频录制权限（无需屏幕录制权限）；同时采集麦克风音频，支持暂停、继续、分段持久化与异常中断恢复，单场最长 4 小时。
  - **Apple 原生流式语音识别**：内存直推 `AVAudioPCMBuffer` 至 `.unbounded` `AsyncStream<AnalyzerInput>`，配合 `0.25s` 微停顿主动断句（`analyzer.finalize(through:)`）、呼吸噪声清洗与 `≤ 1.5s` 短停顿智能续接（`MeetingHeardText`）、扬声器外放回声去重及断流指数退避重连，支持普通话、英语及中英自动评分择优。
  - **内置 Core ML 实时声纹分离**：随包内置 WeSpeaker ResNet34-LM 声纹模型（`SpeakerEmbedding.mlpackage`）与纯 Swift `Accelerate/vDSP` 80 维 Kaldi Fbank 提取，实时区分「我」与多位参会人（`说话人 1/2/…`），支持一键改名、跨声纹簇合并，以及基于上下文 `±2` 行证据校验的 AI 说话人姓名推断。
- **会中实时结构化纪要 & 投屏隐身桌边悬浮窗**：
  - **增量结构化纪要**：会中满 3 句自动生成首轮纪要，之后每 45 秒增量刷新，结束会议后执行全文终审；自动提炼日历风格短标题、概览、分时段议题、数字/日期/金额高亮结论、带负责人待办、根因分析鱼骨图（`≥ 2` 分支时自动展开）与同音误听术语表。
  - **证据回溯与同音词搜索**：点击任意议题、结论或待办右侧的时间戳胶囊可直接跳转并高亮对应转录原句、回放对应录音位置；`⌘F` 搜索支持联动术语表 `heard` 同音误听词一并高亮命中。
  - **防屏幕共享泄露悬浮窗**：基于 `.nonactivatingPanel` + `FirstClickHostingView`，点击交互不抢腾讯会议／飞书／钉钉／Zoom 焦点；默认开启 `sharingType = .none` 在屏幕共享与截图中完全隐身（若手动开启允许共享，顶部常驻呼吸橙色警示灯）；支持拖窄 `< 360pt` 迷你跟进卡片、`360–760pt` 侧栏与 `≥ 760pt` 纪要+转录双栏三种自适应形态。
- **通用模型接口与文档导出**：
  - 使用任意兼容 OpenAI Chat Completions 的接口生成结构化纪要（自动剥离推理模型 `<think>` 标签与代码围栏），API Key 仅保存在 macOS Keychain。
  - 支持一键导出原生 **Word (`.docx`)** 与 **Markdown (`.md`)**，支持对历史转录逐句校对与归档保留。
  - 兼容保留可选的本地 Python `X-ASR` 引擎与 `MiMo` 云端音频转录模式；旧版 `configuration.json` 与 `meeting.json` 无需迁移即可直接读取。
  - 支持腾讯会议、微信、飞书、钉钉、Zoom 通话自动检测（基于 Core Audio 进程音频流检测，默认关闭，首次手动录音完成授权后可按应用单独开关）。

常用验证与基准测试命令：

```bash
# 运行全部单元测试并构建打包 build/DeskSide.app
./build.sh

# 本机回环模拟 Chat Completions 契约与防重定向凭据泄露测试
python3 scripts/test_meeting_cloud.py

# Apple 原生流式转录独立基准测试（16 kHz 单声道 WAV，不访问麦克风）
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  BoFinderApp/MeetingModels.swift BoFinderApp/MeetingAppleSpeech.swift \
  scripts/benchmark_apple_speech.swift -o build/benchmark_apple_speech
build/benchmark_apple_speech --check
build/benchmark_apple_speech --audio /path/to/fixture.wav --realtime
```

会议音频与纪要默认保存在 `~/Library/Application Support/DeskSide/Meetings/`。默认本地转录不上传任何音频；配置纪要接口后仅向你指定的端点发送会议文字转录。

## 安全网关（即将推出）

- **双出口密钥防泄漏定位**：聚焦个人 AI 辅助研发场景，统一拦截**发往外部大模型（Claude Code、Codex、Cursor 等）的上下文流量**与**推送至 GitHub（`git push` SSH/HTTPS、`gh` CLI、GitHub MCP）的代码及接口流量**中夹带的真实密钥与敏感凭证。
- **同仓解耦 Go 引擎 + DeskSide 原生管控**：核心流式检测与代理引擎以独立 Go 模块（`GuardEngine/`，`CGO_ENABLED=0` 零外部依赖）放在本仓库内开发，随 `DeskSide.app` 一键编译、签名与自动热更新，同时保持纯标准协议边界，后续随时可零改造单独拆分为跨平台 CLI 项目；`DeskSide` 负责可视化策略管理、零明文掩码审计、桌面 HUD 实时提醒，并直接联动「环境变量维护」中的已知密码密钥库实现零误报精确匹配。
- **三级递进流量接入（Surge → `mitmproxy` 透明捕获 → 自带代理兜底）**：
  - **Tier 1**：检测到本机已安装 **Surge** 时，直接使用 Surge 协同模式（生成 `.sgmodule` 复用 Surge MITM 根证书与海外代理分流，Header 级无缓冲引流，不断流大模型 SSE 输出）；
  - **Tier 2**：未检测到 Surge 时，优先提示用户是否同意自动下载并集成带 Apple 官方签名的开源 **`mitmproxy` 本地透明捕获组件**（MIT 协议，基于 macOS `NetworkExtension` 按进程精准拦截，保持无盲区防护）；
  - **Tier 3**：仅当用户不同意下载外部组件时，降级使用独立引擎**自带的本地选择性 MITM 代理 + 系统 PAC 分流 + 终端环境注入**完成基础防护。
- 详细方案与技术选型对比见 [docs/security-gateway-design.md](docs/security-gateway-design.md)。

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
├── docs/
│   └── security-gateway-design.md     # 安全网关（大模型 + GitHub 双出口密钥防泄漏）架构与回退方案设计文档
├── Shared/
│   ├── Models.swift                   # 路径格式、应用配置、运行时状态与 IPC 数据模型
│   ├── PathFormatter.swift            # 多格式路径格式化与终端转义实现
│   └── SharedStore.swift              # 跨沙盒命名剪贴板 (NSPasteboard) 与磁盘状态同步
├── BoFinderApp/
│   ├── main.swift                     # 主程序入口
│   ├── AppDelegate.swift              # 状态栏菜单、快捷复制与 DeskSide 生命周期管理
│   ├── EnvModels.swift                # 环境变量、密码密钥、快捷别名模型与 Shell 解析渲染器
│   ├── EnvManager.swift               # 环境变量持久化、Keychain 通道、~/.zshrc 挂载与终端实时刷新引擎
│   ├── EnvView.swift                  # 环境变量可视化维护、导入与脚本预览界面
│   ├── EventTapManager.swift          # CGEventTap 监听 Finder 中剪切粘贴、隐藏文件快捷键与右键事件
│   ├── HiddenFilesManager.swift       # Finder 隐藏文件状态读写、零闪烁快捷键切换与同步管理
│   ├── CutPasteManager.swift          # 剪切状态机、跨进程动作分发与文件移动冲突处理
│   ├── TerminalLauncher.swift         # iTerm2 / Ghostty / 系统终端 / Orca.app 终端与工作区启动器
│   ├── CloudQuickBarController.swift  # 右键菜单顶部置顶快捷栏（兼顾 iCloud 云盘目录支持）
│   ├── QuickPopupMenuController.swift # ⌥+右键 / ⌃+⌥+C 独立快捷弹出菜单
│   ├── FinderSelectionHelper.swift    # 基于 Accessibility 读取 Finder 选中项、光标命中项与当前目录
│   ├── FinderExtensionDoctor.swift    # 基于 pluginkit 的 FinderSync 扩展注册与冲突管理
│   ├── HUDWindowController.swift      # 毛玻璃悬浮提示窗 (HUD Toast)
│   ├── PermissionGuideOverlay.swift   # 辅助功能授权上拖胶囊引导浮层与自动检测关闭
│   ├── MeetingModels.swift            # 会议记录、结构化纪要模型、文本续接与回声判重
│   ├── MeetingCapture.swift           # 麦克风 + Core Audio Process Tap 双音源采集与会议进程检测
│   ├── MeetingAppleSpeech.swift       # Apple SpeechAnalyzer 流式识别、微停顿断句与声纹环形缓冲
│   ├── MeetingSpeakerID.swift         # Accelerate Kaldi Fbank、内置 Core ML 声纹聚类与姓名推断
│   ├── MeetingNotes.swift             # 45s 实时增量结构化纪要引擎、证据映射与 Word (.docx) 导出
│   ├── MeetingFloatingPanel.swift     # 投屏隐身非激活桌边悬浮窗与共享结构化纪要/转录视图
│   ├── MeetingServices.swift          # OpenAI 兼容 Chat Completions 客户端、Keychain 与可选 X-ASR 桥接
│   ├── MeetingManager.swift           # 会议会话编排、多切片连续回放与持久化管理
│   ├── MeetingView.swift              # 主窗口会议助手工作台界面
│   ├── AppUpdater.swift               # GitHub Release 自动检测、SHA-256 校验与无感热替换更新器
│   ├── Resources/
│   │   └── SpeakerEmbedding.mlpackage # 内置 WeSpeaker ResNet34-LM Core ML 声纹模型
│   ├── SettingsWindow.swift           # SwiftUI 全局侧边栏、文件工具、会议设置与关于
│   ├── Info.plist                     # 主应用配置
│   └── BoFinder.entitlements          # 主应用权限配置
├── BoFinderSync/
│   ├── FinderSync.swift               # FIFinderSync 右键菜单扩展实现
│   ├── Info.plist                     # 扩展配置
│   └── BoFinderSync.entitlements      # 扩展标准沙盒配置
├── scripts/
│   ├── generate_icon.swift            # 自动生成 AppIcon.icns 应用图标脚本
│   ├── setup_local_cert.sh            # 一键生成并信任本机代码签名证书（实现本地编译与更新永久免重授）
│   ├── update_local.sh                # 等待 GitHub Action 完成并同步更新本地 /Applications/DeskSide.app
│   ├── benchmark_apple_speech.swift   # Apple 原生流式语音识别基准测试工具
│   └── test_meeting_cloud.py          # Chat Completions 接口契约测试脚本
└── Tests/
    ├── PathFormatterTests.swift       # 文件工具路径与配置单元测试
    ├── EnvTests.swift                 # 环境变量模型、解析、安全转义与终端实时刷新测试
    ├── MeetingTests.swift             # 会议模型、Kaldi Fbank、Core ML 声纹、纪要解析与 .docx 导出测试
    ├── MeetingAppleSpeechTests.swift  # WAV 流式读取采样完整性单元测试
    └── MeetingCloudTests.swift        # Chat Completions 接口安全与边界测试
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

## 开源协议与致谢

- 本项目基于 [MIT License](LICENSE) 开源。
- 内置声纹提取模型源自 [WeSpeaker](https://github.com/wenet-e2e/wespeaker) 项目训练的 VoxCeleb ResNet34-LM 模型，遵循 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 许可协议；流式断句与增量结构化纪要工程设计参考了 [Cicada](https://github.com/wquguru/cicada)（MIT License）。
