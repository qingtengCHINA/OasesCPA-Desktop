import SwiftUI

/// The providers of one model in the order the engine tries them. Rows with `draggable == false`
/// (OAuth account pools) keep their place. A finished drag (or "move up/down" from the
/// accessibility actions) reports the complete new order; nothing moves while `isDisabled`.
/// Routing prefixes are configuration and are not shown.
struct ReorderableProviderList: View {
    let providers: [GatewayModelProvider]
    let isDisabled: Bool
    let testResults: [String: GatewayHealthResult]
    let onReorder: ([String]) -> Void
    let onTest: (GatewayModelProvider) -> Void

    static let rowHeight: CGFloat = 52

    /// The order after moving the rows at `source` to `destination` (`List.onMove` semantics).
    static func order(of providers: [GatewayModelProvider], moving source: IndexSet, to destination: Int) -> [String] {
        var ids = providers.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        return ids
    }

    var body: some View {
        List {
            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                row(provider, index: index)
                    .frame(minHeight: Self.rowHeight - Oases.Space.m)
                    .moveDisabled(!provider.draggable || isDisabled)
            }
            .onMove { source, destination in
                guard !isDisabled else { return }
                let moved = source.map { providers[$0] }
                guard moved.allSatisfy(\.draggable) else { return }
                onReorder(Self.order(of: providers, moving: source, to: destination))
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .frame(height: CGFloat(max(providers.count, 1)) * Self.rowHeight)
        .disabled(isDisabled)
        .oasesCard()
    }

    @ViewBuilder
    private func row(_ provider: GatewayModelProvider, index: Int) -> some View {
        HStack(spacing: Oases.Space.m) {
            Image(systemName: provider.draggable ? "line.3.horizontal" : "lock")
                .foregroundStyle(Oases.Color.textTertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text("\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                Text(provider.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Oases.Color.textPrimary)
                    .lineLimit(1)
                Text(OasesLocalization.localizedFormat("优先级 %lld", Int64(provider.priority)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Oases.Color.textTertiary)
            }
            if provider.kind == .oauth {
                ToneBadge(text: "登录账号", tone: .neutral)
            }
            Spacer(minLength: Oases.Space.sm)
            if let result = testResults[provider.name] {
                ModelHealthDot(status: result.status)
                if let latency = result.latencyMs, result.status == .up {
                    Text("\(latency) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Oases.Color.textSecondary)
                }
            }
            if provider.kind == .compat {
                Button("单独测试") { onTest(provider) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(OasesLocalization.localizedFormat("第 %lld 位：%@", Int64(index + 1), provider.name))
        .accessibilityActions {
            if provider.draggable && !isDisabled {
                if let up = Self.neighbourIndex(of: index, in: providers, step: -1) {
                    Button("上移") { onReorder(Self.order(of: providers, moving: IndexSet(integer: index), to: up)) }
                }
                if let down = Self.neighbourIndex(of: index, in: providers, step: 1) {
                    Button("下移") { onReorder(Self.order(of: providers, moving: IndexSet(integer: index), to: down + 1)) }
                }
            }
        }
    }

    /// The index of the next row in `step` direction (nil at the ends).
    static func neighbourIndex(of index: Int, in providers: [GatewayModelProvider], step: Int) -> Int? {
        let next = index + step
        return providers.indices.contains(next) ? next : nil
    }
}
