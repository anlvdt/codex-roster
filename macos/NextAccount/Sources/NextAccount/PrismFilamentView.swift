import SwiftUI

/// Symmetrically Balanced Two-Ear Live Notch Flanking System for Codex Roster.
/// Minimalist, high-legibility telemetry hugging the MacBook camera notch:
/// - Left Ear: 5-Hour Quota (large, borderless typography directly on glass)
/// - Center: Physical camera notch clearance (100% transparent & centered)
/// - Right Ear: Weekly Quota + Reset Countdown / Banked Resets (borderless & clean)
struct PrismFilamentView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.colorScheme) private var colorScheme

    let account: SavedAccount?
    var diameter: CGFloat = 20
    var compact: Bool = true
    var notchWidth: CGFloat = 185
    var earWidth: CGFloat = 100

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
        HStack(spacing: 8) {
            // 5h Quota
            HStack(spacing: 3.5) {
                Text("5h")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Text("\(fivePercent ?? 0)%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fiveTint)
            }

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 12)

            // Weekly Quota
            HStack(spacing: 3.5) {
                Text(language.text("Tuần", "Wk"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Text("\(weekPercent ?? 0)%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(weekTint)
            }

            // Banked Reset / Reset Countdown
            if bankedCount > 0 {
                HStack(spacing: 2) {
                    Text("⟲")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.orange)
                    Text("\(bankedCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                }
            } else if let weeklyResetDate {
                HStack(spacing: 2) {
                    Text("↺")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.50))
                    Text(compactReset(weeklyResetDate))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4.5)
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
        HStack(spacing: 3.5) {
            Text(language.text("5h", "5h"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))

            if let fivePercent {
                Text("\(fivePercent)%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fiveTint)
            } else {
                Text("—")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(width: earWidth, alignment: .trailing)
        .background(leftEarBackground)
        .overlay(leftEarBorder)
        .help(account?.displayName ?? language.text("Chưa có phiên", "No session"))
    }

    // MARK: - Right Ear Wing (Flanking Right of Camera Notch)
    private var rightEarWing: some View {
        HStack(spacing: 6) {
            // Weekly Quota
            HStack(spacing: 3.5) {
                Text(language.text("Tuần", "Wk"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))

                if let weekPercent {
                    Text("\(weekPercent)%")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(weekTint)
                } else {
                    Text("—")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Banked Reset / Reset Countdown
            if bankedCount > 0 {
                HStack(spacing: 2) {
                    Text("⟲")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.orange)

                    Text("\(bankedCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                }
                .help(language.text("\(bankedCount) lượt banked reset có thể dùng", "\(bankedCount) banked resets available"))
            } else if let weeklyResetDate {
                HStack(spacing: 2) {
                    Text("↺")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.50))

                    Text(compactReset(weeklyResetDate))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .help(account?.usage?.weekly?.resetDescription(in: language.language) ?? "")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(width: earWidth, alignment: .leading)
        .background(rightEarBackground)
        .overlay(rightEarBorder)
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
