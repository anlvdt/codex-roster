import SwiftUI

/// A solar-system canvas: the active account sits at the center (sun) and the
/// other accounts orbit around it. Tap a planet to switch.
struct OrbitSystemView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let centerAccount: SavedAccount
    let planets: [SavedAccount]
    let maxRadius: CGFloat
    var selectedID: UUID? = nil
    let onSelect: (SavedAccount) -> Void

    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let safeRadius = min(maxRadius, min(geometry.size.width, geometry.size.height) / 2 - 56)

                ZStack {
                    ForEach(Array(planets.enumerated()), id: \.element.id) { index, _ in
                        let radius = orbitRadius(for: index, max: safeRadius)
                        Circle()
                            .stroke(OrbitTheme.orbitTrail, lineWidth: 1)
                            .frame(width: radius * 2, height: radius * 2)
                            .position(center)
                    }

                    OrbitQuotaRings(
                        fiveHour: centerAccount.usage?.fiveHour,
                        weekly: centerAccount.usage?.weekly,
                        radius: OrbitTheme.sunDiameter,
                        lineWidth: OrbitTheme.ringWidth
                    )
                    .position(center)

                    sunNode
                        .position(center)

                    ForEach(Array(planets.enumerated()), id: \.element.id) { index, account in
                        let radius = orbitRadius(for: index, max: safeRadius)
                        let angle = OrbitTheme.angle(for: index, total: max(1, planets.count), offset: phase)
                        let x = center.x + radius * cos(angle)
                        let y = center.y + radius * sin(angle)

                        PlanetNode(
                            account: account,
                            isSelected: selectedID == account.id,
                            onSelect: { onSelect(account) }
                        )
                        .position(x: x, y: y)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: OrbitTheme.driftSeconds).repeatForever(autoreverses: false)) {
                phase += 2.0 * .pi
            }
        }
    }

    private var sunNode: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(OrbitTheme.sunGlow)
                    .frame(width: OrbitTheme.sunDiameter + 12, height: OrbitTheme.sunDiameter + 12)
                    .blur(radius: 12)
                Circle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                    .frame(width: OrbitTheme.sunDiameter, height: OrbitTheme.sunDiameter)
                Text(sunInitial)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
            }
            Text(centerAccount.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(language.text("Đang hoạt động", "Active"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.text(
            "Tài khoản đang hoạt động: \(centerAccount.displayName). 5 giờ \(quotaText(centerAccount.usage?.fiveHour)), tuần \(quotaText(centerAccount.usage?.weekly))",
            "Active account: \(centerAccount.displayName). 5-hour \(quotaText(centerAccount.usage?.fiveHour)), weekly \(quotaText(centerAccount.usage?.weekly))"
        ))
    }

    private func quotaText(_ window: UsageWindow?) -> String {
        window.map { "\($0.displayRemainingPercent)%" } ?? language.text("chưa có", "none")
    }

    private func orbitRadius(for index: Int, max: CGFloat) -> CGFloat {
        let score = planets[index].switchQuotaScore
        return OrbitTheme.orbitRadius(for: score, maxRadius: max)
    }

    private var sunInitial: String {
        let source = centerAccount.customLabel ?? centerAccount.name ?? centerAccount.email
        return String(source.prefix(1).uppercased())
    }
}
