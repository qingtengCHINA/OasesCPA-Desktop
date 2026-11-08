import AppKit
import SwiftUI

/// The menu content hosted by the app's `MenuBarExtra` scene.
///
/// This view intentionally uses the system menu vocabulary instead of custom
/// panels so it remains lightweight, keyboard accessible, and familiar to
/// macOS users.
struct MenuBarStatusView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppLanguage.defaultsKey) private var languageRawValue = AppLanguage.system.rawValue

    var body: some View {
        statusSection

        Divider()

        Button {
            openMainWindow()
        } label: {
            Label("打开 Oases CPA", systemImage: "macwindow")
        }

        Button {
            openSection(.dashboard)
        } label: {
            Label("打开仪表盘", systemImage: AppSection.dashboard.systemImage)
        }

        Button {
            openSection(.environments)
        } label: {
            Label("连接与部署", systemImage: AppSection.environments.systemImage)
        }

        if deploymentStore.stage == .attached {
            Button {
                openSection(.panel)
            } label: {
                Label("打开 CPAMP 面板", systemImage: AppSection.panel.systemImage)
            }
        }

        Divider()

        Button("退出 Oases CPA") {
            NSApplication.shared.terminate(nil)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            MenuBarStatusLine(
                title: "CLIProxyAPI",
                value: cliProxyStatus.title,
                systemImage: cliProxyStatus.systemImage,
                tint: cliProxyStatus.tint
            )

            MenuBarStatusLine(
                title: "CPAMP",
                value: cpampStatus.title,
                systemImage: cpampStatus.systemImage,
                tint: cpampStatus.tint
            )

            MenuBarStatusLine(
                title: "当前目标",
                value: deploymentStore.targetTitle,
                systemImage: deploymentStore.targetKind.systemImage,
                tint: .primary
            )

            MenuBarStatusLine(
                title: "Base URL",
                value: deploymentStore.cpaClientURLString,
                systemImage: "link",
                tint: .primary
            )

            MenuBarStatusLine(
                title: "最近更新",
                value: latestDashboardUpdate,
                systemImage: "clock",
                tint: .secondary
            )
        } header: {
            Text("Oases CPA 状态")
        }
    }

    private var cliProxyStatus: ServiceStatus {
        switch deploymentStore.stage {
        case .attached where deploymentStore.healthState == .healthy:
            return .init(title: "运行正常", systemImage: "checkmark.circle.fill", tint: .green)
        case .attached where deploymentStore.healthState == .checking || deploymentStore.healthState == .recovering:
            return .init(title: "检查中", systemImage: "clock.arrow.circlepath", tint: .orange)
        case .attached:
            return .init(title: "连接异常", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .connecting, .installing:
            return .init(title: "启动中", systemImage: "arrow.triangle.2.circlepath", tint: .orange)
        default:
            return .init(title: "未运行", systemImage: "circle", tint: .secondary)
        }
    }

    private var cpampStatus: ServiceStatus {
        switch deploymentStore.stage {
        case .attached where deploymentStore.healthState == .healthy:
            return .init(title: "已连接", systemImage: "checkmark.circle.fill", tint: .green)
        case .attached where deploymentStore.healthState == .checking || deploymentStore.healthState == .recovering:
            return .init(title: "检查中", systemImage: "clock.arrow.circlepath", tint: .orange)
        case .attached:
            return .init(title: "连接异常", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .connecting, .installing:
            return .init(title: "连接中", systemImage: "arrow.triangle.2.circlepath", tint: .orange)
        default:
            return .init(title: "未连接", systemImage: "circle", tint: .secondary)
        }
    }

    private var latestDashboardUpdate: String {
        if let date = runtimeDataStore.dashboard?.lastUpdated ?? runtimeDataStore.lastDashboardRefreshAt {
            let language = AppLanguage(rawValue: languageRawValue) ?? .system
            return date.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(language.locale)
            )
        }
        return "尚未读取"
    }

    private func openMainWindow() {
        openWindow(id: "main")
    }

    private func openSection(_ section: AppSection) {
        store.selectSection(section)
        openMainWindow()
    }
}

/// A compact App Icon label for the macOS menu bar.
struct MenuBarStatusLabel: View {
    var body: some View {
        Image(nsImage: OasesBrandAsset.menuBarImage)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 16, height: 16)
            .accessibilityLabel("Oases CPA")
    }
}

private struct MenuBarStatusLine: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(title)
                Text(LocalizedStringKey(value))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .help(Text(title))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
    }
}

private struct ServiceStatus {
    let title: String
    let systemImage: String
    let tint: Color
}

#Preview {
    MenuBarStatusView()
        .environmentObject(AppStore())
        .environmentObject(DeploymentStore(autoProbe: false))
        .environmentObject(RuntimeDataStore())
}
