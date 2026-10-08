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

enum RosterLauncherDestination {
    case notch
    case settings

    static func resolve(notchEnabled: Bool) -> Self {
        notchEnabled ? .notch : .settings
    }
}

/// All-In-One Panoramic Floating Notch Console for Codex Roster.
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
    @State private var windowShrinkTask: Task<Void, Never>?
    @State private var keyMonitors: [Any] = []
    @State private var isWindowExpanded = false
    @State private var geometry: NotchGeometry = .detect()
    @State private var rosterFilter: RosterListFilter = .all
    @State private var quotaClock = Date()

    // Sheet presentation states directly inside the Notch Console
    @State private var auxiliarySheetActive = false
    @State private var showingAddAccount = false
    @State private var accountForRelogin: SavedAccount? = nil
    @State private var reloginQueue = ReloginPresentationQueue()
    @State private var accountForEditing: SavedAccount? = nil

    private let maxExpandedWidth: CGFloat = NotchRosterLayout.deckWidth
    private let earWidth: CGFloat = 146
    /// Non-notch compact pill width (centered under the top edge).
    private let nonNotchCompactWidth: CGFloat = 270
    private var hasNotch: Bool { geometry.hasNotch }
    private var notchInset: CGFloat { geometry.inset }
    private var notchWidth: CGFloat { geometry.cameraWidth }
    private var compactWidth: CGFloat {
        if hasNotch { return geometry.physicalClearance + 2 * earWidth }
        return nonNotchCompactWidth
    }
    private var screenSwitcherWidth: CGFloat { 156 }
    private let miniDiameter: CGFloat = 20

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !store.isArchived($0) }
    }

    private var rosterSectionCounts: [Int] {
        NotchDisplayedRoster(accounts: store.accounts, filter: rosterFilter).sectionCounts
    }

    private var hasNextActionCaption: Bool {
        if store.sessionResumeCaption != nil { return true }
        return NextAction.resolve(in: store).compactCaption(language: language) != nil
    }

    private var expandedPanelHeight: CGFloat {
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
                panelEnabled: store.notchPanelEnabled || auxiliarySheetActive || reloginQueue.activeID != nil,
                geometry: $geometry
            )
        }

        // Sheets presented directly on top of the Notch Window
        .sheet(isPresented: $showingAddAccount, onDismiss: {
            auxiliarySheetActive = false
            presentNextRelogin()
        }) {
            AddAccountSheet()
                .environmentObject(store)
                .environmentObject(language)
                .background(ElevatePresentedWindow())
        }
        .sheet(item: $accountForRelogin, onDismiss: {
            reloginQueue.didDismiss()
            presentNextRelogin()
        }) { account in
            ReloginAccountSheet(account: account, queuedCount: reloginQueue.pendingIDs.count, cancelQueue: {
                reloginQueue.cancelPending()
            })
                .id(account.id)
                .environmentObject(store)
                .environmentObject(language)
                .background(ElevatePresentedWindow())
        }
        .sheet(item: $accountForEditing, onDismiss: {
            auxiliarySheetActive = false
            presentNextRelogin()
        }) { account in
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
            store.ensureAutomaticFullBackup()
            updater.startAutomaticChecks(currentVersion: AppInfo.shortVersion)
            NotchGlobalHotKey.shared.registerIfNeeded()
            if RosterLauncherDestination.resolve(notchEnabled: store.notchPanelEnabled) == .settings {
                RosterConsolePresenter.request(.settings)
            } else if isPinnedLive && !isExpanded {
                expand()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleNotchPanel)) { _ in
            guard RosterLauncherDestination.resolve(notchEnabled: store.notchPanelEnabled) == .notch else {
                RosterConsolePresenter.request(.settings)
                return
            }
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
            // Keep a launcher available when the accessory app has hidden its notch.
            guard RosterLauncherDestination.resolve(notchEnabled: store.notchPanelEnabled) == .notch else {
                RosterConsolePresenter.request(.settings)
                return
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            if !isExpanded { expand() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddAccount)) { _ in
            guard RosterSheetArbitration.canPresentAuxiliary(isBusy: store.isBusyForActions,
                auxiliaryActive: auxiliarySheetActive, reloginActive: reloginQueue.activeID != nil) else { return }
            auxiliarySheetActive = true
            if !isExpanded { expand() }
            showingAddAccount = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showReloginAccount)) { notification in
            let id = (notification.object as? String).flatMap(UUID.init(uuidString:))
                ?? notification.object as? UUID
            // Require a concrete account UUID — never fall back to "first requiresLogin".
            let ids = notification.object as? [UUID] ?? id.map { [$0] } ?? []
            let validIDs = Set(store.accounts.map(\.id))
            reloginQueue.enqueue(ids.filter { validIDs.contains($0) })
            presentNextRelogin()
        }
        .onChange(of: store.isBusyForActions) { _, busy in
            if !busy { presentNextRelogin() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editAccount)) { notification in
            guard RosterSheetArbitration.canPresentAuxiliary(isBusy: store.isBusyForActions,
                auxiliaryActive: auxiliarySheetActive, reloginActive: reloginQueue.activeID != nil) else { return }
            let id = (notification.object as? String).flatMap(UUID.init(uuidString:))
                ?? notification.object as? UUID
            if let id, let account = store.accounts.first(where: { $0.id == id }) {
                auxiliarySheetActive = true
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
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            // Freshness can expire even when the backend has published no new data.
            quotaClock = now
        }
        .onDisappear {
            hoverTask?.cancel()
            collapseTask?.cancel()
            windowShrinkTask?.cancel()
            removeKeyMonitors()
        }
        .alert("Codex Roster", isPresented: Binding(
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
                .overlay(alignment: .bottomLeading) {
                    verificationBadge(compactQuota.verification)
                        .frame(width: hasNotch ? earWidth : compactWidth)
                }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactAccessibilityLabel)
    }

    // MARK: - Expanded Dropdown Content
    private var expandedDropdownContent: some View {
        ZStack(alignment: .top) {
            MenuBarView(notchNavigationWidth: screenSwitcherWidth, rosterFilter: $rosterFilter)
            Text("Codex")
                .font(PrismTheme.fontCaptionBold)
                .frame(width: screenSwitcherWidth, height: NotchRosterLayout.screenSwitcherHeight)
                .background(PrismTheme.surfacePanel.opacity(0.94), in: Capsule())
                .padding(.top, compactHeight + NotchRosterLayout.screenSwitcherTopInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private var compactQuota: NotchQuotaSnapshot {
        _ = quotaClock
        return NotchQuotaSnapshot(codex: activeAccount)
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
        let verification = quota.verification.caption(in: language.language).map { " (\($0))" } ?? ""
        return language.text(
            "\(quota.providerName): 5 giờ còn \(fiveText), tuần còn \(weekText)\(bankedText)\(verification). Mở Codex Roster.",
            "\(quota.providerName): 5-hour \(fiveText), weekly \(weekText)\(bankedText)\(verification). Open Codex Roster."
        )
    }

    @ViewBuilder
    private func verificationBadge(_ verification: NotchQuotaVerification) -> some View {
        if let caption = verification.caption(in: language.language) {
            Text(caption)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(PrismTheme.amber)
                .lineLimit(1)
                .padding(.horizontal, 3)
                .background(PrismTheme.notchShell, in: Capsule())
        }
    }

    private func presentNextRelogin() {
        guard accountForRelogin == nil, !auxiliarySheetActive,
              let id = reloginQueue.takeNext(isBusy: store.isBusyForActions, validIDs: Set(store.accounts.map(\.id))),
              let account = accountForContextMenuAction(in: store.accounts, capturedID: id) else { return }
        if !isExpanded { expand() }
        accountForRelogin = account
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
            guard !isPinnedLive else { return }
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: Self.hoverCollapseGrace)
                guard !Task.isCancelled, !isPinnedLive else { return }
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
            guard event.window?.identifier?.rawValue == "notch", event.keyCode == 53 else { return event }
            Task { @MainActor in collapse() }
            return nil
        }) {
            keyMonitors.append(local)
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
