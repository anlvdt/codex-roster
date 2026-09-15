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

/// All-In-One Panoramic Floating Notch Console for Codex Roster.
/// Drops down from the camera notch, then blooms out symmetrically to both left and right wings.
struct NotchWindowView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var updater: GitHubUpdater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @AppStorage("codex_roster_notch_pinned_live") private var isPinnedLive = false

    @State private var expansionState: NotchExpansionState = .collapsed
    @State private var hoverTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?
    @State private var keyMonitors: [Any] = []
    @State private var notchInset: CGFloat = 0
    @State private var notchWidth: CGFloat = 0

    // Sheet presentation states directly inside the Notch Console
    @State private var showingAddAccount = false
    @State private var accountForRelogin: SavedAccount? = nil
    @State private var backupOperation: BackupOperation? = nil
    @State private var accountForEditing: SavedAccount? = nil

    private let maxExpandedWidth: CGFloat = 920
    private let earWidth: CGFloat = 126
    private var physicalNotchClearance: CGFloat {
        notchWidth > 0 ? max(notchWidth - 14, 170) : 0
    }
    private var compactWidth: CGFloat {
        notchWidth > 0 ? physicalNotchClearance + 2 * earWidth : 270
    }
    private let miniDiameter: CGFloat = 20

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !store.isArchived($0) }
    }

    private var compactHeight: CGFloat {
        notchInset > 0 ? notchInset : 32
    }

    private var currentWidth: CGFloat {
        switch expansionState {
        case .collapsed:
            return compactWidth
        case .droppingDown:
            return 280
        case .fullyExpanded:
            return maxExpandedWidth
        }
    }

    private var currentHeight: CGFloat {
        switch expansionState {
        case .collapsed:
            return compactHeight
        case .droppingDown, .fullyExpanded:
            return 480
        }
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
            style: .continuous
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Symmetrically expanding Liquid Quartz capsule
            VStack(spacing: 0) {
                if expansionState == .fullyExpanded {
                    expandedDropdownContent
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                } else if expansionState == .droppingDown {
                    Color.clear
                        .frame(height: 480)
                } else {
                    compactBar
                        .transition(.opacity)
                }
            }
            .frame(width: currentWidth, height: currentHeight)
            .background {
                if isExpanded {
                    notchShape
                        .fill(.ultraThinMaterial)
                        .overlay {
                            notchShape.fill(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.62))
                        }
                }
            }
            .overlay {
                if isExpanded {
                    notchShape
                        .strokeBorder(PrismTheme.rimStroke, lineWidth: 1)
                }
            }
            .clipShape(notchShape)
            .contentShape(notchShape)
            .onHover(perform: handleHover)
        }
        .frame(width: maxExpandedWidth, alignment: .top)
        .preferredColorScheme(.dark)
        .background {
            NotchWindowConfigurator(
                isExpanded: isExpanded,
                compactWidth: compactWidth,
                compactHeight: compactHeight,
                expandedWidth: maxExpandedWidth,
                panelEnabled: store.notchPanelEnabled,
                notchInset: $notchInset,
                notchWidth: $notchWidth
            )
        }

        // Sheets presented directly on top of the Notch Window
        .sheet(isPresented: $showingAddAccount) {
            AddAccountSheet()
                .environmentObject(store)
                .environmentObject(language)
        }
        .sheet(item: $accountForRelogin) { account in
            ReloginAccountSheet(account: account, queuedCount: 0, cancelQueue: {})
                .environmentObject(store)
                .environmentObject(language)
        }
        .sheet(item: $backupOperation) { op in
            BackupTransferSheet(operation: op)
                .environmentObject(store)
                .environmentObject(language)
        }
        .sheet(item: $accountForEditing) { account in
            AccountEditorSheet(account: account)
                .environmentObject(store)
                .environmentObject(language)
        }
        .task {
            store.startCoreMonitoring()
            store.refreshProviderStatus(silently: true)
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
        .onReceive(NotificationCenter.default.publisher(for: .showDashboard)) { _ in
            openDashboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddAccount)) { _ in
            if !isExpanded { expand() }
            showingAddAccount = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showReloginAccount)) { notification in
            let id = (notification.object as? String).flatMap(UUID.init(uuidString:))
                ?? notification.object as? UUID
            if let id, let account = store.accounts.first(where: { $0.id == id }) {
                if !isExpanded { expand() }
                accountForRelogin = account
            } else if let account = store.accounts.first(where: { !store.isArchived($0) && $0.requiresLogin }) {
                if !isExpanded { expand() }
                accountForRelogin = account
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportBackup)) { _ in
            if !isExpanded { expand() }
            backupOperation = .export
        }
        .onReceive(NotificationCenter.default.publisher(for: .importBackup)) { _ in
            if !isExpanded { expand() }
            backupOperation = .import
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
        .onDisappear {
            hoverTask?.cancel()
            collapseTask?.cancel()
            removeKeyMonitors()
        }
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.identifier?.rawValue == "dashboard" })?
                .makeKeyAndOrderFront(nil)
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
            PrismFilamentView(account: activeAccount, diameter: miniDiameter, compact: true, notchWidth: notchWidth, earWidth: earWidth, compactHeight: compactHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactAccessibilityLabel)
    }

    // MARK: - Expanded Dropdown Content
    private var expandedDropdownContent: some View {
        MenuBarView()
    }

    private var compactAccessibilityLabel: String {
        let five = activeAccount?.usage?.fiveHour?.displayRemainingPercent
        let week = activeAccount?.usage?.weekly?.displayRemainingPercent
        let banked = activeAccount?.usage?.bankedResets?.availableCount ?? 0
        let fiveText = five.map { "\($0)%" } ?? language.text("chưa có", "no data")
        let weekText = week.map { "\($0)%" } ?? language.text("chưa có", "no data")
        let bankedText = banked > 0
            ? language.text(", \(banked) lượt banked reset", ", \(banked) banked resets available")
            : ""
        return language.text(
            "5 giờ còn \(fiveText), tuần còn \(weekText)\(bankedText). Mở Codex Roster.",
            "5-hour \(fiveText), weekly \(weekText)\(bankedText). Open Codex Roster."
        )
    }
    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        collapseTask?.cancel()

        if hovering {
            guard !isExpanded else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                expand()
            }
        } else if isExpanded {
            guard !isPinnedLive else { return }
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(850))
                guard !Task.isCancelled else { return }
                collapse()
            }
        }
    }

    // MARK: - Choreographed Dropdown & 2-Way Bloom Animation
    private func expand() {
        hoverTask?.cancel()
        collapseTask?.cancel()
        installKeyMonitors()

        guard !reduceMotion else {
            expansionState = .fullyExpanded
            return
        }

        // Phase 1: Rapid drop down from the notch ceiling
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            expansionState = .droppingDown
        }

        // Phase 2: Smoothly bloom outward horizontally to both left and right sides!
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(75))
            guard expansionState != .collapsed else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                expansionState = .fullyExpanded
            }
        }
    }

    private func collapse() {
        hoverTask?.cancel()
        collapseTask?.cancel()
        removeKeyMonitors()

        guard !reduceMotion else {
            expansionState = .collapsed
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            expansionState = .collapsed
        }
    }

    private func installKeyMonitors() {
        guard keyMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in collapse() }
            return nil
        }) {
            keyMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in collapse() }
        }) {
            keyMonitors.append(global)
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
    let panelEnabled: Bool
    @Binding var notchInset: CGFloat
    @Binding var notchWidth: CGFloat

    func makeNSView(context: Context) -> NotchHitTestView {
        let view = NotchHitTestView()
        view.isExpanded = isExpanded
        view.compactWidth = compactWidth
        view.compactHeight = compactHeight
        configureWindow(attachedTo: view)
        return view
    }

    func updateNSView(_ view: NotchHitTestView, context: Context) {
        view.isExpanded = isExpanded
        view.compactWidth = compactWidth
        view.compactHeight = compactHeight
        configureWindow(attachedTo: view)
    }

    private func configureWindow(attachedTo view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            guard panelEnabled else {
                window.orderOut(nil)
                return
            }
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

            // Window stays centered permanently at screen midX with fixed width expandedWidth.
            // Symmetrical 2-way expansion and drop-down happen smoothly inside SwiftUI!
            let x = screen.frame.midX - expandedWidth / 2
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
