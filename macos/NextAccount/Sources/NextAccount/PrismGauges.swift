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
                            .font(.system(size: compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: compact ? 9 : 10))
                            .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                    }

                    Spacer()

                    if let fivePercent {
                        Text("\(fivePercent)%")
                            .font(.system(size: compact ? 11 : 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                    } else {
                        Text(language.text("Chưa có", "No data"))
                            .font(.system(size: compact ? 9 : 10))
                            .foregroundStyle(.secondary)
                    }
                }

                // 5-Segmented tactile bar
                PrismSegmentedBar(percent: fivePercent ?? 0, segments: 5, height: compact ? 5 : 7)

                if showLabels, let fiveHour {
                    HStack {
                        Text(fiveHour.resetDescription(in: language.language))
                            .font(.system(size: 9, weight: .regular))
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
                            .font(.system(size: compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "calendar")
                            .font(.system(size: compact ? 9 : 10))
                            .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                    }

                    Spacer()

                    if let weekPercent {
                        Text("\(weekPercent)%")
                            .font(.system(size: compact ? 11 : 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                    } else {
                        Text(language.text("Chưa có", "No data"))
                            .font(.system(size: compact ? 9 : 10))
                            .foregroundStyle(.secondary)
                    }
                }

                // Continuous Horizon Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
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
                            .font(.system(size: 9, weight: .regular))
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
                            .fill(Color.primary.opacity(0.07))

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
                    Color.primary.opacity(0.10),
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

/// Micro filament dual-line gauge for ultra-compact tiles
struct PrismFilamentBar: View {
    let fivePercent: Int?
    let weekPercent: Int?
    var width: CGFloat = 38
    var height: CGFloat = 3

    var body: some View {
        VStack(spacing: 2) {
            // 5h line
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(PrismTheme.quotaTint(percent: fivePercent))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(fivePercent ?? 0) / 100.0)))
                }
            }
            .frame(width: width, height: height)

            // Weekly line
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(PrismTheme.quotaTint(percent: weekPercent))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(weekPercent ?? 0) / 100.0)))
                }
            }
            .frame(width: width, height: height)
        }
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
                    .font(.system(size: 9))
                    .foregroundStyle(PrismTheme.amber)
                Text(window.relativeReset(in: language.language))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.04))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            )
        }
    }
}
