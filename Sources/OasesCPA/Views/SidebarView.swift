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
                        ForEach(AppSection.allCases.filter { $0.group == group }) { section in
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
                Circle()
                    .fill(deploymentStore.stage == .attached ? Color.oasesGreen : Color.oasesOrange)
                    .frame(width: 9, height: 9)
                    .shadow(
                        color: (deploymentStore.stage == .attached ? Color.oasesGreen : Color.oasesOrange).opacity(0.35),
                        radius: 4
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(deploymentStore.stage == .attached ? "已接入" : store.connectionLabel)
                        .font(.caption.weight(.semibold))
                    Text(deploymentStore.stage == .attached ? deploymentStore.targetTitle : store.connectionDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
