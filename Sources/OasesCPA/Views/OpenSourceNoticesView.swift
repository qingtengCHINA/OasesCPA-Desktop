import Foundation
import SwiftUI

enum OpenSourceNoticesWindow {
    static let id = "open-source-notices"
}

struct OpenSourceNoticesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("开源许可与致谢", systemImage: "curlybraces.square")
                        .font(.title2.weight(.semibold))

                    Text("Oases CPA 是用于连接、部署和管理用户自有目标环境的独立 macOS App，不隶属、未获 CLIProxyAPI 或 CPA Manager Plus 背书。下列上游项目的完整 MIT 许可证已随 App 一同提供。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .oasesCard()

                ForEach(OpenSourceNotice.allCases) { notice in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(Color.oasesMint)
                            Text(notice.title)
                                .font(.headline)
                            Spacer()
                            Text("MIT License")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Text(notice.copyright)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Link(destination: notice.sourceURL) {
                            Label("查看上游项目", systemImage: "arrow.up.right.square")
                        }
                        .font(.callout)

                        Text(notice.licenseText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(20)
                    .oasesCard()
                }

                Text("本页仅展示 Oases CPA 当前随应用引用或互操作的开源上游项目。每次引入新的第三方代码或 SDK，发布前都应同步更新该页及 THIRD_PARTY_NOTICES.md。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
        }
        .frame(minWidth: 760, minHeight: 640)
    }
}

private enum OpenSourceNotice: CaseIterable, Identifiable {
    case cliProxyAPI
    case cpaManagerPlus

    var id: String { resourceName }

    var title: String {
        switch self {
        case .cliProxyAPI:
            "CLIProxyAPI"
        case .cpaManagerPlus:
            "CPA Manager Plus"
        }
    }

    var copyright: String {
        switch self {
        case .cliProxyAPI:
            "Copyright (c) 2025-2005.9 Luis Pater; Copyright (c) 2025.9-present Router-For.ME"
        case .cpaManagerPlus:
            "Copyright (c) 2026 Seakee"
        }
    }

    var sourceURL: URL {
        switch self {
        case .cliProxyAPI:
            URL(string: "https://github.com/router-for-me/CLIProxyAPI")!
        case .cpaManagerPlus:
            URL(string: "https://github.com/seakee/CPA-Manager-Plus")!
        }
    }

    var resourceName: String {
        switch self {
        case .cliProxyAPI:
            "CLIProxyAPI-MIT"
        case .cpaManagerPlus:
            "CPA-Manager-Plus-MIT"
        }
    }

    var licenseText: String {
        let url = resourceBundle.url(
            forResource: resourceName,
            withExtension: "txt",
            subdirectory: "Notices"
        ) ?? resourceBundle.url(
            forResource: resourceName,
            withExtension: "txt"
        )
        guard let url,
        let text = try? String(contentsOf: url, encoding: .utf8) else {
            return OasesLocalization.localized("许可证文本未能从应用资源中读取。请查看项目中的 THIRD_PARTY_NOTICES.md。")
        }
        return text
    }

    private var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
}
