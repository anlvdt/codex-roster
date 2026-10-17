import SwiftUI

/// Symmetrically Balanced Two-Ear Live Notch Flanking System for Codex Roster.
/// Minimalist, high-legibility telemetry hugging the MacBook camera notch:
/// - Left Ear: 5-Hour Quota + Live Indicator & 5H Reset Countdown (informative & fun)
/// - Center: Physical camera notch clearance (100% transparent & hugging notch edges)
/// - Right Ear: Weekly Quota + Reset Countdown / Banked Resets (fully visible, zero clipping)
struct PrismFilamentView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RosterDisplayPreferences.resetAsClockKey) private var resetAsClock = false

    let quota: NotchQuotaSnapshot
    var diameter: CGFloat = 20
    var compact: Bool = true
    var notchWidth: CGFloat = 185
    var earWidth: CGFloat = 126
    var compactHeight: CGFloat = 32

    @State private var resetPulseScale: CGFloat = 1

    private var fivePercent: Int? {
        quota.fivePercent
    }

    private var weekPercent: Int? {
        quota.weekPercent
    }

    private var bankedCount: Int {
        quota.bankedCount
    }

    private var fiveResetDate: Date? {
        quota.fiveResetDate
    }

    private var weeklyResetDate: Date? {
        quota.weeklyResetDate
    }

    private var isRunning: Bool {
        if let activity = store.status?.activity {
            return activity.working > 0
        }
        return quota.providerName == "Codex" && store.hasRunningCodexProcesses
    }

    private var isWaiting: Bool {
        (store.status?.activity?.waiting ?? 0) > 0
    }

    private var fiveTint: Color {
        PrismTheme.quotaTint(percent: fivePercent)
    }

    private var weekTint: Color {
        PrismTheme.quotaTint(percent: weekPercent)
    }

    private var physicalNotchClearance: CGFloat {
        // Hug-tight: pull ears 7pt into each side of the measured camera gap
        // (same formula as NotchGeometry.physicalClearance / pre-da9460b).
        notchWidth > 0 ? max(notchWidth - 14, 170) : 0
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
            // Non-notch / external display: single centered pill (never half-apply ears).
            nonNotchCapsule
        }
    }

    // MARK: - Non-notch Display Mode (External monitors)
    private var nonNotchCapsule: some View {
        HStack(spacing: 8) {
            // 5H Quota with live energy icon
            HStack(spacing: 3) {
                Text("⚡")
                    .font(PrismTheme.fontBodyCompactBold)
                    .foregroundStyle(fiveTint)
                    .fixedSize()
                Text("5H")
                    .font(PrismTheme.fontBodySemibold)
                    .foregroundStyle(PrismTheme.textBright)
                    .fixedSize()
                if let fivePercent {
                    Text("\(fivePercent)%")
                        .font(PrismTheme.fontMetricDense)
                        .monospacedDigit()
                        .foregroundStyle(fiveTint)
                        .fixedSize()
                } else {
                    Text("—")
                        .font(PrismTheme.fontBody)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            Rectangle()
                .fill(PrismTheme.highlight)
                .frame(width: 1, height: 12)

            // Weekly Quota
            HStack(spacing: 3) {
                Text(language.text("Tuần", "Wk"))
                    .font(PrismTheme.fontBodySemibold)
                    .foregroundStyle(PrismTheme.textBright)
                    .fixedSize()
                if let weekPercent {
                    Text("\(weekPercent)%")
                        .font(PrismTheme.fontMetricDense)
                        .monospacedDigit()
                        .foregroundStyle(weekTint)
                        .fixedSize()
                } else {
                    Text("—")
                        .font(PrismTheme.fontBody)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            // Banked Reset / Reset Countdown
            if bankedCount > 0 {
                PrismBankedResetCountBadge(
                    count: bankedCount,
                    style: .filament,
                    helpText: language.text(
                        "\(bankedCount) lượt banked reset có thể dùng trong Codex",
                        "\(bankedCount) banked resets available in Codex"
                    )
                )
            } else if let weeklyResetDate {
                let resetTint = PrismTheme.resetProximityTint(resetAt: weeklyResetDate, kind: .weekly)
                HStack(spacing: 2) {
                    Text("↺")
                        .font(PrismTheme.fontCaptionBold)
                        .foregroundStyle(resetTint.opacity(0.72))
                        .fixedSize()
                    Text(compactReset(weeklyResetDate))
                        .font(PrismTheme.fontBodySemibold)
                        .foregroundStyle(resetTint)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4.5)
        .background(
            Capsule()
                .fill(Color.black)
        )
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [PrismTheme.highlight, PrismTheme.surfacePanel],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.5
            )
        )
    }

    // MARK: - Left Ear Wing (Flanking Left of Camera Notch)
    private var leftEarWing: some View {
        HStack(spacing: 3.5) {
            // Live energy / activity indicator
            Text(isWaiting ? "?" : "⚡")
                .font(PrismTheme.fontBodyCompactBold)
                .foregroundStyle(isWaiting ? PrismTheme.warning : fiveTint)
                .shadow(
                    color: (isWaiting ? PrismTheme.warning : fiveTint)
                        .opacity(isRunning || isWaiting ? 0.85 : 0),
                    radius: isRunning || isWaiting ? 3.5 : 0
                )
                .scaleEffect(resetPulseScale)
                .fixedSize()

            // 5H Quota
            HStack(spacing: 2.5) {
                Text(language.text("5H", "5H"))
                    .font(PrismTheme.fontBodySemibold)
                    .foregroundStyle(PrismTheme.textBright)
                    .lineLimit(1)
                    .fixedSize()

                if let fivePercent {
                    Text("\(fivePercent)%")
                        .font(PrismTheme.fontMetricDense)
                        .monospacedDigit()
                        .foregroundStyle(fiveTint)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text("—")
                        .font(PrismTheme.fontBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            if let caption = quota.verification.compactCaption(in: language.language) {
                Text(caption)
                    .font(PrismTheme.fontMicro)
                    .foregroundStyle(PrismTheme.warning.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
            }

            // 5H Reset Countdown (or Plan Tag if full)
            if let fiveResetDate, fiveResetDate > Date() {
                let resetTint = PrismTheme.resetProximityTint(resetAt: fiveResetDate, kind: .fiveHour)
                HStack(spacing: 2) {
                    Text("↺")
                        .font(PrismTheme.fontCaptionBold)
                        .foregroundStyle(resetTint.opacity(0.72))
                        .fixedSize()

                    Text(compactReset(fiveResetDate))
                        .font(PrismTheme.fontBodySemibold)
                        .foregroundStyle(resetTint)
                        .lineLimit(1)
                        .fixedSize()
                }
                .help(quota.fiveResetDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
            } else if let plan = quota.planLabel, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(PrismTheme.fontChip)
                    .foregroundStyle(fiveTint.opacity(0.85))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(fiveTint.opacity(0.12)))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(width: earWidth, height: compactHeight, alignment: .center)
        .background(leftEarBackground)
        .overlay(leftEarBorder)
        .help(leftEarHelp)
        .onChange(of: store.quotaResetPulse) { _, _ in
            withAnimation(.easeOut(duration: 0.18)) { resetPulseScale = 1.35 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.12)) {
                resetPulseScale = 1
            }
        }
    }

    private var leftEarHelp: String {
        var parts = [
            "\(quota.providerName): \(quota.displayName ?? language.text("Chưa có phiên", "No session"))"
        ]
        if let caption = quota.verification.caption(in: language.language) {
            parts.append(caption)
        }
        if let activity = store.status?.activity, activity.hasSignal {
            parts.append(activity.compactLabel)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Right Ear Wing (Flanking Right of Camera Notch)
    private var rightEarWing: some View {
        HStack(spacing: 4) {
            // Weekly Quota
            HStack(spacing: 2.5) {
                Text(language.text("Tuần", "Wk"))
                    .font(PrismTheme.fontBodySemibold)
                    .foregroundStyle(PrismTheme.textBright)
                    .lineLimit(1)
                    .fixedSize()

                if let weekPercent {
                    Text("\(weekPercent)%")
                        .font(PrismTheme.fontMetricDense)
                        .monospacedDigit()
                        .foregroundStyle(weekTint)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text("—")
                        .font(PrismTheme.fontBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            // Banked Reset / Reset Countdown
            if bankedCount > 0 {
                PrismBankedResetCountBadge(
                    count: bankedCount,
                    style: .filament,
                    helpText: language.text(
                        "\(bankedCount) lượt banked reset có thể dùng",
                        "\(bankedCount) banked resets available"
                    )
                )
            } else if let weeklyResetDate {
                let resetTint = PrismTheme.resetProximityTint(resetAt: weeklyResetDate, kind: .weekly)
                HStack(spacing: 2) {
                    Text("↺")
                        .font(PrismTheme.fontCaptionBold)
                        .foregroundStyle(resetTint.opacity(0.72))
                        .fixedSize()

                    Text(compactReset(weeklyResetDate))
                        .font(PrismTheme.fontBodySemibold)
                        .foregroundStyle(resetTint)
                        .lineLimit(1)
                        .fixedSize()
                }
                .help(quota.weeklyResetDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(width: earWidth, height: compactHeight, alignment: .leading)
        .background(rightEarBackground)
        .overlay(rightEarBorder)
    }

    // MARK: - Ear Shapes & Backgrounds
    // `.circular` keeps zero-radius top corners truly square. Continuous style
    // blends curvature into adjacent rounded bottoms and reads as a top gap.
    private var leftEarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 10,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .circular
        )
    }

    private var rightEarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 10,
            topTrailingRadius: 0,
            style: .circular
        )
    }

    private var leftEarBackground: some View {
        leftEarShape
            .fill(Color.black)
    }

    private var rightEarBackground: some View {
        rightEarShape
            .fill(Color.black)
    }

    private var leftEarBorder: some View {
        leftEarShape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: PrismTheme.highlightSoft, location: 0.0),
                    .init(color: PrismTheme.surfaceSoft, location: 0.5),
                    .init(color: Color.clear, location: 0.85)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            lineWidth: 0.5
        )
    }

    private var rightEarBorder: some View {
        rightEarShape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: Color.clear, location: 0.15),
                    .init(color: PrismTheme.surfaceSoft, location: 0.5),
                    .init(color: PrismTheme.highlightSoft, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            lineWidth: 0.5
        )
    }

    private func compactReset(_ date: Date) -> String {
        ResetClockFormat.compact(date, asClock: resetAsClock, language: language.language)
    }
}

/// One notch ear in dual-agent mode: agent name, 5-hour percent, plan label,
/// and a live countdown to its 5-hour reset — mirroring the single-agent wing
/// detail instead of a bare name+number.
enum NotchEarSide {
    case leading, trailing
}


struct PrismBankedResetCountBadge: View {
    enum Style {
        /// Dense notch ear: icon + bold digit + micro "BR" label in a capsule.
        case filament
        /// Active identity chip: "+N banked".
        case identity
        /// Account card: compact "+N".
        case card
    }

    let count: Int
    var style: Style = .filament
    var helpText: String = ""

    var body: some View {
        Group {
            switch style {
            case .filament:
                HStack(spacing: 3) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(PrismTheme.fontCaptionBold)
                        .foregroundStyle(PrismTheme.warning.opacity(0.9))
                    Text("\(count)")
                        .font(PrismTheme.fontMetricDense)
                        .monospacedDigit()
                        .foregroundStyle(PrismTheme.warning)
                    Text("BR")
                        .font(PrismTheme.fontMicroChip)
                        .foregroundStyle(PrismTheme.warning.opacity(0.78))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.warning, opacity: 0.16)))
                .overlay(Capsule().strokeBorder(PrismTheme.chipStroke(PrismTheme.warning, opacity: 0.28), lineWidth: 0.5))

            case .identity:
                HStack(spacing: 2.5) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(PrismTheme.fontChipIcon)
                    Text(AppLanguage.text("+\(count) dự phòng", "+\(count) banked"))
                        .font(PrismTheme.fontChip)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.warning)))
                .foregroundStyle(PrismTheme.warning)

            case .card:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(PrismTheme.fontMicro)
                    Text("+\(count)")
                        .font(PrismTheme.fontChip)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.warning)))
                .foregroundStyle(PrismTheme.warning)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(helpText.isEmpty ? "\(count) banked resets" : helpText)
        .help(helpText)
    }
}
