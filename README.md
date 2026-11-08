<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Oases CPA：在 macOS 上部署、连接并管理自己的 AI API 中转站">
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#从部署到第一次调用">使用路径</a> ·
  <a href="#安全边界">安全边界</a> ·
  <a href="#开发与构建">开发构建</a> ·
  <a href="#english-overview">English</a>
</p>

Oases CPA 是一个原生 macOS 控制台，用来部署、连接并管理用户自己的
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 与
[CPA Manager Plus](https://github.com/seakee/CPA-Manager-Plus)。默认可直接部署到当前 Mac，也可以通过 SSH 管理 Linux/macOS VPS；日常的 Provider、模型、API Key、用量、成本和运行状态都在一个 App 内完成。

> 当前版本为 `0.1.4` 预发布版本，最低支持 macOS 14。发行构建同时支持 Apple Silicon 与 Intel Mac。

## 它解决什么问题

CLIProxyAPI 能把多个 AI Provider 汇聚为统一的兼容 /v1 接口，但对初次接触终端、配置文件、SSH 隧道和服务进程的用户并不轻松。Oases CPA 把这条链路整理成可见、可恢复的 macOS 工作流：

| 目标 | Oases CPA 提供的体验 |
| --- | --- |
| 快速开始 | 本机优先的一键部署；环境检测、下载、校验、配置和启动归入一条进度流程 |
| 管理远程机器 | 保存多个本机或 SSH/VPS 目标，通过本机回环隧道访问网关、引擎和 CPA Manager Plus 的管理 API |
| 接入 AI 服务 | 原生管理标准兼容接口、Gemini、Claude、Codex、xAI、Vertex 等凭证与路由配置 |
| 找到可用模型 | 显式请求上游 `/models`，展示模型 ID，并提供不会自动改写配置的连通性检查 |
| 交付调用凭据 | 创建、轮换、删除调用 API Key，直接给出带 `/v1` 的 Base URL |
| 观察真实运行 | 实时仪表盘、六维用量分析、请求事件、配额、账号待办、日志与凭证健康巡检 |
| 估算模型成本 | 从 models.dev、LiteLLM 与 OpenRouter 公开元数据同步价格，并结合真实用量估算成本 |

## 从部署到第一次调用

<p align="center">
  <img src="./assets/readme/first-request.svg" width="100%" alt="从连接目标、一键部署、添加 AI Provider 到创建 API Key 并发出第一个 /v1 请求的四步流程">
</p>

完成部署后，在 AI IDE 或 SDK 中填写：

```text
Base URL   http://127.0.0.1:8317/v1
API Key    在「调用 API Key」页面创建
API 格式   兼容 /v1 / Chat Completions
Model ID   从仪表盘或 Provider 的 /models 结果中选择
```

所有服务只监听 `127.0.0.1`：网关 API `8317`、网关管理 `18320`、引擎（CLIProxyAPI）`18316`、CPA Manager Plus `18317`；旧拓扑（0.1.x）只有引擎 `8317` 与 CPA Manager Plus `18317`。远程目标通过 SSH 把这些端口映射到本机回环地址，因此不需要把任何管理端口直接暴露到公网。外部发布 API 时，仍应由用户自行配置 TLS、反向代理和防火墙。

## 快速开始

### 安装发行版

已签名的安装包将在 [GitHub Releases](https://github.com/qingtengCHINA/OasesCPA-Desktop/releases) 提供。打开 `OasesCPA.dmg` 后，将 Oases CPA 拖入 Applications 即可。

如果 Releases 中暂时没有适合当前版本的安装包，请从源码运行。

### 从源码运行

要求：macOS 14 或更新版本，以及带 Swift 6 的 Xcode 工具链。

```bash
git clone https://github.com/qingtengCHINA/OasesCPA-Desktop.git
cd OasesCPA-Desktop
./script/build_and_run.sh
```

验证构建并确认进程成功启动：

```bash
./script/build_and_run.sh --verify
```

首次打开时，欢迎引导会说明 CPA、CLIProxyAPI 和完整调用路径。进入 App 后：

1. 打开「连接与部署」，保持默认的“本机 Mac”，然后点击部署。
2. 部署完成后，在「AI 提供商」添加自己的 AI 服务，可按需获取 `/models` 并测试连通性。
3. 在「调用 API Key」创建调用密钥。
4. 将 App 给出的 `/v1` Base URL、API Key 和 Model ID 填入支持兼容 /v1 格式的 AI IDE 或 SDK。

## 原生管理能力

### 连接与生命周期

- 本机原生二进制部署，以及面向进阶用户的 Docker Compose 模式。
- 通过 SSH 连接 Linux/macOS VPS，独立保存多个目标和主机指纹。
- 部署失败日志、可恢复清理、升级、备份和上一版本回滚。
- 每 30 秒检查服务与 SSH 隧道；异常时按用户保存的运行意图恢复。
- 关闭主窗口后继续在菜单栏运行；真正退出 App 时会回收 SSH 隧道和占用端口的子进程。

### Provider、模型与认证

- 原生管理兼容 Provider 及内置 Provider 凭证池。
- API Key 权重、优先级、冷却策略、独立代理、Headers、模型别名/映射、输入/输出模态与未知高级字段保真。
- Codex、Anthropic、Antigravity、Kimi、xAI 与 OpenRouter PKCE OAuth。
- 认证文件可按 Provider、状态和搜索词筛选，支持排序、紧凑显示、模型清单、额度证据、字段编辑、批量启停与批量删除。
- Provider 编辑窗口与配置页均提供未保存变更保护。

### 原生 CPAMP 工作台

这部分直接按 CPA Manager Plus 与 CLIProxyAPI 的当前管理 API 契约实现，不依赖网页套壳：

| 工作台 | 原生能力 |
| --- | --- |
| 用量分析 | 总览、趋势、模型、客户端 Key、凭证和热力图六个视角；支持时间范围、粒度、模型、Key、Provider、状态与缓存筛选 |
| 认证文件 | Provider 分组、搜索、排序、异常过滤、模型目录、额度信息、优先级/备注等字段编辑和批量操作 |
| 配置面板 | 面向新手的可视化快捷配置、完整 YAML 源文件编辑和 CPAMP 设置三种模式；失败字段可直接重试 |
| 系统信息 | CLIProxyAPI、CPA Manager Plus 与使用指南快捷入口，以及从当前网关 `/v1/models` 实时读取并按 Provider/模型族分组的模型目录 |

App 不再内嵌网页面板：请求监控的高级筛选与原始字段、请求错误文件下载、价格同步候选的逐个采用都已是原生页面。

### 监控、配额与成本

- 仪表盘每 5 秒读取当前目标状态，无需手动刷新。
- 六维用量分析与高级筛选、真实请求事件流、认证历史和脱敏错误证据。
- Codex、Claude、Kimi 与 xAI 配额窗口、冷却状态和显式重置。
- 公开模型价格自动同步、手动价格覆盖和本地成本估算。

### macOS 体验

- SwiftUI 原生界面，支持中文、英文、浅色、深色和跟随系统。
- 首次使用欢迎引导、可滚动且可缩放的独立编辑窗口、菜单栏运行状态。
- 部署过程支持安全暂停、继续和取消；取消时可选择保留现场，或彻底移除受管部署目录、服务与凭据。
- 启动后定期检查官方 GitHub Release Tag；发现新版本时在标题栏提示，并可直接下载、打开最新 DMG。
- 设置页底部实时读取 App Bundle，显示实际版本号与构建号。
- 完整 AppIcon、Xcode 工程、Privacy Manifest、Developer ID/App Store 两套 Entitlements。

## 安全边界

Oases CPA 会执行下载、安装、进程管理和远程 SSH 操作，因此所有有副作用的步骤都需要明确的用户动作。

- CPA/CPAMP 管理密钥与每个目标的 SSH 私钥存放在 macOS Keychain。
- 启动 App 或切换目标不会自动读取钥匙串；只有用户点击连接后才会访问凭据。
- SSH 使用 App 专属 `known_hosts`、首次连接时确认并固定的主机密钥（`StrictHostKeyChecking=yes`）与 `BatchMode`，不会修改用户全局 SSH 主机记录。
- Provider 连通性检查需要确认，只读取安全摘要，不展示密钥、请求头、响应正文或原始元数据。
- 远程管理 API 默认通过 SSH 隧道绑定本机回环地址。
- 停止生命周期操作前会确认 PID 对应进程确实属于 Oases CPA 安装目录。
- 每次升级都会在安装目录下留下一份 `backups/upgrade-*`，没有完成的备份会移到 `backups/incomplete-*`。每份备份都含有一份 `gateway-data`（包括客户端 Key 和搜索服务商 Key），目录权限为 0700；升级和回滚都不会删除它们（只有彻底移除整个部署时才会一并删除），不再需要回滚到对应版本时，可以手动删除旧的备份目录。

### 部署的程序会联网做什么

- 引擎（CLIProxyAPI v8.0.51）在启动时和此后每 3 小时访问 `registry.npmjs.org` 与一个 Antigravity 版本服务，查询客户端版本号。这是引擎自身的行为，引擎没有关闭它的设置。
- 网关在 `/v1/models` 被调用、且本地缓存超过 12 小时时，在后台读取公开模型目录 `MODEL_CATALOG_URL`（默认 `https://openrouter.ai/api/v1/models`），不发送任何 Key。网关环境变量 `MODEL_CATALOG_URL=off` 会关闭它（已有的缓存仍会读取）；App 目前没有提供这个开关。网关的 `gateway/run.sh` 在每次部署和升级时重新生成，手工修改都会丢失，只有 `export MODEL_CATALOG_URL=…` 这一行（值为 `off` 或 `https://` 地址）会被带到新文件里。
- 引擎的用量队列（`/v0/management/usage-queue`，CPA Manager Plus 从这里收集用量）中的每条记录都以明文带着发起请求的客户端 API Key，`source` 字段带着所用的上游凭证；CPA Manager Plus 导入时会遮蔽 `source`。因此引擎端口 `18316`、CPA Manager Plus 端口 `18317` 与网关管理端口 `18320` 只能留在本机回环地址，远程目标通过 SSH 隧道访问，管理密钥要像上游凭证一样保管。

## 开发与构建

项目同时提供 Swift Package 和可上架维护的 Xcode 工程：

```bash
swift test
xcodegen generate
open "OasesCPA.xcodeproj"
```

### 测试

许多测试通过“跟随系统”断言中文文案（开发语言是中文）。在英文系统的 Mac 上先把系统语言偏好设为中文再运行，CI 也是这样做的：

```bash
defaults write -g AppleLanguages -array zh-Hans   # 之后可用 defaults delete -g AppleLanguages 还原
swift test
```

`OasesCPA.xcodeproj` 由 `project.yml` 生成，包含 Debug、Release 与 AppStore 配置。不要把 Team ID、证书或 App Store Connect 凭据提交到仓库。

构建身份在构建时配置：`Config/Base.xcconfig` 给出中性的默认值（不签名团队、`com.example` 包名前缀、不启用自动更新、不显示作者）。把 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`（已被 git 忽略），填入自己的 `DEVELOPMENT_TEAM`、`OASES_BUNDLE_ID_PREFIX`、`OASES_UPDATE_REPOSITORY`（`owner/name`，留空即关闭自动更新）与作者信息，再运行 `xcodegen generate`。

### 本机运行的隔离

开发机上若已有一套在用的部署（默认目录 `~/.oases-cpa`），App 一启动就可能检测并接管它：首次运行时会自动检测默认安装目录，接管后的 30 秒巡检会调用 `ensureRunning` 重启服务。测试进程或带启动参数 `-OasesDisableAutoProbe` 运行时，`DeploymentStore` 不做自动检测、不自动接管、也不启动巡检。测试进程按两种方式识别：只有 Xcode 的测试宿主会设置环境变量 `XCTestConfigurationFilePath`；`swift test` 不设置它，这时靠进程里已加载 XCTest（`NSClassFromString("XCTestCase")` 不为空）来识别，正常启动的 App 不链接 XCTest。图形界面调试请同时做到：

- 使用单独的包标识（`Config/Local.xcconfig` 中的 `OASES_BUNDLE_ID_PREFIX`，或构建时在命令行传入 `OASES_BUNDLE_ID_PREFIX=dev.example.oases-e2e OASES_UPDATE_REPOSITORY=`），这样不会读到正式构建保存的目标；
- 同时把 `HOME` 和 `CFFIXED_USER_HOME` 设为一个临时目录（子 shell 通过 `$HOME` 展开 `~`），并加上 `-OasesDisableAutoProbe`：

  ```bash
  SCRATCH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/oases-gui.XXXXXX")"
  HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" \
    "<DerivedData>/Build/Products/Debug/Oases CPA.app/Contents/MacOS/Oases CPA" -OasesDisableAutoProbe
  ```

- 不要在本机运行 `xcodebuild … test`：它会把 App 作为测试宿主启动；用 `swift test` 与 `xcodebuild … build-for-testing`；
- 设置 `HOME` 和 `CFFIXED_USER_HOME` 不会改变 App 的偏好设置位置：偏好文件 `~/Library/Preferences/<包标识>.plist` 仍写在真实的用户目录里。使用单独的包标识时它只属于这个调试包；每次图形界面走查之前和之后，把这个文件移到废纸篓（`mv` 到 `~/.Trash/`），这样上一次运行留下的内容不会带进下一次；
- 钥匙串服务名 `Oases CPA Credentials` 不随包标识区分，最彻底的隔离是使用一个临时的 macOS 用户账户。

### 生成 DMG

每次准备新版本时，先自动递增 patch 版本号与 build 号，并同步重新生成 Xcode 工程：

```bash
./script/bump_patch_version.sh
```

例如 `0.1.4 (40)` 会变为 `0.1.5 (41)`。然后生成发行包：

```bash
./script/package_release.sh
```

打包脚本从环境变量读取包标识 `OASES_BUNDLE_ID`（默认 `com.example.cpa.macos`）与团队 `OASES_TEAM_ID`。只用于本机测试的 ad hoc 包需要显式声明：

```bash
ALLOW_UNTRUSTED_LOCAL_RELEASE=1 NOTARIZE=0 ./script/package_release.sh
```

正式分发要求 Developer ID 签名与公证，签名身份必须属于 `OASES_TEAM_ID`，并且必须显式设置自己的 `OASES_BUNDLE_ID`（拒绝中性的 `com.example…`）。自动更新读取的仓库 `OASES_UPDATE_REPOSITORY`（`owner/name`）未设置环境变量时取自 `Config/Local.xcconfig`；为空时正式打包会拒绝，确实要发布不带自动更新的版本时设置 `ALLOW_RELEASE_WITHOUT_UPDATER=1`。脚本会打印包标识与更新器状态：

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Company (TEAMID)" \
OASES_TEAM_ID="TEAMID" OASES_BUNDLE_ID="<your.bundle.id>" \
OASES_UPDATE_REPOSITORY="<owner>/<repo>" \
APP_VERSION="0.1.5" APP_BUILD="41" \
NOTARIZE=1 NOTARY_PROFILE="oases-cpa-notary" \
./script/package_release.sh
```

App Store 导出所需的 `ExportOptions.plist` 由模板生成（输出文件已被 git 忽略，已存在时不会覆盖）：

```bash
OASES_TEAM_ID="TEAMID" ./script/package_release.sh --render-export-options script/ExportOptions.plist
```

产物位于 `dist/release/<version>-<build>/`。DMG 包含 App、Applications 快捷方式、背景图和 Finder 拖拽布局。

<details>
<summary><strong>显式运行真实部署集成测试</strong></summary>

这些测试会下载上游包或启动临时服务，默认不会执行：

```bash
OASES_CPA_RUN_INTEGRATION=1 swift test \
  --filter RuntimeDecodingTests/testNativeDeploymentEndToEndWhenExplicitlyEnabled

OASES_CPA_RUN_SSH_INTEGRATION=1 swift test \
  --filter RuntimeDecodingTests/testSSHNativeDeploymentEndToEndWhenExplicitlyEnabled

OASES_CPA_RUN_DOCKER_INTEGRATION=1 swift test \
  --filter RuntimeDecodingTests/testDockerDeploymentEndToEndWhenExplicitlyEnabled
```

真实测试会占用临时端口或容器，并在结束后执行清理。

</details>

### 参与贡献

CI 的私有字符串扫描（`.github/workflows/private-scan.yml`）会拒绝作者或提交者邮箱不在 `script/private-allowlist.txt` 中的提交，以免私人邮箱进入历史；因此外部提交的 Pull Request 会先失败，squash 合并也会让默认分支变红。请使用 GitHub 的 noreply 地址提交（`<id>+<name>@users.noreply.github.com`，可在 GitHub 的邮箱设置中查看）；维护者合并时把该地址连同理由加入 `script/private-allowlist.txt`。在 GitHub 网页上完成的合并与 squash 提交由 GitHub 自己的地址提交，允许清单中已有的仅限提交者的条目已经覆盖它。

## App Store 状态

当前完整版会下载、安装并执行 CLIProxyAPI 与 CPA Manager Plus，因此不能把现有构建描述为已经满足 Mac App Store 审核要求。仓库保留了 AppStore 配置，但正式提交前应先阅读 [APP_STORE_READINESS.md](./APP_STORE_READINESS.md)，并按文档拆分不包含本机组件部署的商店版本。

直接从 GitHub Releases 下载 DMG 的更新机制同样属于 Developer ID / GitHub 直接分发流程；未来的 Mac App Store 变体应关闭该机制，并只通过 Mac App Store 更新。

完整版更适合通过 Developer ID 签名、公证和 GitHub Releases 直接分发。

## 项目结构

```text
Sources/OasesCPA/
├── App/          App 生命周期、窗口、命令与菜单栏
├── Views/        部署、仪表盘、Provider、配置与诊断界面
├── Stores/       App 状态、实时数据和部署状态机
├── Services/     SSH、部署、Keychain、生命周期与管理 API
├── Models/       CLIProxyAPI / CPAMP 请求响应模型
├── Components/   原生视觉组件
└── Resources/    图标、本地化、隐私清单与开源许可证

Tests/OasesCPATests/   状态机、API 契约、安全边界与部署测试
script/                本地运行与发行打包脚本
```

## 开源引用与隐私

Oases CPA 独立开发，不隶属于以下上游项目：

- [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — MIT License
- [seakee/CPA-Manager-Plus](https://github.com/seakee/CPA-Manager-Plus) — MIT License

完整版权和许可证文本见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)，App 内也可从“设置 → 关于 → 开源许可与致谢”查看。

- 隐私声明：App 的“设置 → 关于”只在构建时设置了 `OASES_PRIVACY_POLICY_URL`（`Config/Local.xcconfig`）时显示隐私声明链接；维护者的发行构建会设置它，指向分发方自己的隐私声明。
- [作者 · QingTeng Studio](https://qingtengstudio.com/)
- [CLIProxyAPI 文档](https://help.router-for.me/)

## English overview

Oases CPA is a native macOS control plane for deploying and managing your own CLIProxyAPI and CPA Manager Plus stack. It supports local deployment and SSH-connected Linux/macOS servers, then brings providers, model discovery, API keys, usage, costs, quotas, logs, and service health into one SwiftUI app.

The shortest path is: **deploy locally → add a provider → fetch `/models` → create an API key → call the `/v1` endpoint**. Remote targets stay accessible through localhost SSH tunnels by default, and management credentials are stored in macOS Keychain only after an explicit connection action.

```bash
git clone https://github.com/qingtengCHINA/OasesCPA-Desktop.git
cd OasesCPA-Desktop
./script/build_and_run.sh
```

Requires macOS 14+ and a Swift 6 Xcode toolchain. See [App Store readiness](./APP_STORE_READINESS.md) and [third-party notices](./THIRD_PARTY_NOTICES.md) before distribution. Maintainers: the steps before making the repository public (build configuration, private-string scanning, history rewrite) are in [docs/open-source-release.md](./docs/open-source-release.md).

Network and privacy: the engine (CLIProxyAPI v8.0.51) contacts `registry.npmjs.org` and an Antigravity version service at start and every 3 hours, and has no setting to turn that off. The gateway fetches the public model catalog `MODEL_CATALOG_URL` (default `https://openrouter.ai/api/v1/models`) in the background when `/v1/models` is called and its cache is older than 12 hours, without sending any key; `MODEL_CATALOG_URL=off` disables it, but the app does not offer that switch yet. The gateway's `gateway/run.sh` is regenerated on every install and upgrade, so manual edits are lost, except that an `export MODEL_CATALOG_URL=…` line (`off` or an `https://` URL) is carried over. Every record in the engine's usage queue (`/v0/management/usage-queue`, which CPA Manager Plus collects) carries the client API key in plain text and the upstream credential in `source` (CPA Manager Plus masks `source` on import), so keep the engine (`18316`), CPA Manager Plus (`18317`) and gateway admin (`18320`) ports on loopback and reach remote targets through the SSH tunnel.

Backups: every upgrade leaves a `backups/upgrade-*` directory in the install directory, and an unfinished one is moved to `backups/incomplete-*`. Each holds a copy of `gateway-data`, including client keys and search-provider keys, in 0700 directories. Upgrades and rollbacks never delete them (only removing the whole deployment does); remove old ones by hand once you no longer need to roll back to them.

Contributing: the private-string scan in CI rejects every commit whose author or committer e-mail address is not listed in `script/private-allowlist.txt`, so that no private address reaches the history; a pull request from outside fails it, and a squash merge would leave the default branch red. Commit with your GitHub noreply address (`<id>+<name>@users.noreply.github.com`, shown in GitHub's e-mail settings); the maintainer adds that address to `script/private-allowlist.txt`, with a reason, when merging. Merge and squash commits made in GitHub's web UI are committed by GitHub's own address, which the existing committer-only row of the allowlist already covers.
