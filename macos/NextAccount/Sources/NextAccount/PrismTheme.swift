import SwiftUI
import AppKit

/// Quota window cadence used to scale reset-proximity color bands.
enum QuotaResetWindowKind {
    case fiveHour
    case weekly
    case monthly
}

/// Design tokens, bioluminescent tints, haptics, and physics for the Neo-Prism UI system.
enum PrismTheme {
    // MARK: - Bioluminescent State Tints
    /// Healthy quota (80% - 100%) or active operational flow - calm Apple terminal emerald
    static let emerald = Color(red: 0.20, green: 0.83, blue: 0.60)
    /// Mid/warning quota (20% - 79%) or upcoming quota window reset - warm golden amber
    static let amber = Color(red: 0.98, green: 0.68, blue: 0.22)
    /// Exhausted quota (0% - 19%) or token authentication error - refined coral ruby
    static let ruby = Color(red: 0.94, green: 0.36, blue: 0.36)
    /// Dynamic switching, ChatGPT desktop sync, or active token streaming
    static let cyan = Color(red: 0.16, green: 0.74, blue: 0.96)
    /// Auto-switch fallback nexus and pipeline automation - soft lilac violet
    static let violet = Color(red: 0.68, green: 0.50, blue: 0.98)
    /// Apple system blue for interactive buttons
    static let accent = Color(red: 0.24, green: 0.58, blue: 0.96)
    /// Neutral titanium sheen
    static let titanium = Color(red: 0.62, green: 0.66, blue: 0.74)

    /// Semantic aliases — prefer these over ad-hoc `Color.green` / `.orange` / `.red` / `.purple`.
    static let success = emerald
    static let warning = amber
    static let danger = ruby
    static let autoSwitch = violet

    // MARK: - Semantic Text (dark notch / glass surfaces)
    static let textPrimary = Color.white.opacity(0.92)
    static let textBright = Color.white.opacity(0.68)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.40)
    static let textOnAccent = Color.white
    static let highlight = Color.white.opacity(0.18)
    static let highlightSoft = Color.white.opacity(0.16)

    // MARK: - Surfaces & Borders (dark glass)
    static let surfaceQuiet = Color.white.opacity(0.03)
    static let surfaceFaint = Color.white.opacity(0.018)
    static let surfaceDim = Color.white.opacity(0.05)
    static let surfaceSoft = Color.white.opacity(0.06)
    static let surfaceMuted = Color.white.opacity(0.07)
    static let surfaceFill = Color.white.opacity(0.08)
    static let surfaceStrong = Color.white.opacity(0.12)
    static let surfacePanel = Color.white.opacity(0.04)
    static let surfaceHover = Color.white.opacity(0.10)
    static let borderSubtle = Color.white.opacity(0.08)
    static let borderSoft = Color.white.opacity(0.15)
    static let borderStrong = Color.white.opacity(0.20)
    static let trackFill = Color.primary.opacity(0.08)
    static let trackSoft = Color.primary.opacity(0.07)

    /// Soft tinted chip fill / stroke for status pills.
    static func chipFill(_ tint: Color, opacity: Double = 0.18) -> Color { tint.opacity(opacity) }
    static func chipStroke(_ tint: Color, opacity: Double = 0.35) -> Color { tint.opacity(opacity) }

    // MARK: - Type Scale (notch / compact glass UI)
    /// Large identity glyph (~24pt)
    static let fontDisplay = Font.system(size: 24, weight: .bold)
    /// Active identity glyph (~16pt)
    static let fontTitle = Font.system(size: 16, weight: .bold)
    /// Account display name (~15pt)
    static let fontHeadline = Font.system(size: 15, weight: .bold)
    /// Section / card title (~13pt)
    static let fontSubheadline = Font.system(size: 13, weight: .bold)
    /// Default body copy (~11.5pt)
    static let fontBody = Font.system(size: 11.5, weight: .medium)
    static let fontBodySemibold = Font.system(size: 11.5, weight: .semibold)
    static let fontBodyBold = Font.system(size: 11.5, weight: .bold)
    /// Compact controls / status (~11pt)
    static let fontBodyCompact = Font.system(size: 11, weight: .semibold)
    static let fontBodyCompactBold = Font.system(size: 11, weight: .bold)
    static let fontBodyCompactMedium = Font.system(size: 11, weight: .medium)
    /// Captions / reset lines (~10.5pt)
    static let fontCaption = Font.system(size: 10.5, weight: .medium)
    static let fontCaptionRegular = Font.system(size: 10.5, weight: .regular)
    static let fontCaptionBold = Font.system(size: 10.5, weight: .bold)
    /// Status chips / plan pills / roster email (~10.5pt rounded)
    static let fontChip = Font.system(size: 10.5, weight: .bold, design: .rounded)
    static let fontChipIcon = Font.system(size: 10.5, weight: .regular)
    /// Micro labels on dense cards (~9–9.5pt)
    static let fontMicro = Font.system(size: 9, weight: .bold)
    static let fontMicroChip = Font.system(size: 9.5, weight: .bold, design: .rounded)
    /// Quota / metric figures
    static let fontMetric = Font.system(size: 12.5, weight: .bold, design: .rounded)
    static let fontMetricLarge = Font.system(size: 18, weight: .bold, design: .rounded)
    static let fontMetricSub = Font.system(size: 12, weight: .bold)
    /// Monospaced digits / codes
    static let fontMono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let fontMonoBold = Font.system(size: 11, weight: .bold, design: .monospaced)
    /// Section title / card avatar letter (~14pt)
    static let fontSection = Font.system(size: 14, weight: .bold)
    static let fontAvatar = fontSection
    /// Filament / dense metric (~13.5pt rounded)
    static let fontMetricDense = Font.system(size: 13.5, weight: .bold, design: .rounded)

    // MARK: - Dynamic State Resolvers
    static func quotaTint(percent: Int?) -> Color {
        guard let p = percent else { return titanium }
        if p >= 80 { return emerald }
        if p >= 20 { return amber }
        return ruby
    }

    static func quotaGradient(percent: Int?) -> LinearGradient {
        let tint = quotaTint(percent: percent)
        return LinearGradient(
            colors: [tint.opacity(0.95), tint.opacity(0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Soft lime between emerald and amber — “approaching reset” mid band.
    private static let resetNearMid = Color(red: 0.42, green: 0.82, blue: 0.45)
    /// Cooler green for monthly proximity (distinguishes from 5h/weekly).
    private static let resetMonthlyNear = Color(red: 0.32, green: 0.78, blue: 0.62)
    /// Muted amber when still far from reset.
    private static let resetFarMuted = Color(red: 0.72, green: 0.58, blue: 0.36)

    /// Maps time-until-reset → tint. Closer to reset = greener; farther = amber/muted.
    /// `kind` retunes band thresholds to each window’s natural cadence.
    static func resetProximityTint(
        resetAt: Date?,
        kind: QuotaResetWindowKind = .fiveHour,
        now: Date = Date()
    ) -> Color {
        guard let resetAt else { return textSecondary }
        let remaining = resetAt.timeIntervalSince(now)
        if remaining <= 0 { return emerald }

        let hours = remaining / 3600.0
        switch kind {
        case .fiveHour:
            // Horizon ~5h — tight bands so “soon” reads green quickly.
            if hours <= 0.5 { return emerald }
            if hours <= 1.5 { return resetNearMid }
            if hours <= 3.0 { return amber }
            return resetFarMuted
        case .weekly:
            if hours <= 6 { return emerald }
            if hours <= 24 { return resetNearMid }
            if hours <= 72 { return amber }
            return textSecondary
        case .monthly:
            if hours <= 24 { return emerald }
            if hours <= 72 { return resetMonthlyNear }
            if hours <= 168 { return amber }
            return textSecondary
        }
    }

    static func resetProximityTint(
        window: UsageWindow,
        kind: QuotaResetWindowKind,
        now: Date = Date()
    ) -> Color {
        resetProximityTint(resetAt: window.resetAt.value, kind: kind, now: now)
    }

    // MARK: - Glass Materials & Specular Rim Light
    static let darkBackground = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let lightBackground = Color(red: 0.95, green: 0.96, blue: 0.98)
    /// Notch shell fill (matches physical-camera backdrop)
    static let notchShell = Color(red: 0.08, green: 0.09, blue: 0.12)

    static var rimStroke: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.24),
                borderSubtle,
                surfaceQuiet,
                surfaceStrong
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func subtleRim(isHovered: Bool = false) -> LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(isHovered ? 0.32 : 0.16),
                Color.white.opacity(isHovered ? 0.12 : 0.04)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Apple WWDC Fluid Spring Physics
    /// Snappy, critically-damped spring for layout snapping and container morphing
    static let snapSpring = Animation.spring(response: 0.32, dampingFraction: 1.0)
    /// Immediate, tactile press feedback spring
    static let pressFeedback = Animation.spring(response: 0.18, dampingFraction: 0.82)
    /// Silky smooth transition spring for expanded states
    static let smoothSpring = Animation.spring(response: 0.42, dampingFraction: 0.92)
    /// Duration used when user enables UIAccessibility.isReduceMotionEnabled
    static let reduceMotionDuration: Double = 0.15

    // MARK: - Haptic Engine
    @MainActor
    static func triggerHaptic(type: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        NSHapticFeedbackManager.defaultPerformer.perform(type, performanceTime: .now)
    }
}

// MARK: - Prism View Modifiers
struct PrismGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var tint: Color? = nil
    var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                (tint ?? (colorScheme == .dark ? Color.white : Color.black))
                                    .opacity(colorScheme == .dark ? 0.04 : 0.02)
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        tint != nil
                            ? LinearGradient(
                                colors: [tint!.opacity(0.4), tint!.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : PrismTheme.subtleRim(isHovered: isHovered),
                        lineWidth: 1
                    )
            )
    }
}

struct PrismInteractiveModifier: ViewModifier {
    @State private var isHovered = false
    var cornerRadius: CGFloat = 12
    var action: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .modifier(PrismGlassModifier(cornerRadius: cornerRadius, isHovered: isHovered))
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .animation(PrismTheme.snapSpring, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .pointingHandCursor()
    }
}

extension View {
    func prismGlass(cornerRadius: CGFloat = 16, tint: Color? = nil, isHovered: Bool = false) -> some View {
        modifier(PrismGlassModifier(cornerRadius: cornerRadius, tint: tint, isHovered: isHovered))
    }

    func prismInteractive(cornerRadius: CGFloat = 12, action: (() -> Void)? = nil) -> some View {
        modifier(PrismInteractiveModifier(cornerRadius: cornerRadius, action: action))
    }
}
