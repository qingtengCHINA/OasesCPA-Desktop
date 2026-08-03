import SwiftUI

struct MetricCard: View {
    let metric: MetricSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: metric.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(metric.tint)
                    .frame(width: 30, height: 30)
                    .background(metric.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Spacer()

                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(metric.tint.opacity(0.55))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(metric.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(LocalizedStringKey(metric.value))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())

                Text(LocalizedStringKey(metric.caption))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oasesCard()
    }
}
