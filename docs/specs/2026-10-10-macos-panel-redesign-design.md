# macOS 版面板风格改版（2026-10-10）

## 目标

Oases CPA for macOS 是面向大众的桌面应用。这次改版让它和作者自己的线上部署所用的网页面板看起来是同一套产品，同时保留 macOS 原生控件和交互：侧栏、工具栏、表格、设置窗口、菜单栏图标。

范围只限于外观和交互，部署、SSH、运行时 API、数据模型都不改。参考资料见 [`../design-research-2026-10-10.md`](../design-research-2026-10-10.md)。

## 决定

1. **设计系统先行。** 先替换共享层，然后按页面逐个改结构。
   - 各页面原本就大量引用共享样式：`.oasesCard` 114 处，`Color.oases*` 约 500 处，`StatusPill` 67 处。
   - 替换共享层后，所有页面一次换皮，之后再逐页调整结构。
2. **颜色和尺寸 token** 写在 `Support/DesignTokens.swift` 的 `Oases.Color / Space / Radius / Motion / Tone`，取值与网页面板一致，只把尺寸换成 macOS 的规格。
   - 内容区底色：浅色 `#FAFAFA`，深色 `#000`。
   - 卡片：浅色 `#FFF`，深色 `#0A0A0A`。边框 1 pt，浅色 `#EAEAEA`，深色 `#1F1F1F`。圆角 12，没有阴影。
   - 旧的颜色名（`oasesBlue/Green/Orange/Red/Mint/Purple/Ink`）映射到面板 token，旧页面不改代码也能拿到新配色。
   - 侧栏保留系统材质和半透明效果，内容区用不透明底色。
3. **按钮。**
   - 主按钮 `.oasesPrimary`：浅色模式黑底、深色模式白底，跟随 `controlSize`。原来的 56 处 `.borderedProminent` 全部换成它。每个视图最多一个主按钮，不放进工具栏。
   - 次要按钮继续用系统的 `.bordered`。
   - App 的强调色（tint）统一为 `#1D9BF0`，用于开关、链接和焦点环。
4. **状态色**只用在圆点、图标和关键词上。
   - 指标卡不再给每张卡配一个颜色，图标统一用中性色。
   - `StatusPill` 改成细边框的徽章。默认的实心圆图标显示成 6 pt 圆点。
5. **侧栏分组**和网页面板一致。
   - 分组为：概览 / 账号 / 网关 / 配置 / 运维（`SectionGroup.sections` 决定组内顺序）。
   - 侧栏底部只放一行连接状态。
   - 同样的状态也显示在窗口副标题里（`.navigationSubtitle`），工具栏标题显示当前页面名。
6. **页面之间互相跳转，不做孤岛。**
   - 仪表盘每张卡的标题可以点击跳转：流量 → 用量分析，健康时间线 / 最近请求 → 请求监控，模型成本 → 成本与价格，渠道 → 认证文件。
   - 未连接时，主按钮改为"连接与部署"。
7. **仪表盘顶部**改成一行状态栏：状态点、一句结论、目标环境、可复制的 Base URL、最近刷新时间、一个主按钮。页面标题移到工具栏，内容区不再重复。

## 组件

`Components/OasesComponents.swift` 提供以下组件：

| 组件 | 用途 |
|---|---|
| `OasesPrimaryButtonStyle` | 黑白主按钮 |
| `StatusDot` / `ToneBadge` | 状态圆点和状态徽章 |
| `OasesSectionHeader` | 分区标题，可以带 › 跳转 |
| `OasesRowGroup` | 一组行，行间有分隔线。macOS 15 以上用 `Group(subviews:)`，14 上退回为不带分隔线 |
| `OasesLinkRow` | 可点击的行，鼠标悬停时整行高亮 |
| `OasesValueRow` | 标签 / 数值行 |
| `OasesMonoValue` | 等宽显示的值，带复制按钮 |
| `OasesEmptyState` | 空状态 |

## 验证

- **调试启动参数**：`-OasesQASection <section>` 直接打开某个分区，只在 DEBUG 构建中生效。`-oases.cpa.appearance dark|light` 是标准 defaults 参数，用来切换外观。
- **截图**：用 `screencapture -l <窗口号>` 截取 App 窗口。每个分区在深色和浅色下各截一张。
- **测试**：`swift test` 全部通过。
