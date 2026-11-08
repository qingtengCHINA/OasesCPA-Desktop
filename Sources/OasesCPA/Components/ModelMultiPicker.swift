import SwiftUI

/// Picks models from the gateway's `groupedModels`. Internal `pin-x/…` ids are never offered.
/// `selection` holds model ids as the gateway stores them in policies (canonical: lower case,
/// without "cc-", the part after the last "/"); an option counts as selected when its canonical
/// id is in the selection. With `storesCanonicalIDs` false (model pack members, which the engine
/// must receive exactly as it lists them) ids are compared and stored as they are; a newly
/// ticked model is appended, so the selection keeps the order in which models were added.
struct ModelMultiPicker: View {
    let groupedModels: [String: [String]]
    @Binding var selection: [String]
    var disabledGroups: [String] = []
    var storesCanonicalIDs = true
    @State private var search = ""

    /// Public ids by group, sorted; empty groups dropped.
    nonisolated static func options(from groupedModels: [String: [String]]) -> [(group: String, models: [String])] {
        groupedModels
            .map { group, ids in
                (group, Array(Set(ids.filter { InternalModelID.publicName($0) == $0 && !$0.isEmpty }))
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            }
            .filter { !$0.1.isEmpty }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .map { (group: $0.0, models: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            HStack {
                TextField("筛选模型", text: $search)
                    .textFieldStyle(.roundedBorder)
                Text(OasesLocalization.localizedFormat("已选 %lld", selection.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Oases.Color.textSecondary)
            }
            let groups = filteredOptions
            if groups.isEmpty {
                Text(groupedModels.isEmpty ? "网关还没有可用模型" : "没有匹配的模型。")
                    .font(.callout)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Oases.Space.m) {
                        ForEach(groups, id: \.group) { entry in
                            groupSection(entry.group, models: entry.models)
                        }
                    }
                    .padding(.vertical, Oases.Space.xs)
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    private var filteredOptions: [(group: String, models: [String])] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = Self.options(from: groupedModels)
        guard !query.isEmpty else { return all }
        return all.compactMap { entry in
            let models = entry.group.localizedCaseInsensitiveContains(query)
                ? entry.models
                : entry.models.filter { $0.localizedCaseInsensitiveContains(query) }
            return models.isEmpty ? nil : (group: entry.group, models: models)
        }
    }

    private func groupSection(_ group: String, models: [String]) -> some View {
        VStack(alignment: .leading, spacing: Oases.Space.xs) {
            HStack(spacing: Oases.Space.s) {
                Text(group)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Oases.Color.textSecondary)
                if disabledGroups.contains(group) {
                    ToneBadge(text: "已停用", tone: .warning)
                }
            }
            ForEach(models, id: \.self) { model in
                Toggle(isOn: binding(for: model)) {
                    Text(model)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func binding(for model: String) -> Binding<Bool> {
        let canonical = storesCanonicalIDs
        let id = canonical ? GatewayPolicyModelID.canonical(model) : model
        let key: (String) -> String = { canonical ? GatewayPolicyModelID.canonical($0) : $0 }
        return Binding(
            get: { selection.contains { key($0) == id } },
            set: { isOn in
                var next = selection.filter { key($0) != id }
                if isOn { next.append(id) }
                selection = next
            }
        )
    }
}
