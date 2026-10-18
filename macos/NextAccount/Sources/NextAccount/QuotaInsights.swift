import SwiftUI

// MARK: - Models (CLI JSON)

struct QuotaHistoryOutput: Decodable {
    let accountId: UUID?
    let samples: [QuotaHistorySample]
}

struct QuotaHistorySample: Decodable, Identifiable {
    let minute: Int64
    let fiveRemaining: Int
    let weekRemaining: Int

    var id: Int64 { minute }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(minute * 60))
    }
}

struct CodexActivitySummary: Decodable, Equatable {
    let working: Int
    let waiting: Int
    let idle: Int
    let desktopRunning: Bool
    let entries: [CodexActivityEntry]

    var hasSignal: Bool {
        working > 0 || waiting > 0 || idle > 0 || desktopRunning
    }

    var compactLabel: String {
        var parts: [String] = []
        if working > 0 { parts.append("▶\(working)") }
        if waiting > 0 { parts.append("?\(waiting)") }
        if idle > 0 { parts.append("○\(idle)") }
        return parts.isEmpty ? (desktopRunning ? "Desktop" : "—") : parts.joined(separator: " · ")
    }
}

struct CodexActivityEntry: Decodable, Equatable, Identifiable {
    let kind: String
    let label: String
    let detail: String?

    var id: String { "\(kind)-\(label)-\(detail ?? "")" }
}

// MARK: - Preferences

enum RosterDisplayPreferences {
    static let resetAsClockKey = "codex_roster_reset_as_clock"

    static var resetAsClock: Bool {
        get { UserDefaults.standard.bool(forKey: resetAsClockKey) }
        set { UserDefaults.standard.set(newValue, forKey: resetAsClockKey) }
    }
}

enum ResetClockFormat {
    /// Countdown (`3H`, `12M`) or absolute clock (`03:20`, `tmrw 01:00`).
    static func compact(_ date: Date, asClock: Bool, language: AppLanguage) -> String {
        if asClock {
            return clockLabel(date, language: language)
        }
        return countdownLabel(date, language: language)
    }

    private static func countdownLabel(_ date: Date, language: AppLanguage) -> String {
        let diff = date.timeIntervalSince(Date())
        guard diff > 0 else {
            return language == .vietnamese ? "CHỜ" : "PENDING"
        }
        let seconds = Int(diff)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        if days > 0 {
            return "\(days)D"
        } else if hours > 0 {
            return "\(hours)H"
        } else {
            let minutes = max(1, (seconds % 3600) / 60)
            return "\(minutes)M"
        }
    }

    private static func clockLabel(_ date: Date, language: AppLanguage) -> String {
        let calendar = Calendar.current
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(language.locale))
        if calendar.isDateInToday(date) {
            return time
        }
        if calendar.isDateInTomorrow(date) {
            return language == .vietnamese ? "mai \(time)" : "tmrw \(time)"
        }
        let weekday = date.formatted(Date.FormatStyle().weekday(.abbreviated).locale(language.locale))
        return "\(weekday) \(time)"
    }
}

// MARK: - Sparkline

struct QuotaHistorySparkline: View {
    @EnvironmentObject private var language: LanguageStore
    let samples: [QuotaHistorySample]
    var height: CGFloat = 44

    @State private var hoverIndex: Int?

    private var plotted: [QuotaHistorySample] {
        Array(samples.suffix(max(2, samples.count)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.text("Quota 7 ngày", "7-day quota"))
                    .font(RosterSecondaryChrome.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let hoverIndex, plotted.indices.contains(hoverIndex) {
                    let sample = plotted[hoverIndex]
                    Text(hoverCaption(sample))
                        .font(RosterSecondaryChrome.micro.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    LegendDot(color: PrismTheme.accent, label: "5H")
                    LegendDot(color: PrismTheme.emerald, label: language.text("Tuần", "Wk"))
                }
            }

            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                    if plotted.count >= 2 {
                        path(for: \.fiveRemaining, in: width, height: height)
                            .stroke(PrismTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        path(for: \.weekRemaining, in: width, height: height)
                            .stroke(PrismTheme.emerald, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    } else {
                        Text(language.text("Chưa đủ mẫu — sẽ đầy sau vài lần quét quota.", "Not enough samples yet — fills after a few quota polls."))
                            .font(RosterSecondaryChrome.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard plotted.count >= 2 else { return }
                        let step = width / CGFloat(max(plotted.count - 1, 1))
                        let index = Int((location.x / max(step, 1)).rounded())
                        hoverIndex = min(max(index, 0), plotted.count - 1)
                    case .ended:
                        hoverIndex = nil
                    }
                }
            }
            .frame(height: height)
        }
    }

    private func hoverCaption(_ sample: QuotaHistorySample) -> String {
        let time = sample.date.formatted(date: .abbreviated, time: .shortened)
        let five = sample.fiveRemaining >= 0 ? "\(sample.fiveRemaining)%" : "—"
        let week = sample.weekRemaining >= 0 ? "\(sample.weekRemaining)%" : "—"
        return "\(time) · 5H \(five) · Wk \(week)"
    }

    private func path(
        for keyPath: KeyPath<QuotaHistorySample, Int>,
        in width: CGFloat,
        height: CGFloat
    ) -> Path {
        Path { path in
            for (index, sample) in plotted.enumerated() {
                let value = sample[keyPath: keyPath]
                guard value >= 0 else { continue }
                let x = width * CGFloat(index) / CGFloat(max(plotted.count - 1, 1))
                let y = height - (CGFloat(value) / 100) * (height - 4) - 2
                if path.isEmpty {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(RosterSecondaryChrome.micro)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Live activity strip

struct CodexActivityStrip: View {
    @EnvironmentObject private var language: LanguageStore
    let activity: CodexActivitySummary?

    var body: some View {
        if let activity, activity.hasSignal {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(activity.working > 0 ? PrismTheme.accent : .secondary)
                    Text(language.text("Phiên Codex", "Codex sessions"))
                        .font(RosterSecondaryChrome.caption.weight(.medium))
                    Spacer()
                    Text(activityCaption(activity))
                        .font(RosterSecondaryChrome.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !activity.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(activity.entries.prefix(4)) { entry in
                            HStack(spacing: 6) {
                                Text(glyph(for: entry.kind))
                                    .font(RosterSecondaryChrome.micro)
                                    .foregroundStyle(tint(for: entry.kind))
                                Text(entry.label)
                                    .font(RosterSecondaryChrome.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let detail = entry.detail {
                                    Text(detail)
                                        .font(RosterSecondaryChrome.micro)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .help(language.text(
                "▶ đang chạy · ? chờ bạn · ○ idle. Ước lượng từ process + rollout gần đây.",
                "▶ working · ? waiting · ○ idle. Estimated from processes + recent rollouts."
            ))
        }
    }

    private func activityCaption(_ activity: CodexActivitySummary) -> String {
        language.text(
            "▶\(activity.working) · ?\(activity.waiting) · ○\(activity.idle)",
            "▶\(activity.working) · ?\(activity.waiting) · ○\(activity.idle)"
        )
    }

    private func glyph(for kind: String) -> String {
        switch kind {
        case "working": return "▶"
        case "waiting": return "?"
        default: return "○"
        }
    }

    private func tint(for kind: String) -> Color {
        switch kind {
        case "working": return PrismTheme.accent
        case "waiting": return PrismTheme.warning
        default: return .secondary
        }
    }
}

/// `codex-roster quota-forecast --json` (contract v1, additive fields).
struct QuotaForecastOutput: Decodable {
    let accountId: UUID?
    let generatedAt: RustDate?
    let fiveHour: QuotaWindowForecast?
    let weekly: QuotaWindowForecast?
}

struct QuotaWindowForecast: Decodable {
    let window: String
    let remainingPercent: Double
    let burnPerMinute: Double
    let timeToEmptyMinutes: Double?
    let ciLowMinutes: Double?
    let ciHighMinutes: Double?
    let confidence: String
    let sampleCount: Int

    /// `cạn sau ~22 phút (CI 14–35)` / `empty in ~22m (CI 14–35)`.
    /// Returns nil when the window shows no measurable burn.
    func summary(vietnamese: Bool) -> String? {
        guard let timeToEmptyMinutes else { return nil }
        let estimate = Self.humanize(timeToEmptyMinutes, vietnamese: vietnamese)
        let interval: String
        if let low = ciLowMinutes, let high = ciHighMinutes {
            interval = " (CI \(Self.humanize(low, vietnamese: vietnamese))–\(Self.humanize(high, vietnamese: vietnamese)))"
        } else {
            interval = ""
        }
        let confidenceText = vietnamese ? "độ tin cậy \(confidence)" : "confidence \(confidence)"
        return vietnamese
            ? "cạn sau ~\(estimate)\(interval) · \(confidenceText)"
            : "empty in ~\(estimate)\(interval) · \(confidenceText)"
    }

    static func humanize(_ minutes: Double, vietnamese: Bool) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        if rounded >= 120 {
            let hours = rounded / 60
            let rest = rounded % 60
            if rest == 0 { return vietnamese ? "\(hours) giờ" : "\(hours)h" }
            return vietnamese ? "\(hours) giờ \(rest) phút" : "\(hours)h \(rest)m"
        }
        return vietnamese ? "\(rounded) phút" : "\(rounded)m"
    }
}
