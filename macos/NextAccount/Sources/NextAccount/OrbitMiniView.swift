import SwiftUI

/// The smallest Orbit unit: a central sun with two quota moons.
/// `compact` lays the moons out horizontally beside the sun so the view fits
/// inside the menu-bar band; otherwise the moons orbit around it.
struct OrbitMiniView: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.colorScheme) private var colorScheme
    let account: SavedAccount?
    let diameter: CGFloat
    var compact: Bool = false

    var body: some View {
        if compact {
            compactLayout
        } else {
            orbitalLayout
        }
    }

    private var compactLayout: some View {
        HStack(spacing: 6) {
            if let account {
                OrbitMiniRing(window: account.usage?.fiveHour, diameter: diameter * 0.38, lineWidth: 2)
                sun(diameter: diameter)
                OrbitMiniRing(window: account.usage?.weekly, diameter: diameter * 0.38, lineWidth: 2)
            } else {
                Text("—")
                    .font(.body.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var orbitalLayout: some View {
        ZStack {
            if let account {
                // Orbital trail for the two moons
                Circle()
                    .stroke(OrbitTheme.orbitTrail, lineWidth: 1)
                    .frame(width: diameter * 1.3, height: diameter * 1.3)

                // Weekly moon (right)
                orbitMoon(
                    window: account.usage?.weekly,
                    label: language.text("Tuần", "Wk"),
                    angle: .pi / 4
                )

                // 5-hour moon (left)
                orbitMoon(
                    window: account.usage?.fiveHour,
                    label: language.text("5H", "5h"),
                    angle: -.pi * 0.75
                )

                sun(diameter: diameter)
            } else {
                Text("—")
                    .font(.body.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter * 2.2, height: diameter * 1.9)
    }

    private func sun(diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(OrbitTheme.sunGlow)
                .frame(width: diameter, height: diameter)
                .blur(radius: 8)
            Circle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                .frame(width: diameter * 0.78, height: diameter * 0.78)
            if let account {
                Text(initial(for: account))
                    .font(.system(size: diameter * 0.32, weight: .bold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private func orbitMoon(window: UsageWindow?, label: String, angle: Double) -> some View {
        let orbitRadius = diameter * 0.75
        let x = orbitRadius * cos(angle)
        let y = orbitRadius * sin(angle)

        return VStack(spacing: 2) {
            OrbitMiniRing(window: window, diameter: diameter * 0.35, lineWidth: 2)
            Text(label)
                .font(.system(size: diameter * 0.13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .offset(x: x, y: y)
    }

    private func initial(for account: SavedAccount) -> String {
        let source = account.customLabel ?? account.name ?? account.email
        return String(source.prefix(1).uppercased())
    }
}
