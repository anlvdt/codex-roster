import SwiftUI

/// Two concentric quota rings rendered as orbital arcs around a center.
/// The inner ring represents the 5-hour window, the outer ring represents
/// the weekly window. Fill angle maps to remaining percentage.
struct OrbitQuotaRings: View {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let radius: CGFloat
    let lineWidth: CGFloat

    private var fivePercent: CGFloat {
        max(0, min(100, CGFloat(fiveHour?.remainingPercent ?? 0))) / 100.0
    }

    private var weekPercent: CGFloat {
        max(0, min(100, CGFloat(weekly?.remainingPercent ?? 0))) / 100.0
    }

    var body: some View {
        ZStack {
            ring(radius: radius * 0.65, percent: fivePercent, color: tint(fiveHour))
            ring(radius: radius * 0.95, percent: weekPercent, color: tint(weekly))
        }
    }

    private func ring(radius: CGFloat, percent: CGFloat, color: Color) -> some View {
        ZStack {
            Circle()
                .stroke(OrbitTheme.ringBackground, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: percent)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: radius * 2, height: radius * 2)
    }

    private func tint(_ window: UsageWindow?) -> Color {
        guard let window else { return .secondary }
        return Color.quotaTint(
            remainingPercent: window.remainingPercent,
            exhaustedAt: UsageWindow.exhaustedRemainingPercent
        )
    }
}

/// Single small ring used for moons and planet status badges.
struct OrbitMiniRing: View {
    let window: UsageWindow?
    let diameter: CGFloat
    let lineWidth: CGFloat

    private var percent: CGFloat {
        max(0, min(100, CGFloat(window?.remainingPercent ?? 0))) / 100.0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(OrbitTheme.ringBackground, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: percent)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }

    private var tint: Color {
        guard let window else { return .secondary }
        return Color.quotaTint(
            remainingPercent: window.remainingPercent,
            exhaustedAt: UsageWindow.exhaustedRemainingPercent
        )
    }
}
