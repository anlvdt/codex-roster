import SwiftUI

/// Mini circular progress gauge for quota windows
private struct MiniQuotaRing: View {
    let percent: Int?
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: 1.8)
            if let percent {
                Circle()
                    .trim(from: 0, to: min(1, max(0, CGFloat(percent) / 100.0)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 11, height: 11)
    }
}

/// Symmetrically Balanced Two-Ear Live Notch Flanking System for Codex Roster.
/// Seamlessly hugs the MacBook camera notch with balanced weight and telemetry:
/// - Left Ear: Session identity orb (Provider Icon) + 5-Hour Quota Pill (larger font)
/// - Center: Physical camera notch clearance (100% transparent & centered)
/// - Right Ear: Weekly Quota Pill + Banked Resets (if available) / Reset Countdown
struct PrismFilamentView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.colorScheme) private var colorScheme

    let account: SavedAccount?
    var diameter: CGFloat = 20
    var compact: Bool = true
    var notchWidth: CGFloat = 185
    var earWidth: CGFloat = 156

    private var fivePercent: Int? {
        account?.usage?.fiveHour?.displayRemainingPercent
    }

    private var weekPercent: Int? {
        account?.usage?.weekly?.displayRemainingPercent
    }

    private var bankedCount: Int {
        account?.usage?.bankedResets?.availableCount ?? 0
    }

    private var weeklyResetDate: Date? {
        account?.usage?.weekly?.resetAt.value
    }

    private var provider: AIProvider {
        account?.aiProvider ?? .openAI
    }

    private var isRunning: Bool {
        store.hasRunningCodexProcesses
    }

    private var fiveTint: Color {
        PrismTheme.quotaTint(percent: fivePercent)
    }

    private var weekTint: Color {
        PrismTheme.quotaTint(percent: weekPercent)
    }

    var body: some View {
        if notchWidth > 0 {
            // Hardware Notch Mode: Flanks left and right of the physical camera notch
            HStack(spacing: 0) {
                leftEarWing

                Spacer(minLength: 0)
                    .frame(width: max(notchWidth, 185))

                rightEarWing
            }
        } else {
            nonNotchCapsule
        }
    }

    // MARK: - Non-notch Display Mode (External monitors)
    private var nonNotchCapsule: some View {
        HStack(spacing: 7) {
            identityBadge
            fiveHourPill

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 12)

            weeklyQuotaPill

            if bankedCount > 0 {
                bankedPill
            } else if let weeklyResetDate {
                resetCountdownPill(date: weeklyResetDate)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.black.opacity(0.72)))
        )
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.6
            )
        )
    }

    // MARK: - Left Ear Wing (Flanking Left of Camera Notch)
    private var leftEarWing: some View {
        HStack(spacing: 6) {
            identityBadge
            fiveHourPill
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: earWidth, alignment: .trailing)
        .background(leftEarBackground)
        .overlay(leftEarBorder)
    }

    // MARK: - Right Ear Wing (Flanking Right of Camera Notch)
    private var rightEarWing: some View {
        HStack(spacing: 5) {
            weeklyQuotaPill

            if bankedCount > 0 {
                bankedPill
            } else if let weeklyResetDate {
                resetCountdownPill(date: weeklyResetDate)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: earWidth, alignment: .leading)
        .background(rightEarBackground)
        .overlay(rightEarBorder)
    }

    // MARK: - Component Pills
    private var identityBadge: some View {
        ZStack {
            Circle()
                .fill(fiveTint.opacity(0.18))
                .frame(width: 20, height: 20)

            Image(systemName: provider.icon)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(fiveTint)
        }
        .overlay(
            Circle()
                .strokeBorder(
                    fiveTint.opacity(isRunning ? 0.90 : 0.35),
                    lineWidth: isRunning ? 1.5 : 0.8
                )
        )
        .help(account?.displayName ?? language.text("Chưa có phiên", "No session"))
    }

    private var fiveHourPill: some View {
        HStack(spacing: 3.5) {
            MiniQuotaRing(percent: fivePercent, tint: fiveTint)

            Text(language.text("5h", "5h"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))

            if let fivePercent {
                Text("\(fivePercent)%")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fiveTint)
            } else {
                Text("—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(fiveTint.opacity(0.25), lineWidth: 0.5))
        )
    }

    private var weeklyQuotaPill: some View {
        HStack(spacing: 3.5) {
            MiniQuotaRing(percent: weekPercent, tint: weekTint)

            Text(language.text("Tuần", "Wk"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))

            if let weekPercent {
                Text("\(weekPercent)%")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(weekTint)
            } else {
                Text("—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(weekTint.opacity(0.25), lineWidth: 0.5))
        )
    }

    private var bankedPill: some View {
        HStack(spacing: 3.5) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.orange)

            Text("\(bankedCount)")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.orange)
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.14))
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.40), lineWidth: 0.5))
        )
        .help(language.text("\(bankedCount) lượt banked reset có thể dùng", "\(bankedCount) banked resets available"))
    }

    private func resetCountdownPill(date: Date) -> some View {
        HStack(spacing: 3) {
            Text("↺")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))

            Text(compactReset(date))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.05))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        )
        .help(account?.usage?.weekly?.resetDescription(in: language.language) ?? "")
    }

    // MARK: - Ear Shapes & Backgrounds
    private var leftEarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 11,
            bottomTrailingRadius: 4,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var rightEarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 4,
            bottomTrailingRadius: 11,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var leftEarBackground: some View {
        leftEarShape
            .fill(.ultraThinMaterial)
            .overlay {
                leftEarShape.fill(Color.black.opacity(0.72))
            }
    }

    private var rightEarBackground: some View {
        rightEarShape
            .fill(.ultraThinMaterial)
            .overlay {
                rightEarShape.fill(Color.black.opacity(0.72))
            }
    }

    private var leftEarBorder: some View {
        leftEarShape.strokeBorder(
            LinearGradient(
                colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 0.6
        )
    }

    private var rightEarBorder: some View {
        rightEarShape.strokeBorder(
            LinearGradient(
                colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 0.6
        )
    }

    private func compactReset(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        guard diff > 0 else {
            return language.text("chờ", "pending")
        }
        let seconds = Int(diff)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        if days > 0 {
            return "\(days)d"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            let minutes = max(1, (seconds % 3600) / 60)
            return language.text("\(minutes)p", "\(minutes)m")
        }
    }
}
