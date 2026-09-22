import SwiftUI

/// Components for precision tactile quota gauges, dual chambers, and reset clocks.
struct PrismDualChamberGauge: View {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    var showLabels: Bool = true
    var compact: Bool = false
    @EnvironmentObject private var language: LanguageStore

    private var fivePercent: Int? {
        fiveHour?.displayRemainingPercent
    }

    private var weekPercent: Int? {
        weekly?.displayRemainingPercent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            // Chamber 1: 5-Hour Rolling Allowance (Segmented)
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(spacing: 4) {
                    if compact {
                        Text("5H")
                            .font(PrismTheme.fontChip)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 30, alignment: .leading)
                    } else {
                        Label {
                            Text(language.text("Cửa sổ 5 giờ", "5-hour window"))
                                .font(PrismTheme.fontBodyCompactMedium)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(PrismTheme.fontCaptionRegular)
                                .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                        }
                    }

                    Spacer(minLength: 4)

                    if let fivePercent {
                        Text("\(fivePercent)%")
                            .font(compact ? PrismTheme.fontCaptionBold : PrismTheme.fontMetricSub)
                            .monospacedDigit()
                            .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                    } else {
                        Text(language.text("—", "—"))
                            .font(PrismTheme.fontChip)
                            .foregroundStyle(.secondary)
                    }
                }

                PrismSegmentedBar(percent: fivePercent ?? 0, segments: 5, height: compact ? 4 : 7)

                if showLabels, let fiveHour {
                    Text(fiveHour.resetDescription(in: language.language))
                        .font(PrismTheme.fontMicro)
                        .foregroundStyle(
                            PrismTheme.resetProximityTint(window: fiveHour, kind: .fiveHour)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            // Chamber 2: Weekly Quota Horizon
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(spacing: 4) {
                    if compact {
                        Text(language.text("Tuần", "Wk"))
                            .font(PrismTheme.fontChip)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 30, alignment: .leading)
                    } else {
                        Label {
                            Text(language.text("Hạn mức tuần", "Weekly quota"))
                                .font(PrismTheme.fontBodyCompactMedium)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "calendar")
                                .font(PrismTheme.fontCaptionRegular)
                                .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                        }
                    }

                    Spacer(minLength: 4)

                    if let weekPercent {
                        Text("\(weekPercent)%")
                            .font(compact ? PrismTheme.fontCaptionBold : PrismTheme.fontMetricSub)
                            .monospacedDigit()
                            .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                    } else {
                        Text(language.text("—", "—"))
                            .font(PrismTheme.fontChip)
                            .foregroundStyle(.secondary)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(PrismTheme.trackFill)
                            .frame(height: compact ? 3 : 4)

                        let width = max(0, min(geo.size.width, geo.size.width * CGFloat(weekPercent ?? 0) / 100.0))
                        Capsule()
                            .fill(PrismTheme.quotaGradient(percent: weekPercent))
                            .frame(width: width, height: compact ? 3 : 4)
                            .shadow(color: PrismTheme.quotaTint(percent: weekPercent).opacity(0.3), radius: compact ? 1 : 2)
                    }
                }
                .frame(height: compact ? 3 : 4)

                if showLabels, let weekly {
                    Text(weekly.resetDescription(in: language.language))
                        .font(PrismTheme.fontMicro)
                        .foregroundStyle(
                            PrismTheme.resetProximityTint(window: weekly, kind: .weekly)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
    }
}

/// A tactile segmented progress bar representing discrete energy cells
struct PrismSegmentedBar: View {
    let percent: Int
    var segments: Int = 5
    var height: CGFloat = 6

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                let segmentMin = index * (100 / segments)
                let fillRatio = max(0.0, min(1.0, Double(percent - segmentMin) / Double(100 / segments)))
                let tint = PrismTheme.quotaTint(percent: percent)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                            .fill(PrismTheme.trackSoft)

                        if fillRatio > 0 {
                            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                                .fill(tint)
                                .frame(width: geo.size.width * CGFloat(fillRatio))
                                .shadow(color: tint.opacity(0.25), radius: 1.5)
                        }
                    }
                }
                .frame(height: height)
            }
        }
    }
}

/// Arc gauge (180 or 120-degree sweep) for compact account cards & tiles
struct PrismArcGauge: View {
    let percent: Int?
    var size: CGFloat = 42
    var lineWidth: CGFloat = 3.5

    private var ratio: CGFloat {
        guard let p = percent else { return 0 }
        return max(0, min(1, CGFloat(p) / 100.0))
    }

    var body: some View {
        ZStack {
            // Track arc
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(
                    PrismTheme.surfaceHover,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(90))

            // Value arc
            if ratio > 0 {
                Circle()
                    .trim(from: 0.15, to: 0.15 + (0.70 * ratio))
                    .stroke(
                        PrismTheme.quotaTint(percent: percent),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90))
                    .shadow(color: PrismTheme.quotaTint(percent: percent).opacity(0.35), radius: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Micro filament dual-line gauge for ultra-compact tiles.
struct PrismFilamentBar: View {
    @EnvironmentObject private var language: LanguageStore
    let fivePercent: Int?
    let weekPercent: Int?
    /// Optional monthly spend-control remaining % (`credit_limit`). Shown only when
    /// the usage payload publishes it — never derived from weekly/5H.
    var monthPercent: Int? = nil
    var width: CGFloat = 36
    var height: CGFloat = 3.5
    /// Axis labels (5H / Wk). Hide on dense roster rows; tooltip still has them.
    var showAxisLabels: Bool = true
    var showPercents: Bool = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            filamentRow(label: "5H", percent: fivePercent)
            filamentRow(label: language.text("Wk", "Wk"), percent: weekPercent)
            if let monthPercent {
                filamentRow(label: language.text("Th", "Mo"), percent: monthPercent)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        var parts = [
            language.text(
                "5H: \(fivePercent.map { "\($0)%" } ?? "—")",
                "5H: \(fivePercent.map { "\($0)%" } ?? "—")"
            ),
            language.text(
                "Tuần: \(weekPercent.map { "\($0)%" } ?? "—")",
                "Weekly: \(weekPercent.map { "\($0)%" } ?? "—")"
            ),
        ]
        if let monthPercent {
            parts.append(language.text("Tháng: \(monthPercent)%", "Monthly: \(monthPercent)%"))
        }
        return parts.joined(separator: ", ")
    }

    private func filamentRow(label: String, percent: Int?) -> some View {
        HStack(spacing: 3) {
            if showAxisLabels {
                Text(label)
                    .font(PrismTheme.fontMicro)
                    .foregroundStyle(PrismTheme.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 14, alignment: .leading)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PrismTheme.surfaceStrong)
                    Capsule()
                        .fill(PrismTheme.quotaTint(percent: percent))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent ?? 0) / 100.0)))
                }
            }
            .frame(width: width, height: height)

            if showPercents {
                // fixedSize before frame so "100%" never wraps; minWidth keeps columns aligned.
                Text(percent.map { "\($0)%" } ?? "—")
                    .font(PrismTheme.fontChip)
                    .monospacedDigit()
                    .foregroundStyle(PrismTheme.quotaTint(percent: percent))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// Reset countdown badge with clock icon and monospaced digits
struct PrismResetClockChip: View {
    let window: UsageWindow?
    var kind: QuotaResetWindowKind = .fiveHour
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        if let window {
            let tint = PrismTheme.resetProximityTint(window: window, kind: kind)
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(PrismTheme.fontChipIcon)
                    .foregroundStyle(tint)
                Text(window.relativeReset(in: language.language))
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(PrismTheme.surfacePanel)
                    .overlay(Capsule().strokeBorder(PrismTheme.trackFill, lineWidth: 0.5))
            )
        }
    }
}
