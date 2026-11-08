import SwiftUI

/// The provider pin of one model for one key: "automatic" (no pin) or an openai-compatibility
/// provider with "only" or "prefer". OAuth pools are never offered (they cannot be pinned).
/// Routing prefixes are configuration and are not shown here.
struct ProviderPinEditor: View {
    let model: String
    /// The model's providers (`modelProviders(model:)`); nil while they have not been read.
    let providers: [GatewayModelProvider]?
    @Binding var pin: GatewayProviderPin?

    /// The provider names a pin may use, in the engine's order.
    nonisolated static func options(from providers: [GatewayModelProvider]) -> [String] {
        var names: [String] = []
        for provider in providers where provider.kind == .compat && !names.contains(provider.name) {
            names.append(provider.name)
        }
        return names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.xs) {
            HStack(spacing: Oases.Space.m) {
                Text(model)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .frame(minWidth: 140, alignment: .leading)
                    .accessibilityLabel(accessibilityText)
                Picker("供应商", selection: providerBinding) {
                    Text("自动").tag(String?.none)
                    ForEach(choices, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .accessibilityLabel(OasesLocalization.localizedFormat("%@ 的供应商", model))
                if pin != nil {
                    Picker("方式", selection: modeBinding) {
                        Text("只走这一家").tag(GatewayPinMode.only)
                        Text("优先这一家").tag(GatewayPinMode.prefer)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .accessibilityLabel(OasesLocalization.localizedFormat("%@ 的指定方式", model))
                }
            }
            if isUnavailable {
                Text("这家已不提供该模型或已停用")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.dangerText)
            }
        }
        // Each picker stays its own operable element (a combined element could not be operated).
        .accessibilityElement(children: .contain)
    }

    private var options: [String] { providers.map(Self.options(from:)) ?? [] }

    /// The options, plus the pinned provider when it is no longer one of them (so it stays visible).
    private var choices: [String] {
        guard let current = pin?.provider, !options.contains(current) else { return options }
        return options + [current]
    }

    private var isUnavailable: Bool {
        guard let current = pin?.provider, providers != nil else { return false }
        return !options.contains(current)
    }

    private var providerBinding: Binding<String?> {
        Binding(
            get: { pin?.provider },
            set: { name in
                pin = name.map { GatewayProviderPin(provider: $0, mode: pin?.mode ?? .only) }
            }
        )
    }

    private var modeBinding: Binding<GatewayPinMode> {
        Binding(
            get: { pin?.mode ?? .only },
            set: { mode in
                if let provider = pin?.provider { pin = GatewayProviderPin(provider: provider, mode: mode) }
            }
        )
    }

    private var accessibilityText: String {
        guard let pin else { return OasesLocalization.localizedFormat("%@，自动选择供应商", model) }
        let mode = pin.mode == .only ? OasesLocalization.localized("只走这一家") : OasesLocalization.localized("优先这一家")
        return OasesLocalization.localizedFormat("%@，指定 %@，%@", model, pin.provider, mode)
    }
}
