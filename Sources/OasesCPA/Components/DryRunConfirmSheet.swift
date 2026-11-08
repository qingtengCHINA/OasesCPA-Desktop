import SwiftUI

/// Confirms an order whose dry run changes the order of other models too: lists those models
/// (public names) and the providers that must stay equal. Nothing is applied until "应用".
struct DryRunConfirmSheet: View {
    let plan: GatewayReorderPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.md) {
            Text("这个顺序也会改变其他模型")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Oases.Color.textPrimary)
            Text("供应商的优先级对它提供的每个模型都生效。应用后，下面这些模型的供应商先后顺序也会变化：")
                .font(.callout)
                .foregroundStyle(Oases.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: Oases.Space.xs) {
                    ForEach(ModelDetailStore.displayModels(plan.affected), id: \.self) { model in
                        Label(model, systemImage: "cpu")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Oases.Color.textPrimary)
                    }
                    if !plan.ties.isEmpty {
                        Text("这些供应商与登录账号同级，会保持并列：")
                            .font(.callout)
                            .foregroundStyle(Oases.Color.textSecondary)
                            .padding(.top, Oases.Space.sm)
                        ForEach(Array(plan.ties.enumerated()), id: \.offset) { _, group in
                            Text(group.joined(separator: " = "))
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(Oases.Color.textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("应用", action: onConfirm)
                    .buttonStyle(.oasesPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Oases.Space.l)
        .frame(width: 460)
    }
}
