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
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            // Chamber 1: 5-Hour Rolling Allowance (Segmented)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label {
                        Text(language.text("Cửa sổ 5 giờ", "5-hour window"))
                            .font(compact ? PrismTheme.fontCaption : PrismTheme.fontBodyCompactMedium)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(compact ? PrismTheme.fontChipIcon : PrismTheme.fontCaptionRegular)
                            .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                    }

                    Spacer()

                    if let fivePercent {
                        Text("\(fivePercent)%")
                            .font(compact ? PrismTheme.fontBodyCompactBold : PrismTheme.fontMetricSub)
                            .monospacedDigit()
                            .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                    } else {
                        Text(language.text("Chưa có", "No data"))
                            .font(compact ? PrismTheme.fontChipIcon : PrismTheme.fontCaptionRegular)
                            .foregroundStyle(.secondary)
                    }
                }

                // 5-Segmented tactile bar
                PrismSegmentedBar(percent: fivePercent ?? 0, segments: 5, height: compact ? 5 : 7)

                if showLabels, let fiveHour {
                    HStack {
                        Text(fiveHour.resetDescription(in: language.language))
                            .font(PrismTheme.fontChipIcon)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 1)
                }
            }

            // Chamber 2: Weekly Quota Horizon
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label {
                        Text(language.text("Hạn mức tuần", "Weekly quota"))
                            .font(compact ? PrismTheme.fontCaption : PrismTheme.fontBodyCompactMedium)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "calendar")
                            .font(compact ? PrismTheme.fontChipIcon : PrismTheme.fontCaptionRegular)
                            .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                    }

                    Spacer()

                    if let weekPercent {
                        Text("\(weekPercent)%")
                            .font(compact ? PrismTheme.fontBodyCompactBold : PrismTheme.fontMetricSub)
                            .monospacedDigit()
                            .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                    } else {
                        Text(language.text("Chưa có", "No data"))
                            .font(compact ? PrismTheme.fontChipIcon : PrismTheme.fontCaptionRegular)
                            .foregroundStyle(.secondary)
                    }
                }

                // Continuous Horizon Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(PrismTheme.trackFill)
                            .frame(height: compact ? 3 : 4)

                        let width = max(0, min(geo.size.width, geo.size.width * CGFloat(weekPercent ?? 0) / 100.0))
                        Capsule()
                            .fill(PrismTheme.quotaGradient(percent: weekPercent))
                            .frame(width: width, height: compact ? 3 : 4)
                            .shadow(color: PrismTheme.quotaTint(percent: weekPercent).opacity(0.3), radius: 2)
                    }
                }
                .frame(height: compact ? 3 : 4)

                if showLabels, let weekly {
                    HStack {
                        Text(weekly.resetDescription(in: language.language))
                            .font(PrismTheme.fontChipIcon)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 1)
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

/// Micro filament dual-line gauge for ultra-compact tiles with explicit labels and percentages
struct PrismFilamentBar: View {
    @EnvironmentObject private var language: LanguageStore
    let fivePercent: Int?
    let weekPercent: Int?
    var width: CGFloat = 36
    var height: CGFloat = 3.5
    var showLabels: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            // 5H quota line
            HStack(spacing: 3) {
                if showLabels {
                    Text("5H")
                        .font(PrismTheme.fontMicro)
                        .foregroundStyle(PrismTheme.textSecondary)
                        .frame(width: 14, alignment: .leading)
                        .fixedSize()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(PrismTheme.surfaceStrong)
                        Capsule()
                            .fill(PrismTheme.quotaTint(percent: fivePercent))
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(fivePercent ?? 0) / 100.0)))
                    }
                }
                .frame(width: width, height: height)

                if showLabels, let fivePercent {
                    Text("\(fivePercent)%")
                        .font(PrismTheme.fontChip)
                        .monospacedDigit()
                        .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                        .frame(width: 32, alignment: .trailing)
                        .fixedSize()
                }
            }

            // Weekly quota line
            HStack(spacing: 3) {
                if showLabels {
                    Text(language.text("Wk", "Wk"))
                        .font(PrismTheme.fontMicro)
                        .foregroundStyle(PrismTheme.textSecondary)
                        .frame(width: 14, alignment: .leading)
                        .fixedSize()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(PrismTheme.surfaceStrong)
                        Capsule()
                            .fill(PrismTheme.quotaTint(percent: weekPercent))
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(weekPercent ?? 0) / 100.0)))
                    }
                }
                .frame(width: width, height: height)

                if showLabels, let weekPercent {
                    Text("\(weekPercent)%")
                        .font(PrismTheme.fontChip)
                        .monospacedDigit()
                        .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                        .frame(width: 32, alignment: .trailing)
                        .fixedSize()
                }
            }
        }
        .help(
            language.text(
                "5H: \(fivePercent.map { "\($0)%" } ?? "—"), Tuần: \(weekPercent.map { "\($0)%" } ?? "—")",
                "5H: \(fivePercent.map { "\($0)%" } ?? "—"), Weekly: \(weekPercent.map { "\($0)%" } ?? "—")"
            )
        )
    }
}

/// Reset countdown badge with clock icon and monospaced digits
struct PrismResetClockChip: View {
    let window: UsageWindow?
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        if let window {
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(PrismTheme.fontChipIcon)
                    .foregroundStyle(PrismTheme.amber)
                Text(window.relativeReset(in: language.language))
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(.secondary)
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
