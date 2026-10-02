import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Registers ⌃⌥R as a process-wide hotkey that toggles the notch panel.
@MainActor
final class NotchGlobalHotKey {
    static let shared = NotchGlobalHotKey()

    private let signature = OSType(0x4352_5354) // 'CRST'
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func registerIfNeeded() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == OSType(0x4352_5354) else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .toggleNotchPanel, object: nil)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }
}

enum NotchExpansionState: Equatable {
    case collapsed
    case droppingDown
    case fullyExpanded
}

private enum NotchScreen: CaseIterable {
    case codex
    case claude

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

/// All-In-One Panoramic Floating Notch Console for AgentDock.
/// Drops down from the camera notch, then blooms out symmetrically to both left and right wings.
struct NotchWindowView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var updater: GitHubUpdater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("codex_roster_notch_pinned_live") private var isPinnedLive = false
    @AppStorage(NotchRosterLayout.rosterExpandedKey) private var isRosterExpanded = false

    @State private var expansionState: NotchExpansionState = .collapsed
    @State private var hoverTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?
    @State private var isClaudeQuotaGuidePresented = false
    @State private var isClaudeInteractionPresented = false
    @State private var windowShrinkTask: Task<Void, Never>?
    @State private var keyMonitors: [Any] = []
    @State private var isWindowExpanded = false
    @State private var geometry: NotchGeometry = .detect()
    @State private var notchScreen: NotchScreen = .codex
    @State private var horizontalScroll: CGFloat = 0
    @State private var lastScreenSwipeAt: TimeInterval = 0

    // Sheet presentation states directly inside the Notch Console
    @State private var showingAddAccount = false
    @State private var accountForRelogin: SavedAccount? = nil
    @State private var accountForEditing: SavedAccount? = nil

    private let maxExpandedWidth: CGFloat = NotchRosterLayout.deckWidth
    private let earWidth: CGFloat = 126
    /// Non-notch compact pill width (centered under the top edge).
    private let nonNotchCompactWidth: CGFloat = 270
    private var hasNotch: Bool { geometry.hasNotch }
    private var notchInset: CGFloat { geometry.inset }
    private var notchWidth: CGFloat { geometry.cameraWidth }
    private var compactWidth: CGFloat {
        hasNotch ? geometry.physicalClearance + 2 * earWidth : nonNotchCompactWidth
    }
    private let miniDiameter: CGFloat = 20

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !store.isArchived($0) }
    }

    private var rosterSectionCounts: [Int] {
        NotchRosterLayout.planSectionAccountCounts(
            from: store.accounts.filter { !$0.archived }
        )
    }

    private var hasNextActionCaption: Bool {
        if store.sessionResumeCaption != nil { return true }
        return NextAction.resolve(in: store).compactCaption(language: language) != nil
    }

    private var expandedPanelHeight: CGFloat {
        if notchScreen == .claude {
            return ClaudeRosterView.notchDeckHeight(
                accountCount: store.claudeAccounts.count,
                hasQuotaCaption: ClaudeRosterView.notchShowsQuotaCaption(account: store.claudeAccounts.first(where: \.isActive)),
                hasMessage: store.claudeSwitchMessage != nil)
        }
        return NotchRosterLayout.deckHeight(
            sectionCounts: rosterSectionCounts,
            expanded: isRosterExpanded,
            hasNextActionCaption: hasNextActionCaption
        )
    }

    private var compactHeight: CGFloat {
        notchInset > 0 ? notchInset : 32
    }

    private var isExpanded: Bool {
        expansionState != .collapsed
    }

    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: isExpanded ? 24 : 12,
            bottomTrailingRadius: isExpanded ? 24 : 12,
            topTrailingRadius: 0,
            // Circular keeps zero-radius tops square; continuous softens them.
            style: .circular
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Keep content through the closing fade, then release the hidden roster.
            // Only opacity and translation animate; AppKit resizes once.
            if isWindowExpanded {
                expandedDropdownContent
                    .frame(width: maxExpandedWidth, height: expandedPanelHeight)
                    .opacity(isExpanded ? 1 : 0)
                    .offset(y: isExpanded || reduceMotion ? 0 : -6)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
                    .allowsHitTesting(isExpanded)
                    .disabled(!isExpanded)
                    .accessibilityHidden(!isExpanded)
            }

            compactBar
                .frame(width: compactWidth, height: compactHeight)
                .opacity(isExpanded ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
                .allowsHitTesting(!isExpanded)
                .accessibilityHidden(isExpanded)
        }
        .frame(
            width: isWindowExpanded ? maxExpandedWidth : compactWidth,
            height: isWindowExpanded ? expandedPanelHeight : compactHeight,
            alignment: .top
        )
        .background {
            if isWindowExpanded {
                notchShape.fill(PrismTheme.notchShell)
                    .opacity(isExpanded ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
            }
        }
        .overlay {
            if isWindowExpanded {
                notchShape.strokeBorder(PrismTheme.rimStroke, lineWidth: 1)
                    .opacity(isExpanded ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
            }
        }
        .clipShape(notchShape)
        .contentShape(notchShape)
        .onHover(perform: handleHover)
        .preferredColorScheme(.dark)
        .rosterConsoleOpenBridge()
        .background {
            NotchWindowConfigurator(
                isExpanded: isWindowExpanded,
                compactWidth: compactWidth,
                compactHeight: compactHeight,
                expandedWidth: maxExpandedWidth,
                expandedHeight: expandedPanelHeight,
                panelEnabled: store.notchPanelEnabled,
                geometry: $geometry
            )
        }

        // Sheets presented directly on top of the Notch Window
        .sheet(isPresented: $showingAddAccount) {
            AddAccountSheet()
                .environmentObject(store)
                .environmentObject(language)
                .background(ElevatePresentedWindow())
        }
        .sheet(item: $accountForRelogin) { account in
            ReloginAccountSheet(account: account, queuedCount: 0, cancelQueue: {})
                .environmentObject(store)
                .environmentObject(language)
                .background(ElevatePresentedWindow())
        }
        .sheet(item: $accountForEditing) { account in
            AccountEditorSheet(account: account)
                .environmentObject(store)
                .environmentObject(language)
                .background(ElevatePresentedWindow())
        }
        .task {
            store.startCoreMonitoring()
            store.refreshTokenUsage(silently: true)
            store.refreshResetOutlook(silently: true)
            store.refreshOpenAIStatus(silently: true)
            store.refreshProviderStatus(silently: true)
            store.ensureAutomaticFullBackup()
            updater.startAutomaticChecks(currentVersion: AppInfo.shortVersion)
            NotchGlobalHotKey.shared.registerIfNeeded()
            if isPinnedLive && !isExpanded {
                expand()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleNotchPanel)) { _ in
            guard store.notchPanelEnabled else { return }
            hoverTask?.cancel()
            collapseTask?.cancel()
            if isExpanded {
                collapse()
            } else {
                NSApplication.shared.activate(ignoringOtherApps: true)
                expand()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .collapseNotchPanel)) { _ in
            hoverTask?.cancel()
            collapseTask?.cancel()
            if isExpanded { collapse() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDashboard)) { _ in
            // Second-instance / Dock reopen: reveal the notch (no companion window).
            guard store.notchPanelEnabled else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            if !isExpanded { expand() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddAccount)) { _ in
            if !isExpanded { expand() }
            showingAddAccount = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showReloginAccount)) { notification in
            let id = (notification.object as? String).flatMap(UUID.init(uuidString:))
                ?? notification.object as? UUID
            // Require a concrete account UUID — never fall back to "first requiresLogin".
            guard let id,
                  let account = store.accounts.first(where: { $0.id == id }) else { return }
            if !isExpanded { expand() }
            accountForRelogin = account
        }
        .onReceive(NotificationCenter.default.publisher(for: .editAccount)) { notification in
            let id = (notification.object as? String).flatMap(UUID.init(uuidString:))
                ?? notification.object as? UUID
            if let id, let account = store.accounts.first(where: { $0.id == id }) {
                if !isExpanded { expand() }
                accountForEditing = account
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if isExpanded && !isPinnedLive { collapse() }
        }
        .onChange(of: store.notchPanelEnabled) { _, enabled in
            if !enabled { collapse() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            // Re-detect notch vs non-notch when displays connect/disconnect or rearrange.
            let measured = NotchGeometry.detect()
            if geometry != measured {
                geometry = measured
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            collapseTask?.cancel()
            windowShrinkTask?.cancel()
            removeKeyMonitors()
        }
        .alert("AgentDock", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(language.text("Đồng ý", "OK"), role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: - Compact Bar (Top Notch Filament)
    private var compactBar: some View {
        Button {
            hoverTask?.cancel()
            collapseTask?.cancel()
            PrismTheme.triggerHaptic(type: .alignment)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if isExpanded {
                collapse()
            } else {
                expand()
            }
        } label: {
            PrismFilamentView(
                quota: compactQuota,
                diameter: miniDiameter,
                compact: true,
                notchWidth: hasNotch ? notchWidth : 0,
                earWidth: earWidth,
                compactHeight: compactHeight
            )
                // Top-align so ears sit flush under the window's top edge
                // (center alignment left a hairline wallpaper strip on notch).
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactAccessibilityLabel)
    }

    // MARK: - Expanded Dropdown Content
    private var expandedDropdownContent: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if notchScreen == .codex {
                    MenuBarView()
                        .transition(.asymmetric(
                            insertion: .offset(x: -18).combined(with: .opacity),
                            removal: .opacity
                        ))
                } else {
                    ClaudeRosterView(notchLayout: true, onQuotaGuidePresentationChanged: { shown in
                        isClaudeQuotaGuidePresented = shown
                        collapseTask?.cancel()
                    }, onInteractionPresentationChanged: { shown in
                        isClaudeInteractionPresented = shown
                        collapseTask?.cancel()
                        if shown && !isExpanded { expand() }
                    })
                        .transition(.asymmetric(
                            insertion: .offset(x: 18).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            // Only page opacity/translation animate. Native window sizing and
            // navigation chrome use the destination layout immediately.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: notchScreen)
            notchScreenSwitcher
                .padding(.top, compactHeight + NotchRosterLayout.screenSwitcherTopInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 28)
                .onEnded { gesture in
                    let x = gesture.predictedEndTranslation.width
                    let y = gesture.predictedEndTranslation.height
                    guard abs(x) > 55, abs(x) > abs(y) * 1.25 else { return }
                    switchNotchScreen(x < 0 ? .claude : .codex)
                }
        )
    }

    private var notchScreenSwitcher: some View {
        HStack(spacing: 8) {
            Button {
                switchNotchScreen(.codex)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: NotchRosterLayout.screenSwitcherHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(notchScreen == .codex ? PrismTheme.textTertiary : PrismTheme.textBright)
            .disabled(notchScreen == .codex)
            .accessibilityLabel(language.text("Màn hình Codex", "Codex screen"))

            Text(notchScreen.title)
                .font(PrismTheme.fontCaptionBold)
                .foregroundStyle(PrismTheme.textBright)
                .frame(maxWidth: .infinity)

            Button {
                switchNotchScreen(.claude)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: NotchRosterLayout.screenSwitcherHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(notchScreen == .claude ? PrismTheme.textTertiary : PrismTheme.textBright)
            .disabled(notchScreen == .claude)
            .accessibilityLabel(language.text("Màn hình Claude Code", "Claude Code screen"))
        }
        .frame(width: 156, height: NotchRosterLayout.screenSwitcherHeight)
        .background(PrismTheme.surfacePanel.opacity(0.94), in: Capsule())
    }

    private func switchNotchScreen(_ target: NotchScreen) {
        guard notchScreen != target else { return }
        // Do not animate the entire window/grid height when changing providers.
        notchScreen = target
    }

    private func handleNotchScroll(_ event: NSEvent) {
        guard isExpanded, event.momentumPhase.isEmpty else { return }
        let x = event.scrollingDeltaX
        let y = event.scrollingDeltaY
        if event.phase.contains(.began) { horizontalScroll = 0 }
        guard abs(x) > abs(y) * 1.25 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScreenSwipeAt > 0.55 else { return }
        horizontalScroll += x * (event.hasPreciseScrollingDeltas ? 1 : 32)
        guard abs(horizontalScroll) >= 35 else { return }
        switchNotchScreen(horizontalScroll > 0 ? .claude : .codex)
        lastScreenSwipeAt = now
        horizontalScroll = 0
    }

    private var compactQuota: NotchQuotaSnapshot {
        switch notchScreen {
        case .codex: return NotchQuotaSnapshot(codex: activeAccount)
        case .claude: return NotchQuotaSnapshot(claude: store.claudeAccounts.first(where: \.isActive))
        }
    }

    private var compactAccessibilityLabel: String {
        let quota = compactQuota
        let five = quota.fivePercent
        let week = quota.weekPercent
        let banked = quota.bankedCount
        let fiveText = five.map { "\($0)%" } ?? language.text("chưa có", "no data")
        let weekText = week.map { "\($0)%" } ?? language.text("chưa có", "no data")
        let bankedText = banked > 0
            ? language.text(", \(banked) lượt banked reset", ", \(banked) banked resets available")
            : ""
        return language.text(
            "\(quota.providerName): 5 giờ còn \(fiveText), tuần còn \(weekText)\(bankedText). Mở AgentDock.",
            "\(quota.providerName): 5-hour \(fiveText), weekly \(weekText)\(bankedText). Open AgentDock."
        )
    }
    /// Leave-grace before auto-collapse. Long enough to cross shape edges /
    /// camera gap / nested menus; short enough that dismiss still feels snappy.
    private static let hoverCollapseGrace: Duration = .milliseconds(450)

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        collapseTask?.cancel()

        if hovering {
            guard !isExpanded else { return }
            hoverTask = Task { @MainActor in
                // Open only after the pointer *lingers* nearly still. A fast
                // horizontal sweep across the menu-bar pill aborts as drive-by.
                var tracker = NotchHoverIntent.Tracker(origin: NSEvent.mouseLocation)
                let interval = Duration.milliseconds(NotchHoverIntent.sampleIntervalMilliseconds)
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    switch tracker.ingest(NSEvent.mouseLocation) {
                    case .keepWaiting:
                        continue
                    case .open:
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        expand()
                        return
                    case .abortDriveBy, .abortTimeout:
                        return
                    }
                }
            }
        } else if isExpanded {
            guard !isPinnedLive, !isClaudeQuotaGuidePresented, !isClaudeInteractionPresented else { return }
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: Self.hoverCollapseGrace)
                guard !Task.isCancelled, !isClaudeQuotaGuidePresented, !isClaudeInteractionPresented else { return }
                collapse()
            }
        }
    }

    // MARK: - Choreographed Dropdown & 2-Way Bloom Animation
    private func expand() {
        hoverTask?.cancel()
        collapseTask?.cancel()
        windowShrinkTask?.cancel()
        installKeyMonitors()
        isWindowExpanded = true

        // Native bounds change once, without an interpolated layout pass.
        expansionState = .fullyExpanded
    }

    private func collapse() {
        guard !isClaudeQuotaGuidePresented, !isClaudeInteractionPresented else { return }
        hoverTask?.cancel()
        collapseTask?.cancel()
        windowShrinkTask?.cancel()
        removeKeyMonitors()

        guard !reduceMotion else {
            expansionState = .collapsed
            isWindowExpanded = false
            return
        }

        expansionState = .collapsed

        windowShrinkTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled, expansionState == .collapsed else { return }
            isWindowExpanded = false
        }
    }

    private func installKeyMonitors() {
        guard keyMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53, !isClaudeQuotaGuidePresented, !isClaudeInteractionPresented else { return event }
            Task { @MainActor in collapse() }
            return nil
        }) {
            keyMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53, !isClaudeQuotaGuidePresented, !isClaudeInteractionPresented else { return }
            Task { @MainActor in collapse() }
        }) {
            keyMonitors.append(global)
        }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            guard event.window?.identifier?.rawValue == "notch" else { return event }
            Task { @MainActor in handleNotchScroll(event) }
            return event
        }) {
            keyMonitors.append(scroll)
        }
    }

    private func removeKeyMonitors() {
        for monitor in keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitors.removeAll()
    }
}

// MARK: - Notch Window Configurator with Custom Hit Testing
private struct NotchWindowConfigurator: NSViewRepresentable {
    let isExpanded: Bool
    let compactWidth: CGFloat
    let compactHeight: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
    let panelEnabled: Bool
    @Binding var geometry: NotchGeometry

    final class Coordinator {
        weak var configuredWindow: NSWindow?
        var configurationGeneration = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NotchHitTestView {
        let view = NotchHitTestView()
        view.isExpanded = isExpanded
        view.compactWidth = compactWidth
        view.compactHeight = compactHeight
        configureWindow(attachedTo: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NotchHitTestView, context: Context) {
        view.isExpanded = isExpanded
        view.compactWidth = compactWidth
        view.compactHeight = compactHeight
        configureWindow(attachedTo: view, coordinator: context.coordinator)
    }

    private func configureWindow(attachedTo view: NSView, coordinator: Coordinator) {
        coordinator.configurationGeneration += 1
        let generation = coordinator.configurationGeneration
        DispatchQueue.main.async {
            // SwiftUI may queue several updates in the same run-loop turn.
            // Apply only the newest bounds, including a rapid close/reopen.
            guard generation == coordinator.configurationGeneration,
                  let window = view.window else { return }
            guard panelEnabled else {
                window.orderOut(nil)
                return
            }
            let needsPresentation = coordinator.configuredWindow !== window || !window.isVisible
            if coordinator.configuredWindow !== window {
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
                coordinator.configuredWindow = window
            }

            let measured = NotchGeometry.detect(fallbackScreen: window.screen)
            if geometry != measured {
                geometry = measured
            }

            // Dynamic sizing: only occupy compact capsule bounds when collapsed so
            // menu-bar icons and menus remain directly clickable without interception.
            // Frame is anchored on measured notch centerX (or screen midX when non-notch)
            // and snapped to the pixel grid to avoid half-pixel blur / 1px drift.
            let targetWidth = isExpanded ? expandedWidth : compactWidth
            let targetHeight = isExpanded ? expandedHeight : compactHeight
            let targetFrame = measured.windowFrame(width: targetWidth, height: targetHeight)
            if window.frame != targetFrame {
                // Match SwiftUI's bounds once. A second AppKit resize animation
                // would force the full roster through repeated layout passes.
                window.setFrame(targetFrame, display: true, animate: false)
            }
            // Quota publications must not reorder an already-visible window.
            if needsPresentation { window.orderFrontRegardless() }
        }
    }
}

/// Custom NSView that only intercepts clicks within the compact capsule when collapsed,
/// letting mouse clicks pass directly through to menu-bar items and background apps on the wings.
final class NotchHitTestView: NSView {
    var isExpanded: Bool = false
    var compactWidth: CGFloat = 415
    var compactHeight: CGFloat = 32

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isExpanded {
            return super.hitTest(point)
        }
        // In compact mode, only hit-test the centered compact capsule
        let capsuleX = (bounds.width - compactWidth) / 2
        let capsuleRect = NSRect(
            x: capsuleX,
            y: bounds.height - compactHeight,
            width: compactWidth,
            height: compactHeight
        )
        guard capsuleRect.contains(point) else {
            return nil
        }
        return super.hitTest(point)
    }
}
