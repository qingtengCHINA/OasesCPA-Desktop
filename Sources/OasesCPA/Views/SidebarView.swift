import SwiftUI

/// The native source list: section headers, `Label` rows (icons follow the system accent), a
/// badge only where something needs the user. No brand header, no footer: the connection state
/// lives in the toolbar subtitle (`ShellStatus`).
struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    var body: some View {
        List(selection: Binding(
            get: { store.selectedSection },
            set: { store.selectSection($0) }
        )) {
            ForEach(SectionGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .badge(badge(for: section))
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func badge(for section: AppSection) -> Text? {
        ShellStatus.sidebarBadge(
            for: section,
            pendingAccountActions: runtimeDataStore.accountActionPendingCount,
            deploymentNeedsUpgrade: ShellStatus.deploymentNeedsUpgrade(deploymentStore)
        )
    }
}
