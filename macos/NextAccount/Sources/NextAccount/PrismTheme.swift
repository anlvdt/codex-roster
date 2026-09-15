import SwiftUI
import AppKit

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

    // MARK: - Glass Materials & Specular Rim Light
    static let darkBackground = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let lightBackground = Color(red: 0.95, green: 0.96, blue: 0.98)

    static var rimStroke: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.24),
                Color.white.opacity(0.08),
                Color.white.opacity(0.03),
                Color.white.opacity(0.12)
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
