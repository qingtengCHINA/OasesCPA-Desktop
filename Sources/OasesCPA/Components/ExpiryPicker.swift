import SwiftUI

/// An optional expiry date: off (never expires) or a date and time, with quick presets.
struct ExpiryPicker: View {
    @Binding var date: Date?
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            Toggle("设置到期时间", isOn: Binding(
                get: { date != nil },
                set: { isOn in date = isOn ? (date ?? Self.preset(days: 30, from: now)) : nil }
            ))
            if let current = date {
                DatePicker(
                    "到期于",
                    selection: Binding(get: { current }, set: { date = $0 }),
                    displayedComponents: [.date, .hourAndMinute]
                )
                HStack(spacing: Oases.Space.s) {
                    ForEach([7, 30, 90], id: \.self) { days in
                        Button(OasesLocalization.localizedFormat("%lld 天后", days)) {
                            date = Self.preset(days: days, from: now)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if current <= now {
                    Text("这个时间已经过去：保存后这把 Key 立即失效。")
                        .font(.caption)
                        .foregroundStyle(Oases.Color.dangerText)
                }
            } else {
                Text("不会自动到期。")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
            }
        }
    }

    static func preset(days: Int, from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: now) ?? now.addingTimeInterval(Double(days) * 86_400)
    }
}
