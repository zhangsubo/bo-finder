# 安全网关架构与需求设计文档（LLM & GitHub 密钥防泄漏守护）

> 状态：架构设计与需求定稿（对应 `DeskSide`「安全网关」模块 + 同仓解耦 Go 守护引擎 `GuardEngine/`）  
> 部署形态：形态 A —— macOS 个人开发机本地守护（零 Python 强依赖，Go 静态单二进制随包签名内嵌 + 随时可零改造独立拆仓）

---

## 1. 背景与定位调整

`DeskSide` 早期将「安全网关」占位定义为“通过手机确认 Agent 的敏感操作”。结合日常 AI 辅助编程（Claude Code、Codex、Cursor、GitHub Copilot、Antigravity 等）的真实高频风险，现将需求方向正式调整并收敛聚焦为：

> **面向 AI 辅助研发的双出口密钥防泄漏安全网关（Dual-Egress Secret Guard）**  
> 守住个人研发机最致命的两个敏感凭证外泄通道：  
> 1. **大模型流量出口（LLM Egress）**：防止 `.env`、云厂商 AK/SK、数据库账密、私钥等通过 Prompt、文件读取结果、终端报错或 MCP 工具发往外部大模型接口，同时防止模型回写占位符破坏本地文件。  
> 2. **代码托管推送出口（Git & GitHub Egress）**：防止人工或 AI Agent 通过 `git push`（SSH / HTTPS）、`gh` CLI 或 GitHub MCP 接口将包含真实密钥的代码、配置文件或历史 Commit 推送至 GitHub。

### 1.1「同仓独立 Go 模块 + 随时可拆仓」工程解耦原则

采用 **源码同仓开发打包、边界完全解耦（Monorepo + Clean Boundary）** 的组织方式，兼顾当前一键分发体验与未来的独立开源扩展性：

- **Go 核心引擎子目录（`GuardEngine/`，拥有独立 `go.mod`）**：
  - 使用纯 Go（`CGO_ENABLED=0`）编写，**严禁在 Go 代码中硬编码任何 `DeskSide` 专属 UI 逻辑或 macOS 私有绑定**；所有策略、精确密钥指纹同步与审计查询均通过标准配置文件（TOML/JSON）与本地 Unix Socket / CLI 参数通信，天然兼容 macOS / Linux / Windows。
  - **平时在 `DeskSide` 仓库内**：由 [build.sh](file:///Users/zhangsubo/orca/workspaces/bo-finder/blenny/build.sh) 与 `.github/workflows/release.yml` 自动编译输出至 `DeskSide.app/Contents/MacOS/deskside-guard`，随主程序统一代码签名、打包与热更新；同时承担常驻轻量流式网关（`127.0.0.1:19840`）与毫秒级同步 CLI（供 Git `pre-push` Hook 调用）两种角色。
  - **未来按需独立拆出时**：由于 `GuardEngine/` 自成独立 Go Module 且无外部耦合，随时可通过 `git subtree split --prefix=GuardEngine`（保留完整提交历史）或直接提取目录，零代码修改发布为独立的跨平台命令行/服务端网关项目。
- **`DeskSide`「安全网关」原生面板（`BoFinderApp/`）**：
  - 作为 macOS 原生图形化管理与审计前端：负责随包守护进程的生命周期托管、网络捕获通道递进配置（Surge 模块 / `mitmproxy` 透明捕获 / 自带代理）、零明文掩码审计展示、桌面毛玻璃 HUD 实时告警，以及将「环境变量维护」中的敏感密钥同步注入引擎内存字典。

---

## 2. 外部开源方案评估结论

### 2.1 `GetSHIM/shim-cli` 与 `GetSHIM/shim`（Apache-2.0）—— 核心检测与防回写重点借鉴

经源码级评估，`GetSHIM` 体系对本项目具有极高参考价值，同时也暴露了纯客户端 Hook 的边界缺陷：

| 评估维度 | 可直接借鉴的设计资产 | 局限性与本方案改进点 |
| :--- | :--- | :--- |
| **代码场景低误报识别** | 区分「环境变量读取/代码传参（如 `os.Getenv("DB_PASS")`、`this.password = pwd;`）」与「硬编码字面量 / 默认兜底值」；支持跨行 Base64（含 `git diff` 新增行）解码二次检测、URL `%xx` 与 Unicode 零宽字符归一化；内置自定义正则防 ReDoS 回溯探针 | 原项目偏重欧美与土耳其 PII，缺少国内云厂商（阿里云 `LTAI`、腾讯云 `AKID`、华为云、火山、七牛及飞书/企微/钉钉 Webhook）特征，需在独立引擎中补齐 |
| **DB URI 保结构脱敏** | `postgresql://user:pass@prod-db:5432/app` 仅将账密替换为 `<DB_URI_1>`，保留主机名与库名，不干扰模型排查代码 | 沿用该设计 |
| **防占位符回写毁盘** | `shim-cli` 记录会话签发的占位符名称拦截文件写回；`GetSHIM/shim` 网关在响应流中将 `<SECRET_1>` 原位还原，避免模型把占位符写进磁盘覆盖真密钥 | 采用网关侧 **内存短时映射 + SSE 流式窗口实时还原** 为主、Agent Hook 写回拦截为辅的双保险 |
| **Agent 自保护机制** | 硬编码拦截 Agent 修改安全配置或执行卸载/关闭命令 | 扩展至 Git 链路：**严禁 Agent 执行 `git commit/push --no-verify` 或篡改 `core.hooksPath`** |
| **拦截位置覆盖度** | `shim-cli` 纯靠客户端 Hook，在 Codex / Copilot CLI 下完全拿不到工具读取的文件内容，VS Code 下 `read_file` 结果为空，且完全不管 Git 推送 | 本方案改为 **网络层透明网关（覆盖所有客户端）+ 全局 Git `pre-push` Hook（覆盖 SSH 推送）** |

### 2.2 无 Surge 场景下开源防火墙 / 代理替代方案评估（LuLu vs 透明代理）

针对本机**未安装 Surge** 时的回退方案，对 macOS 主流开源网络工具评估结论如下：

1. **为什么 `LuLu`（Objective-See 开源防火墙）不能直接替代 Surge 做密钥拦截？**
   - `LuLu` 基于 macOS `NEFilterSocketProvider` / `NEFilterDataProvider` 构建，工作在 **网络层/传输层（L3/L4 出站防火墙）**。
   - 它只能识别「哪个进程正在连接哪个域名/IP:端口」（例如 `claude` 连接 `api.anthropic.com:443`），并决定**整条连接放行或阻断**；它**不具备 HTTPS MITM 解密能力**，看不到加密 TLS 隧道内的 JSON Prompt 内容，更无法做敏感词脱敏或改写。
   - 由于正常提问与包含密钥的提问都发往同一个 `api.anthropic.com:443`，用 LuLu 阻断会导致 AI 工具彻底断网不可用。（注：LuLu 的思路仅适合未来扩展“禁止未知进程连接陌生外网 IP”的场景，不能作为密钥网关的流量解密层。）

2. **真正可替代 Surge 的无商业软件回退优先级（先强捕获，再自带降级）：**
   - **优先回退路径（Tier 2：提示用户授权下载/集成 `mitmproxy` 开源透明捕获）**：当检测到本机没有安装 Surge 时，为保证与 Surge 增强模式同等级的**无盲区拦截能力**（防止独立原生二进制忽略系统代理漏检），优先提示用户是否同意下载集成 **`mitmproxy` macOS Local Capture 组件（`--mode local`，MIT 开源协议）**。`mitmproxy` 10+ 提供了带 Apple Developer 官方公证签名的 macOS `NetworkExtension` 本地透明捕获驱动，支持**按进程名精准劫持出站流量**（如仅捕获 `claude`、`codex`、`Cursor`、`gh`），天然防本机代理死循环且无需接管全机日常上网流量（若检测到本机已装 `mitmproxy` 或 `mihomo` / `sing-box` 也可直接识别复用）。
   - **兜底降级路径（Tier 3：用户不同意下载外部组件时，使用引擎自带本地代理功能）**：仅当用户明确拒绝下载第三方组件（或处于离线环境）时，回退至独立网关原生内置的 **选择性 HTTP/HTTPS `CONNECT` MITM 代理** + **macOS 系统 PAC 自动代理分流（`networksetup -setautoproxyurl`）** + **`DeskSide` 托管终端环境变量注入**，零外部依赖覆盖遵循系统代理与环境变量的主流客户端，并在界面明确标注其相比 Tier 1/2 的进程盲区边界。

---

## 3. 系统总体架构与三级递进回退接入

```text
                        ┌──────────────────────────────────────────────┐
                        │           DeskSide.app (SwiftUI)             │
                        │  • 安全网关控制台 / 策略开关 / 零明文审计视图  │
                        │  • EnvManager 已知敏感密钥指纹实时同步        │
                        │  • 接入诊断向导 & 毛玻璃 HUD 拦截实时提醒      │
                        └──────────────────────┬───────────────────────┘
                                               │ Unix Socket (0600)
                                               ▼
┌───────────────────┐   ┌──────────────────────────────────────────────┐
│ AI 客户端 & 终端   │   │       独立安全网关守护进程 (bo-guard)          │
│ Claude / Codex    │──▶│  1. 统一密钥识别引擎 (精确字典 + 语法消歧正则) │
│ Cursor / VS Code  │   │  2. LLM 请求阻断(400) 或 占位符脱敏+SSE流式还原│
│ gh / curl / MCP   │   │  3. GitHub API 审计 & Git pre-push 全量扫描   │
└─────────┬─────────┘   └──────────────────────▲───────────────────────┘
          │                                    │
          ▼                                    │ 127.0.0.1:19840
┌──────────────────────────────────────────────┴───────────────────────┐
│                三级递进流量捕获层（按顺序探测与征询回退）                │
│  [Tier 1] 检测到已安装 Surge  ──▶ 直接生成 .sgmodule 复用 Surge MITM  │
│  [Tier 2] 未装 Surge (优先回退)─▶ 提示用户同意下载/集成 mitmproxy 捕获 │
│  [Tier 3] 用户不同意下载外部组件─▶ 降级使用引擎自带本地 MITM+PAC+Env  │
└──────────────────────────────────────────────────────────────────────┘
          +
┌──────────────────────────────────────────────────────────────────────┐
│  [SSH 盲区闭环] 全局 Git core.hooksPath (pre-push 扫描新增 Commit Blob) │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.1 Tier 1：检测到本机已安装 Surge ——「Surge 模块协同模式」（自动首选）

当 `DeskSide` 检测到 `/Applications/Surge.app` 存在时，直接使用 Surge 协同模式：

1. **零额外根证书**：直接复用用户已在系统钥匙串信任的 Surge CA 根证书。
2. **禁止在 Surge 内运行 `requires-body=true` 响应脚本**：避免 Surge 缓冲整个响应体导致大模型 `text/event-stream`（SSE）流式打字机效果卡死，以及大上下文触发 `max-size` 漏检。
3. **无缓冲透明引流与防死循环机制**：
   - `DeskSide` 自动生成 `deskside-guard.sgmodule`，仅将受保护的目标域名（`api.anthropic.com`、`api.openai.com`、`chatgpt.com`、`generativelanguage.googleapis.com`、`api.deepseek.com`、`openrouter.ai`、`api.github.com`、`github.com` 及用户自定义模型域名）加入 `[MITM]` `hostname` 列表。
   - 使用 `requires-body=false` 的轻量请求头路由规则：凡未携带本机网关一次性启动信物（`X-Guard-Hop: <ephemeral_boot_token>`，每次守护进程启动随机生成并写入 `0600` 私有文件）的请求，透明改写转发至 `http://127.0.0.1:19840`。
   - 独立网关完成扫描/脱敏后重新发出的上游请求附带该信物，Surge 校验通过后自动剥离该请求头，并**继续走用户原有的 Surge 海外代理策略组出境**——既彻底避免 MITM 死循环，又防止恶意 Agent 伪造请求头绕过检查。
4. **CLI 证书环境自动补齐**：通过 `DeskSide` 现有的 `EnvManager` 自动挂载 `NODE_EXTRA_CA_CERTS`、`SSL_CERT_FILE` 指向 Surge CA 证书导出路径，确保 Node.js（Claude Code）与 Python 脚本不报证书错误。

### 3.2 Tier 2：未检测到 Surge 时的优先回退 ——「提示下载并集成开源 `mitmproxy` 透明捕获」

当检测不到 `/Applications/Surge.app` 时，优先引导采用内核级开源透明捕获方案，避免因客户端忽略系统代理而产生漏检盲区：

1. **已有环境优先识别**：先检查本机是否已安装 `mitmproxy`（macOS Local Capture 驱动）；若已存在，直接询问用户启用绑定，无需重复下载。
2. **明确提示与授权内部下载集成**：
   - 若本机既无 Surge 也无 `mitmproxy`，`DeskSide` 弹出清晰引导说明：「未检测到 Surge，是否下载并启用开源 `mitmproxy` 本地透明捕获组件（MIT 协议，Apple 官方公证签名）以实现全进程无盲区防护？」并提供「同意下载并集成（推荐）」、「自行手动安装」与「暂不下载，仅使用自带基础代理」三个明确选项。
   - 用户点击**同意**后，由 `DeskSide` 从官方发行源拉取固定版本包、强制校验 **SHA-256 摘要与 Apple 代码签名**，安装至 `~/Library/Application Support/DeskSide/GuardRuntime/`，通过 `--mode local` 按目标进程名（如 `claude`、`codex`、`Cursor`、`gh`）将流量透明导入独立安全网关 `127.0.0.1:19840`（同时自动识别并串联用户本机已有的 Clash Verge / Mihomo / V2Ray 出口，保证海外连接畅通）。
   - 未经用户点击同意，绝不静默联网下载任何第三方组件。

### 3.3 Tier 3：用户不同意下载外部组件时的兜底回退 ——「引擎自带本地 MITM + PAC + 环境注入」

仅当用户在 Tier 2 引导中选择**不同意下载 `mitmproxy`**（或处于完全离线环境）时，回退使用独立引擎自带的零外部依赖能力：

1. **内置选择性 `CONNECT` MITM 引擎**：独立网关在 `127.0.0.1:19840` 提供标准代理服务，仅对白名单内的 AI 与 GitHub 域名动态签发证书解密检查，其余域名一律纯 TCP 直通（不解密、不降速）。
2. **本机私有 CA 一键生成与信任**：在本地生成唯一 `DeskSide Local Guard CA`（私钥权限 `0600`，永不出本机），经用户确认后调用系统 `/usr/bin/security` 写入钥匙串信任，并同步通过 `EnvManager` 注入终端代理（`HTTPS_PROXY`）与 CA 环境变量（`NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE` / `GIT_SSL_CAINFO`）。
3. **精准系统 PAC 分流 + 已有代理串联**：生成本地 `http://127.0.0.1:19840/proxy.pac` 定向分流目标域名，若检测到本机已有 Clash / V2Ray 等代理端口则自动串联为上游出口。
4. **边界透明提示**：在 `DeskSide` 状态栏与面板中明确标识当前处于「自带基础代理模式（Tier 3）」，提示极少数完全忽略系统代理与环境变量的原生进程可能无法被网络层捕获（全局 Git `pre-push` 钩子不受影响），并保留随时一键升级至 Tier 2（集成 `mitmproxy`）的入口。

---

## 4. 双出口防护核心能力细则

### 4.1 统一高精度密钥检测引擎（三层漏斗）

1. **第一层：`DeskSide` 环境变量精确密钥字典（零误报杀手锏）**
   - 直接联动 `DeskSide`「环境变量维护」模块中所有 `kind == .secret` 条目（含托管文件与按需读取的 Keychain 敏感值）。
   - 在守护进程内存中构建 **Aho-Corasick 多模匹配自动机**（同步覆盖原值、Base64 编码值、URL 编码值；长度 `< 6` 的极短值仅在键值上下文命中时告警），磁盘上不额外落盘任何明文副本。
   - 效果：哪怕用户自定义密码不符合任何公开正则格式，只要在 `DeskSide` 环境变量中登记过，外发给模型或推送至 GitHub 时 **100% 零误报精准拦截**。
2. **第二层：国内外高置信度凭证指纹库**
   - **国际主流**：OpenAI (`sk-` / `sk-proj-`)、Anthropic (`sk-ant-`)、Google (`AIza` / `ya29.`)、AWS (`AKIA`)、GitHub (`ghp_` / `gho_` / `ghs_` / `github_pat_`)、GitLab (`glpat-`)、Stripe、Slack/Discord Webhook、NPM (`npm_`)、HuggingFace (`hf_`)、JWT、PEM/PGP/SSH2 私钥、`Authorization: Basic/Bearer`。
   - **国内生态补齐**：阿里云 AccessKey (`LTAI...`)、腾讯云 (`AKID...`)、华为云、七牛云、火山引擎、DeepSeek / 智谱 / 月之暗面 API Key、飞书 / 企业微信 / 钉钉机器人 Webhook Token。
   - **数据库连接串**：`postgres(ql)://`、`mysql://`、`mongodb(+srv)://`、`redis(s)://`、`clickhouse://` 账密段识别。
3. **第三层：代码语法上下文消歧（借鉴 `shim-cli`）**
   - 识别 `.env`、YAML、JSON、TOML、K8s `name/value`、Terraform `default`、代码常量初始化与环境变量 fallback 默认值中的硬编码密钥；
   - 自动豁免环境变量读取调用（`os.Getenv` / `process.env` / `${VAR}`）、变量标识符传递、示例占位符（`<YOUR_API_KEY>`、`xxxx`）、回环 IP 与 Git SSH 仓库地址；
   - 支持用户自定义正则表达式，保存前执行静态嵌套量词检查与动态超时探针（杜绝 ReDoS 拖慢请求）。

### 4.2 大模型出口（LLM Egress）处置策略

- **严格阻断模式（Block）**：发现密钥后立即中止向上游模型转发，直接向客户端返回符合 OpenAI / Anthropic / Gemini 错误规范的 `400` 响应（注明命中的规则名称与所在字段位置，不包含密钥明文），同时唤醒 `DeskSide` 毛玻璃 HUD 悬浮提示。
- **无感脱敏还原模式（Mask & Stream Restore）**：
  - 请求发往上游前将敏感值替换为带类型的编号占位符（如 `<SECRET_1>`、`<DB_URI_1>`）；
  - 在网关进程内存中按会话维护短时映射表（TTL 自动过期淘汰，绝不写盘）；
  - 对上游返回的普通 JSON 及 `text/event-stream`（SSE）流式块执行滑动窗口实时还原（仅还原文本内容与 Tool Call 参数字符串，严格跳过 `id`、`tool_call_id`、`thought_signature` 等协议元数据字段），确保流式输出丝滑不卡顿，且模型调用文件编辑工具时写回本地磁盘的永远是真实原值。

### 4.3 GitHub 推送出口（Git & GitHub Egress）全链路封堵

1. **全局 Git `pre-push` / `pre-commit` 钩子（封堵 SSH 22 端口与本地提交）**：
   - `DeskSide` 支持一键配置全局 `git config --global core.hooksPath ~/.config/deskside-guard/git-hooks`。
   - **无损链式兼容**：全局钩子执行完密钥扫描后，自动检测并继续调用当前仓库原有的 `.git/hooks/<hook>`（或 Husky / pre-commit 配置），绝不破坏项目既有工作流。
   - **全量待推送 Commit 扫描**：在 `pre-push` 阶段计算 `remote_oid..local_oid` 范围内**所有待推送 Commit 的新增 Blob 差异**——即使开发者在早期 Commit 误提交了 `.env`、随后又用新 Commit 删除了文件，只要历史 Commit 中残留密钥，推送仍会被当场阻断，并输出命中的 Commit Hash、文件路径、行号与修复指引。
2. **GitHub HTTPS & API / MCP 流量拦截（封堵非 Git CLI 渠道）**：
   - 通过网络捕获层审计发往 `api.github.com`（创建/更新文件 Contents API、Gist、PR/Issue 正文与评论、GitHub MCP Server 远程调用）及 `https://github.com/*/*.git/git-receive-pack` 的请求体，发现明文密钥立即阻断。
3. **Agent 防绕过自保护**：
   - 可选向 Claude Code / Codex 注入轻量 `PreToolUse` 钩子：一旦检测到 AI Agent 试图执行 `git push --no-verify`、`git commit --no-verify`、篡改 `core.hooksPath`、修改 `.sgmodule` 或停止守护进程，立即拒绝执行并通知用户。

---

## 5. 隐私安全底线与 `DeskSide` 界面规划

### 5.1 安全网关自身的隐私铁律

1. **零明文审计日志**：拦截与脱敏记录仅持久化「时间戳、目标域名/仓库、触发进程、规则名称、文件路径、掩码摘要（如 `LTAI****8f2a`）及不可逆 SHA-256 指纹截断值」，**任何情况下不将完整密钥明文或完整请求包体写入磁盘**。
2. **本地闭环零遥测**：守护进程仅监听回环地址 `127.0.0.1` 与权限 `0600` 的本地 Unix Socket，无任何外部账号体系或遥测上报。
3. **异常退出自动恢复网络**：守护进程退出或崩溃时，通过守护清理钩子与 `DeskSide` 生命周期监听自动回滚系统 PAC 设置（若处于 Tier 3 自带代理模式），绝不造成用户本机断网。

### 5.2 `DeskSide`「安全网关」视图结构（对齐现有全局侧边栏设计）

在 [SettingsWindow.swift](file:///Users/zhangsubo/orca/workspaces/bo-finder/blenny/BoFinderApp/SettingsWindow.swift) 的 `gateway` 页面中，按与「文件工具」一致的分段控制器组织 4 个子面板：

1. **总览与防护开关**：守护引擎连接状态、当前激活的网络捕获层级（`Tier 1: Surge 协同` / `Tier 2: mitmproxy 透明捕获` / `Tier 3: 自带基础代理`）、Git 全局钩子状态、今日扫描流量与已拦截次数统计卡片。
2. **拦截与脱敏记录**：按时间倒序展示 LLM 外发与 GitHub 推送拦截事件（脱敏掩码展示），支持按文件相对路径或密钥指纹哈希一键加入项目白名单（用于豁免测试假凭证）。
3. **策略与规则库**：
   - 大模型默认动作切换（`严格阻断` / `无感脱敏并流式还原`）；
   - 「自动同步保护 `DeskSide` 环境变量中的所有密码密钥」开关；
   - 内置规则分组开关（国内云厂商、国际云与 AI 平台、私钥与证书、数据库连接串）与自定义正则编辑器（内置实时回溯耗时校验）。
4. **接入与诊断（Doctor）**：
   - 本机环境递进探测（先检查 Surge → 未安装则提示授权下载/集成 `mitmproxy` → 用户不同意时配置自带基础代理，同时检查 Git 全局钩子与终端 CA 环境变量）；
   - 模式切换管理（支持从 Tier 3 随时授权下载升级至 Tier 2 `mitmproxy` 透明捕获，或在安装 Surge 后切换至 Tier 1）；
   - 「发送模拟测试密钥」端到端自检按钮（使用合成假密钥验证拦截链路是否生效）。
