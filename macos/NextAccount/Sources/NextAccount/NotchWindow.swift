import AppKit
import SwiftUI

struct NotchWindowView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var updater: GitHubUpdater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded = false
    @State private var rendersExpandedContent = false
    @State private var expandedContentOpacity = 0.0
    @State private var hoverTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?
    /// Height of the display's physical notch (menu-bar band). The compact
    /// panel sits inside this band so it never hangs below over other windows.
    @State private var notchInset: CGFloat = 0
    /// Width of the physical notch. The compact panel keeps this much clear
    /// space in its centre so the two quota rings flank the camera housing.
    @State private var notchWidth: CGFloat = 0

    private let earHalfWidth: CGFloat = 74
    private let expandedWidth: CGFloat = 392

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !store.isArchived($0) }
    }

    /// Two ears flanking the notch. On displays without a notch this collapses
    /// to a small centred pill (an 8pt gap instead of the camera width).
    private var compactWidth: CGFloat {
        earHalfWidth * 2 + max(notchWidth, 8)
    }

    private var compactHeight: CGFloat {
        // When collapsed the rings sit nestled inside the ears with margin above
        // and below. When expanded this same row is just the panel's header, so
        // it tightens to the notch band and the content starts near the top.
        isExpanded ? max(notchInset, 28) : max(notchInset, 26) + 8
    }

    private var panelWidth: CGFloat {
        isExpanded ? expandedWidth : compactWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            compactBar

            if rendersExpandedContent {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                    .padding(.horizontal, 14)

                MenuBarView()
                    .opacity(expandedContentOpacity)
                    .scaleEffect(
                        expandedContentOpacity == 0 ? 0.985 : 1,
                        anchor: .top
                    )
            }
        }
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            notchShape
                .fill(.ultraThinMaterial)
                .overlay {
                    notchShape.fill(Color.black.opacity(isExpanded ? 0.76 : 0.88))
                }
        }
        .overlay {
            notchShape
                .stroke(Color.white.opacity(isExpanded ? 0.16 : 0.09), lineWidth: 1)
        }
        .clipShape(notchShape)
        // No SwiftUI drop shadow: a content-sized borderless window includes the
        // shadow's bleed in its frame, which pushes the panel down from the very
        // top of the screen. The stroke border provides edge definition instead.
        .preferredColorScheme(.dark)
        .background(NotchWindowConfigurator(panelWidth: panelWidth, notchInset: $notchInset, notchWidth: $notchWidth))
        .onHover(perform: handleHover)
        .animation(panelAnimation, value: isExpanded)
        .task {
            store.startCoreMonitoring()
            store.refreshProviderStatus(silently: true)
            updater.startAutomaticChecks(currentVersion: AppInfo.shortVersion)
        }
        .onDisappear {
            hoverTask?.cancel()
            collapseTask?.cancel()
        }
    }

    private var compactBar: some View {
        Button {
            hoverTask?.cancel()
            collapseTask?.cancel()
            NSApplication.shared.activate(ignoringOtherApps: true)
            if isExpanded {
                collapse()
            } else {
                expand()
            }
        } label: {
            HStack(spacing: 0) {
                notchEar(
                    label: language.text("5H", "5h"),
                    window: activeAccount?.usage?.fiveHour,
                    prominent: true,
                    ringFirst: false
                )
                .frame(width: earHalfWidth, alignment: .center)

                Color.clear.frame(width: max(notchWidth, 8))

                notchEar(
                    label: language.text("Tuần", "Wk"),
                    window: activeAccount?.usage?.weekly,
                    prominent: false,
                    ringFirst: true
                )
                .frame(width: earHalfWidth, alignment: .center)
            }
            .frame(height: compactHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactAccessibilityLabel)
    }

    /// One side of the notch: a progress ring with the remaining percentage in
    /// its centre, plus a short window label on the outward side.
    private func notchEar(label: String, window: UsageWindow?, prominent: Bool, ringFirst: Bool) -> some View {
        let text = Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        return HStack(spacing: 6) {
            if ringFirst {
                NotchRing(window: window, prominent: prominent)
                text
            } else {
                text
                NotchRing(window: window, prominent: prominent)
            }
        }
    }

    private var compactAccessibilityLabel: String {
        let five = activeAccount?.usage?.fiveHour?.displayRemainingPercent
        let week = activeAccount?.usage?.weekly?.displayRemainingPercent
        let fiveText = five.map { "\($0)%" } ?? language.text("chưa có", "no data")
        let weekText = week.map { "\($0)%" } ?? language.text("chưa có", "no data")
        return language.text(
            "5 giờ còn \(fiveText), tuần còn \(weekText). Mở Codex Roster.",
            "5-hour \(fiveText), weekly \(weekText). Open Codex Roster."
        )
    }

    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: isExpanded ? 24 : 10,
            bottomTrailingRadius: isExpanded ? 24 : 10,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var panelAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.34, dampingFraction: 0.88)
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        collapseTask?.cancel()
        guard !reduceMotion else { return }

        if hovering {
            guard !isExpanded else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                expand()
            }
        } else if isExpanded {
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(850))
                guard !Task.isCancelled else { return }
                collapse()
            }
        }
    }

    private func expand() {
        hoverTask?.cancel()
        collapseTask?.cancel()

        // Animate width AND the added content height together so the panel
        // grows in one smooth motion instead of snapping to full size.
        withAnimation(panelAnimation) {
            isExpanded = true
            rendersExpandedContent = true
        }

        if reduceMotion {
            expandedContentOpacity = 1
        } else {
            withAnimation(.easeOut(duration: 0.22).delay(0.06)) {
                expandedContentOpacity = 1
            }
        }
    }

    private func collapse() {
        hoverTask?.cancel()
        collapseTask?.cancel()

        guard !reduceMotion else {
            expandedContentOpacity = 0
            rendersExpandedContent = false
            isExpanded = false
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            expandedContentOpacity = 0
        }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else { return }
            withAnimation(panelAnimation) {
                isExpanded = false
                rendersExpandedContent = false
            }
        }
    }
}

/// A quota window drawn as a thin progress ring with the remaining percentage
/// centred inside it. The ring and number are tinted by remaining quota so a
/// low window reads as urgent at a glance.
private struct NotchRing: View {
    let window: UsageWindow?
    var prominent: Bool = true

    private var percent: Int {
        max(0, min(100, window?.displayRemainingPercent ?? 0))
    }

    private var tint: Color {
        guard let window else { return .secondary }
        return Color.quotaTint(
            remainingPercent: window.remainingPercent,
            exhaustedAt: UsageWindow.exhaustedRemainingPercent
        )
    }

    private var diameter: CGFloat { prominent ? 24 : 22 }
    private var lineWidth: CGFloat { prominent ? 3 : 2.5 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(window == nil ? "—" : "\(percent)")
                .font(.system(size: prominent ? 11 : 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 1)
        }
        .frame(width: diameter, height: diameter)
        .opacity(prominent ? 1 : 0.94)
    }
}

private struct NotchWindowConfigurator: NSViewRepresentable {
    let panelWidth: CGFloat
    @Binding var notchInset: CGFloat
    @Binding var notchWidth: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(attachedTo: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(attachedTo: view)
    }

    private func configureWindow(attachedTo view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("notch")
            window.styleMask = [.borderless, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovable = false
            window.hidesOnDeactivate = false
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isExcludedFromWindowsMenu = true
            window.ignoresMouseEvents = false

            let screen = preferredNotchScreen(for: window)
            // The compact panel lives inside the menu-bar band and keeps the
            // camera width clear, so the rings flank the notch and nothing
            // hangs below over other windows.
            let inset = screen.safeAreaInsets.top
            if notchInset != inset {
                notchInset = inset
            }
            let camera: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                camera = max(0, right.minX - left.maxX)
            } else {
                camera = 0
            }
            if notchWidth != camera {
                notchWidth = camera
            }
            let x = screen.frame.midX - panelWidth / 2
            window.setFrameTopLeftPoint(NSPoint(x: x, y: screen.frame.maxY))
            window.orderFrontRegardless()
        }
    }

    private func preferredNotchScreen(for window: NSWindow) -> NSScreen {
        NSScreen.screens.max { left, right in
            left.safeAreaInsets.top < right.safeAreaInsets.top
        } ?? window.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
