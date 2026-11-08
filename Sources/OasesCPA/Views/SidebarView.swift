import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                OasesMark()

                VStack(alignment: .leading, spacing: 1) {
                    Text("Oases CPA")
                        .font(.headline)
                    Text("Mac 控制台")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            List(selection: Binding(
                get: { store.selectedSection },
                set: { store.selectSection($0) }
            )) {
                ForEach(SectionGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            HStack(spacing: 8) {
                                Image(systemName: section.systemImage)
                                    .frame(width: 24, alignment: .center)

                                Text(section.title)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .accessibilityElement(children: .combine)
                            .tag(section)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 10) {
                StatusDot(tone: deploymentStore.stage == .attached ? .success : .warning, size: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(deploymentStore.stage == .attached ? OasesLocalization.localized("已接入") : store.connectionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Oases.Color.textPrimary)
                    Text(deploymentStore.stage == .attached ? deploymentStore.targetTitle : store.connectionDetail)
                        .font(.caption2)
                        .foregroundStyle(Oases.Color.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
