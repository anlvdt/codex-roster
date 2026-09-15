import SwiftUI

/// Symmetrically Balanced Two-Ear Live Notch Flanking System for Codex Roster.
/// Minimalist, high-legibility telemetry hugging the MacBook camera notch:
/// - Left Ear: 5-Hour Quota (large, borderless typography, seamlessly flush to notch)
/// - Center: Physical camera notch clearance (100% transparent & hugging notch edges)
/// - Right Ear: Weekly Quota + Reset Countdown / Banked Resets (seamlessly flush to notch)
struct PrismFilamentView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.colorScheme) private var colorScheme

    let account: SavedAccount?
    var diameter: CGFloat = 20
    var compact: Bool = true
    var notchWidth: CGFloat = 185
    var earWidth: CGFloat = 106
    var compactHeight: CGFloat = 32

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

    private var physicalNotchClearance: CGFloat {
        notchWidth > 0 ? max(notchWidth - 22, 160) : 0
    }

    var body: some View {
        if notchWidth > 0 {
            // Hardware Notch Mode: Hugs left and right of the physical camera notch tightly
            HStack(spacing: 0) {
                leftEarWing

                Spacer(minLength: 0)
                    .frame(width: physicalNotchClearance)

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
            HStack(spacing: 3) {
                Text("5H")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize()
                Text("\(fivePercent ?? 0)%")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fiveTint)
                    .fixedSize()
            }

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 12)

            // Weekly Quota
            HStack(spacing: 3) {
                Text(language.text("Tuần", "Wk"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize()
                Text("\(weekPercent ?? 0)%")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(weekTint)
                    .fixedSize()
            }

            // Banked Reset / Reset Countdown
            if bankedCount > 0 {
                HStack(spacing: 2) {
                    Text("⟲")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .fixedSize()
                    Text("\(bankedCount)")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                        .fixedSize()
                }
            } else if let weeklyResetDate {
                HStack(spacing: 2) {
                    Text("↺")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.50))
                        .fixedSize()
                    Text(compactReset(weeklyResetDate))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize()
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
        HStack(spacing: 3) {
            Text(language.text("5H", "5H"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize()

            if let fivePercent {
                Text("\(fivePercent)%")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fiveTint)
                    .fixedSize()
            } else {
                Text("—")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(width: earWidth, height: compactHeight, alignment: .center)
        .background(leftEarBackground)
        .overlay(leftEarBorder)
        .help(account?.displayName ?? language.text("Chưa có phiên", "No session"))
    }

    // MARK: - Right Ear Wing (Flanking Right of Camera Notch)
    private var rightEarWing: some View {
        HStack(spacing: 4.5) {
            // Weekly Quota
            HStack(spacing: 2.5) {
                Text(language.text("Tuần", "Wk"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize()

                if let weekPercent {
                    Text("\(weekPercent)%")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(weekTint)
                        .fixedSize()
                } else {
                    Text("—")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            // Banked Reset / Reset Countdown
            if bankedCount > 0 {
                HStack(spacing: 2) {
                    Text("⟲")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .fixedSize()

                    Text("\(bankedCount)")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                        .fixedSize()
                }
                .help(language.text("\(bankedCount) lượt banked reset có thể dùng", "\(bankedCount) banked resets available"))
            } else if let weeklyResetDate {
                HStack(spacing: 2) {
                    Text("↺")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.50))
                        .fixedSize()

                    Text(compactReset(weeklyResetDate))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize()
                }
                .help(account?.usage?.weekly?.resetDescription(in: language.language) ?? "")
            }
        }
        .padding(.horizontal, 7)
        .frame(width: earWidth, height: compactHeight, alignment: .center)
        .background(rightEarBackground)
        .overlay(rightEarBorder)
    }

    // MARK: - Ear Shapes & Backgrounds
    private var leftEarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 10,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var rightEarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 10,
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
                stops: [
                    .init(color: Color.white.opacity(0.22), location: 0.0),
                    .init(color: Color.white.opacity(0.10), location: 0.65),
                    .init(color: Color.clear, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            lineWidth: 0.6
        )
    }

    private var rightEarBorder: some View {
        rightEarShape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: Color.clear, location: 0.0),
                    .init(color: Color.white.opacity(0.10), location: 0.35),
                    .init(color: Color.white.opacity(0.22), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
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
