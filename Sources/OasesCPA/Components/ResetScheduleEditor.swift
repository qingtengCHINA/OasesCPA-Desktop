import SwiftUI

/// A pack key's scheduled quota restore: off (never), or every N days / weeks / months counted
/// from a start time (now unless one is chosen; at most one day ahead, like the gateway). The
/// gateway's `next_reset_at` is shown when the schedule came from the server and is unchanged.
struct ResetScheduleEditor: View {
    @Binding var schedule: GatewayResetSchedule?
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            Toggle("定时恢复额度", isOn: Binding(
                get: { schedule != nil },
                set: { isOn in schedule = isOn ? (schedule ?? GatewayResetSchedule(unit: .month, every: 1)) : nil }
            ))
            if let current = schedule {
                HStack(spacing: Oases.Space.m) {
                    Stepper(value: Binding(
                        get: { current.every },
                        set: { value in update { $0.every = min(max(1, value), $0.unit.maximumEvery) } }
                    ), in: 1...current.unit.maximumEvery) {
                        Text(OasesLocalization.localizedFormat("每 %lld", current.every))
                            .monospacedDigit()
                    }
                    Picker("周期", selection: Binding(
                        get: { current.unit },
                        set: { unit in update { $0.unit = unit; $0.every = min($0.every, unit.maximumEvery) } }
                    )) {
                        Text("天").tag(GatewayResetUnit.day)
                        Text("周").tag(GatewayResetUnit.week)
                        Text("月").tag(GatewayResetUnit.month)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("指定起算时间", isOn: Binding(
                    get: { current.anchorAt != nil },
                    set: { isOn in update { $0.anchorAt = isOn ? ($0.anchorAt ?? now) : nil } }
                ))
                if let anchor = current.anchorAt {
                    DatePicker(
                        "起算于",
                        selection: Binding(get: { anchor }, set: { date in update { $0.anchorAt = date } }),
                        in: ...now.addingTimeInterval(86_400),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } else {
                    Text("从保存时起算。")
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                }
                if let next = current.nextResetAt {
                    Text(OasesLocalization.localizedFormat("下次恢复：%@", next.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                }
                ForEach(GatewayPackValidation.errors(reset: current, now: now), id: \.self) { message in
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Oases.Color.dangerText)
                }
                Text("到时把本周期用量并入累计，额度重新开始；已经过去的时间点不补算。")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textTertiary)
            } else {
                Text("额度用完后不会自动恢复。")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
            }
        }
    }

    /// Any edit makes a new schedule: the server's next/last restore no longer apply to it.
    private func update(_ change: (inout GatewayResetSchedule) -> Void) {
        guard var value = schedule else { return }
        change(&value)
        schedule = GatewayResetSchedule(unit: value.unit, every: value.every, anchorAt: value.anchorAt)
    }
}
