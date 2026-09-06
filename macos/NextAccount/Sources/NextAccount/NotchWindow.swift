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

    private let compactWidth: CGFloat = 356
    private let expandedWidth: CGFloat = 436

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !store.isArchived($0) }
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
                        expandedContentOpacity == 0 ? 0.98 : 1,
                        anchor: .top
                    )
            }
        }
        .frame(width: panelWidth)
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
        .shadow(color: .black.opacity(isExpanded ? 0.34 : 0.18), radius: isExpanded ? 24 : 10, y: 10)
        .preferredColorScheme(.dark)
        .background(NotchWindowConfigurator(panelWidth: panelWidth))
        .onHover(perform: handleHover)
        .animation(panelAnimation, value: isExpanded)
        .task {
            store.startCoreMonitoring()
            store.refreshProviderStatus(silently: true)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.46"
            updater.startAutomaticChecks(currentVersion: version)
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
            HStack(spacing: 9) {
                NotchAccountIdentity(
                    account: activeAccount,
                    providerStates: store.providerStates
                )

                Spacer(minLength: 2)

                NotchQuotaMetric(
                    title: language.text("5H", "5h"),
                    window: activeAccount?.usage?.fiveHour,
                    alignment: .leading
                )

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary.opacity(0.78))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .padding(.horizontal, 11)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text(
            isExpanded ? "Thu gọn Codex Roster" : "Mở Codex Roster từ notch",
            isExpanded ? "Collapse Codex Roster" : "Open Codex Roster from the notch"
        ))
    }

    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: isExpanded ? 24 : 14,
            bottomTrailingRadius: isExpanded ? 24 : 14,
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

        withAnimation(panelAnimation) {
            isExpanded = true
        }
        rendersExpandedContent = true

        if reduceMotion {
            expandedContentOpacity = 1
        } else {
            withAnimation(.easeOut(duration: 0.16).delay(0.08)) {
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

        withAnimation(.easeOut(duration: 0.14)) {
            expandedContentOpacity = 0
        }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            rendersExpandedContent = false
            withAnimation(panelAnimation) {
                isExpanded = false
            }
        }
    }
}

private struct NotchAccountIdentity: View {
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount?
    let providerStates: [ProviderState]

    private var provider: AIProvider {
        account?.aiProvider ?? .openAI
    }

    private var liveProviderCount: Int {
        providerStates.filter(\.available).count
    }

    var body: some View {
        HStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: provider.icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

                Circle()
                    .fill(account == nil ? Color.secondary : Color.green)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.8), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(account == nil
                    ? language.text("\(liveProviderCount)/4 provider live", "\(liveProviderCount)/4 providers live")
                    : provider.compactName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 108, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct NotchQuotaMetric: View {
    @EnvironmentObject private var language: LanguageStore
    let title: String
    let window: UsageWindow?
    let alignment: HorizontalAlignment

    private var tint: Color {
        guard let window else { return .secondary }
        return Color.quotaTint(
            remainingPercent: window.remainingPercent,
            exhaustedAt: UsageWindow.exhaustedRemainingPercent
        )
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 4) {
                if alignment == .trailing {
                    Text(title)
                        .foregroundStyle(.secondary)
                }

                if let window {
                    Text("\(window.displayRemainingPercent)%")
                        .foregroundStyle(.primary)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }

                if alignment == .leading {
                    Text(title)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2.monospacedDigit().weight(.semibold))

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * CGFloat(window?.displayRemainingPercent ?? 0) / 100)
                    }
            }
            .frame(width: 64, height: 2)
        }
        .frame(width: 72, alignment: alignment == .leading ? .leading : .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let window else {
            return language.text("\(title), chưa có dữ liệu quota", "\(title), no quota data")
        }
        return language.text(
            "\(title) còn \(window.displayRemainingPercent) phần trăm",
            "\(title) \(window.displayRemainingPercent) percent remaining"
        )
    }
}

private struct NotchWindowConfigurator: NSViewRepresentable {
    let panelWidth: CGFloat

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
