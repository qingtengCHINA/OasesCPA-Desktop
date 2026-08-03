import SwiftUI

struct WelcomeFlowView: View {
    let onFinish: () -> Void

    @State private var pageIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                OasesMark()

                Spacer()

                Text("Oases CPA")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Oases CPA")

            Group {
                switch pageIndex {
                case 0:
                    WelcomeIntroPage()
                case 1:
                    WelcomeConceptPage()
                default:
                    WelcomeTutorialPage()
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 12)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: pageIndex)

            VStack(spacing: 16) {
                WelcomeProgressView(currentPage: pageIndex, pageCount: pageCount)

                HStack {
                    if pageIndex > 0 {
                        Button("返回") {
                            moveToPreviousPage()
                        }
                        .keyboardShortcut(.cancelAction)
                    }

                    Spacer()

                    Button(pageIndex == pageCount - 1 ? "进入软件" : "继续") {
                        moveToNextPage()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func moveToPreviousPage() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
    }

    private func moveToNextPage() {
        guard pageIndex < pageCount - 1 else {
            onFinish()
            return
        }

        pageIndex += 1
    }
}

private struct WelcomeIntroPage: View {
    var body: some View {
        VStack(spacing: 24) {
            OasesMark()
                .scaleEffect(2.15)
                .padding(.bottom, 12)

            VStack(spacing: 10) {
                Text("欢迎使用 Oases CPA")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text("助力你搭建自己的第一套 Token 工厂")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("从本地部署开始，连接你选择的 AI 服务，并在一个清晰的面板中管理它们。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeConceptPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("先了解两个概念")
                    .font(.title.bold())

                Text("Oases CPA 会帮你把部署、供应商和访问密钥整理在一起。")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                WelcomeConceptRow(
                    systemImage: "arrow.triangle.branch",
                    title: "CPA",
                    text: "统一管理多个 AI 服务的连接、模型和调用方式。"
                )

                WelcomeConceptRow(
                    systemImage: "server.rack",
                    title: "CLIProxyAPI",
                    text: "运行在你的设备或 VPS 上，为 AI 工具提供 OpenAI 兼容的 API。"
                )
            }

            Text("你可以从本机开始，也可以稍后连接远程 SSH 服务器。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 590, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }
}

private struct WelcomeConceptRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeTutorialPage: View {
    private let tutorialSteps: [(String, LocalizedStringKey)] = [
        ("1", "前往连接与部署页"),
        ("2", "点击部署"),
        ("3", "如有提示，输入系统密码"),
        ("4", "等待部署完成"),
        ("5", "前往 AI 提供商页，添加 AI 服务"),
        ("6", "前往调用 API Key 页，新建 API Key"),
        ("7", "在 AI IDE 工具中输入 Base URL 和 API Key，API 格式选择 OpenAI 兼容（Chat Completions），再填写可用的 Model ID"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("三分钟开始使用")
                    .font(.title.bold())

                Text("按照下面的顺序完成配置，就可以在 AI IDE 中开始调用。")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(tutorialSteps, id: \.0) { number, text in
                        WelcomeTutorialRow(number: number, text: text)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }
}

private struct WelcomeTutorialRow: View {
    let number: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeProgressView: View {
    let currentPage: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
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
