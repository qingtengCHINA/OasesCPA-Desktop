import SwiftUI

/// A number with its label: label over value over one caption line. No box, no icon tile, no
/// per-metric colour; a row of metrics is separated by spacing only.
struct MetricCard: View {
    let metric: MetricSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.xs) {
            Text(LocalizedStringKey(metric.title))
                .font(.caption)
                .foregroundStyle(Oases.Color.textSecondary)
                .lineLimit(1)

            Text(LocalizedStringKey(metric.value))
                .font(.title3.monospacedDigit())
                .foregroundStyle(Oases.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())

            Text(LocalizedStringKey(metric.caption))
                .font(.caption)
                .foregroundStyle(Oases.Color.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, Oases.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
