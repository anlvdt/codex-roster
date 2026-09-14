import SwiftUI

/// A subtle starfield background for the Orbit visual system.
/// Respects Reduce Motion by keeping the field static; otherwise the stars
/// drift very slowly to give a sense of depth without burning CPU.
struct StarfieldBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let starCount = 48
    private let stars: [Star] = (0..<starCount).map { _ in Star.random() }

    var body: some View {
        GeometryReader { geometry in
            if reduceMotion {
                starCanvas(in: geometry.size, phase: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: OrbitTheme.driftSeconds)
                    starCanvas(in: geometry.size, phase: phase)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func starCanvas(in size: CGSize, phase: Double) -> some View {
        Canvas { context, size in
            let base = baseColor
            for star in stars {
                let drift = phase / OrbitTheme.driftSeconds * 2.0 * .pi * star.speed
                let x = (star.x + cos(drift + star.phaseOffset) * 0.02).truncatingRemainder(dividingBy: 1.0)
                let y = (star.y + sin(drift + star.phaseOffset) * 0.015).truncatingRemainder(dividingBy: 1.0)
                let px = x * size.width
                let py = y * size.height
                let rect = CGRect(origin: CGPoint(x: px, y: py), size: CGSize(width: star.size, height: star.size))
                context.fill(Path(ellipseIn: rect), with: .color(base.opacity(star.opacity)))
            }
        }
    }

    private var baseColor: Color {
        colorScheme == .dark ? Color.white : Color(red: 0.45, green: 0.50, blue: 0.58)
    }
}

private struct Star {
    let x: Double
    let y: Double
    let size: Double
    let opacity: Double
    let speed: Double
    let phaseOffset: Double

    static func random() -> Star {
        Star(
            x: Double.random(in: 0...1),
            y: Double.random(in: 0...1),
            size: Double.random(in: 1...2.5),
            opacity: Double.random(in: 0.15...0.55),
            speed: Double.random(in: 0.2...1.0),
            phaseOffset: Double.random(in: 0...(2.0 * .pi))
        )
    }
}
