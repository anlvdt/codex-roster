import SwiftUI

/// Design tokens and constants for the Orbit visual system.
enum OrbitTheme {
    // MARK: - Backgrounds
    static let starfieldOpacity: Double = 0.18
    static let panelGlassDark: Color = Color.black.opacity(0.42)
    static let panelGlassLight: Color = Color.white.opacity(0.72)
    static let orbitBackgroundDark: Color = Color(red: 0.04, green: 0.05, blue: 0.08)
    static let orbitBackgroundLight: Color = Color(red: 0.93, green: 0.95, blue: 0.98)
    static let orbitGrid: Color = Color.white.opacity(0.04)

    // MARK: - Accents
    static let sunGlow: Color = Color.accentColor.opacity(0.45)
    static let ringBackground: Color = Color.white.opacity(0.10)
    static let orbitTrail: Color = Color.white.opacity(0.06)
    static let planetStrokeActive: Color = Color.white.opacity(0.35)

    // MARK: - Sizing
    static let sunDiameter: CGFloat = 64
    static let planetDiameter: CGFloat = 40
    static let moonDiameter: CGFloat = 22
    static let ringWidth: CGFloat = 6
    static let minTouchDiameter: CGFloat = 44

    // MARK: - Motion
    static let driftSeconds: Double = 120
    static let springResponse: Double = 0.45
    static let springDamping: Double = 0.85
    static let reduceMotionDuration: Double = 0.20
    static let entranceDelay: Double = 0.06

    // MARK: - Layout helpers
    static func angle(for index: Int, total: Int, offset: Double) -> Double {
        let base = 2.0 * .pi * Double(index) / Double(total)
        return base + offset
    }

    static func orbitRadius(for switchScore: Int, maxRadius: CGFloat) -> CGFloat {
        let minRadius: CGFloat = 44
        let normalized = max(0, min(1, Double(switchScore) / 100.0))
        return minRadius + (maxRadius - minRadius) * CGFloat(normalized)
    }
}
