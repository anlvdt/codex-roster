import SwiftUI

/// A tappable account represented as a planet in the orbit system.
struct PlanetNode: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let account: SavedAccount
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    private var planetColor: Color {
        if let window = account.primaryQuotaWindow {
            Color.quotaTint(remainingPercent: window.remainingPercent, exhaustedAt: UsageWindow.exhaustedRemainingPercent)
        } else {
            .secondary
        }
    }

    private var accessibilityLabel: String {
        let name = account.displayName
        let five = account.usage?.fiveHour.map { "\($0.displayRemainingPercent)%" } ?? language.text("chưa có", "none")
        let week = account.usage?.weekly.map { "\($0.displayRemainingPercent)%" } ?? language.text("chưa có", "none")
        return language.text(
            "Chuyển sang \(name). 5 giờ \(five), tuần \(week).",
            "Switch to \(name). 5-hour \(five), weekly \(week)."
        )
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                        .frame(width: OrbitTheme.planetDiameter, height: OrbitTheme.planetDiameter)
                    if let window = account.primaryQuotaWindow {
                        OrbitMiniRing(window: window, diameter: OrbitTheme.planetDiameter - 4, lineWidth: 2.5)
                    }
                    Text(initial)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(planetColor)
                }
                .frame(width: max(OrbitTheme.minTouchDiameter, OrbitTheme.planetDiameter), height: max(OrbitTheme.minTouchDiameter, OrbitTheme.planetDiameter))

                Text(account.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected || isHovering ? OrbitTheme.planetDiameter / 36.0 : 1.0)
        .animation(reduceMotion ? .easeOut(duration: OrbitTheme.reduceMotionDuration) : .spring(response: OrbitTheme.springResponse, dampingFraction: OrbitTheme.springDamping), value: isHovering)
        .animation(reduceMotion ? .easeOut(duration: OrbitTheme.reduceMotionDuration) : .spring(response: OrbitTheme.springResponse, dampingFraction: OrbitTheme.springDamping), value: isSelected)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text(language.text("Nhấn để kích hoạt tài khoản này", "Tap to activate this account")))
    }

    private var initial: String {
        let source = account.customLabel ?? account.name ?? account.email
        return String(source.prefix(1).uppercased())
    }
}
