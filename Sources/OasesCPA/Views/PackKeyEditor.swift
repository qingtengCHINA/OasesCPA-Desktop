import SwiftUI

/// Creates a batch of pack keys, or edits one key (only the changed fields are sent; an emptied
/// limit is cleared). Limits: total tokens and total cost of the current period; a scheduled
/// restore starts a new period.
struct PackKeyEditor: View {
    enum Mode {
        case create(GatewayPack)
        case edit(GatewayPackKey, GatewayPack)
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ModelPacksStore
    let mode: Mode

    @State private var count = 1
    @State private var label: String
    @State private var enabled: Bool
    @State private var expiresAt: Date?
    @State private var tokensText: String
    @State private var costText: String
    @State private var reset: GatewayResetSchedule?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(store: ModelPacksStore, mode: Mode) {
        self.store = store
        self.mode = mode
        switch mode {
        case .create:
            _label = State(initialValue: "")
            _enabled = State(initialValue: true)
            _expiresAt = State(initialValue: nil)
            _tokensText = State(initialValue: "")
            _costText = State(initialValue: "")
            _reset = State(initialValue: nil)
        case .edit(let key, _):
            _label = State(initialValue: key.label)
            _enabled = State(initialValue: key.enabled)
            _expiresAt = State(initialValue: key.expiresAt)
            _tokensText = State(initialValue: key.limits.totalTokens.map(String.init) ?? "")
            _costText = State(initialValue: key.limits.totalCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
            _reset = State(initialValue: key.reset)
        }
    }

    private var pack: GatewayPack {
        switch mode {
        case .create(let pack), .edit(_, let pack): pack
        }
    }

    private var editedKey: GatewayPackKey? {
        if case .edit(let key, _) = mode { return key }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if editedKey == nil {
                        Stepper(value: $count, in: 1...GatewayPackValidation.maximumBatch) {
                            Text(OasesLocalization.localizedFormat("创建 %lld 把 Key", count))
                        }
                        TextField("名称前缀", text: $label, prompt: Text("多把时自动加上 -1、-2…"))
                    } else {
                        TextField("名称", text: $label)
                        Toggle("启用", isOn: $enabled)
                    }
                } header: {
                    Text(editedKey == nil
                         ? OasesLocalization.localizedFormat("为 %@ 新建 Key", pack.modelID)
                         : OasesLocalization.localized("编辑模型包 Key"))
                }

                Section("额度（本周期）") {
                    TextField("总 Token 上限", text: $tokensText, prompt: Text("不限"))
                    TextField("总花费上限（美元）", text: $costText, prompt: Text("不限"))
                    if !pack.isPriced {
                        Text("这个模型包有成员没有价格，不能设置花费上限。")
                            .font(.caption)
                            .foregroundStyle(Oases.Color.warningText)
                    }
                    if case .failure(let error) = LimitFields.parse(tokensText) {
                        Text(error.message).font(.caption).foregroundStyle(Oases.Color.dangerText)
                    }
                    if case .failure(let error) = LimitFields.parseDecimal(costText) {
                        Text(error.message).font(.caption).foregroundStyle(Oases.Color.dangerText)
                    }
                }

                Section("到期") {
                    ExpiryPicker(date: $expiresAt)
                }

                Section("定时恢复") {
                    ResetScheduleEditor(schedule: $reset)
                }

                if !problems.isEmpty || errorMessage != nil {
                    Section {
                        ForEach(problems, id: \.self) { Text($0).foregroundStyle(Oases.Color.dangerText) }
                        if let errorMessage { Text(errorMessage).foregroundStyle(Oases.Color.dangerText) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editedKey == nil ? "创建" : "保存") { Task { await save() } }
                    .buttonStyle(.oasesPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !problems.isEmpty || !limitsAreValid)
            }
            .padding(Oases.Space.md)
        }
        .frame(width: 560, height: 640)
    }

    private var limitsAreValid: Bool {
        if case .failure = LimitFields.parse(tokensText) { return false }
        if case .failure = LimitFields.parseDecimal(costText) { return false }
        return true
    }

    private var totalTokens: Int? {
        if case .success(let value) = LimitFields.parse(tokensText) { return value }
        return nil
    }

    private var totalCost: Decimal? {
        guard case .success(let value) = LimitFields.parseDecimal(costText), value != nil else { return nil }
        let cleaned = costText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private var batch: GatewayPackKeyBatch {
        GatewayPackKeyBatch(packID: pack.id, count: count, labelPrefix: label, expiresAt: expiresAt,
                            totalTokens: totalTokens, totalCostUSD: totalCost, reset: reset)
    }

    private var problems: [String] {
        if editedKey == nil {
            return GatewayPackValidation.errors(batch: batch, pack: pack)
        }
        var problems: [String] = []
        if let reset { problems += GatewayPackValidation.errors(reset: reset, now: Date()) }
        if totalCost != nil && !pack.isPriced { problems.append(GatewayPackValidation.pricingRequiredMessage) }
        return problems
    }

    /// Only what changed: an emptied limit or expiry is cleared, an untouched one is kept.
    static func patch(for key: GatewayPackKey, label: String, enabled: Bool, expiresAt: Date?, totalTokens: Int?,
                      totalCost: Decimal?, reset: GatewayResetSchedule?) -> GatewayPackKeyPatch {
        var patch = GatewayPackKeyPatch(keyID: key.id)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != key.label { patch.label = .set(trimmed) }
        if enabled != key.enabled { patch.enabled = .set(enabled) }
        if expiresAt != key.expiresAt { patch.expiresAt = expiresAt.map(PatchField.set) ?? .clear }
        if totalTokens != key.limits.totalTokens { patch.totalTokens = totalTokens.map(PatchField.set) ?? .clear }
        if totalCost != key.limits.totalCostUSD { patch.totalCostUSD = totalCost.map(PatchField.set) ?? .clear }
        let before = key.reset.map { GatewayResetSchedule(unit: $0.unit, every: $0.every, anchorAt: $0.anchorAt) }
        let after = reset.map { GatewayResetSchedule(unit: $0.unit, every: $0.every, anchorAt: $0.anchorAt) }
        if before != after { patch.reset = after.map(PatchField.set) ?? .clear }
        return patch
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let succeeded: Bool
        if let key = editedKey {
            succeeded = await store.updateKey(Self.patch(for: key, label: label, enabled: enabled, expiresAt: expiresAt,
                                                         totalTokens: totalTokens, totalCost: totalCost, reset: reset))
        } else {
            succeeded = await store.createKeys(batch)
        }
        if succeeded {
            dismiss()
        } else {
            errorMessage = store.actionError
        }
    }
}

/// The plaintext of keys just created, shown this one time. Copy is on demand; closing the sheet
/// forgets them (`ModelPacksStore.dismissRevealedKeys()`).
struct PackKeysRevealSheet: View {
    let keys: [GatewayCreatedPackKey]
    let onDone: () -> Void
    @State private var copiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.md) {
            Text(OasesLocalization.localizedFormat("已创建 %lld 把 Key", keys.count))
                .font(.title2.weight(.bold))
            Text("这是唯一一次显示完整 Key。请立即复制到密码管理器或客户端配置中；之后列表里只显示掩码。")
                .font(.callout)
                .foregroundStyle(Oases.Color.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: Oases.Space.sm) {
                    ForEach(keys) { key in
                        HStack(spacing: Oases.Space.m) {
                            VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                                if !key.label.isEmpty {
                                    Text(key.label)
                                        .font(.caption)
                                        .foregroundStyle(Oases.Color.textSecondary)
                                }
                                Text(key.key)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .privacySensitive()
                            }
                            Spacer()
                            Button(copiedID == key.id ? "已复制" : "复制", systemImage: copiedID == key.id ? "checkmark" : "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(key.key, forType: .string)
                                copiedID = key.id
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(Oases.Space.sm)
                        .oasesIconTile()
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                if keys.count > 1 {
                    Button("全部复制", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(keys.map(\.key).joined(separator: "\n"), forType: .string)
                        copiedID = "*"
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("完成", action: onDone)
                    .buttonStyle(.oasesPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Oases.Space.xl)
        .frame(width: 600)
    }
}
