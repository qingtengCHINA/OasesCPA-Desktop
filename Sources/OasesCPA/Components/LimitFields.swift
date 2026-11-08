import SwiftUI

enum LimitFieldError: Error, Equatable {
    /// Not a whole number greater than zero.
    case notPositiveInteger
    /// Not a number greater than zero.
    case notPositiveNumber

    var message: String {
        switch self {
        case .notPositiveInteger: OasesLocalization.localized("请输入大于 0 的整数，或留空表示不限。")
        case .notPositiveNumber: OasesLocalization.localized("请输入大于 0 的数字，或留空表示不限。")
        }
    }
}

/// The two rate limits of a key: requests per minute and tokens per day, each a positive whole
/// number or empty (no limit). An invalid entry keeps the last valid value and sets `hasError`.
struct LimitFields: View {
    @Binding var rateLimit: GatewayRateLimit
    @Binding var hasError: Bool
    @State private var requestsText: String
    @State private var tokensText: String

    init(rateLimit: Binding<GatewayRateLimit>, hasError: Binding<Bool>) {
        _rateLimit = rateLimit
        _hasError = hasError
        _requestsText = State(initialValue: rateLimit.wrappedValue.requestsPerMinute.map(String.init) ?? "")
        _tokensText = State(initialValue: rateLimit.wrappedValue.tokensPerDay.map(String.init) ?? "")
    }

    /// Empty → nil; a whole number > 0 → that number (spaces, "," and "_" are ignored).
    nonisolated static func parse(_ text: String) -> Result<Int?, LimitFieldError> {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return .success(nil) }
        guard cleaned.allSatisfy(\.isASCII), let value = Int(cleaned), value > 0 else {
            return .failure(.notPositiveInteger)
        }
        return .success(value)
    }

    /// Empty → nil; a number > 0 (for example a spending limit) → that number.
    nonisolated static func parseDecimal(_ text: String) -> Result<Double?, LimitFieldError> {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return .success(nil) }
        guard cleaned.allSatisfy(\.isASCII), let value = Double(cleaned), value.isFinite, value > 0 else {
            return .failure(.notPositiveNumber)
        }
        return .success(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            field("每分钟请求数", placeholder: "不限", text: $requestsText) { rateLimit.requestsPerMinute = $0 }
            field("每日 Token 上限", placeholder: "不限", text: $tokensText) { rateLimit.tokensPerDay = $0 }
            if let message = errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Oases.Color.dangerText)
            }
        }
        .onAppear { updateError() }
    }

    private var errorMessage: String? {
        for text in [requestsText, tokensText] {
            if case .failure(let error) = Self.parse(text) { return error.message }
        }
        return nil
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, apply: @escaping (Int?) -> Void) -> some View {
        LabeledContent {
            TextField(LocalizedStringKey(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .onChange(of: text.wrappedValue) { _, newValue in
                    if case .success(let value) = Self.parse(newValue) { apply(value) }
                    updateError()
                }
        } label: {
            Text(LocalizedStringKey(title))
        }
    }

    private func updateError() {
        hasError = errorMessage != nil
    }
}
