import SwiftUI

/// Creates or edits a model pack: its public model name, the member models (in order: the first
/// is the primary in "主备"), their prices, the mode and the failover settings.
struct ModelPackEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ModelPacksStore
    @State private var draft: GatewayPackDraft
    @State private var priceTexts: [String: (input: String, output: String)] = [:]
    @State private var customModel = ""
    @State private var timeoutText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let isNew: Bool

    init(store: ModelPacksStore, pack: GatewayPack?) {
        self.store = store
        isNew = pack == nil
        let draft = pack.map(GatewayPackDraft.init(pack:)) ?? GatewayPackDraft()
        _draft = State(initialValue: draft)
        _timeoutText = State(initialValue: String(draft.failover.firstByteTimeoutMs))
        var texts: [String: (input: String, output: String)] = [:]
        for member in draft.members {
            texts[member.model] = (Self.text(member.inputUSDPer1M), Self.text(member.outputUSDPer1M))
        }
        _priceTexts = State(initialValue: texts)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("对外模型名", text: $draft.modelID, prompt: Text("客户端请求时使用的 model，例如 team-chat"))
                        .font(.system(.body, design: .monospaced))
                    TextField("名称", text: $draft.name, prompt: Text("留空时与对外模型名相同"))
                    Toggle("启用", isOn: $draft.enabled)
                    Toggle("回答时自称为对外模型名", isOn: $draft.identity)
                } header: {
                    Text(isNew ? "新建模型包" : "编辑模型包")
                }

                Section("成员模型") {
                    Picker("调度方式", selection: $draft.mode) {
                        ForEach(GatewayPackMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(modeExplanation)
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                    ModelMultiPicker(
                        groupedModels: store.models.isEmpty ? [:] : [OasesLocalization.localized("引擎模型"): store.models],
                        selection: memberSelection,
                        storesCanonicalIDs: false
                    )
                    HStack {
                        TextField("其他模型名", text: $customModel, prompt: Text("列表里没有时手动填写"))
                            .font(.system(.body, design: .monospaced))
                        Button("添加") { addCustomModel() }
                            .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(Array(draft.members.enumerated()), id: \.element.model) { index, member in
                        memberRow(member, index: index)
                    }
                }

                Section("失败切换") {
                    TextField("首字节超时（毫秒）", text: $timeoutText, prompt: Text("1000–120000"))
                    if Self.timeout(from: timeoutText) == nil {
                        Text("首字节超时必须是整数毫秒（1000–120000）。")
                            .font(.caption)
                            .foregroundStyle(Oases.Color.dangerText)
                    }
                    Stepper(value: attemptsBinding, in: 1...max(1, draft.members.count)) {
                        Text(OasesLocalization.localizedFormat("最多尝试 %lld 个成员", draft.failover.maxAttempts))
                    }
                }

                if !problems.isEmpty || errorMessage != nil {
                    Section {
                        ForEach(problems, id: \.self) { message in
                            Text(message).foregroundStyle(Oases.Color.dangerText)
                        }
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(Oases.Color.dangerText)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "创建" : "保存") { Task { await save() } }
                    .buttonStyle(.oasesPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !problems.isEmpty || !pricesAreValid || Self.timeout(from: timeoutText) == nil)
            }
            .padding(Oases.Space.md)
        }
        .frame(width: 640, height: 720)
    }

    private var modeExplanation: String {
        switch draft.mode {
        case .roundRobin: OasesLocalization.localized("每次请求按顺序换下一个成员。")
        case .random: OasesLocalization.localized("每次请求随机排列成员。")
        case .primaryBackup: OasesLocalization.localized("总是先用第一个成员，失败时按顺序换下一个。")
        }
    }

    private var problems: [String] {
        GatewayPackValidation.errors(pack: currentDraft, hasCostLimitedKeys: store.hasCostLimitedKeys(packID: draft.id))
    }

    private var pricesAreValid: Bool {
        priceTexts.values.allSatisfy { Self.price($0.input) != nil && Self.price($0.output) != nil }
    }

    /// The draft with the typed prices and timeout (an invalid timeout keeps the last valid one;
    /// saving is disabled meanwhile).
    private var currentDraft: GatewayPackDraft {
        var value = draft
        if let timeout = Self.timeout(from: timeoutText) { value.failover.firstByteTimeoutMs = timeout }
        value.members = draft.members.map { member in
            let texts = priceTexts[member.model] ?? ("", "")
            return GatewayPackMember(model: member.model, inputUSDPer1M: Self.price(texts.input) ?? nil, outputUSDPer1M: Self.price(texts.output) ?? nil)
        }
        return value
    }

    private var memberSelection: Binding<[String]> {
        Binding(
            get: { draft.members.map(\.model) },
            set: { models in
                let existing = Dictionary(draft.members.map { ($0.model, $0) }, uniquingKeysWith: { first, _ in first })
                draft.setMembers(models.map { existing[$0] ?? GatewayPackMember(model: $0) })
            }
        )
    }

    /// The stepper is the user's own choice: the attempts stop following the member count.
    private var attemptsBinding: Binding<Int> {
        Binding(get: { draft.failover.maxAttempts }, set: { draft.setMaxAttempts($0) })
    }

    @ViewBuilder
    private func memberRow(_ member: GatewayPackMember, index: Int) -> some View {
        HStack(spacing: Oases.Space.sm) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Oases.Color.textTertiary)
                .frame(width: 18)
            Text(member.model)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
            Spacer()
            TextField("输入 $/1M", text: priceBinding(member.model, input: true))
                .frame(width: 90)
            TextField("输出 $/1M", text: priceBinding(member.model, input: false))
                .frame(width: 90)
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("上移")
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == draft.members.count - 1)
                .help("下移")
            Button(role: .destructive) { remove(member.model) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("移除")
        }
        .accessibilityElement(children: .contain)
    }

    private func priceBinding(_ model: String, input: Bool) -> Binding<String> {
        Binding(
            get: { input ? (priceTexts[model]?.input ?? "") : (priceTexts[model]?.output ?? "") },
            set: { value in
                var texts = priceTexts[model] ?? ("", "")
                if input { texts.input = value } else { texts.output = value }
                priceTexts[model] = texts
            }
        )
    }

    private func move(_ index: Int, by step: Int) {
        let target = index + step
        guard draft.members.indices.contains(index), draft.members.indices.contains(target) else { return }
        draft.members.swapAt(index, target)
    }

    private func remove(_ model: String) {
        draft.setMembers(draft.members.filter { $0.model != model })
        priceTexts[model] = nil
    }

    private func addCustomModel() {
        let model = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !InternalModelID.isInternal(model),
              !draft.members.contains(where: { $0.model.lowercased() == model.lowercased() }) else { return }
        draft.setMembers(draft.members + [GatewayPackMember(model: model)])
        customModel = ""
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        if await store.savePack(currentDraft) {
            dismiss()
        } else {
            errorMessage = store.mutationFailureMessage
        }
    }

    /// The first-byte timeout typed: a whole number of milliseconds (ASCII digits only), else nil.
    /// The range is checked by `GatewayPackValidation`.
    nonisolated static func timeout(from text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(cleaned)
    }

    /// Empty → no price (`.some(nil)`); a number ≥ 0 → that price; anything else → nil (invalid).
    static func price(_ text: String) -> Decimal?? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return .some(nil) }
        guard cleaned.allSatisfy({ $0.isASCII }), let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value >= 0, Double(cleaned) != nil else { return nil }
        return .some(value)
    }

    static func text(_ price: Decimal?) -> String {
        price.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }
}
