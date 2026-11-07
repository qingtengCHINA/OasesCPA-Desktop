# Oases CPA for Mac：设计调研与落地规则（2026-10-10）

> 目标：Mac 版的视觉照搬作者自己的线上部署所用的 Web 管理面板，走 Geist 式近单色风格；结构上仍然只用原生组件（NavigationSplitView、Toolbar、Table、Inspector、Settings、MenuBarExtra、Sheet）。
> 写法：每条规则后的方括号里写来源。标"建议值"的是根据来源推出来的数，没有官方数字可以直接引用。

---

## 0. 设计令牌（Geist 映射到 macOS）

| 令牌 | Light | Dark | 用途 | 依据 |
|---|---|---|---|---|
| `Canvas` | #FAFAFA | #000000 | 内容区底色（实色） | Geist background-200 作次级背景 [vercel.com/geist/colors] |
| `Card` | #FFFFFF | #0A0A0A | 卡片和表格容器 | Geist background-100 是默认元素背景 [同上] |
| `Border` | #EAEAEA | #1F1F1F | 1 pt 描边 | Gray 400 是默认描边，500/600 用于 hover 和 active [同上] |
| `Hover` / `Active` | gray-200 / gray-300 | 对应暗色阶 | 自绘按钮和卡片的悬停、按下态 | 100 默认、200 hover、300 active [同上] |
| `Ink` | #000 | #FFF | 主按钮底色（文字取反色） | Geist 的 default 变体就是主按钮 [vercel.com/geist/button] |
| `Accent` | #1D9BF0 | #1D9BF0 | 写入 Assets 的 AccentColor，用于焦点环、链接、选中 | 系统强调色机制 [WWDC20 10104] |
| `OK / Warn / Err` | #00BA7C / #FBBF24 / #F4212E | 同 | 只用于 8 pt 状态点和关键词 | "颜色只用来传达含义" [WWDC25 323 笔记] |

做法：所有颜色放在 Asset Catalog 的 Color Set 里，同时配 Any/Dark 两种外观，再加一套 High Contrast 变体（描边加深一级）。文字一律用系统的 `.primary` 和 `.secondary`，这两个对应 Geist 的 gray-1000 和 gray-900，好处是在侧栏材质上能自动获得 vibrancy。[developer.apple.com/design/human-interface-guidelines/materials]

---

## 1. 窗口骨架

**1.1 结构**：`NavigationSplitView` 用两栏（侧栏 + 详情），再在详情上挂 `.inspector`。只有日志这类"列表 → 详情"的页面才考虑三栏。HIG 的说法是：层级超过两层时，在侧栏和详情之间加一个内容列表。[HIG Sidebars: developer.apple.com/design/human-interface-guidelines/sidebars]

**1.2 侧栏分组**：层级最多两层，组名要短。[HIG Sidebars] 建议分成：
- 概览：仪表盘
- 网关：提供商凭证、API Keys、模型与路由
- 运维：用量、日志、部署
图标用 SF Symbols。HIG 默认侧栏图标跟随强调色；如果想保持 Geist 的单色感，可以改成 monochrome tint（AppKit 里是 `NSTintConfiguration.monochrome`）。固定色只用在需要突出的个别项上，比如 Mail 里黄色的 VIP。[HIG Sidebars；WWDC20 10104: developer.apple.com/videos/play/wwdc2020/10104/]
侧栏宽度（建议值）：`.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)`。[developer.apple.com/documentation/swiftui/view/navigationsplitviewcolumnwidth(min:ideal:max:)]

**1.3 侧栏底部状态**：HIG 明确说不要把关键信息或操作放在侧栏或窗口底部，因为窗口底边经常被拖到屏幕外。[HIG Sidebars；HIG Windows: developer.apple.com/design/human-interface-guidelines/windows] 所以底部用 `.safeAreaInset(edge: .bottom)` 只放一行次要信息（例如"● 运行中 · v7.2.110 · :8317"），同样的状态必须在标题副标题和菜单栏里各出现一次。

**1.4 标题与副标题**：
- 标题写当前分区名，不要写 App 名，长度控制在 15 个字符以内。[HIG Toolbars: developer.apple.com/design/human-interface-guidelines/toolbars]
- 副标题用 `.navigationSubtitle("运行中 · 3 个提供商")`，macOS 会把它显示在标题栏里，用法和 Mail 的未读数一样。[developer.apple.com/documentation/swiftui/view/navigationsubtitle(_:)；WWDC20 10104]

**1.5 工具栏**：用 `.windowToolbarStyle(.unified)`，最多三组。
- 前缘：侧栏开关和标题，由系统放置。
- 后缘依次是：刷新、搜索、唯一的主操作（如"添加凭证"）、检查器开关。HIG 规定检查器按钮和搜索放在后缘，主操作只能有一个，并且在后缘。[HIG Toolbars]
- 搜索：把 `.searchable()` 挂在 `NavigationSplitView` 上，Mac 会自动放到右上角。[WWDC25 323 笔记: wwdcnotes.com/documentation/wwdc25-323-build-a-swiftui-app-with-the-new-design/]
- 不要给工具栏加自定义背景或着色，macOS 26 会自动把按钮分组放进 Liquid Glass。需要拆组时用 `ToolbarSpacer(.fixed)`。[HIG Toolbars；WWDC25 323]
- 工具栏里的每一项都必须在菜单栏里有对应命令，例如自定义一个"网关"菜单，包含 启动 / 停止 / 重启。[HIG Toolbars macOS；HIG The menu bar: developer.apple.com/design/human-interface-guidelines/the-menu-bar]
- 不要在工具栏里放设置按钮。[HIG Settings]

**1.6 窗口尺寸（建议值）**：
- 最小 900×600，默认 1200×760。推算依据：侧栏 220 + 表格至少 560 + 检查器 300，大约需要 1080，窗口低于这个宽度时检查器会自动收起。
- 写法：`.frame(minWidth: 900, minHeight: 600)` 加上 `.windowResizability(.contentMinSize)`。[developer.apple.com/documentation/swiftui/scene/windowresizability(_:)]
- HIG 还建议分栏的最小宽度要设到分隔线不会"消失"的程度，分隔线用 1 pt 的 thin 样式。[HIG Split views: developer.apple.com/design/human-interface-guidelines/split-views]
- 关于窗口、首次引导这类窗口应该关闭状态恢复：`.restorationBehavior(.disabled)`。[WWDC24 10148: developer.apple.com/videos/play/wwdc2024/10148/]

---

## 2. 仪表盘与列表密度

**2.1 Table 和 List 怎么选**：
- 凭证、API Key、用量明细这类多列记录用 `Table`，并且支持点列头排序（再点一次反向）和拖动调整列宽。[HIG Lists and tables: developer.apple.com/design/human-interface-guidelines/lists-and-tables]
- 内容不规则的流（最近事件、告警）用 `List`。
- 仪表盘用 `LazyVGrid` 排卡片，卡片里不要再套表格。

**2.2 行高**：Apple 没有公布具体数值，只说 inset 样式的默认行高"略高一些"。[WWDC20 10104] 建议：
- 直接用 `.tableStyle(.inset)` 的系统默认行高，不要自己设。
- 日志页可以设成紧凑的 22–24 pt（建议值），并打开 `alternatesRowBackgrounds`。HIG 说宽表适合交替行色。[HIG Lists and tables]
- 侧栏行高跟随用户在"通用 → 侧边栏图标大小"里的设置，不要写死。[HIG Sidebars macOS]
- 行数很多时（超过几千行的日志）要注意：有开发者反映 macOS 15.5 起 SwiftUI Table 性能下降，必要时退回 NSTableView。[developer.apple.com/forums/thread/784845]

**2.3 悬停**：
- 原生 Table 不加行悬停底色，保持系统行为。
- 自绘的卡片和按钮用 `.onHover` 在 gray-100 和 gray-200 之间切换。[Geist colors；developer.apple.com/documentation/swiftui/view/onhover(perform:)]
- 每行的"复制"按钮可以在悬停时才显示，但同样的操作必须也能从右键菜单里找到。

**2.4 右键菜单与主操作**：用 `.contextMenu(forSelectionType:menu:primaryAction:)`。
- 选中集合为空时，表示用户在空白处右键，菜单里放"新建…"。
- `primaryAction` 对应双击和回车，用来打开检查器。
[developer.apple.com/documentation/swiftui/view/contextmenu(forselectiontype:menu:primaryaction:)]

**2.5 快捷键**：

| 快捷键 | 操作 |
|---|---|
| ⌘N | 新建 |
| ⌘F | 搜索 |
| ⌘R | 刷新 |
| ⌘⌥I | 显示或隐藏检查器（在 `commands` 里加 `InspectorCommands()`） |
| ⌘1 到 ⌘6 | 切换侧栏分区 |
| ⌘C | 复制选中行的 Key |
| ⌘⌫ | 删除（先弹确认） |
| ⌘, | 打开设置 |

可选：参考 Raycast 加一个 ⌘K 动作面板，回车执行主操作，⌘↩ 执行次操作。[manual.raycast.com/keyboard-shortcuts；developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)]

**2.6 文本处理**：
- Key、URL、模型 ID 用 `.truncationMode(.middle)`，开头和结尾都保留。[HIG Lists and tables]
- 数字用 `.monospacedDigit()`。
- 列头用名词，标题式大小写，结尾不加标点。[HIG Lists and tables]

**2.7 选中与检查器**：
- 选中一行时，检查器显示这条记录的详情。
- 多选时，检查器显示"已选 3 项"和批量操作。
- 检查器内容随选中项实时更新，这是 HIG 对 inspector 的定义；对应的菜单项叫"显示检查器"。[HIG Panels: developer.apple.com/design/human-interface-guidelines/panels]

---

## 3. 用检查器编辑记录，少用模态

**3.1 宽度**：`.inspector(isPresented:)` 加 `.inspectorColumnWidth(min: 260, ideal: 300, max: 400)`。检查器的显示状态由框架自动恢复。[inspector 和 inspectorColumnWidth 文档：developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)]
macOS 26 上检查器的背景是模糊的，但不会浮起来，所以不要再给它加卡片底。[WWDC25 323 笔记]

**3.2 原地编辑**：
- 检查器内容用 `Form` 配 `.formStyle(.grouped)`，每行用 `LabeledContent`。
- 简单字段（名称、备注、优先级）直接改，回车或失焦时提交。
- 只有存在未保存的修改时，才在底部显示"还原 / 保存"两个按钮，"保存"用 Ink 样式。
- 这种做法来自 Linear 和 Things：减少层级和视觉噪音，属性就在原处编辑。[linear.app/now/how-we-redesigned-the-linear-ui]

**3.3 密钥字段**：
- 列表里只显示 `sk-…a1F9` 这样的前后缀。
- 检查器里默认遮罩，旁边放"显示"和"复制"两个按钮。复制后 2 秒内显示一次 ✓ 作为反馈，不弹 toast。

**3.4 什么时候才用 Sheet 或对话框**：
- 新建 API Key：只在这个 sheet 里显示一次完整密钥。
- 多步骤的 OAuth 登录。
- 破坏性操作的确认：用 `.confirmationDialog`。
除此之外，编辑一律不弹窗。HIG 的说法是，只跟某个任务有关的选项就放在那个任务里。[HIG Settings "Task-specific options"]

**3.5 校验与测试**：
- 校验错误显示在字段下方：红色关键词加图标，不用 alert。
- "测试连接"按钮放在检查器里，结果在原处显示（状态点 + 耗时）。

---

## 4. 单色风格在 AppKit/SwiftUI 里怎么落地：材质与 vibrancy

**4.1 分层原则**：
- 侧栏保持系统材质（`.sidebar` 或 Liquid Glass），不要给 List 设背景。
- 内容画布用实色 `Canvas`。
HIG 的分层是：Liquid Glass 只给控件和导航层用，不要放进内容层；内容层用标准材质或实色。[HIG Materials；NSVisualEffectView.Material.sidebar 和 .contentBackground: developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum]

**4.2 推荐做法**：
- 详情根视图写 `.background(Color("Canvas"))`；Table 和 List 写 `.scrollContentBackground(.hidden)`，然后放进 `Card` 容器。
- 卡片描边：`RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color("Border"), lineWidth: 1)`。Geist 的 medium 和 large 材质都是 12 px 圆角。[vercel.com/geist/materials]
- 卡片之间靠描边区分层级，不加阴影。只有菜单和弹层这种浮起来的元素才有阴影，Geist 里也只有 menu、modal、tooltip 带投影。[Geist materials]
- 窗口不是当前窗口时，系统控件会自动变淡；自定义颜色不会，需要检查失焦时的状态点和 Ink 按钮是否太刺眼。[HIG Windows "Make sure custom windows use the system-defined appearances"]

**4.3 不要做的事**：
- 不要在内容区用 `.glassEffect()` 或半透明卡片。[HIG Materials]
- 不要按材质"看起来是什么颜色"来选材质，要按语义选。[HIG Materials]
- 不要给工具栏染色，也不要把内容区的颜色和工具栏按钮做成同色。[HIG Toolbars]
- 不要让侧栏选中色和 `Accent` 打架：选中色由系统强调色决定，用户可以在系统里改。[HIG Sidebars]
- 开启"降低透明度"和"增强对比度"后都要检查一遍。[HIG Materials]

**4.4 按钮分级**：
- 画布里的主按钮用自定义 `InkButtonStyle`（Ink 底、反色字），一个视图里只放一个。
- 次按钮用 `.bordered`（相当于 Geist secondary）。
- 破坏性按钮用 `role: .destructive`。
- 工具栏里的按钮保持系统样式，不套 Ink。
[Geist button；HIG Toolbars ".prominent 只给一个主操作"]

---

## 5. 空、加载、错误状态与"部署到这台 Mac"的引导

**5.1 空状态**：用 `ContentUnavailableView`，包括图标、标题、一句说明和一个 Ink 主操作（比如"部署到这台 Mac"或"连接已有服务器"）。搜索无结果时直接用 `ContentUnavailableView.search`。[developer.apple.com/documentation/swiftui/contentunavailableview]

**5.2 加载**：
- 先把骨架画出来：卡片框加 `.redacted(reason: .placeholder)`，不要整屏转圈。[HIG Loading: developer.apple.com/design/human-interface-guidelines/loading]
- 后台刷新时用小号 spinner，不配文字。[HIG Progress indicators macOS]
- 部署这种有明确步骤的流程，用确定进度加步骤列表。

**5.3 错误**：
- 在画布顶部显示内联横幅：1 pt 描边，"连接失败"这几个字用 Err 色，右侧放"重试"和"查看日志"两个按钮。
- 只有阻塞性的错误（比如端口被占用、无法启动）才用 alert。
- 同时让侧栏底部的状态点、副标题、菜单栏图标三处一起变化。

**5.4 首次引导（三步，可跳过）**：
1. **检查环境**：端口是否空闲、磁盘空间、是否有旧实例。
2. **启动网关**：通过 `SMAppService` 注册 App 包内自带的 helper。如果 `status == .requiresApproval`，用 `SMAppService.openSystemSettingsLoginItems()` 引导用户去系统设置批准。[developer.apple.com/documentation/servicemanagement/smappservice]
3. **完成**：创建第一个 API Key，并显示 Base URL，提供复制按钮。

引导里的规矩：
- 引导要短、能交互、可以跳过；跳过后不再自动弹出，但要能在帮助菜单里重新打开。[HIG Onboarding: developer.apple.com/design/human-interface-guidelines/onboarding]
- 第 2 步顺带提供两个开关："登录时启动"和"在菜单栏显示"，默认都是关。[HIG Menu bar extras；App Review 2.4.5(iii)]
- 不要在启动时弹许可协议。[App Review 2.4.5(vi)]

**5.5 参考**：OrbStack 的菜单栏小程序可以在设置里开关，提供启动/停止、日志、复制地址等功能。我们的菜单栏就照这个范围做。[docs.orbstack.dev/menu-bar]

---

## 6. Mac App Store 审核与 UI 相关的坑

**6.1 Settings 场景**：
- 用 `Settings { TabView { Tab(...) } }`，系统会自动生成"设置…"菜单项和 ⌘,。[developer.apple.com/documentation/swiftui/settings]
- 设置窗口的工具栏不能自定义，标题跟着当前面板变，再次打开时回到上次的面板，最小化和缩放按钮置灰。[HIG Settings]
- 在菜单栏小程序里打开设置，用 `SettingsLink` 或 `@Environment(\.openSettings)`。[developer.apple.com/documentation/swiftui/settingslink]
- 设置里只放不常改的全局项，系统已有的设置不要重复做一份。[HIG Settings]

**6.2 菜单栏小程序（MenuBarExtra）**：
- 用 `MenuBarExtra(_:systemImage:isInserted:)` 加 `@AppStorage`，由用户决定是否显示；用户把图标移除后，绑定值会自动变成 false。[developer.apple.com/documentation/swiftui/menubarextra]
- 优先用菜单样式；内容复杂时才用 `.menuBarExtraStyle(.window)`。[HIG The menu bar → Menu bar extras]
- 图标用单色 symbol，菜单栏高度 24 pt。系统随时可能把它藏起来，所以关键功能不能只放在这里；同时提供 Dock 右键菜单。[HIG Menu bar extras]
- 如果做成纯菜单栏 App（`LSUIElement`），用户移除图标后 App 会直接退出，要考虑清楚。[MenuBarExtra 文档]

**6.3 Helper 进程与网关服务**：
- **2.4.5(iii)**：开机或登录时自动运行，或者退出 App 后进程继续运行，都必须先得到用户同意。所以要做一个明确的开关"退出 App 后保持网关运行"，默认关闭；关闭时，App 退出就要停掉子进程。
- **2.4.5(iv) 和 2.5.2**：不能下载或安装可执行代码来增加功能。CLIProxyAPI 和面板的二进制必须随 .app 一起打包签名，不能在运行时从 GitHub 拉取。这一条和仓库里 `APP_STORE_READINESS.md` 记录的阻塞项一致。
- **2.4.5(v)**：不能提权、不能用 setuid。所以不用需要 root 的 LaunchDaemon，只监听 1024 以上的回环端口。
- **2.4.5(vii)**：App Store 版不能有自更新入口，要把"检查更新"编译掉。
- **4.2**：不能只是网页套壳，原生 UI 要做实，不能用 WebView 承载 CPA 面板。
[以上均见 developer.apple.com/app-store/review/guidelines/]
- 沙盒：监听端口需要 `com.apple.security.network.server` entitlement。有开发者在论坛里引用 macOS 14.2 的发布说明，说主 App 开了沙盒时，用 SMAppService 注册的 agent 的可执行文件也必须开沙盒。这条来自社区引用，需要用真机验证。[developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server；developer.apple.com/forums/thread/743395]

---

## 7. 字号、间距、圆角（macOS 正文 13 pt 体系）

**7.1 系统字号**（macOS 内置文本样式）：

| 样式 | 字号/行高（pt） | 用途 |
|---|---|---|
| Large Title | 26/32 | 仪表盘的大号 KPI 数字 |
| Title 1 | 22/26 | 卡片里的主数值 |
| Title 2 | 17/22 | 画布内的页面标题（很少用） |
| Title 3 | 15/20 | 首次引导的标题 |
| Headline | 13/16，Bold | 卡片标题、分组标题 |
| Body | 13/16 | 正文、表格单元格 |
| Callout | 12/15 | 次要说明 |
| Subheadline | 11/14 | 辅助元信息 |
| Footnote / Caption | 10/13 | 最小字号，macOS 下限就是 10 pt |

[HIG Typography: developer.apple.com/design/human-interface-guidelines/typography]

**7.2 Geist 到 macOS 的字号对照**：Web 端的 label-14、copy-14 对应 Mac 的 Body 13；label-13 对应 Callout 12；label-12 对应 Subheadline 11；label-13-mono 对应 `.system(size: 12, design: .monospaced)`，用在 Key、端口、模型 ID 上。[Geist typography: vercel.com/geist/typography]
- UI 字体保持 SF Pro，这样最像原生 App。
- Linear 的做法是标题用 Display 字重，其余用常规字重，我们可以在 KPI 数字上借鉴。[Linear redesign]

**7.3 图标**：工具栏图标交给系统处理（13 pt，medium 字重，large scale）。状态点 8 pt，和文字基线对齐。[WWDC20 10104]

**7.4 间距（建议值，4 pt 栅格）**：
- 画布内边距 20 pt。
- 卡片内边距 16 pt。
- 卡片之间 12 pt。
- 表单行间距用系统 Form 的默认值。
- 卡片内标题和数值之间 4 pt。
- 页面分区之间 24 pt。

**7.5 圆角**：
- 卡片、菜单、sheet 12 pt。
- 小控件、标签、输入框内的按钮 6 pt。
- 全屏层 16 pt。
以上和 Geist 的 base/small 6、medium/large/menu/modal 12、fullscreen 16 一致。[Geist materials]
macOS 26 上嵌套圆角要同心，可以用 `.containerConcentric`。[WWDC25 323 笔记]
系统按钮不要改圆角：macOS 上 mini、small、medium 尺寸仍是圆角矩形，系统会自己处理。[WWDC25 323 笔记]

---

## 来源清单

- Apple HIG：Sidebars、Toolbars、Lists and tables、Split views、Windows、Panels、Settings、The menu bar、Materials、Typography、Loading、Progress indicators、Onboarding，全部在 https://developer.apple.com/design/human-interface-guidelines/ 下面
- WWDC20 10104 "Adopt the new look of macOS"：https://developer.apple.com/videos/play/wwdc2020/10104/
- WWDC24 10148 "Tailor macOS windows with SwiftUI"：https://developer.apple.com/videos/play/wwdc2024/10148/ 和 https://wwdcnotes.com/documentation/wwdc24-10148-tailor-macos-windows-with-swiftui/
- WWDC25 323 "Build a SwiftUI app with the new design"：https://developer.apple.com/videos/play/wwdc2025/323/ 和 https://wwdcnotes.com/documentation/wwdc25-323-build-a-swiftui-app-with-the-new-design/
- SwiftUI 和 AppKit 文档：Settings、SettingsLink、MenuBarExtra、ContentUnavailableView、inspector、inspectorColumnWidth、contextMenu(forSelectionType:)、navigationSubtitle、windowResizability、NSVisualEffectView.Material、SMAppService，均在 https://developer.apple.com/documentation/
- App Review Guidelines：https://developer.apple.com/app-store/review/guidelines/ （2.4.5、2.5.2、4.2）
- Vercel Geist：https://vercel.com/geist/colors 、/materials 、/typography 、/button
- Linear 重设计：https://linear.app/now/how-we-redesigned-the-linear-ui
- Raycast 快捷键：https://manual.raycast.com/keyboard-shortcuts
- OrbStack 菜单栏：https://docs.orbstack.dev/menu-bar
- Tower 6（Big Sur 全高侧栏和 SF 图标）：https://git-tower.com/blog/tower-mac-6
- SwiftUI Table 性能讨论：https://developer.apple.com/forums/thread/784845 ；SMAppService 与沙盒：https://developer.apple.com/forums/thread/743395
