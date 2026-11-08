import SwiftUI

struct CodexInspectionPolicyEditor: View {
    @Binding var draft: RuntimeCodexInspectionPolicyDraft

    let onChange: () -> Void
    @State private var advancedSettingsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(
                title: "凭证健康巡检策略",
                subtitle: "保存到当前 CPAMP；手动巡检与定时巡检都会遵守这些策略",
                icon: "checkmark.shield"
            )

            Toggle("启用定时巡检", isOn: binding(\.scheduledEnabled))
                .toggleStyle(.switch)

            Text("关闭后不会按计划运行，但你仍可在“凭证健康巡检”中手动开始一次检查。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("巡检目标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("巡检目标", selection: binding(\.targetSelection)) {
                    ForEach(RuntimeCodexInspectionTargetSelection.allCases) { selection in
                        Text(selection.title).tag(selection)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("执行时间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("执行时间", selection: binding(\.scheduleMode)) {
                    ForEach(RuntimeCodexInspectionScheduleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if draft.scheduleMode == .interval {
                LabeledField(
                    title: "巡检间隔（分钟）",
                    placeholder: "60",
                    text: binding(\.intervalMinutes)
                )
            } else {
                LabeledField(
                    title: "每天执行时间",
                    placeholder: "09:00, 21:00",
                    text: binding(\.timePoints)
                )
                Text("使用 24 小时制，多个时间可用逗号或空格分隔。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                LabeledField(
                    title: "时区（IANA）",
                    placeholder: "Asia/Shanghai",
                    text: binding(\.timeZone)
                )
                LabeledField(
                    title: "额度阈值（%）",
                    placeholder: "100",
                    text: binding(\.usedPercentThreshold)
                )
                LabeledField(
                    title: "采样账号数",
                    placeholder: "0（全部）",
                    text: binding(\.sampleSize)
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("异常后的自动处理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("异常后的自动处理", selection: binding(\.autoActionMode)) {
                    ForEach(RuntimeCodexInspectionAutoActionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Toggle(
                    "仅恢复由巡检自身禁用、且服务端已确认恢复条件的账号",
                    isOn: binding(\.autoRecoverEnabled)
                )
                .toggleStyle(.switch)
            }

            InfoBanner(
                title: safetyTitle,
                message: draft.safetySummary,
                systemImage: safetySystemImage,
                tint: safetyTint
            )

            if let validationMessage = draft.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.oasesRed)
            }

            DisclosureGroup("高级探测设置", isExpanded: $advancedSettingsExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("这些参数仅影响后续巡检的请求并发、超时和探测方式；保存配置本身不会立即启动巡检。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("执行参数")
                            .font(.callout.weight(.semibold))

                        HStack(alignment: .top, spacing: 12) {
                            advancedNumberField(
                                title: "常规巡检并发",
                                placeholder: "4",
                                text: binding(\.workers)
                            )
                            advancedNumberField(
                                title: "删除动作并发",
                                placeholder: "4",
                                text: binding(\.deleteWorkers)
                            )
                        }
                        HStack(alignment: .top, spacing: 12) {
                            advancedNumberField(
                                title: "单次探测超时（ms）",
                                placeholder: "15000",
                                text: binding(\.timeoutMilliseconds)
                            )
                            advancedNumberField(
                                title: "重试次数",
                                placeholder: "0",
                                text: binding(\.retries)
                            )
                        }
                    }

                    if draft.targetSelection.includesCodex {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Codex 探测")
                                .font(.callout.weight(.semibold))
                            LabeledField(
                                title: "请求 User-Agent",
                                placeholder: "codex_cli_rs/...",
                                text: binding(\.userAgent)
                            )
                            Text("仅用于巡检请求标识；不要在此填写 API Key、Cookie 或其他机密信息。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if draft.targetSelection.includesXAI {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("xAI 推理探针")
                                .font(.callout.weight(.semibold))

                            Toggle(
                                "启用 xAI 推理探针（会额外发起请求）",
                                isOn: binding(\.xaiInferenceEnabled)
                            )
                            .toggleStyle(.switch)

                            if draft.hasActiveXAIInferenceProbe {
                                InfoBanner(
                                    title: "后续 xAI 巡检会发送额外推理请求",
                                    message: "该请求用于验证实际推理可用性，可能消耗账号额度。探测提示词会随请求发送，请勿填写 API Key、Cookie 或其他机密。",
                                    systemImage: "bolt.shield",
                                    tint: .oasesOrange
                                )

                                LabeledField(
                                    title: "推理请求 User-Agent",
                                    placeholder: "xai-grok-workspace/...",
                                    text: binding(\.xaiInferenceUserAgent)
                                )
                                LabeledField(
                                    title: "推理模型",
                                    placeholder: "grok-4.5",
                                    text: binding(\.xaiInferenceModel)
                                )
                                xAIInferencePromptEditor
                            } else {
                                Text("关闭后，xAI 巡检不会发起额外的推理验证请求；已有探针参数会保留，以便日后再次启用。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if draft.xaiInferenceEnabled {
                        InfoBanner(
                            title: "xAI 推理探针设置已保留",
                            message: "当前巡检目标不包含 xAI，因此不会使用推理探针。若要修改或关闭它，请先将巡检目标切换为包含 xAI。",
                            systemImage: "pause.circle",
                            tint: .oasesBlue
                        )
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout.weight(.medium))
        }
        .padding(22)
        .oasesCard()
        .onChange(of: draft.advancedValidationMessage) { _, validationMessage in
            if validationMessage != nil {
                advancedSettingsExpanded = true
            }
        }
    }

    private var safetyTitle: String {
        if draft.autoActionMode.isDestructive {
            return OasesLocalization.localized("自动删除会修改目标认证文件")
        }
        if draft.isMutationCapable {
            return OasesLocalization.localized("自动动作可能修改目标认证文件")
        }
        return OasesLocalization.localized("仅记录策略")
    }

    private var safetySystemImage: String {
        draft.isMutationCapable ? "exclamationmark.shield" : "eye"
    }

    private var safetyTint: Color {
        if draft.autoActionMode.isDestructive {
            return .oasesRed
        }
        return draft.isMutationCapable ? .oasesOrange : .oasesGreen
    }

    private var xAIInferencePromptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("探测提示词")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: binding(\.xaiInferencePrompt))
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96, maxHeight: 144)
                .padding(8)
                .background(Oases.Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: Oases.Radius.row, style: .continuous))

            HStack(spacing: 10) {
                Text(OasesLocalization.localizedFormat("提示词会发送给 xAI；当前 %lld 个字符。", draft.xaiInferencePrompt.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("恢复默认提示词", systemImage: "arrow.counterclockwise") {
                    draft.xaiInferencePrompt = RuntimeCodexInspectionPolicyDraft
                        .defaultConfig()
                        .xaiInferencePrompt
                    onChange()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func advancedNumberField(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<RuntimeCodexInspectionPolicyDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                draft[keyPath: keyPath] = value
                onChange()
            }
        )
    }
}
