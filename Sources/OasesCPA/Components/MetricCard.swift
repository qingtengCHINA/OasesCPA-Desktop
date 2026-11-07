import SwiftUI

/// Stat tile: small label with a neutral icon, large SF digits, one caption line. No
/// per-tile colour, so a grid of tiles reads as one surface (status colour belongs to dots).
struct MetricCard: View {
    let metric: MetricSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            HStack(spacing: Oases.Space.s) {
                Image(systemName: metric.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Oases.Color.textTertiary)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(metric.title))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Oases.Color.textSecondary)
                    .lineLimit(1)
            }

            Text(LocalizedStringKey(metric.value))
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(Oases.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())

            Text(LocalizedStringKey(metric.caption))
                .font(.caption)
                .foregroundStyle(Oases.Color.textTertiary)
                .lineLimit(1)
        }
        .padding(Oases.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oasesCard()
        .accessibilityElement(children: .combine)
    }
}
