import SwiftUI

/// First-run hero welcome. Pattern from Appllama's public welcome-screen research
/// (identity → map → first action, one primary CTA, skip always available, reduced
/// motion renders the final state immediately). Desktop-landscape, Oases-branded.
struct WelcomeFlowView: View {
    let onFinish: () -> Void

    @State private var pageIndex = 0
    @State private var actionsEnabled = false
    @State private var revealGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch pageIndex {
                case 0:
                    WelcomeHeroPage()
                case 1:
                    WelcomeMapPage()
                default:
                    WelcomeFirstRunPage()
                }
            }
            .id(pageIndex)
            .transition(pageTransition)
            .padding(.horizontal, 36)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(WelcomeAtmosphere())
        .onAppear(perform: revealActions)
        .onChange(of: pageIndex) { _, _ in
            revealActions()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OasesMark(size: 28)
            Text("Oases CPA")
                .font(.headline)
            Spacer()
            Button("直接进入软件") {
                onFinish()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!actionsEnabled)
            .opacity(actionsEnabled ? 1 : 0)
            .accessibilityHidden(!actionsEnabled)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if pageIndex > 0 {
                Button("返回") {
                    moveToPreviousPage()
                }
                .disabled(!actionsEnabled)
                .keyboardShortcut(.cancelAction)
            }

            Spacer()

            WelcomeProgressView(currentPage: pageIndex, pageCount: pageCount)

            Spacer()

            Button(primaryTitle) {
                moveToNextPage()
            }
            .buttonStyle(.oasesPrimary)
            .controlSize(.large)
            .disabled(!actionsEnabled)
            .opacity(actionsEnabled ? 1 : 0)
            .accessibilityHidden(!actionsEnabled)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .padding(.top, 12)
    }

    private var primaryTitle: LocalizedStringKey {
        switch pageIndex {
        case 0: "开始了解"
        case pageCount - 1: "进入软件"
        default: "下一步"
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 18)),
            removal: .opacity.combined(with: .offset(x: -18))
        )
    }

    private func revealActions() {
        if reduceMotion {
            actionsEnabled = true
            return
        }
        actionsEnabled = false
        revealGeneration += 1
        let token = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard token == revealGeneration else { return }
            actionsEnabled = true
        }
    }

    private func moveToPreviousPage() {
        guard pageIndex > 0 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            pageIndex -= 1
        }
    }

    private func moveToNextPage() {
        guard pageIndex < pageCount - 1 else {
            onFinish()
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            pageIndex += 1
        }
    }
}

private struct WelcomeAtmosphere: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Oases.Color.background
            Circle()
                .fill(Color.accentColor.opacity(0.10))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: -120, y: -160)
                .allowsHitTesting(false)
            Circle()
                .fill(Color.accentColor.opacity(0.06))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 80, y: 80)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

private struct WelcomeHeroPage: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 40) {
                copy
                    .frame(maxWidth: 420, alignment: .leading)
                WelcomeHeroDiagram()
                    .frame(maxWidth: .infinity, minHeight: 280)
            }
            VStack(alignment: .leading, spacing: 28) {
                copy
                WelcomeHeroDiagram()
                    .frame(minHeight: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SELF-HOSTED AI GATEWAY")
                .font(.caption.weight(.semibold).monospaced())
                .tracking(1.4)
                .foregroundStyle(Color.accentColor)

            Text("欢迎使用 Oases CPA")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)

            Text("搭建并管理你自己的 AI API 中转站")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("本机一键部署，或经 SSH 连到 VPS。Provider、模型、调用密钥和用量，都在这一处控制面里。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                WelcomePill("本机 · SSH / VPS")
                WelcomePill("CLIProxyAPI")
                WelcomePill("CPAMP")
            }
            .padding(.top, 4)
        }
    }
}

private struct WelcomeMapPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("三件事，先记清楚")
                    .font(.largeTitle.bold())

                Text("Oases CPA 是控制面。它不替代网关，也不替代管理面板。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cards) { card in
                        WelcomeMapCardView(card: card)
                    }
                }
                VStack(spacing: 12) {
                    ForEach(cards) { card in
                        WelcomeMapCardView(card: card)
                    }
                }
            }
        }
        .frame(maxWidth: 920, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var cards: [WelcomeMapCard] {
        [
            WelcomeMapCard(
                id: "target",
                symbol: "laptopcomputer.and.iphone",
                title: "本机或 SSH",
                detail: "把控制面连到你自己的电脑，或一台 VPS。"
            ),
            WelcomeMapCard(
                id: "runtime",
                symbol: "server.rack",
                title: "运行时网关",
                detail: "对外提供通用兼容 /v1，默认 :8317。"
            ),
            WelcomeMapCard(
                id: "panel",
                symbol: "switch.2",
                title: "管理面板",
                detail: "签发密钥、看用量、管 Provider。"
            ),
        ]
    }
}

private struct WelcomeMapCard: Identifiable {
    let id: String
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
}

private struct WelcomeMapCardView: View {
    let card: WelcomeMapCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: card.symbol)
                .font(.title2)
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(width: 40, height: 40)
                .oasesIconTile(cornerRadius: 999)
                .accessibilityHidden(true)

            Text(card.title)
                .font(.headline)

            Text(card.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(
            Oases.Color.surface.opacity(0.86),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeFirstRunPage: View {
    private let steps: [(String, LocalizedStringKey, LocalizedStringKey)] = [
        ("1", "部署运行时", "在「连接与部署」把 CLIProxyAPI 和 CPAMP 装上。"),
        ("2", "接入 Provider", "添加上游凭证，让网关能真正转发。"),
        ("3", "签发调用 Key", "给 Cursor / Claude Code 发一把调用密钥。"),
        ("4", "开始调用", "用通用兼容接口连上你自己的中转站。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("第一次这样走")
                    .font(.largeTitle.bold())

                Text("四步就能在 AI IDE 里打到你自己的网关。随时可以回来重看。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(steps, id: \.0) { number, title, detail in
                        WelcomeStepCard(number: number, title: title, detail: detail)
                    }
                }
                VStack(spacing: 10) {
                    ForEach(steps, id: \.0) { number, title, detail in
                        WelcomeStepCard(number: number, title: title, detail: detail)
                    }
                }
            }
        }
        .frame(maxWidth: 920, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct WelcomeStepCard: View {
    let number: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(number)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(width: 28, height: 28)
                .oasesIconTile(cornerRadius: 999)

            Text(title)
                .font(.headline)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(
            Oases.Color.surface.opacity(0.86),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeHeroDiagram: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ONE CONTROL PLANE")
                .font(.caption.weight(.semibold).monospaced())
                .tracking(1.2)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 10) {
                    WelcomeDiagramChip(symbol: "laptopcomputer", title: "本机", subtitle: "默认目标")
                    WelcomeDiagramChip(symbol: "server.rack", title: "SSH / VPS", subtitle: "安全隧道")
                }

                Image(systemName: "arrow.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    OasesMark(size: 44)
                    Text("Oases CPA")
                        .font(.headline)
                    Text("native app")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(
                    Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                }
            }

            VStack(spacing: 8) {
                WelcomeRuntimeRow(dot: Color.accentColor, name: "CLIProxyAPI", meta: ":8317 /v1")
                WelcomeRuntimeRow(dot: Color.accentColor.opacity(0.55), name: "CPA Manager Plus", meta: "panel")
            }
            .padding(14)
            .background(
                Oases.Color.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .padding(22)
        .background(
            Oases.Color.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("控制面连接本机或 SSH，再管理 CLIProxyAPI 与 CPA Manager Plus")
    }
}

private struct WelcomeDiagramChip: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Oases.Color.surface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct WelcomeRuntimeRow: View {
    let dot: Color
    let name: String
    let meta: String

    var body: some View {
        HStack {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.subheadline.monospaced())
            Spacer()
            Text(meta)
                .font(.caption.monospaced())
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomePill: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold).monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.10), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
            }
    }
}

private struct WelcomeProgressView: View {
    let currentPage: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == currentPage ? 24 : 8, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("欢迎引导进度")
        .accessibilityValue("第 \(currentPage + 1) 页，共 \(pageCount) 页")
    }
}
