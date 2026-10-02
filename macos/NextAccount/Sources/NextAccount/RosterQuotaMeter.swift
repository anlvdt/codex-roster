import SwiftUI

/// Shows each independent allowance as remaining quota; unknown is never full.
struct RosterQuotaMeter: View {
    let title: String
    let remaining: Int?
    let remainingLabel: String

    private var tint: Color { PrismTheme.quotaTint(percent: remaining) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(remaining.map { "\($0)%" } ?? "—")
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    if let remaining {
                        Capsule().fill(tint)
                            .frame(width: geometry.size.width * Double(min(100, max(0, remaining))) / 100)
                    }
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + " · " + remainingLabel)
        .accessibilityValue(remaining.map { "\($0)%" } ?? "—")
        .help(title + " · " + remainingLabel)
    }
}
