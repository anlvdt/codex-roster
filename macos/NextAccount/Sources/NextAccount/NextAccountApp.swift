import AppKit
import Darwin
import SwiftUI

private final class SingleInstanceGuard {
    private let descriptor: Int32

    init?() {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.codexroster.app-\(getuid()).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

extension Notification.Name {
    static let requestShowDashboard = Notification.Name("codexRoster.requestShowDashboard")
    static let showDashboard = Notification.Name("codexRoster.showDashboard")
    static let showAddAccount = Notification.Name("codexRoster.showAddAccount")
    static let showReloginAccount = Notification.Name("codexRoster.showReloginAccount")
    static let exportBackup = Notification.Name("codexRoster.exportBackup")
    static let importBackup = Notification.Name("codexRoster.importBackup")
    static let toggleNotchPanel = Notification.Name("codexRoster.toggleNotchPanel")
    static let editAccount = Notification.Name("codexRoster.editAccount")
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var showDashboardObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showDashboardObserver = DistributedNotificationCenter.default().addObserver(
            forName: .requestShowDashboard,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .showDashboard, object: nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .showDashboard, object: nil)
        return true
    }

    deinit {
        if let showDashboardObserver {
            DistributedNotificationCenter.default().removeObserver(showDashboardObserver)
        }
    }
}

private let dashboardCardFill = AnyShapeStyle(.ultraThinMaterial)
private let rosterActionBlue = Color(nsColor: .systemBlue)

private struct PointingHandCursor: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                // Only pop the cursor we pushed, so a stale exit event can't
                // unbalance the shared cursor stack.
                if hovering, !isHovering {
                    NSCursor.pointingHand.push()
                    isHovering = true
                } else if !hovering, isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

private struct MenuBarHoverFeedback: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background(
                isHovering ? Color.primary.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }

    func menuBarInteractive(cornerRadius: CGFloat = 8) -> some View {
        modifier(MenuBarHoverFeedback(cornerRadius: cornerRadius))
            .pointingHandCursor()
    }
}

@main
struct CodexRosterApp: App {
    private static let instanceGuard = SingleInstanceGuard()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AccountStore()
    @StateObject private var language = LanguageStore()
    @StateObject private var updater = GitHubUpdater()

    init() {
        guard Self.instanceGuard != nil else {
            DistributedNotificationCenter.default().postNotificationName(
                .requestShowDashboard,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.codexroster.app")
                .first { $0.processIdentifier != getpid() }?
                .activate(options: [])
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Window("Codex Roster Notch", id: "notch") {
            NotchWindowView()
                .ignoresSafeArea()
                .environmentObject(store)
                .environmentObject(language)
                .environmentObject(updater)
                .environment(\.locale, language.language.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.top)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(language.text("Thêm tài khoản…", "Add account…")) {
                    NotificationCenter.default.post(name: .showAddAccount, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button(language.text("Xuất bản sao lưu…", "Export backup…")) {
                    RosterConsolePresenter.request(.exportBackup)
                }
                Button(language.text("Nhập bản sao lưu…", "Import backup…")) {
                    RosterConsolePresenter.request(.importBackup)
                }
            }
            CommandGroup(after: .toolbar) {
                Button(language.text("Làm mới", "Refresh")) { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button(language.text("Cập nhật quota đang dùng", "Refresh active quota")) {
                    store.refreshUsage(scope: .activeOnly)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Button(language.text("Cập nhật quota tất cả", "Refresh all quotas")) {
                    store.refreshUsage(scope: .allSaved)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift, .option])
            }
        }

        Window(language.text("Bảng điều khiển", "Roster Console"), id: RosterConsoleTab.windowID) {
            RosterConsoleView()
                .environmentObject(store)
                .environmentObject(language)
                .environment(\.locale, language.language.locale)
        }
        .defaultSize(width: RosterSecondaryChrome.consoleWidth, height: RosterSecondaryChrome.consoleHeight)
    }

}

struct ContentView: View {
    /// Legacy companion host removed — notch owns sheets and switching.
    /// Kept as an empty stub so older call sites / previews do not break the module.
    var body: some View {
        EmptyView()
    }
}

private struct AccountSidebar: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: UUID?
    @Binding var focus: AccountTriage?
    @State private var showingServiceStatus = false
    @State private var showingSessionSafety = false

    var body: some View {
        List(selection: $selection) {
            Section {
                Button { selection = nil } label: {
                    Label(language.text("Tổng quan", "Overview"), systemImage: "star")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            selection == nil ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == nil ? [.isSelected] : [])
            }
            if let activeAccount {
                Section {
                    activeSessionCard(activeAccount)
                } header: {
                    Text(language.text("Telemetry", "Telemetry"))
                }
            }
            Section {
                ForEach(AccountTriage.allCases, id: \.self) { bucket in
                    let count = count(for: bucket)
                    // The two set-aside buckets only earn a row once they exist;
                    // ready and needs-action stay put so the filter never moves.
                    if count > 0 || bucket == .ready || bucket == .needsAction {
                        signalRow(bucket, count: count)
                    }
                }
            } header: {
                Text(language.text("Tín hiệu", "Signals"))
            }
            Section {
                serviceStatusRow
                sessionSafetyRow
            } header: {
                Text(language.text("Hệ thống", "System"))
            }
        }
        .navigationTitle("Codex Roster")
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 290)
        .background {
            Color.clear
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: openAboutWindow) {
                Label(language.text("Giới thiệu", "About"), systemImage: "heart.text.square")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Live session

    private func activeSessionCard(_ account: SavedAccount) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { selection = account.id } label: {
                HStack(spacing: 10) {
                    Text(String(account.displayName.prefix(1)).uppercased())
                        .font(PrismTheme.fontBodyCompactBold)
                        .foregroundStyle(PrismTheme.quotaTint(percent: account.usage?.fiveHour?.displayRemainingPercent))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(PrismTheme.quotaTint(percent: account.usage?.fiveHour?.displayRemainingPercent).opacity(0.15)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if account.email != account.displayName {
                            Text(account.email)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(language.text("Mở chi tiết \(account.displayName)", "Open \(account.displayName)"))

            SidebarQuotaMeter(account: account)

            Text(language.text("Theo ~/.codex", "From ~/.codex"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(selection == account.id ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Signals double as the account filter

    private func signalRow(_ bucket: AccountTriage, count: Int) -> some View {
        let isFocused = focus == bucket
        return Button {
            focus = isFocused ? nil : bucket
            // Filtering only means anything on the board, so surface it.
            selection = nil
        } label: {
            HStack(spacing: 9) {
                Image(systemName: bucket.systemImage)
                    .foregroundStyle(bucket.tint)
                Text(bucket.title(in: language.language))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                isFocused ? bucket.tint.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isFocused ? bucket.tint.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isFocused ? [.isSelected] : [])
        .help(language.text(
            "Lọc danh sách theo \(bucket.title(in: language.language))",
            "Filter the list by \(bucket.title(in: language.language))"
        ))
    }

    // MARK: - System rows

    private var serviceStatusRow: some View {
        Button { showingServiceStatus.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: serviceStatusIcon)
                    .foregroundStyle(serviceStatusTint)
                Text(serviceStatusTitle)
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(language.text("Xem chi tiết trạng thái dịch vụ OpenAI", "Show OpenAI service status details"))
        .popover(isPresented: $showingServiceStatus, arrowEdge: .trailing) {
            OpenAIStatusCard()
                .environmentObject(store)
                .environmentObject(language)
                .frame(width: 330)
                .padding(6)
        }
    }

    private var sessionSafetyRow: some View {
        let isBlocked = store.hasRunningCodexProcesses
        return Button { showingSessionSafety.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: isBlocked ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                    .foregroundStyle(isBlocked ? PrismTheme.warning : PrismTheme.success)
                Text(isBlocked
                    ? language.text(
                        "\(store.status?.processWarnings.count ?? 0) tiến trình Codex đang chạy",
                        "\(store.status?.processWarnings.count ?? 0) Codex processes running"
                    )
                    : language.text("Sẵn sàng chuyển tài khoản", "Ready to switch accounts"))
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(language.text("Vì sao chuyển phiên là an toàn", "Why switching sessions is safe"))
        .popover(isPresented: $showingSessionSafety, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 9) {
                Label(language.text(
                    "Roster không xoay refresh token của phiên đang dùng",
                    "Roster does not rotate the active session refresh token"
                ), systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                Text(language.text(
                    "Codex là chủ sở hữu duy nhất của live session. Kiểm tra quota nền chỉ dùng access token hiện có; nếu token hết hạn, app giữ kết quả đã xác minh gần nhất thay vì mạo hiểm làm bạn bị đăng xuất.",
                    "Codex is the sole owner of the live session. Background quota checks only use its current access token; if it expires, the app keeps the last verified result instead of risking a sign-out."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }

    private var serviceStatusIcon: String {
        guard let status = store.openAIStatus else { return "dot.radiowaves.left.and.right" }
        return status.isOperational ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var serviceStatusTint: Color {
        guard let status = store.openAIStatus else { return .secondary }
        return status.isOperational ? .green : .orange
    }

    private var serviceStatusTitle: String {
        guard let status = store.openAIStatus else {
            return store.isLoadingOpenAIStatus
                ? language.text("Đang kiểm tra dịch vụ…", "Checking service status…")
                : language.text("Chưa có trạng thái dịch vụ", "Service status unavailable")
        }
        return status.isOperational
            ? language.text("Dịch vụ OpenAI bình thường", "OpenAI services normal")
            : localizedOpenAIStatus(status.description, language: language.language)
    }

    private var activeAccount: SavedAccount? {
        store.accounts.first(where: \.isActive)
    }

    private func count(for bucket: AccountTriage) -> Int {
        store.accounts.filter { $0.triage == bucket }.count
    }

    private func openAboutWindow() {
        RosterConsolePresenter.open(.about, using: openWindow)
    }

}

private struct DashboardView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?
    @Binding var focus: AccountTriage?
    let relogin: (SavedAccount) -> Void
    let reloginAll: ([SavedAccount]) -> Void

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, min(geometry.size.width - 48, 1_240))
            // Resolved here rather than inside the banner so the banner can be
            // dropped outright when nothing needs the user; the live session is
            // reported once, by the sidebar.
            let nextAction = NextAction.resolve(in: store)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StarMapHero(selection: $selection)

                    if !nextAction.isAllClear {
                        NextActionBanner(
                            selection: $selection,
                            action: nextAction,
                            reloginAll: reloginAll
                        )
                    }

                    AccountTriageBoard(
                        selection: $selection,
                        focus: $focus,
                        relogin: relogin,
                        reloginAll: reloginAll
                    )

                    ProviderOverview(selection: $selection)

                    GlobalResetOutlookCard()

                    TokenUsageOverview()
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationTitle(language.text("Tổng quan", "Overview"))
        .background {
            Color.clear
        }
    }
}

/// Per-provider session and saved-account health across OpenAI, Claude, Cursor,
/// and Grok. Each provider stays siloed: rows only read that provider's own
/// `ProviderState` or its own saved accounts, never another provider's data.
private struct ProviderOverview: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.text("AI providers", "AI providers"), systemImage: "square.grid.2x2")
                .font(.headline)
            Text(language.text(
                "Tình trạng phiên và tài khoản đã lưu của OpenAI, Claude, Cursor và Grok.",
                "Live sessions and saved-account health across OpenAI, Claude, Cursor, and Grok."
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(AIProvider.allCases) { provider in
                    ProviderStatusRow(provider: provider, selection: $selection)
                    if provider != AIProvider.allCases.last { Divider() }
                }
            }
            .padding(.horizontal, 16)
            .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 15))
        }
        .onAppear {
            store.refreshProviderStatus(silently: true)
        }
    }
}

private struct ProviderStatusRow: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let provider: AIProvider
    @Binding var selection: UUID?

    private var accounts: [SavedAccount] {
        store.accounts.filter { $0.aiProvider == provider && !store.isArchived($0) }
    }

    private var providerState: ProviderState? {
        store.providerStates.first { $0.provider == provider }
    }

    private var savedCount: Int {
        provider == .openAI ? accounts.count : (providerState?.savedAccounts ?? 0)
    }

    private var hasLiveSession: Bool {
        providerState?.available ?? (provider == .openAI && accounts.contains(where: \.isActive))
    }

    private var readyAccounts: [SavedAccount] {
        store.sortedAccounts(accounts.filter { !$0.requiresLogin })
    }

    private var attentionCount: Int {
        accounts.filter(\.requiresLogin).count
    }

    private var bestQuotaAccount: SavedAccount? {
        readyAccounts.max { $0.switchQuotaScore < $1.switchQuotaScore }
    }

    private var bestFiveHourWindow: UsageWindow? { bestQuotaAccount?.usage?.fiveHour }

    private var bestWeeklyWindow: UsageWindow? {
        bestQuotaAccount?.usage?.weekly
    }

    private func quotaTint(_ window: UsageWindow) -> Color {
        Color.quotaTint(
            remainingPercent: window.remainingPercent,
            exhaustedAt: UsageWindow.exhaustedRemainingPercent
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: provider.icon)
                .font(.title3)
                .foregroundStyle(savedCount == 0 && !hasLiveSession ? Color.secondary : Color.accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name).font(.subheadline.weight(.semibold))
                if provider == .openAI {
                    if accounts.isEmpty {
                        Text(language.text("Chưa có tài khoản đã lưu", "No saved accounts"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(language.text("\(readyAccounts.count) sẵn sàng · \(attentionCount) cần đăng nhập", "\(readyAccounts.count) ready · \(attentionCount) need sign-in"))
                            .font(.caption)
                            .foregroundStyle(attentionCount == 0 ? Color.secondary : PrismTheme.warning)
                    }
                } else if providerState == nil && store.isLoadingProviderStatus {
                    Text(language.text("Đang kiểm tra phiên local…", "Checking local session…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(language.text(
                        "\(savedCount) đã lưu · \(hasLiveSession ? "phiên live" : "chưa có phiên live")",
                        "\(savedCount) saved · \(hasLiveSession ? "live session" : "no live session")"
                    ))
                        .font(.caption)
                        .foregroundStyle(hasLiveSession ? Color.secondary : PrismTheme.warning)
                }
            }

            Spacer(minLength: 12)

            if bestFiveHourWindow != nil || bestWeeklyWindow != nil {
                VStack(alignment: .trailing, spacing: 5) {
                    if let window = bestFiveHourWindow {
                        providerQuotaLine(language.text("5 giờ", "5-hour"), window: window)
                    }
                    if let window = bestWeeklyWindow {
                        providerQuotaLine(language.text("Tuần", "Weekly"), window: window)
                    }
                }
                .frame(width: 166, alignment: .trailing)
            } else if provider == .openAI && !accounts.isEmpty {
                Text(language.text("Chưa có quota", "Quota not checked"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if provider == .openAI && !accounts.isEmpty {
                Button(language.text("Xem", "View")) {
                    selection = readyAccounts.first?.id ?? accounts.first?.id
                }
                .controlSize(.small)
                Button(language.text("Cập nhật", "Refresh")) {
                    store.refreshUsage(scope: .activeOnly)
                }
                .controlSize(.small)
                .disabled(store.isBusyForActions)
            } else if provider != .openAI {
                Label(
                    hasLiveSession ? language.text("Live", "Live") : language.text("Offline", "Offline"),
                    systemImage: hasLiveSession ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(hasLiveSession ? PrismTheme.success : Color.secondary)
            }
        }
        .padding(.vertical, 14)
    }

    private func providerQuotaLine(_ label: String, window: UsageWindow) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(window.displayRemainingPercent)%")
                .fontWeight(.bold)
                .foregroundStyle(quotaTint(window))
            Text(compactReset(window, language: language.language))
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
    }
}

/// The single most useful thing the user can do right now. Derived from the
/// same `AccountTriage` buckets the board renders, so the banner can never
/// recommend something the board contradicts.
/// Shared by Ops `NextActionBanner` and the notch next-action caption.
enum NextAction {
    case addAccount
    case switchTo(SavedAccount)
    case redeemBankedReset(SavedAccount)
    case waitForReset(SavedAccount)
    case signIn([SavedAccount])
    case recover(SavedAccount)
    case retryQuota([SavedAccount])
    case allClear(SavedAccount?)

    /// The dashboard drops the banner entirely when nothing needs the user, so
    /// the live session is stated once in the sidebar instead of three times.
    var isAllClear: Bool {
        if case .allClear = self { return true }
        return false
    }

    /// Priority order: being blocked *right now* outranks housekeeping on other
    /// accounts, so an exhausted live session is resolved before sign-ins.
    @MainActor
    static func resolve(in store: AccountStore) -> NextAction {
        let accounts = store.accounts
        guard !accounts.isEmpty else { return .addAccount }
        let ready = store.sortedAccounts(accounts.filter { $0.triage == .ready })
        let signIn = accounts.filter { $0.triage == .needsAction && $0.requiresLogin }
        let recovery = accounts.filter { $0.triage == .needsAction && $0.requiresLocalRecovery }
        let transient = accounts.filter { $0.triage == .needsAction && $0.hasTransientUsageError }
        let resting = accounts.filter { $0.triage == .resting }
        let active = accounts.first(where: \.isActive)

        let needsReplacement = active == nil || active?.isExhaustedForSwitch == true
        if needsReplacement {
            if let candidate = ready.first { return .switchTo(candidate) }
            if let banked = store.sortedAccounts(resting.filter(\.restingHasBankedReset)).first {
                return .redeemBankedReset(banked)
            }
            if !signIn.isEmpty { return .signIn(signIn) }
            if let soonest = soonestReset(among: resting) { return .waitForReset(soonest) }
        }
        if !signIn.isEmpty { return .signIn(signIn) }
        if let account = recovery.first { return .recover(account) }
        if !transient.isEmpty { return .retryQuota(transient) }
        return .allClear(active)
    }

    @MainActor
    private static func soonestReset(among accounts: [SavedAccount]) -> SavedAccount? {
        accounts
            .compactMap { account -> (SavedAccount, Date)? in
                guard let reset = account.quotaWindowsForSwitch.map(\.resetAt.value).min() else { return nil }
                return (account, reset)
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    @MainActor
    func headline(language: LanguageStore) -> String {
        switch self {
        case .addAccount:
            language.text("Thêm tài khoản đầu tiên", "Add your first account")
        case .switchTo(let account):
            language.text("Chuyển sang \(account.displayName)", "Switch to \(account.displayName)")
        case .redeemBankedReset(let account):
            language.text("Dùng banked reset của \(account.displayName)", "Redeem \(account.displayName)'s banked reset")
        case .waitForReset:
            language.text("Tất cả tài khoản đang nghỉ", "Every account is resting")
        case .signIn(let accounts):
            accounts.count == 1
                ? language.text("Đăng nhập lại \(accounts[0].displayName)", "Sign in to \(accounts[0].displayName)")
                : language.text("Đăng nhập lại \(accounts.count) tài khoản", "Sign in to \(accounts.count) accounts")
        case .recover(let account):
            language.text("Khôi phục \(account.displayName)", "Recover \(account.displayName)")
        case .retryQuota(let accounts):
            language.text("Thử lại quota cho \(accounts.count) tài khoản", "Retry quota for \(accounts.count) accounts")
        case .allClear(let active):
            active.map { language.text("Đang dùng \($0.displayName)", "Running on \($0.displayName)") }
                ?? language.text("Mọi thứ ổn", "Everything is ready")
        }
    }

    @MainActor
    func detail(language: LanguageStore) -> String {
        switch self {
        case .addAccount:
            language.text(
                "Roster chưa có tài khoản nào để chuyển đổi.",
                "Roster has no accounts to switch between yet."
            )
        case .switchTo(let account):
            language.text(
                "Phiên hiện tại không dùng được; \(account.displayName) còn \(Self.quotaSummary(account, language: language)).",
                "The current session is unusable; \(account.displayName) has \(Self.quotaSummary(account, language: language))."
            )
        case .redeemBankedReset(let account):
            language.text(
                "Không còn tài khoản nào còn quota. \(account.displayName) giữ \(account.bankedResetCount) banked reset — chuyển sang rồi redeem trong Codex.",
                "No account has quota left. \(account.displayName) holds \(account.bankedResetCount) banked reset — switch there, then redeem it inside Codex."
            )
        case .waitForReset(let account):
            language.text(
                "Cửa sổ sớm nhất là \(account.displayName), \(Self.resetSummary(account, language: language)).",
                "The earliest window belongs to \(account.displayName), \(Self.resetSummary(account, language: language))."
            )
        case .signIn(let accounts):
            language.text(
                "Phiên đã hết hạn: \(accounts.prefix(3).map(\.displayName).joined(separator: ", ")).",
                "Expired sessions: \(accounts.prefix(3).map(\.displayName).joined(separator: ", "))."
            )
        case .recover(let account):
            language.text(
                "Snapshot của \(account.email) không đọc được trên máy này.",
                "The snapshot for \(account.email) cannot be read on this Mac."
            )
        case .retryQuota:
            language.text(
                "Không lấy được quota — thường là mạng chập chờn, thử lại là đủ.",
                "Quota could not be fetched — usually a flaky network; a retry is enough."
            )
        case .allClear(let active):
            if let active {
                language.text(
                    "Còn \(Self.quotaSummary(active, language: language)). Không có việc gì cần bạn xử lý.",
                    "\(Self.quotaSummary(active, language: language)) left. Nothing needs your attention."
                )
            } else {
                language.text(
                    "Không có tài khoản nào cần xử lý.",
                    "No account needs attention."
                )
            }
        }
    }

    /// Compact 1–2 line caption for the notch (skips all-clear noise).
    @MainActor
    func compactCaption(language: LanguageStore) -> String? {
        guard !isAllClear else { return nil }
        let head = headline(language: language)
        switch self {
        case .waitForReset(let account):
            return "\(head) · \(Self.resetSummary(account, language: language))"
        case .switchTo(let account):
            return "\(head) · \(Self.quotaSummary(account, language: language))"
        case .redeemBankedReset(let account):
            let count = account.bankedResetCount
            return "\(head) · ×\(count)"
        default:
            return head
        }
    }

    @MainActor
    private static func quotaSummary(_ account: SavedAccount, language: LanguageStore) -> String {
        let parts = [
            account.usage?.fiveHour.map { language.text("5 giờ \($0.displayRemainingPercent)%", "5-hour \($0.displayRemainingPercent)%") },
            account.usage?.weekly.map { language.text("tuần \($0.displayRemainingPercent)%", "weekly \($0.displayRemainingPercent)%") },
        ].compactMap { $0 }
        if parts.isEmpty {
            return language.text("quota chưa xác minh", "unverified quota")
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private static func resetSummary(_ account: SavedAccount, language: LanguageStore) -> String {
        guard let window = account.quotaWindowsForSwitch.min(by: { $0.resetAt.value < $1.resetAt.value }) else {
            return language.text("chưa rõ thời điểm đặt lại", "with no known reset time")
        }
        return window.resetDescription(in: language.language).lowercased()
    }
}

struct NextActionBanner: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?
    let action: NextAction
    let reloginAll: ([SavedAccount]) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon(for: action))
                .font(RosterSecondaryChrome.iconLarge)
                .foregroundStyle(tint(for: action))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.headline(language: language))
                    .font(RosterSecondaryChrome.section)
                    .lineLimit(2)
                Text(action.detail(language: language))
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            button(for: action)
        }
        .padding(16)
        .background(tint(for: action).opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint(for: action).opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("Việc nên làm tiếp theo", "Next action"))
    }

    private func icon(for action: NextAction) -> String {
        switch action {
        case .addAccount: "person.badge.plus"
        case .switchTo: "arrow.left.arrow.right.circle.fill"
        case .redeemBankedReset: "arrow.counterclockwise.circle.fill"
        case .waitForReset: "hourglass"
        case .signIn: "person.crop.circle.badge.exclamationmark"
        case .recover: "externaldrive.badge.exclamationmark"
        case .retryQuota: "wifi.exclamationmark"
        case .allClear: "checkmark.seal.fill"
        }
    }

    private func tint(for action: NextAction) -> Color {
        switch action {
        case .addAccount: .accentColor
        case .switchTo, .redeemBankedReset: .accentColor
        case .waitForReset: .orange
        case .signIn: .orange
        case .recover: .red
        case .retryQuota: .orange
        case .allClear: .green
        }
    }

    @ViewBuilder
    private func button(for action: NextAction) -> some View {
        switch action {
        case .addAccount:
            Button(language.text("Thêm tài khoản", "Add account")) {
                NotificationCenter.default.post(name: .showAddAccount, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isWorking)
        case .switchTo(let account), .redeemBankedReset(let account):
            Button(language.text("Chuyển", "Switch")) {
                store.activate(account, force: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusyForActions)
        case .waitForReset(let account):
            Button(language.text("Xem chi tiết", "View details")) { selection = account.id }
        case .signIn(let accounts):
            Button(accounts.count == 1
                ? language.text("Đăng nhập", "Sign in")
                : language.text("Đăng nhập tất cả", "Sign in to all")) {
                reloginAll(accounts)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(store.isBusyForActions)
        case .recover(let account):
            Button(language.text("Xem chi tiết", "View details")) { selection = account.id }
        case .retryQuota(let accounts):
            Button(language.text("Thử lại", "Retry")) {
                store.refreshUsage(for: accounts)
            }
            .disabled(store.isBusyForActions)
        case .allClear(let active):
            if let active {
                Button(language.text("Xem chi tiết", "View details")) { selection = active.id }
            } else {
                EmptyView()
            }
        }
    }

}

private struct AccountTriageBoard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?
    @Binding var focus: AccountTriage?
    let relogin: (SavedAccount) -> Void
    let reloginAll: ([SavedAccount]) -> Void
    @State private var searchText = ""
    /// Low-signal buckets start folded so the board opens on what matters.
    @State private var collapsed: Set<Int> = [
        AccountTriage.resting.rawValue,
        AccountTriage.archived.rawValue,
    ]
    @State private var isSelecting = false
    @State private var selectedAccountIDs: Set<UUID> = []
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isSelecting { bulkBar }
            Divider()
            if matchingAccounts.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleBuckets, id: \.self) { bucket in
                        bucketSection(bucket)
                    }
                }
            }
        }
        .padding(16)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 13))
        .onChange(of: store.accounts.map(\.id)) { _, accountIDs in
            selectedAccountIDs.formIntersection(accountIDs)
        }
        .confirmationDialog(
            language.text(
                "Xóa \(deletableAccounts.count) tài khoản khỏi Roster?",
                "Remove \(deletableAccounts.count) accounts from Roster?"
            ),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(language.text("Xóa vĩnh viễn", "Remove permanently"), role: .destructive) {
                store.delete(deletableAccounts)
                selectedAccountIDs.subtract(deletableAccounts.map(\.id))
            }
            Button(language.text("Hủy", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text(
                "Phiên đang dùng không bị xóa. Các snapshot đã chọn sẽ bị xóa khỏi máy và không thể hoàn tác.",
                "The active session will not be removed. Selected snapshots will be deleted from this Mac and cannot be undone."
            ))
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Label(language.text("Trạng thái tài khoản", "Account states"), systemImage: "square.stack.3d.up")
                .font(.subheadline.weight(.semibold))
            Text("\(store.accounts.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let focus {
                Button {
                    self.focus = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: focus.systemImage)
                        Text(focus.title(in: language.language))
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(focus.tint.opacity(0.20), in: Capsule())
                    .foregroundStyle(focus.tint)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(language.text("Bỏ lọc", "Clear the filter"))
            }

            Spacer(minLength: 12)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(language.text("Tìm tài khoản", "Find an account"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("Xóa tìm kiếm", "Clear search"))
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background.opacity(0.6), in: Capsule())
            .frame(maxWidth: 210)

            Picker(language.text("Sắp xếp", "Sort"), selection: Binding(
                get: { store.accountSortMode },
                set: { store.setAccountSortMode($0) }
            )) {
                ForEach(AccountSortMode.allCases) { mode in
                    Text(mode.title(in: language.language)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 170)

            Button(isSelecting
                ? language.text("Xong", "Done")
                : language.text("Chọn", "Select")) {
                isSelecting.toggle()
                if !isSelecting { selectedAccountIDs.removeAll() }
            }
            .controlSize(.small)
            .disabled(store.accounts.isEmpty)
        }
    }

    private var bulkBar: some View {
        HStack(spacing: 8) {
            Button(allVisibleSelected
                ? language.text("Bỏ chọn", "Clear")
                : language.text("Chọn tất cả", "Select all")) {
                let visible = matchingAccounts.map(\.id)
                if allVisibleSelected {
                    selectedAccountIDs.subtract(visible)
                } else {
                    selectedAccountIDs.formUnion(visible)
                }
            }
            .buttonStyle(.borderless)
            Text(language.text(
                "Đã chọn \(selectedAccounts.count)",
                "\(selectedAccounts.count) selected"
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Spacer()

            Button(language.text("Làm mới quota", "Refresh quota")) {
                store.refreshUsage(for: refreshableAccounts)
            }
            .disabled(refreshableAccounts.isEmpty || store.isBusyForActions)
            if !selectedReloginAccounts.isEmpty {
                Button(language.text(
                    "Đăng nhập lại \(selectedReloginAccounts.count)",
                    "Sign in to \(selectedReloginAccounts.count)"
                )) {
                    reloginAll(selectedReloginAccounts)
                }
                .tint(.orange)
            }
            Menu {
                Button(language.text("Sao chép email", "Copy emails")) {
                    copyAccountEmails(selectedAccounts.map(\.email))
                }
                .disabled(selectedAccounts.isEmpty)
                Button(language.text("Lưu trữ", "Archive")) {
                    store.setArchived(archivableAccounts, archived: true)
                }
                .disabled(archivableAccounts.isEmpty || store.isBusyForActions)
                Button(language.text("Khôi phục", "Restore")) {
                    store.setArchived(restorableAccounts, archived: false)
                }
                .disabled(restorableAccounts.isEmpty || store.isBusyForActions)
                Divider()
                Button(language.text("Xóa", "Remove"), role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(deletableAccounts.isEmpty || store.isBusyForActions)
            } label: {
                Label(language.text("Khác", "More"), systemImage: "ellipsis.circle")
            }
        }
        .controlSize(.small)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(searchText.isEmpty
                ? language.text(
                    "Chưa có tài khoản nào trong nhóm này.",
                    "No accounts in this group yet."
                )
                : language.text(
                    "Không tìm thấy tài khoản khớp “\(searchText)”.",
                    "No accounts match “\(searchText)”."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !searchText.isEmpty {
                Button(language.text("Xóa tìm kiếm", "Clear search")) { searchText = "" }
                    .buttonStyle(.link)
                    .controlSize(.small)
            } else if focus != nil {
                Button(language.text("Xem tất cả trạng thái", "Show every state")) { focus = nil }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Sections

    @ViewBuilder
    private func bucketSection(_ bucket: AccountTriage) -> some View {
        let accounts = accounts(in: bucket)
        let isCollapsed = collapsed.contains(bucket.rawValue)
        VStack(alignment: .leading, spacing: 9) {
            Button {
                if isCollapsed {
                    collapsed.remove(bucket.rawValue)
                } else {
                    collapsed.insert(bucket.rawValue)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Image(systemName: bucket.systemImage)
                        .foregroundStyle(bucket.tint)
                    Text(bucket.title(in: language.language))
                        .font(.subheadline.weight(.semibold))
                    Text("\(accounts.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(bucket.subtitle(in: language.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if !isCollapsed {
                // Adaptive columns still fill LTR row-major: ForEach order from
                // `sortedAccounts` is the visible quota order (top→bottom, left→right).
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 268, maximum: 420), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(accounts) { account in
                        TriageAccountCard(
                            account: account,
                            bucket: bucket,
                            isSelecting: isSelecting,
                            isSelected: selectedAccountIDs.contains(account.id),
                            toggleSelection: { toggleSelection(account) },
                            openDetails: { selection = account.id },
                            relogin: relogin
                        )
                    }
                }
            }
        }
    }

    // MARK: - Data

    private var searchedAccounts: [SavedAccount] {
        store.sortedAccounts(store.accounts.filter(matchesSearch))
    }

    private var matchingAccounts: [SavedAccount] {
        guard let focus else { return searchedAccounts }
        return searchedAccounts.filter { $0.triage == focus }
    }

    private func accounts(in bucket: AccountTriage) -> [SavedAccount] {
        matchingAccounts.filter { $0.triage == bucket }
    }

    private var visibleBuckets: [AccountTriage] {
        AccountTriage.allCases.filter { !accounts(in: $0).isEmpty }
    }

    private func matchesSearch(_ account: SavedAccount) -> Bool {
        guard !searchText.isEmpty else { return true }
        return [account.displayName, account.email, account.planLabel]
            .compactMap { $0 }
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(searchText)
    }

    private func toggleSelection(_ account: SavedAccount) {
        if selectedAccountIDs.contains(account.id) {
            selectedAccountIDs.remove(account.id)
        } else {
            selectedAccountIDs.insert(account.id)
        }
    }

    private var allVisibleSelected: Bool {
        let visible = matchingAccounts
        return !visible.isEmpty && visible.allSatisfy { selectedAccountIDs.contains($0.id) }
    }

    private var selectedAccounts: [SavedAccount] {
        store.accounts.filter { selectedAccountIDs.contains($0.id) }
    }

    private var refreshableAccounts: [SavedAccount] {
        selectedAccounts.filter { !$0.archived && !$0.requiresLogin && !$0.requiresLocalRecovery }
    }

    private var selectedReloginAccounts: [SavedAccount] {
        selectedAccounts.filter { !$0.archived && $0.requiresLogin }
    }

    private var archivableAccounts: [SavedAccount] {
        selectedAccounts.filter { !$0.archived && !$0.isActive }
    }

    private var restorableAccounts: [SavedAccount] {
        selectedAccounts.filter(\.archived)
    }

    private var deletableAccounts: [SavedAccount] {
        selectedAccounts.filter { !$0.isActive }
    }
}

private struct TriageAccountCard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount
    let bucket: AccountTriage
    let isSelecting: Bool
    let isSelected: Bool
    let toggleSelection: () -> Void
    let openDetails: () -> Void
    let relogin: (SavedAccount) -> Void

    var body: some View {
        // Freeze card identity — LazyVGrid must not retarget Login to another row.
        let targetID = account.id
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                if isSelecting {
                    Toggle(isOn: Binding(get: { isSelected }, set: { _ in toggleSelection() })) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(language.text("Chọn \(account.displayName)", "Select \(account.displayName)"))
                }

                Button(action: openDetails) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: bucket.systemImage)
                                .font(.caption)
                                .foregroundStyle(bucket.tint)
                            Text(account.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .help(account.displayName)
                        }
                        Text(account.email)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(account.email)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(language.text("Mở chẩn đoán tài khoản", "Open account diagnostics"))

                planBadge
            }

            stateLine

            if account.usage?.fiveHour != nil || account.usage?.weekly != nil {
                VStack(alignment: .leading, spacing: 5) {
                    if let window = account.usage?.fiveHour {
                        TriageQuotaBar(label: language.text("5 giờ", "5-hour"), window: window)
                    }
                    if let window = account.usage?.weekly {
                        TriageQuotaBar(label: language.text("Tuần", "Weekly"), window: window)
                    }
                }
            } else {
                Text(language.text("Chưa có số liệu quota", "No quota reading yet"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                bankedResetBadge
                lunaReserveBadge
                Spacer(minLength: 4)
                primaryAction
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.75) : bucket.tint.opacity(0.22),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .id(targetID)
    }

    @ViewBuilder
    private var planBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(account.planLabel ?? "—")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            if let activeUntil = account.paidSubscriptionActiveUntil {
                Text(compactSubscriptionUntil(activeUntil, language: language.language))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(activeUntil < Date() ? PrismTheme.danger : Color.secondary)
            }
        }
    }

    private var stateLine: some View {
        HStack(spacing: 6) {
            Text(healthLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(healthColor)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(lastVerifiedLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var bankedResetBadge: some View {
        if let summary = account.usage?.bankedResets, summary.totalAvailableCount > 0 {
            let count = summary.totalAvailableCount
            let nearestExpiry = summary.credits?
                .compactMap { $0.expiresAt?.value }
                .filter { $0 > Date() }
                .min()
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                Text("\(count)")
                    .monospacedDigit()
                if let nearestExpiry {
                    Text(compactTimeRemaining(until: nearestExpiry, language: language.language))
                        .foregroundStyle(.secondary)
                } else if let granted = summary.credits?
                    .first(where: { $0.status == "available" })?.grantedAt.value {
                    Text(formatRelativeTime(granted, language: language.language))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(language.text(
                "Có \(count) lượt banked reset",
                "\(count) banked resets available"
            ))
            .help(language.text(
                "Banked reset chỉ dùng được sau khi redeem trong Codex.",
                "A banked reset only counts once redeemed inside Codex."
            ))
        }
    }

    @ViewBuilder
    private var lunaReserveBadge: some View {
        if account.hasLunaReserve {
            let isLunaActive = store.isLunaReserveActive(for: account)
            HStack(spacing: 3) {
                Image(systemName: isLunaActive ? "moon.stars.fill" : "moon.fill")
                Text(isLunaActive ? "Luna Active" : "Luna")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PrismTheme.autoSwitch)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(PrismTheme.autoSwitch.opacity(0.15)))
            .help(language.text(
                isLunaActive ? "Codex đang chạy bằng Luna Reserve" : "Tài khoản có Luna Reserve",
                isLunaActive ? "Codex is active on Luna Reserve" : "Account has Luna Reserve"
            ))
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch bucket {
        case .needsAction:
            if account.requiresLogin {
                Button(language.text("Đăng nhập lại", "Sign in")) {
                    guard let target = accountForContextMenuAction(in: store.accounts, capturedID: account.id) else { return }
                    relogin(target)
                }
                    .controlSize(.small)
                    .tint(.orange)
            } else if account.requiresLocalRecovery {
                Button(language.text("Chi tiết", "Details"), action: openDetails)
                    .controlSize(.small)
            } else {
                Button(language.text("Thử lại", "Retry")) {
                    store.refreshUsage(for: account)
                }
                .controlSize(.small)
                .disabled(store.isBusyForActions)
            }
        case .active:
            Label(language.text("Đang dùng", "Active"), systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .ready:
            Button(language.text("Chuyển", "Switch")) {
                store.activate(account, force: true)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusyForActions)
        case .resting:
            if account.restingHasBankedReset {
                // A banked reset is not spendable quota until redeemed inside
                // Codex, but the user must still be able to switch here to do
                // that — so this stays an action, not a dead "out of quota" tag.
                Button(language.text("Chuyển & redeem", "Switch & redeem")) {
                    store.activate(account, force: true)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusyForActions)
                .help(language.text(
                    "Hết quota nhưng có banked reset — chuyển sang tài khoản này rồi redeem trong Codex.",
                    "Out of quota but has a banked reset — switch here, then redeem it in Codex."
                ))
            } else {
                Text(resetHint)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .archived:
            Button(language.text("Khôi phục", "Restore")) {
                store.setArchived([account], archived: false)
            }
            .controlSize(.small)
            .disabled(store.isBusyForActions)
        }
    }

    private var resetHint: String {
        guard let window = account.quotaWindowsForSwitch.min(by: { $0.resetAt.value < $1.resetAt.value }) else {
            return language.text("Hết quota", "Out of quota")
        }
        return window.resetDescription(in: language.language)
    }

    private var healthLabel: String {
        if account.archived { return language.text("Đã lưu trữ", "Archived") }
        if account.usageError?.localizedCaseInsensitiveContains("[server_session_revoked]") == true {
            return language.text("Phiên bị thu hồi", "Session revoked")
        }
        if account.requiresLogin { return language.text("Cần đăng nhập", "Sign-in required") }
        if account.requiresLocalRecovery { return language.text("Cần phục hồi", "Local recovery") }
        if account.hasTransientUsageError { return language.text("Lỗi quota tạm thời", "Quota unavailable") }
        return language.text("Phiên khỏe", "Session healthy")
    }

    private var healthColor: Color {
        if account.requiresLogin { return .orange }
        if account.requiresLocalRecovery { return .red }
        if account.hasTransientUsageError { return .orange }
        if account.archived { return .secondary }
        return .green
    }

    private var lastVerifiedLabel: String {
        guard let date = account.lastVerifiedAt else {
            return language.text("Chưa xác minh quota", "Quota not verified")
        }
        return language.text(
            "Xác minh \(compactVerificationDate(date, language: language.language))",
            "Verified \(compactVerificationDate(date, language: language.language))"
        )
    }
}

private struct TriageQuotaBar: View {
    @EnvironmentObject private var language: LanguageStore
    let label: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(window.displayRemainingPercent)%")
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
                Text(compactReset(window, language: language.language))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospacedDigit())
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, proxy.size.width * CGFloat(window.displayRemainingPercent) / 100))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.text(
            "\(label) còn \(window.displayRemainingPercent) phần trăm, đặt lại \(window.relativeReset(in: language.language))",
            "\(label) \(window.displayRemainingPercent) percent remaining, resets \(window.relativeReset(in: language.language))"
        ))
    }

    private var tint: Color {
        Color.quotaTint(
            remainingPercent: window.remainingPercent,
            exhaustedAt: UsageWindow.exhaustedRemainingPercent
        )
    }
}


private struct StarMapHero: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !store.isArchived($0) }
    }

    private var planetAccounts: [SavedAccount] {
        Array(store.sortedAccounts(store.accounts.filter { !store.isArchived($0) && !$0.isActive }).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Text(language.text("Bản đồ hệ tài khoản", "Account star map"))
                    .font(.title2.weight(.bold))
                Spacer(minLength: 8)
                Label(language.text("\(store.accounts.count) tài khoản đã lưu", "\(store.accounts.count) saved accounts"), systemImage: "tray.full")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let activeAccount {
                PrismDualChamberGauge(
                    fiveHour: activeAccount.usage?.fiveHour,
                    weekly: activeAccount.usage?.weekly,
                    showLabels: true,
                    compact: false
                )
                .padding(.vertical, 8)
            } else {
                Text(language.text("Chưa có tài khoản nào. Thêm tài khoản đầu tiên để khởi động bản đồ.", "No accounts yet. Add the first account to start the star map."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
        }
        .padding(22)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct TokenUsageOverview: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.text("Mức dùng Codex trên máy này", "Local Codex usage"), systemImage: "chart.bar.xaxis")
                .font(RosterSecondaryChrome.section)
            Text(language.text("Thống kê token theo các phiên sử dụng gần đây.", "Token activity from recent sessions."))
                .font(RosterSecondaryChrome.callout)
                .foregroundStyle(.secondary)
            if let summary = store.tokenUsage {
                VStack(alignment: .leading, spacing: 14) {
                    if let vibe = store.status?.vibeUsage {
                        HStack(spacing: 10) {
                            TokenMetric(title: "VibeCafe 7d", tokens: vibe.totalTokens)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(language.text("Chi phí ước tính", "Estimated cost"))
                                    .font(RosterSecondaryChrome.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "$%.2f", vibe.estimatedCostUsd))
                                    .font(RosterSecondaryChrome.metric)
                                Text("\(vibe.sessions) sessions · \(String(format: "%.1f", Double(vibe.activeSeconds) / 3600))h")
                                    .font(RosterSecondaryChrome.micro)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Divider()
                    }
                    HStack(spacing: 10) {
                        TokenMetric(title: language.text("Hôm nay", "Today"), tokens: summary.today)
                        TokenMetric(title: language.text("7 ngày", "7 days"), tokens: summary.last7Days)
                        TokenMetric(title: language.text("30 ngày", "30 days"), tokens: summary.last30Days)
                        TokenMetric(title: language.text("12 tháng", "12 months"), tokens: summary.last365Days)
                    }

                    Divider()

                    TokenUsageChart(days: summary.daily)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                    TokenUsageDetails(summary: summary)

                    HStack {
                        Text(language.text(
                            "Bao gồm token context và cache; không dùng để tính chi phí.",
                            "Includes context and cached tokens; it is not a billing total."
                        ))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button(language.text("Cập nhật token", "Refresh tokens")) {
                            store.refreshTokenUsage()
                        }
                        .controlSize(.small)
                        .disabled(store.isLoadingTokenUsage)
                    }
                }
            } else {
                HStack {
                    if store.isLoadingTokenUsage {
                        ProgressView()
                        Text(language.text("Đang cập nhật thống kê…", "Updating statistics…"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(language.text("Chưa có thống kê token.", "Token statistics are not available yet."))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(language.text("Tải thống kê", "Load statistics")) {
                            store.refreshTokenUsage()
                        }
                    }
                }
                .font(RosterSecondaryChrome.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TokenUsageDetails: View {
    @EnvironmentObject private var language: LanguageStore
    let summary: TokenUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("Phân bổ token", "Token breakdown"))
                .font(RosterSecondaryChrome.section)

            HStack(spacing: 10) {
                TokenBreakdownMetric(title: language.text("Input", "Input"), tokens: summary.inputTokens)
                TokenBreakdownMetric(title: language.text("Output", "Output"), tokens: summary.outputTokens)
                TokenBreakdownMetric(title: language.text("Cache", "Cache"), tokens: summary.cachedInputTokens)
                TokenBreakdownMetric(title: language.text("Lý luận", "Reasoning"), tokens: summary.reasoningOutputTokens)
            }

            HStack(spacing: 6) {
                Text(language.text("Cache hit", "Cache hit"))
                Text("\(summary.cacheHitPercent)%")
                    .fontWeight(.semibold)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(language.text("Tạo cache", "Cache write"))
                Text(compactTokenCount(summary.cacheWriteInputTokens, in: language.language))
                    .fontWeight(.semibold)
            }
            .font(RosterSecondaryChrome.caption)
            .foregroundStyle(.secondary)

            if let cost = summary.estimatedCostUsd, cost > 0 {
                HStack(spacing: 8) {
                    Label(
                        language.text(
                            String(format: "Ước tính giá trị API: $%.2f", cost),
                            String(format: "Est. API token value: $%.2f", cost)
                        ),
                        systemImage: "dollarsign.circle.fill"
                    )
                    .font(RosterSecondaryChrome.caption.weight(.semibold))
                    .foregroundStyle(PrismTheme.emerald)

                    if let todayCost = summary.todayCostUsd, todayCost > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(format: language.text("Hôm nay: $%.2f", "Today: $%.2f"), todayCost))
                            .font(RosterSecondaryChrome.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 1)
            }

            if let sub = summary.subagentSessions, sub > 0, let main = summary.mainSessions {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text(language.text(
                        "Phiên chạy: \(main) chính, \(sub) subagents",
                        "Sessions: \(main) main, \(sub) subagents"
                    ))
                }
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.secondary)
            }

            if !summary.byModel.isEmpty {
                TokenUsageRanking(title: language.text("Theo model", "By model"), entries: summary.byModel, showBars: true)
            }
            if !summary.byProject.isEmpty {
                TokenUsageRanking(title: language.text("Theo dự án", "By project"), entries: summary.byProject, showBars: false)
            }
        }
        .padding(14)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TokenBreakdownMetric: View {
    @EnvironmentObject private var language: LanguageStore
    let title: String
    let tokens: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.secondary)
            Text(compactTokenCount(tokens, in: language.language))
                .font(RosterSecondaryChrome.section.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TokenUsageRanking: View {
    @EnvironmentObject private var language: LanguageStore
    let title: String
    let entries: [TokenUsageBreakdown]
    var showBars: Bool = false

    private var ranked: [TokenUsageBreakdown] {
        Array(entries.sorted { $0.tokens > $1.tokens }.prefix(showBars ? 6 : 3))
    }

    private var maxTokens: UInt64 {
        ranked.map(\.tokens).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(RosterSecondaryChrome.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(ranked) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(entry.label)
                            .lineLimit(1)
                            .font(RosterSecondaryChrome.callout)
                        Spacer(minLength: 4)
                        if let cost = entry.estimatedCostUsd, cost > 0 {
                            Text(String(format: "$%.2f", cost))
                                .font(RosterSecondaryChrome.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(PrismTheme.emerald)
                        }
                        Text(compactTokenCount(entry.tokens, in: language.language))
                            .font(RosterSecondaryChrome.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if showBars {
                        GeometryReader { geo in
                            let ratio = maxTokens == 0 ? 0 : CGFloat(entry.tokens) / CGFloat(maxTokens)
                            ZStack(alignment: .leading) {
                                Capsule().fill(PrismTheme.trackFill)
                                Capsule()
                                    .fill(PrismTheme.accent.opacity(0.75))
                                    .frame(width: max(4, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }
}

private struct TokenMetric: View {
    @EnvironmentObject private var language: LanguageStore
    let title: String
    let tokens: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(PrismTheme.fontMicro)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(RosterSecondaryChrome.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(compactTokenCount(tokens, in: language.language))
                .font(RosterSecondaryChrome.metricLarge)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(language.text("token", "tokens"))
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TokenUsageChart: View {
    @EnvironmentObject private var language: LanguageStore
    let days: [TokenUsageDay]

    private var maximum: UInt64 {
        max(days.map(\.tokens).max() ?? 0, 1)
    }

    private var average: UInt64 {
        guard !days.isEmpty else { return 0 }
        return days.reduce(0) { $0 + $1.tokens } / UInt64(days.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("Hoạt động 7 ngày", "Seven-day activity"))
                        .font(RosterSecondaryChrome.section)
                    Text(language.text("Trung bình \(compactTokenCount(average, in: language.language)) token/ngày", "Average \(compactTokenCount(average, in: language.language)) tokens/day"))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(language.text("Cao nhất", "Peak"))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                    Text(compactTokenCount(maximum, in: language.language))
                        .font(RosterSecondaryChrome.section.monospacedDigit())
                }
            }

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    Divider().opacity(0.45)
                    Spacer()
                    Divider().opacity(0.3)
                    Spacer()
                    Divider().opacity(0.45)
                }
                .padding(.bottom, 24)

                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(days) { day in
                        TokenDayColumn(
                            day: day,
                            maximum: maximum,
                            isLatest: day.id == days.last?.id,
                            isPeak: day.tokens == maximum,
                            language: language.language
                        )
                    }
                }
            }
            .frame(height: 142)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct TokenDayColumn: View {
    let day: TokenUsageDay
    let maximum: UInt64
    let isLatest: Bool
    let isPeak: Bool
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 6) {
            Text(isLatest || isPeak ? compactTokenCount(day.tokens, in: language) : " ")
                .font(RosterSecondaryChrome.caption.monospacedDigit())
                .foregroundStyle(isLatest ? Color.accentColor : Color.secondary)
                .lineLimit(1)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(isLatest ? 0.95 : 0.62))
                    .frame(height: barHeight)
            }
            .frame(width: 24, height: 78)
            Text(dayLabel)
                .font(RosterSecondaryChrome.caption.weight(isLatest ? .semibold : .regular))
                .foregroundStyle(isLatest ? Color.accentColor : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(day.date)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLanguage.text(
            "\(day.date): \(compactTokenCount(day.tokens, in: language)) token",
            "\(day.date): \(compactTokenCount(day.tokens, in: language)) tokens"
        ))
    }

    private var barHeight: CGFloat {
        guard day.tokens > 0 else { return 4 }
        return max(4, 78 * CGFloat(Double(day.tokens) / Double(maximum)))
    }

    private var dayLabel: String {
        if isLatest {
            return language == .vietnamese ? "Nay" : "Today"
        }
        return String(day.date.suffix(2))
    }
}
func compactMetric(_ tokens: UInt64) -> String {
    let value = Double(tokens)
    if value >= 1_000_000_000 {
        return String(format: "%.1fB", value / 1_000_000_000)
    } else if value >= 1_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    } else if value >= 1_000 {
        return String(format: "%.1fK", value / 1_000)
    } else {
        return "\(tokens)"
    }
}


private func compactTokenCount(_ tokens: UInt64, in language: AppLanguage) -> String {
    let value = Double(tokens)
    let (scaledValue, unit): (Double, String)
    if value >= 1_000_000_000 {
        scaledValue = value / 1_000_000_000
        unit = language == .vietnamese ? "tỷ" : "B"
    } else if value >= 1_000_000 {
        scaledValue = value / 1_000_000
        unit = language == .vietnamese ? "triệu" : "M"
    } else if value >= 1_000 {
        scaledValue = value / 1_000
        unit = language == .vietnamese ? "nghìn" : "K"
    } else {
        return "\(tokens)"
    }

    let scaled = scaledValue.formatted(
        .number.precision(.fractionLength(0...1)).locale(language.locale)
    )
    return "\(scaled) \(unit)"
}

private struct SidebarQuotaMeter: View {
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount

    var body: some View {
        if account.requiresLogin {
            Label(language.text("Cần đăng nhập lại", "Sign-in required"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        } else if account.requiresLocalRecovery {
            Label(language.text("Cần khôi phục local", "Local recovery"), systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        } else if account.hasTransientUsageError {
            Label(language.text("Quota tạm thời lỗi", "Quota temporarily unavailable"), systemImage: "wifi.exclamationmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(.yellow)
        } else if account.primaryQuotaWindow != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let window = account.usage?.fiveHour {
                    quotaLine(language.text("5 giờ", "5-hour"), window: window)
                }
                if let window = account.usage?.weekly {
                    quotaLine(language.text("Tuần", "Weekly"), window: window)
                }
            }
        } else {
            Text(language.text("Chưa có quota", "Quota not checked"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func quotaLine(_ label: String, window: UsageWindow) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .frame(width: 40, alignment: .leading)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(window.displayRemainingPercent), total: 100)
                .tint(Color.quotaTint(
                    remainingPercent: window.remainingPercent,
                    exhaustedAt: UsageWindow.exhaustedRemainingPercent
                ))
                .frame(minWidth: 46, maxWidth: .infinity)
            Text("\(window.displayRemainingPercent)%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.quotaTint(
                    remainingPercent: window.remainingPercent,
                    exhaustedAt: UsageWindow.exhaustedRemainingPercent
                ))
            Text(compactReset(window, language: language.language))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(language.text(
            "\(label) còn \(window.displayRemainingPercent) phần trăm, \(compactReset(window, language: language.language))",
            "\(label) \(window.displayRemainingPercent) percent remaining, \(compactReset(window, language: language.language))"
        ))
    }
}

private func compactReset(_ window: UsageWindow, language: AppLanguage) -> String {
    let interval = max(0, window.resetAt.value.timeIntervalSinceNow)
    let minutes = Int(interval / 60)
    if minutes < 1 { return language == .vietnamese ? "đang reset" : "resetting" }

    let days = minutes / 1_440
    if days > 0 { return language == .vietnamese ? "↺ \(days) ngày" : "↺ \(days)d" }
    let hours = minutes / 60
    if hours > 0 { return language == .vietnamese ? "↺ \(hours) giờ" : "↺ \(hours)h" }
    return language == .vietnamese ? "↺ \(minutes) phút" : "↺ \(minutes)m"
}

private func compactSubscriptionUntil(_ date: Date, language: AppLanguage) -> String {
    let value = date.formatted(
        Date.FormatStyle(date: .numeric, time: .omitted).locale(language.locale)
    )
    return language == .vietnamese ? "đến \(value)" : "until \(value)"
}

private func compactVerificationDate(_ date: Date, language: AppLanguage) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let style = calendar.isDateInToday(date)
        ? Date.FormatStyle(date: .omitted, time: .shortened)
        : Date.FormatStyle(date: .numeric, time: .omitted)
    return date.formatted(style.locale(language.locale))
}

private func compactTimeRemaining(until date: Date, language: AppLanguage) -> String {
    let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
    let days = minutes / 1_440
    if days > 0 {
        return language == .vietnamese ? "còn \(days) ngày" : "\(days)d left"
    }
    let hours = minutes / 60
    if hours > 0 {
        return language == .vietnamese ? "còn \(hours) giờ" : "\(hours)h left"
    }
    return language == .vietnamese ? "còn \(minutes) phút" : "\(minutes)m left"
}

struct OpenAIStatusCard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openURL) private var openURL

    private let sourceURL = URL(string: "https://status.openai.com/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(language.text("Trạng thái dịch vụ OpenAI", "OpenAI service status"), systemImage: "dot.radiowaves.left.and.right")
                    .font(RosterSecondaryChrome.section)
                Spacer()
                Button { openURL(sourceURL) } label: {
                    Label("status.openai.com", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

            if let status = store.openAIStatus {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: status.isOperational ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isOperational ? .green : .orange)
                    Text(localizedOpenAIStatus(status.description, language: language.language))
                        .font(RosterSecondaryChrome.body.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Button(language.text("Cập nhật", "Refresh")) { store.refreshOpenAIStatus() }
                        .controlSize(.small)
                        .disabled(store.isLoadingOpenAIStatus)
                }

                if !status.codexComponents.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(status.codexComponents) { component in
                            Label(component.name, systemImage: component.isOperational ? "circle.fill" : "exclamationmark.circle.fill")
                                .font(RosterSecondaryChrome.caption)
                                .foregroundStyle(component.isOperational ? Color.secondary : PrismTheme.warning)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                HStack {
                    if store.isLoadingOpenAIStatus {
                        ProgressView()
                        Text(language.text("Đang kiểm tra dịch vụ…", "Checking service status…"))
                    } else {
                        Text(language.text("Chưa nhận được trạng thái dịch vụ.", "Service status is unavailable."))
                        Spacer()
                        Button(language.text("Tải lại", "Retry")) { store.refreshOpenAIStatus() }
                    }
                }
                .font(RosterSecondaryChrome.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 15))
    }

}

private func localizedOpenAIStatus(_ description: String, language: AppLanguage) -> String {
    guard language == .vietnamese, description == "All Systems Operational" else {
        return description
    }
    return "Mọi hệ thống đang hoạt động"
}

struct GlobalResetOutlookCard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openURL) private var openURL
    @State private var showingSignalDetails = false

    private let sourceURL = URL(string: "https://codex-resets.com/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(language.text("Reset outlook", "Reset outlook"), systemImage: "antenna.radiowaves.left.and.right")
                    .font(RosterSecondaryChrome.section)
                Spacer()
                Button {
                    openURL(outlookSourceURL ?? sourceURL)
                } label: {
                    Label("codex-resets.com", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

            if let outlook = store.resetOutlook {
                let isConfirmedReset = outlook.lastResetIsConfirmed == true
                let leadPercent = outlook.signalPercent ?? max(outlook.chance24Hours, outlook.chance48Hours)
                let urgencyColor = forecastColor(leadPercent, high: .orange)

                // One full-width row of metrics; the card used to stack these
                // vertically and leave half of its width blank.
                HStack(alignment: .top, spacing: 12) {
                    if let signalPercent = outlook.signalPercent {
                        ResetOutlookMetric(
                            title: language.text("Tín hiệu cam kết", "Signal commitment"),
                            value: "\(signalPercent)%",
                            tint: forecastColor(signalPercent, high: .red)
                        )
                    }
                    ResetOutlookMetric(
                        title: language.text("24 giờ", "24 hours"),
                        value: "\(outlook.chance24Hours)%",
                        tint: forecastColor(outlook.chance24Hours)
                    )
                    ResetOutlookMetric(
                        title: language.text("48 giờ", "48 hours"),
                        value: "\(outlook.chance48Hours)%",
                        tint: forecastColor(outlook.chance48Hours)
                    )
                    ResetOutlookMetric(
                        title: language.text("Giờ thường reset", "Reset window"),
                        value: formatResetWindow(outlook, language: language.language),
                        tint: .secondary
                    )
                    if let scheduledResetAt = outlook.nextResetAt {
                        ResetOutlookMetric(
                            title: language.text("Reset dự kiến", "Expected reset"),
                            value: formattedVietnamResetDate(scheduledResetAt, language: language.language),
                            tint: .orange
                        )
                    }
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(urgencyColor)
                        .frame(width: 8, height: 8)
                    Text(language.text(
                        "Độ tin cậy mô hình: \(localizedConfidence(outlook.confidence))",
                        "Model confidence: \(localizedConfidence(outlook.confidence))"
                    ))
                    if isConfirmedReset {
                        Text("·").foregroundStyle(.tertiary)
                        Text(language.text("Đã xác nhận", "Confirmed"))
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                    }
                    if let cadenceDays = outlook.cadenceDays {
                        Text("·").foregroundStyle(.tertiary)
                        Text(language.text(
                            "Nhịp ~\(String(format: "%.1f", cadenceDays)) ngày",
                            "Cadence ~\(String(format: "%.1f", cadenceDays)) days"
                        ))
                        if outlook.cadenceAccelerating == true {
                            Text(language.text("(tăng nhanh)", "(accelerating)"))
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer(minLength: 8)

                    Button(language.text("Chi tiết tín hiệu", "Signal details")) {
                        showingSignalDetails.toggle()
                    }
                    .controlSize(.small)
                    .popover(isPresented: $showingSignalDetails, arrowEdge: .bottom) {
                        signalDetails(outlook, isConfirmedReset: isConfirmedReset)
                    }
                    Button(language.text("Cập nhật", "Refresh")) { store.refreshResetOutlook() }
                        .controlSize(.small)
                        .disabled(store.isLoadingResetOutlook)
                }
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.secondary)

                Text(language.text("Quota tài khoản là xác nhận cuối cùng.", "Account quota is the final confirmation."))
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack {
                    if store.isLoadingResetOutlook {
                        ProgressView()
                        Text(language.text("Đang tải tín hiệu reset…", "Loading reset outlook…"))
                    } else {
                        Text(language.text("Chưa có tín hiệu reset.", "Reset outlook is unavailable."))
                        Spacer()
                        Button(language.text("Tải lại", "Retry")) { store.refreshResetOutlook() }
                    }
                }
                .font(RosterSecondaryChrome.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 15))
    }

    @ViewBuilder
    private func signalDetails(_ outlook: ResetOutlook, isConfirmedReset: Bool) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isConfirmedReset
                    ? language.text("Lần reset gần nhất", "Last reset")
                    : language.text("Tín hiệu gần nhất", "Latest signal"))
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formattedResetDate(outlook.lastResetAt, language: language.language))
                        .font(RosterSecondaryChrome.section)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(formattedRelativeResetDate(
                            outlook.lastResetAt,
                            relativeTo: context.date,
                            language: language.language
                        ))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            if let summary = outlook.signalSummary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("Tóm tắt tín hiệu", "Signal summary"))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                    Text(localizedSignalSummary(summary))
                        .font(RosterSecondaryChrome.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if let timeline = store.resetTimeline, !timeline.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("Lịch sử reset", "Reset history"))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                    ForEach(timeline.prefix(3)) { event in
                        HStack(alignment: .top, spacing: 6) {
                            Text(event.date)
                                .font(RosterSecondaryChrome.micro.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(event.summary)
                                .font(RosterSecondaryChrome.micro)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let juice = store.resetJuice, !juice.efforts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("Mức effort còn lại", "Remaining effort levels"))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ForEach(juice.efforts.prefix(4)) { effort in
                            HStack(spacing: 4) {
                                Text(effort.effort.capitalized)
                                    .font(RosterSecondaryChrome.micro)
                                    .foregroundStyle(.secondary)
                                Text("\(effort.current)")
                                    .font(RosterSecondaryChrome.micro.monospacedDigit().weight(.medium))
                                    .foregroundStyle(effort.delta > 0 ? .green : effort.delta < 0 ? .red : .secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    /// The upstream feed answers "did a reset happen" with a bare token, which
    /// used to reach the card as an unlabelled "Yes".
    private func localizedSignalSummary(_ summary: String) -> String {
        switch summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true":
            return language.text("Nguồn báo đã có reset.", "The source reports a reset.")
        case "no", "false":
            return language.text("Nguồn báo chưa có reset.", "The source reports no reset yet.")
        default:
            return summary
        }
    }

    private func forecastColor(_ percent: Int, high: Color = .orange) -> Color {
        switch percent {
        case 0..<20: return .green
        case 20..<50: return high
        case 50..<75: return .orange
        default: return .red
        }
    }

    private func localizedConfidence(_ value: String) -> String {
        guard language.language == .vietnamese else { return value.capitalized }
        return switch value.lowercased() {
        case "high": "Cao"
        case "medium": "Trung bình"
        case "low": "Thấp"
        default: value
        }
    }

    private var outlookSourceURL: URL? {
        trustedResetSourceURL(store.resetOutlook?.sourceUrl)
    }
}

private struct ResetOutlookMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(value)
                .font(RosterSecondaryChrome.metric)
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(minWidth: 112, maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 11))
    }
}

private func formattedResetDate(_ value: String, language: AppLanguage) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
    return date.formatted(
        .dateTime
            .day()
            .month(.abbreviated)
            .hour()
            .minute()
            .locale(language.locale)
    )
}

private func formatResetWindow(_ outlook: ResetOutlook, language: AppLanguage) -> String {
    // API returns a UTC time window (e.g., 11 PM - 2 AM UTC). Vietnamese mode
    // keeps the historical Asia/Ho_Chi_Minh conversion; English follows the
    // user's own timezone so the hours are locally meaningful.
    guard let startHour = outlook.windowStartHour, let endHour = outlook.windowEndHour else {
        return outlook.windowLabel
    }
    let timeZone = language == .vietnamese
        ? (TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current)
        : .current
    let offsetMinutes = timeZone.secondsFromGMT() / 60
    return "\(formatClockTime(startHour * 60 + offsetMinutes, language: language)) - \(formatClockTime(endHour * 60 + offsetMinutes, language: language))"
}

private func formatClockTime(_ totalMinutes: Int, language: AppLanguage) -> String {
    let minutes = ((totalMinutes % 1_440) + 1_440) % 1_440
    let hour = minutes / 60
    let minute = minutes % 60
    if language == .vietnamese {
        return String(format: "%d:%02d", hour, minute)
    }
    let hour12 = hour % 12 == 0 ? 12 : hour % 12
    return String(format: "%d:%02d %@", hour12, minute, hour < 12 ? "AM" : "PM")
}

private func formatRelativeTime(_ date: Date, language: AppLanguage) -> String {
    let relativeFormatter = RelativeDateTimeFormatter()
    relativeFormatter.locale = language.locale
    relativeFormatter.unitsStyle = .abbreviated
    let relativeTime = relativeFormatter.localizedString(for: date, relativeTo: Date())
    return AppLanguage.text("Nhận \(relativeTime)", "Received \(relativeTime)")
}

private func formattedRelativeResetDate(
    _ value: String,
    relativeTo referenceDate: Date,
    language: AppLanguage
) -> String {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
        return value
    }
    let relativeFormatter = RelativeDateTimeFormatter()
    relativeFormatter.locale = language.locale
    relativeFormatter.unitsStyle = .full
    return relativeFormatter.localizedString(for: date, relativeTo: referenceDate)
}

private func formattedVietnamResetDate(_ value: String, language: AppLanguage) -> String {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
        return value
    }

    // Same convention as formatResetWindow: Vietnamese reads Asia/Ho_Chi_Minh,
    // English reads the user's own timezone.
    let displayTimeZone = language == .vietnamese
        ? (TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current)
        : .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = displayTimeZone
    let components = calendar.dateComponents([.hour, .weekday], from: date)

    let posixLocale = Locale(identifier: "en_US_POSIX")
    let timeFormatter = DateFormatter()
    timeFormatter.locale = posixLocale
    timeFormatter.timeZone = displayTimeZone
    let dateFormatter = DateFormatter()
    dateFormatter.locale = posixLocale
    dateFormatter.timeZone = displayTimeZone
    let symbolFormatter = DateFormatter()
    symbolFormatter.locale = language.locale
    symbolFormatter.timeZone = displayTimeZone

    if language == .vietnamese {
        timeFormatter.dateFormat = "HH:mm"
        dateFormatter.dateFormat = "dd/MM"
        let hour = components.hour ?? 0
        let period = switch hour {
        case 0..<12: "sáng"
        case 12..<18: "chiều"
        default: "tối"
        }
        let weekday = symbolFormatter.weekdaySymbols[(components.weekday ?? 1) - 1]
        let weekdayPrefix = weekday.prefix(1).lowercased()
        let formattedWeekday = weekdayPrefix + weekday.dropFirst()
        return "khoảng \(timeFormatter.string(from: date)) \(period) \(formattedWeekday) \(dateFormatter.string(from: date)) giờ Việt Nam"
    }

    timeFormatter.dateFormat = "h:mm a"
    dateFormatter.dateFormat = "MM/dd"
    let weekday = symbolFormatter.weekdaySymbols[(components.weekday ?? 1) - 1]
    return "around \(timeFormatter.string(from: date)) \(weekday), \(dateFormatter.string(from: date))"
}

struct AddAccountSheet: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: AddAccountMode = .enrollOnly
    @State private var didStartLogin = false

    private var isChoosingMode: Bool {
        !didStartLogin && store.newAccountLoginState == .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(language.text("Thêm tài khoản", "Add account"), systemImage: "plus.circle.fill")
                .font(RosterSecondaryChrome.title)
                .foregroundStyle(.tint)

            if isChoosingMode {
                modeChooser
            } else {
                progressBody
            }
        }
        .padding(RosterSecondaryChrome.contentPadding)
        .frame(width: RosterSecondaryChrome.sheetWidth)
        .interactiveDismissDisabled(store.isPendingLogin)
        .onAppear {
            // Resume an in-flight login (app relaunch / sheet reopen).
            if store.isPendingLogin || store.newAccountLoginState != .idle {
                didStartLogin = true
                selectedMode = store.pendingAddAccountMode ?? .addAndSwitch
                if case .ready = store.newAccountLoginState {
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        store.saveDetectedNewAccount()
                    }
                }
            }
        }
        .onChange(of: store.newAccountLoginState) { _, state in
            if case .ready = state {
                Task {
                    // A resumed login can publish `.ready` just before the
                    // launcher operation releases its busy flag.
                    try? await Task.sleep(for: .milliseconds(150))
                    store.saveDetectedNewAccount()
                }
            } else if case .saved = state {
                Task {
                    try? await Task.sleep(for: .milliseconds(1_200))
                    dismiss()
                }
            }
        }
        .background {
            Color.clear
        }
    }

    @ViewBuilder
    private var modeChooser: some View {
        Text(language.text(
            "Chọn rõ trước khi đăng nhập — tránh giữ phiên cũ khi bạn muốn chuyển, và tránh đổi phiên khi bạn chỉ muốn thêm vào danh sách.",
            "Choose explicitly before signing in — avoid staying on the old account when you meant to switch, and avoid switching when you only wanted to enroll."
        ))
        .foregroundStyle(.secondary)

        Picker(selection: $selectedMode) {
            Text(language.text("Chỉ thêm · không đổi phiên", "Add only · don’t switch"))
                .tag(AddAccountMode.enrollOnly)
            Text(language.text("Thêm & chuyển", "Add & switch"))
                .tag(AddAccountMode.addAndSwitch)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(modeDetailTitle)
                    .font(RosterSecondaryChrome.section)
                Text(modeDetailBody)
                    .font(RosterSecondaryChrome.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }

        if selectedMode == .enrollOnly, CodexLoginPort.isBusy {
            Label(language.text(
                "Cổng 1455/1457 đang bận — Chỉ thêm sẽ báo lỗi trừ khi bạn thoát Desktop trước (hoặc chọn Thêm & chuyển).",
                "Ports 1455/1457 are busy — Add only will fail unless you quit Desktop first (or choose Add & switch)."
            ), systemImage: "exclamationmark.triangle.fill")
            .font(RosterSecondaryChrome.footnote)
            .foregroundStyle(.orange)
        }

        HStack {
            Spacer()
            Button(language.text("Đóng", "Close")) {
                dismiss()
            }
            Button(startButtonTitle) {
                didStartLogin = true
                store.startNewAccountLogin(mode: selectedMode)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusyForActions)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var progressBody: some View {
        Text(progressIntro)
            .foregroundStyle(.secondary)

        GroupBox {
            HStack(spacing: 12) {
                if isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(RosterSecondaryChrome.iconLarge)
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(progressTitle).font(RosterSecondaryChrome.section)
                    Text(saveStatusText)
                        .font(RosterSecondaryChrome.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }

        if case let .saved(identity) = store.newAccountLoginState {
            Label(language.text(
                selectedMode == .enrollOnly
                    ? "Đã lưu \(identity.email) vào roster. Phiên đang dùng không đổi."
                    : "Đã lưu \(identity.email) vào Codex Roster.",
                selectedMode == .enrollOnly
                    ? "Saved \(identity.email) to the roster. The live session is unchanged."
                    : "Saved \(identity.email) to Codex Roster."
            ), systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else if case let .failed(message) = store.newAccountLoginState {
            Text(message)
                .font(RosterSecondaryChrome.footnote)
                .foregroundStyle(.red)
        }

        Label(progressSafetyNote, systemImage: "lock.shield")
            .font(RosterSecondaryChrome.footnote)
            .foregroundStyle(.secondary)

        HStack {
            if case .failed = store.newAccountLoginState {
                Button(language.text("Thử lại", "Try again")) {
                    store.resetNewAccountLogin()
                    didStartLogin = false
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
            Button(store.isPendingLogin
                ? language.text("Hủy", "Cancel")
                : language.text("Đóng", "Close")) {
                if store.isPendingLogin {
                    store.cancelPendingLogin()
                } else {
                    store.resetNewAccountLogin()
                }
                dismiss()
            }
            .disabled(store.isWorking)
        }
    }

    private var startButtonTitle: String {
        switch selectedMode {
        case .enrollOnly:
            return language.text("Thêm (giữ phiên)", "Add (keep session)")
        case .addAndSwitch:
            return language.text("Thêm & chuyển", "Add & switch")
        }
    }

    private var modeDetailTitle: String {
        switch selectedMode {
        case .enrollOnly:
            return language.text("Chỉ ghi vào roster", "Roster snapshot only")
        case .addAndSwitch:
            return language.text("Đăng nhập thành phiên đang dùng", "Become the live session")
        }
    }

    private var modeDetailBody: String {
        switch selectedMode {
        case .enrollOnly:
            return language.text(
                "Đăng nhập vào thư mục tạm (CODEX_HOME riêng), import auth.json vào roster. Không ghi đè ~/.codex, không tắt Desktop, không kích hoạt / auto-resume tài khoản mới. Nếu cổng 1455/1457 đang bị Desktop giữ — không thể Chỉ thêm.",
                "Signs in under an isolated CODEX_HOME, then imports auth.json into the roster. Does not overwrite ~/.codex, quit Desktop, or activate / auto-resume the new account. If ports 1455/1457 are held by Desktop, Add only cannot run."
            )
        case .addAndSwitch:
            return language.text(
                "Sao lưu phiên hiện tại, đăng nhập vào ~/.codex (có thể đóng Desktop nếu cổng login bận), rồi để credential mới làm phiên live. Hủy sẽ khôi phục phiên trước.",
                "Backs up the current session, signs into ~/.codex (may quit Desktop if login ports are busy), and leaves the new credential as the live session. Cancel restores the previous session."
            )
        }
    }

    private var progressIntro: String {
        switch selectedMode {
        case .enrollOnly:
            return language.text(
                "Hoàn tất đăng nhập OpenAI trong cửa sổ vừa mở. Roster lưu snapshot rồi giữ nguyên phiên đang dùng.",
                "Finish signing in to OpenAI in the window that just opened. Roster saves a snapshot and keeps the current live session."
            )
        case .addAndSwitch:
            return language.text(
                "Hoàn tất đăng nhập OpenAI trong cửa sổ vừa mở. Roster sẽ tự nhận diện và lưu tài khoản mới làm phiên hiện tại.",
                "Finish signing in to OpenAI in the window that just opened. Roster will detect and save the new account as the live session."
            )
        }
    }

    private var progressSafetyNote: String {
        switch selectedMode {
        case .enrollOnly:
            return language.text(
                "Phiên live và Desktop không bị đụng tới. Hủy chỉ xóa thư mục đăng nhập tạm.",
                "The live session and Desktop are left alone. Cancel only discards the temporary login home."
            )
        case .addAndSwitch:
            return language.text(
                "Phiên Codex hiện tại được sao lưu trước khi đăng nhập mới. Hủy sẽ khôi phục phiên trước.",
                "The current Codex session is backed up before a new sign-in. Cancel restores the previous session."
            )
        }
    }

    private var isFinished: Bool {
        if case .saved = store.newAccountLoginState { return true }
        return false
    }

    private var progressTitle: String {
        switch store.newAccountLoginState {
        case .idle, .waiting: return language.text("Đang chờ đăng nhập", "Waiting for sign-in")
        case .ready, .saving: return language.text("Đang tự động lưu", "Saving automatically")
        case .saved: return language.text("Đã thêm tài khoản", "Account added")
        case .failed: return language.text("Chưa thể hoàn tất", "Could not finish")
        }
    }

    private var saveStatusText: String {
        switch store.newAccountLoginState {
        case .idle:
            return language.text("Đang mở trang đăng nhập OpenAI…", "Opening OpenAI sign-in…")
        case .waiting:
            return language.text(
                selectedMode == .enrollOnly
                    ? "Không cần bấm thêm — Roster đang theo dõi credential trong thư mục tạm."
                    : "Không cần bấm thêm — Roster đang theo dõi phiên Codex.",
                selectedMode == .enrollOnly
                    ? "No more clicks needed — Roster is watching credentials in the temporary home."
                    : "No more clicks needed — Roster is watching the Codex session."
            )
        case .ready(let identity):
            return language.text("Đã nhận diện \(identity.email).", "Detected \(identity.email).")
        case .saving:
            return language.text("Đang lưu và cập nhật quota…", "Saving and refreshing quota…")
        case .saved(let identity):
            return language.text("Đã lưu: \(identity.email)", "Saved: \(identity.email)")
        case .failed:
            return language.text("Không thể chuẩn bị login. Hãy thử lại.", "Could not prepare sign-in. Try again.")
        }
    }
}

private struct AccountDetail: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount
    let home: () -> Void
    let activate: () -> Void
    let edit: () -> Void
    let archive: () -> Void
    let restore: () -> Void
    /// Must receive the detail's current `account` at tap time — never a parent-captured
    /// `selected` snapshot that can diverge after roster refresh / selection changes.
    let remove: (SavedAccount) -> Void
    /// Same capture rule as remove — Login must target this detail's account, not selection.
    let relogin: (SavedAccount) -> Void

    private var isArchived: Bool { store.isArchived(account) }
    private var serverSessionRevoked: Bool {
        account.usageError?.localizedCaseInsensitiveContains("[server_session_revoked]") == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(PrismTheme.quotaTint(percent: account.usage?.fiveHour?.displayRemainingPercent).opacity(0.18))
                                .frame(width: 52, height: 52)
                            Image(systemName: account.aiProvider.icon)
                                .font(PrismTheme.fontDisplay)
                                .foregroundStyle(PrismTheme.quotaTint(percent: account.usage?.fiveHour?.displayRemainingPercent))
                        }
                        .overlay(
                            Circle()
                                .strokeBorder(PrismTheme.quotaTint(percent: account.usage?.fiveHour?.displayRemainingPercent).opacity(0.4), lineWidth: 1.5)
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Label(account.isActive ? language.text("Tài khoản đang dùng", "Active account") : language.text("Tài khoản đã lưu", "Saved account"), systemImage: account.isActive ? "checkmark.seal.fill" : "person.crop.circle")
                                .foregroundStyle(account.isActive ? .green : .secondary)
                            Text(account.displayName)
                                .font(.largeTitle.weight(.bold))
                            HStack(spacing: 8) {
                                Text(account.email)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button {
                                    copyAccountEmail(account.email)
                                } label: {
                                    Label(language.text("Sao chép", "Copy"), systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help(language.text("Sao chép địa chỉ email", "Copy email address"))
                            }
                        }
                    }
                    Spacer()
                    Button(language.text("Sửa", "Edit"), action: edit)
                    .disabled(store.isBusyForActions)
                    Button(isArchived ? language.text("Khôi phục", "Restore") : language.text("Lưu trữ", "Archive")) {
                        isArchived ? restore() : archive()
                    }
                    .disabled(store.isBusyForActions)
                    Menu {
                        Button(language.text("Sao chép email", "Copy email")) {
                            copyAccountEmail(account.email)
                        }
                        Divider()
                        Button(language.text("Xóa tài khoản", "Remove account"), role: .destructive) {
                            remove(account)
                        }
                            .disabled(store.isBusyForActions)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(language.text("Thao tác khác", "More actions"))
                    .accessibilityLabel(language.text("Thao tác khác", "More actions"))
                    if !isArchived && account.requiresLogin {
                        Button(language.text("Đăng nhập lại", "Sign in again")) {
                            relogin(account)
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(store.isBusyForActions)
                    } else if !isArchived && !account.isActive
                                && !account.requiresLogin && !account.requiresLocalRecovery {
                        Button(language.text("Chuyển sang tài khoản này", "Activate"), action: activate)
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isBusyForActions)
                    }
                }

                SessionDiagnosticsPanel(account: account)

                HStack(alignment: .top, spacing: 12) {
                    UsageCard(
                        title: language.text("Quota 5 giờ", "5-hour quota"),
                        window: account.usage?.fiveHour
                    )
                    UsageCard(
                        title: language.text("Quota tuần", "Weekly quota"),
                        window: account.usage?.weekly
                    )
                }

                if let resets = account.usage?.bankedResets {
                    BankedResetCard(summary: resets)
                }

                if account.hasLunaReserve {
                    LunaReserveCard(account: account)
                }

                if let credits = account.usage?.credits,
                   credits.unlimited || credits.hasDisplayableBalance || credits.creditLimit != nil
                {
                    GroupBox(language.text("Tín dụng ChatGPT", "ChatGPT credits")) {
                        if credits.unlimited || credits.hasDisplayableBalance {
                            HStack {
                                Label(
                                    credits.unlimited
                                        ? language.text("Không giới hạn", "Unlimited")
                                        : language.text("Số dư: \(credits.balance)", "Balance: \(credits.balance)"),
                                    systemImage: "creditcard"
                                )
                                Spacer()
                                Text(language.text("Có thể mở rộng quota Codex", "Can extend Codex quota"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let creditLimit = credits.creditLimit {
                            HStack {
                                Label(
                                    language.text(
                                        "Hạn mức tháng: \(creditLimit.displayText)",
                                        "Monthly cap: \(creditLimit.displayText)"),
                                    systemImage: "chart.bar"
                                )
                                Spacer()
                                Text(language.text(
                                    "Còn \(Int(creditLimit.remainingPercent.rounded()))%",
                                    "\(Int(creditLimit.remainingPercent.rounded()))% left"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if account.requiresLogin {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            serverSessionRevoked
                                ? language.text("OpenAI đã thu hồi phiên OAuth của tài khoản này.", "OpenAI revoked this account's OAuth session.")
                                : language.text("Phiên Codex của tài khoản này đã hết hạn hoặc bị đăng xuất.", "This account's Codex session expired or was logged out."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                            .foregroundStyle(.orange)
                        Text(language.text(
                            serverSessionRevoked
                                ? "Dữ liệu Roster vẫn còn nguyên; chỉ credential phía server không còn hiệu lực. Đăng nhập lại bằng đúng email \(account.email)."
                                : "Đăng nhập lại bằng đúng email \(account.email), rồi lưu phiên mới vào Codex Roster.",
                            serverSessionRevoked
                                ? "Roster data is intact; only the server credential is no longer valid. Sign in again with \(account.email)."
                                : "Sign in again with \(account.email), then save the new session into Codex Roster."
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Button(language.text("Bắt đầu đăng nhập lại…", "Start sign-in again…")) {
                            relogin(account)
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(store.isBusyForActions || isArchived)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                if account.requiresLocalRecovery {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(language.text(
                            "Snapshot cục bộ không thể giải mã — chưa cần đăng nhập lại.",
                            "The local snapshot could not be decrypted — do not sign in again yet."
                        ), systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.red)
                        Text(language.text(
                            "Hãy dùng Khôi phục phiên sao lưu ở Tổng quan. Chỉ đăng nhập lại nếu không còn bản sao hợp lệ.",
                            "Use Restore saved sessions from Overview. Sign in again only if no valid backup remains."
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                GroupBox(language.text("Chi tiết tài khoản", "Account details")) {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                        GridRow { Text(language.text("Tên hiển thị", "Display name")).foregroundStyle(.secondary); Text(account.displayName) }
                        GridRow {
                            Text(language.text("Email", "Email")).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(account.email)
                                    .textSelection(.enabled)
                                Button {
                                    copyAccountEmail(account.email)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help(language.text("Sao chép địa chỉ email", "Copy email address"))
                                .accessibilityLabel(language.text("Sao chép địa chỉ email", "Copy email address"))
                            }
                        }
                        GridRow { Text(language.text("Gói ChatGPT", "ChatGPT plan")).foregroundStyle(.secondary); Text(account.planLabel ?? language.text("Chưa có", "Not available")) }
                        GridRow {
                            Text(language.text("Gói hiệu lực đến", "Plan active until")).foregroundStyle(.secondary)
                            Text(account.paidSubscriptionActiveUntil?.formatted(
                                Date.FormatStyle(date: .long, time: .shortened).locale(language.language.locale)
                            ) ?? language.text("Chưa có dữ liệu", "Not available"))
                        }
                        GridRow { Text(language.text("Trạng thái", "Status")).foregroundStyle(.secondary); Text(account.usageStatus(in: language.language)) }
                        GridRow {
                            Text(language.text("Quota xác minh gần nhất", "Last quota verification")).foregroundStyle(.secondary)
                            Text(account.lastVerifiedAt?.formatted(date: .abbreviated, time: .standard)
                                ?? language.text("Chưa có", "Not available"))
                        }
                        GridRow {
                            Text(language.text("Kích hoạt gần nhất", "Last activated")).foregroundStyle(.secondary)
                            Text(account.lastActivatedAt?.value.formatted(date: .abbreviated, time: .standard)
                                ?? language.text("Chưa có", "Not available"))
                        }
                        GridRow { Text(language.text("Môi trường", "Environment")).foregroundStyle(.secondary); Text(account.environment.capitalized) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button {
                        store.refreshUsage(for: account)
                    } label: {
                        Label(language.text("Cập nhật quota", "Refresh usage"), systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isBusyForActions || isArchived)
                }
            }
            .padding(32)
        }
        .navigationTitle(account.email)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: home) {
                    Label(language.text("Tổng quan", "Overview"), systemImage: "star")
                }
                .help(language.text("Quay về trang tổng quan", "Return to overview"))
            }
        }
        .background {
            Color.clear
        }
    }
}

private struct SessionDiagnosticsPanel: View {
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount

    private var sessionTitle: String {
        if account.requiresLogin {
            return language.text("Cần đăng nhập", "Sign-in required")
        }
        if account.requiresLocalRecovery {
            return language.text("Cần phục hồi local", "Local recovery")
        }
        if account.hasTransientUsageError {
            return language.text("Lỗi kiểm tra tạm thời", "Temporary check error")
        }
        return language.text("Chưa ghi nhận thu hồi", "No revocation detected")
    }

    private var sessionIcon: String {
        if account.requiresLogin { return "person.crop.circle.badge.exclamationmark" }
        if account.requiresLocalRecovery { return "externaldrive.badge.exclamationmark" }
        if account.hasTransientUsageError { return "wifi.exclamationmark" }
        return "checkmark.shield.fill"
    }

    private var sessionColor: Color {
        if account.requiresLogin { return .orange }
        if account.requiresLocalRecovery { return .red }
        if account.hasTransientUsageError { return .orange }
        return .green
    }

    private var quotaTitle: String {
        guard let verifiedAt = account.lastVerifiedAt else {
            return language.text("Chưa xác minh", "Not verified")
        }
        if account.hasTransientUsageError {
            return language.text("Giữ kết quả tốt gần nhất", "Last good result kept")
        }
        return language.text(
            "Xác minh \(verifiedAt.formatted(date: .omitted, time: .shortened))",
            "Verified \(verifiedAt.formatted(date: .omitted, time: .shortened))"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(language.text("Chẩn đoán phiên", "Session diagnostics"), systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                Text(language.text("Không coi lỗi quota là logout", "Quota errors are not sign-outs"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { diagnosticItems }
                VStack(spacing: 8) { diagnosticItems }
            }
        }
        .padding(16)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var diagnosticItems: some View {
        DiagnosticMetric(
            title: language.text("Roster", "Roster"),
            value: language.text("Snapshot đã lưu", "Snapshot saved"),
            detail: language.text("Dữ liệu tài khoản còn nguyên", "Account data is intact"),
            icon: "externaldrive.fill.badge.checkmark",
            tint: .green
        )
        DiagnosticMetric(
            title: language.text("Phiên server", "Server session"),
            value: sessionTitle,
            detail: account.requiresLogin
                ? language.text("Chỉ login lại khi server xác nhận", "Re-login only after server confirmation")
                : language.text("Không suy diễn từ lỗi mạng", "Network errors do not imply logout"),
            icon: sessionIcon,
            tint: sessionColor
        )
        DiagnosticMetric(
            title: language.text("Quota", "Quota"),
            value: quotaTitle,
            detail: account.hasTransientUsageError
                ? language.text("Snapshot không bị thay đổi", "Snapshot remains unchanged")
                : language.text("Tách riêng cửa sổ 5 giờ và tuần", "Separate 5-hour and weekly windows"),
            icon: account.hasTransientUsageError ? "wifi.exclamationmark" : "gauge.with.dots.needle.67percent",
            tint: account.hasTransientUsageError ? .orange : .accentColor
        )
        DiagnosticMetric(
            title: language.text("Live session", "Live session"),
            value: account.isActive
                ? language.text("Đang dùng", "Active now")
                : language.text("Đã lưu, chưa nạp", "Saved, not loaded"),
            detail: language.text("Theo ~/.codex", "Based on ~/.codex"),
            icon: account.isActive ? "checkmark.circle.fill" : "person.crop.circle",
            tint: account.isActive ? .green : .secondary
        )
    }
}

private struct DiagnosticMetric: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ReloginAccountSheet: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    let account: SavedAccount
    let queuedCount: Int
    let cancelQueue: () -> Void
    @State private var didStart = false
    @State private var isCompleting = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(language.text("Đăng nhập lại", "Sign in again"), systemImage: "arrow.triangle.2.circlepath")
                .font(RosterSecondaryChrome.title)
                .foregroundStyle(.orange)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(language.text(
                    "Đăng nhập \(account.email) trong cửa sổ vừa mở. Roster sẽ tự xác minh và cập nhật phiên này.",
                    "Sign in as \(account.email) in the window that just opened. Roster will verify and update this session automatically."
                ))
                .font(RosterSecondaryChrome.body)
                .foregroundStyle(.secondary)
                Button {
                    copyAccountEmail(account.email)
                } label: {
                    Label(language.text("Sao chép email", "Copy email"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }

            GroupBox {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isCompleting
                            ? language.text("Đang tự động cập nhật", "Updating automatically")
                            : language.text("Đang chờ đúng tài khoản", "Waiting for the correct account"))
                            .font(RosterSecondaryChrome.section)
                        Text(isCompleting
                            ? language.text("Đang lưu phiên và kiểm tra lại quota…", "Saving the session and checking quota…")
                            : language.text("Không cần tải lại hay bấm Lưu — Roster tự hoàn tất khi nhận diện \(account.email).", "No reload or Save click needed — Roster finishes when it detects \(account.email)."))
                            .font(RosterSecondaryChrome.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if queuedCount > 0 {
                Label(language.text(
                    "Sau tài khoản này, Roster tự mở lần lượt \(queuedCount) tài khoản còn lại.",
                    "After this account, Roster will automatically open the remaining \(queuedCount) accounts in sequence."
                ), systemImage: "list.number")
                .font(RosterSecondaryChrome.footnote.weight(.medium))
                .foregroundStyle(.tint)
            }

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .font(RosterSecondaryChrome.footnote)
                    .foregroundStyle(.orange)
            }

            Label(language.text(
                "Phiên Codex đang dùng được sao lưu trước khi mở đăng nhập mới. Hủy sẽ khôi phục phiên trước. Phải đăng nhập đúng \(account.email).",
                "The current Codex session is backed up before the new sign-in. Cancel restores it. You must sign in as \(account.email)."
            ), systemImage: "lock.shield")
            .font(RosterSecondaryChrome.footnote)
            .foregroundStyle(.secondary)

            HStack {
                if localError != nil {
                    Button(language.text("Thử lại", "Try again")) {
                        localError = nil
                        isCompleting = false
                        store.startRelogin(for: account)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                Spacer()
                Button(store.isPendingLogin
                    ? language.text("Hủy", "Cancel")
                    : language.text("Đóng", "Close")) {
                    if store.isPendingLogin {
                        cancelQueue()
                        store.cancelPendingLogin()
                    } else {
                        cancelQueue()
                    }
                    dismiss()
                }
                .disabled(isCompleting || store.isWorking)
            }
        }
        .padding(24)
        .frame(width: RosterSecondaryChrome.sheetWidth)
        .interactiveDismissDisabled(store.isPendingLogin || isCompleting)
        .onAppear {
            guard !didStart else { return }
            didStart = true
            store.startRelogin(for: account)
        }
        .onChange(of: store.newAccountLoginState) { _, state in
            switch state {
            case .ready where !isCompleting:
                isCompleting = true
                Task {
                    do {
                        // Let the login launcher release its action lock before
                        // verification starts on a resumed session.
                        try? await Task.sleep(for: .milliseconds(150))
                        localError = nil
                        try await store.completeRelogin(for: account)
                        dismiss()
                    } catch {
                        isCompleting = false
                        localError = error.localizedDescription
                    }
                }
            case .failed(let message):
                isCompleting = false
                localError = message
            default:
                break
            }
        }
        .background {
            Color.clear
        }
    }
}

struct AccountEditorSheet: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    let account: SavedAccount
    @State private var label: String

    init(account: SavedAccount) {
        self.account = account
        _label = State(initialValue: account.customLabel ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(language.text("Sửa tài khoản", "Edit account"), systemImage: "pencil.circle.fill")
                .font(RosterSecondaryChrome.title)
                .foregroundStyle(.tint)
            Text(account.email)
                .font(RosterSecondaryChrome.body)
                .foregroundStyle(.secondary)

            Form {
                TextField(language.text("Tên hiển thị", "Display name"), text: $label, prompt: Text(account.name ?? account.email))
            }
            .formStyle(.grouped)

            Text(language.text(
                "Đặt tên để dễ nhận biết tài khoản.",
                "Choose a name that makes the account easy to recognize."
            ))
            .font(RosterSecondaryChrome.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(language.text("Hủy", "Cancel")) { dismiss() }
                Spacer()
                Button(language.text("Lưu thay đổi", "Save changes")) {
                    store.updateAccount(account, label: label)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isWorking)
            }
        }
        .padding(24)
        .frame(width: RosterSecondaryChrome.sheetWidth)
        .background {
            Color.clear
        }
    }
}

private struct UsageCard: View {
    @EnvironmentObject private var language: LanguageStore
    let title: String
    let window: UsageWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let window {
                Text(language.text("Còn \(window.displayRemainingPercent)%", "\(window.displayRemainingPercent)% remaining"))
                    .font(.title2.weight(.semibold))
                ProgressView(value: Double(window.displayRemainingPercent), total: 100)
                    .tint(window.isDepleted ? .red : (window.remainingPercent < 20 ? .orange : .accentColor))
                Text(language.text("Đặt lại \(window.resetAt.value.formatted(date: .abbreviated, time: .shortened))", "Resets \(window.resetAt.value.formatted(date: .abbreviated, time: .shortened))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(language.text("Chưa có quota", "Quota not checked"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(18)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct BankedResetCard: View {
    @EnvironmentObject private var language: LanguageStore
    let summary: BankedResetSummary

    private var availableCount: Int { summary.totalAvailableCount }
    private var visibleCredits: [BankedResetCredit] { summary.credits ?? [] }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(language.text("Banked reset", "Banked resets"), systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.headline)
                        .foregroundStyle(availableCount > 0 ? Color.accentColor : Color.secondary)
                    Spacer()
                    Text("\(availableCount)")
                        .font(.title2.monospacedDigit().weight(.bold))
                    Text(language.text("khả dụng", "available"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if availableCount == 0 {
                    Text(language.text(
                        "Tài khoản hiện không có lượt đặt lại quota đã lưu.",
                        "This account currently has no saved quota resets."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else if visibleCredits.isEmpty {
                    Label(language.text(
                        "OpenAI đã trả về số lượt nhưng chưa cung cấp chi tiết ngày hết hạn.",
                        "OpenAI returned the count but no expiry details."
                    ), systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleCredits) { credit in
                        BankedResetCreditRow(credit: credit)
                        if credit.id != visibleCredits.last?.id {
                            Divider()
                        }
                    }
                    if availableCount > visibleCredits.count {
                        Text(language.text(
                            "+\(availableCount - visibleCredits.count) lượt khác chưa có chi tiết từ backend",
                            "+\(availableCount - visibleCredits.count) more without backend details"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Label(language.text(
                    "Dữ liệu riêng của tài khoản, được kiểm tra cùng lúc với quota. Chỉ hiển thị — Roster không tự dùng lượt reset.",
                    "Private account data checked with quota. Display only — Roster never redeems a reset automatically."
                ), systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

private struct LunaReserveCard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount

    private var isLunaActive: Bool {
        store.isLunaReserveActive(for: account)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Luna Reserve (GPT-5.6 Luna)", systemImage: "moon.stars.fill")
                        .font(.headline)
                        .foregroundStyle(PrismTheme.autoSwitch)
                    Spacer()
                    if isLunaActive {
                        Text(language.text("Đang hoạt động", "Active in Codex"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PrismTheme.emerald)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(PrismTheme.emerald.opacity(0.16)))
                    } else if account.isLunaReserveAllowed {
                        Text(language.text("Sẵn sàng bật", "Ready to enable"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PrismTheme.autoSwitch)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(PrismTheme.autoSwitch.opacity(0.16)))
                    }
                }

                Text(language.text(
                    "Hạn mức dự phòng khẩn cấp khi hết quota chính của tài khoản Plus/Pro. Cho phép tiếp tục code với model GPT-5.6 Luna.",
                    "Emergency fallback allowance when primary quota is exhausted on Plus/Pro. Allows continued coding with GPT-5.6 Luna."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    if let used = account.usage?.lunaReserve?.usedPercent {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("Đã dùng", "Used"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(used)%")
                                .font(.subheadline.weight(.semibold))
                        }
                    }

                    if let resetAt = account.usage?.lunaReserve?.resetAt {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("Đặt lại", "Resets"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(resetAt.value.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline.weight(.semibold))
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("Model", "Model"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(account.usage?.lunaReserve?.modelSlug ?? "gpt-5.6-luna")
                            .font(.subheadline.weight(.semibold).monospaced())
                    }

                    Spacer()

                    if !isLunaActive && account.isLunaReserveAllowed {
                        Button {
                            PrismTheme.triggerHaptic()
                            store.enableLunaReserve(account)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "moon.stars.fill")
                                Text(language.text("Bật Luna Reserve", "Enable Luna Reserve"))
                            }
                            .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PrismTheme.autoSwitch)
                        .disabled(store.isBusyForActions)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

private struct BankedResetCreditRow: View {
    @EnvironmentObject private var language: LanguageStore
    let credit: BankedResetCredit

    private var title: String {
        if let value = credit.title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return language.text("Đặt lại toàn bộ quota Codex", "Full Codex quota reset")
    }

    private var statusColor: Color {
        switch credit.status {
        case "available": return .green
        case "redeeming": return .orange
        case "redeemed": return .secondary
        default: return .secondary
        }
    }

    private var statusText: String {
        switch credit.status {
        case "available": return language.text("Sẵn sàng", "Available")
        case "redeeming": return language.text("Đang sử dụng", "Redeeming")
        case "redeemed": return language.text("Đã sử dụng", "Redeemed")
        default: return language.text("Chưa rõ", "Unknown")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }
                if let description = credit.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text(language.text(
                        "Được cấp \(credit.grantedAt.value.formatted(date: .abbreviated, time: .omitted))",
                        "Granted \(credit.grantedAt.value.formatted(date: .abbreviated, time: .omitted))"
                    ))
                    if let expiry = credit.expiresAt?.value {
                        HStack(spacing: 4) {
                            Text(language.text("Hết hạn", "Expires"))
                            Text(expiry, style: .relative)
                                .fontWeight(.semibold)
                            Text("· \(expiry.formatted(date: .abbreviated, time: .shortened))")
                        }
                        .foregroundStyle(expiry < Date() ? PrismTheme.danger : Color.secondary)
                    } else {
                        Text(language.text("Không có ngày hết hạn", "No expiry reported"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var updater: GitHubUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PrismQuickSwitchDeck(
            openSettings: openSettings,
            openOperations: openOperations,
            openAddAccountFlow: openAddAccountFlow,
            openReloginFlow: openReloginFlow,
            openBackupFlow: openBackupFlow,
            openEditAccount: openEditAccount,
            openAbout: openAbout
        )
        .onAppear {
            refreshMenuBar()
        }
    }

    private func openSettings() {
        // Named console window (not Settings scene): LSUIElement/.accessory apps
        // often never surface showSettingsWindow:. Notch is `.statusBar`, so
        // elevate the hub above it and collapse the panel first.
        RosterConsolePresenter.open(.settings, using: openWindow)
    }

    private func openOperations() {
        RosterConsolePresenter.open(.operations, using: openWindow)
    }

    private func openReloginFlow(_ accountID: UUID) {
        // Always post the clicked row's ID — never substitute "first requiresLogin".
        guard let id = accountIDForReloginNotification(in: store.accounts, capturedID: accountID) else { return }
        NotificationCenter.default.post(name: .showReloginAccount, object: id.uuidString)
    }

    private func openAddAccountFlow() {
        NotificationCenter.default.post(name: .showAddAccount, object: nil)
    }

    private func openBackupFlow(_ op: BackupOperation) {
        RosterConsolePresenter.open(op == .export ? .exportBackup : .importBackup, using: openWindow)
    }

    private func openEditAccount(_ account: SavedAccount) {
        NotificationCenter.default.post(name: .editAccount, object: account.id.uuidString)
    }

    private func openAbout() {
        RosterConsolePresenter.open(.about, using: openWindow)
    }

    private func refreshMenuBar() {
        store.refreshAccountsInBackground()
        store.refreshProviderStatus(silently: true)
        store.refreshOpenAIStatus(silently: true)
        store.refreshResetOutlook(silently: true)
    }
}

private struct MenuBarLiveSignals: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    private var openAITint: Color {
        guard let status = store.openAIStatus else { return .secondary }
        return status.isOperational ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                if store.isLoadingOpenAIStatus && store.openAIStatus == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(openAITint)
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenAI")
                        .font(.caption.weight(.semibold))
                    Text(openAIStatusText)
                        .font(.caption)
                        .foregroundStyle(openAITint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 28)

            HStack(spacing: 7) {
                if store.isLoadingResetOutlook && store.resetOutlook == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(rosterActionBlue)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.text("Reset outlook", "Reset outlook"))
                        .font(.caption.weight(.semibold))
                    Text(resetSignalText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
        .help(language.text(
            "Trạng thái OpenAI và tín hiệu reset công khai được làm mới khi mở menu. Quota tài khoản vẫn là xác nhận cuối cùng.",
            "OpenAI status and public reset signals refresh when the menu opens. Account quota remains the source of truth."
        ))
    }

    private var openAIStatusText: String {
        guard let status = store.openAIStatus else {
            return language.text("Đang kiểm tra", "Checking")
        }
        return status.isOperational
            ? language.text("Ổn định", "Operational")
            : language.text("Có sự cố", "Incident")
    }

    private var resetSignalText: String {
        guard let outlook = store.resetOutlook else {
            return language.text("Đang theo dõi", "Monitoring")
        }
        if let signalPercent = outlook.signalPercent {
            return language.text("Tín hiệu \(signalPercent)%", "Signal \(signalPercent)%")
        }
        return "\(outlook.chance24Hours)% / 24H"
    }
}

private struct MenuBarUpdateStatus: View {
    @EnvironmentObject private var updater: GitHubUpdater
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        switch updater.state {
        case .available(let update):
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.app.fill")
                    .foregroundStyle(Color.accentColor)
                Text(language.text("Có bản \(update.version)", "Version \(update.version) available"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(language.text("Cập nhật", "Update")) {
                    updater.installAvailableUpdate()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

        case .checking, .downloading, .installing:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

        case .failed:
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(language.text("Không thể kiểm tra cập nhật", "Could not check for updates"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(language.text("Thử lại", "Retry")) {
                    updater.checkForUpdates(currentVersion: AppInfo.shortVersion)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(PrismTheme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))

        case .idle, .upToDate:
            EmptyView()
        }
    }

    private var statusText: String {
        switch updater.state {
        case .checking:
            language.text("Đang kiểm tra cập nhật…", "Checking for updates…")
        case .downloading:
            language.text("Đang tải và xác thực cập nhật…", "Downloading and verifying update…")
        case .installing:
            language.text("Đang cài đặt và mở lại app…", "Installing and reopening app…")
        default:
            ""
        }
    }
}

private struct MenuBarOperationStatus: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    private var message: String {
        if let resume = store.sessionResumeCaption {
            return resume
        }
        if let phase = store.switchPhaseMessage {
            return phase
        }
        if store.isSwitching {
            return language.text("Đang chuyển tài khoản…", "Switching account…")
        }
        if store.isWorking {
            return language.text("Đang cập nhật…", "Updating…")
        }
        if store.isCheckingAutoSwitch {
            return language.text("Đang kiểm tra quota…", "Checking quota…")
        }
        if store.errorMessage != nil {
            return language.text("Cập nhật thất bại", "Update failed")
        }
        guard let state = store.autoSwitchState else { return "" }
        switch state {
        case .waitingForLogin:
            return language.text("Tự động chuyển tạm dừng khi đang đăng nhập", "Auto-switch paused while signing in")
        case .allAccountsExhausted:
            return language.text("Tất cả tài khoản đều hết quota", "All accounts are out of quota")
        case .bankedResetAvailable(let account, let count, _):
            return language.text(
                "\(account) còn \(count) banked reset cần dùng",
                "\(account) has \(count) banked reset to redeem"
            )
        case .closingDesktop:
            return language.text("Đang đóng ChatGPT để tự chuyển…", "Closing ChatGPT to auto-switch…")
        case .switchingAccount:
            return language.text("Đang chuyển phiên Codex…", "Switching Codex session…")
        case .relaunchingDesktop:
            return language.text("Đang mở lại ChatGPT…", "Relaunching ChatGPT…")
        case .desktopRelaunchFailed:
            return language.text("Đã chuyển phiên, nhưng không mở lại được ChatGPT", "Session switched, but ChatGPT did not relaunch")
        case .waitingForProcesses:
            return language.text("Không đóng được ChatGPT — đóng thủ công", "Could not quit ChatGPT — quit manually")
        case .switched(let name):
            return language.text("Đã chuyển sang \(name)", "Switched to \(name)")
        case .checkFailed:
            return language.text("Không thể kiểm tra/chuyển quota", "Quota check/switch failed")
        case .generationInProgress:
            return language.text("Đang tạo phản hồi — chờ phiên yên", "Generating — waiting for idle")
        }
    }

    private var tint: Color {
        if store.isBusyForActions || store.isCheckingAutoSwitch { return .secondary }
        if store.errorMessage != nil { return .orange }
        switch store.autoSwitchState {
        case .some(.switched): return .green
        case .some(.closingDesktop), .some(.switchingAccount), .some(.relaunchingDesktop),
             .some(.generationInProgress): return .secondary
        case .some(.waitingForLogin), .some(.allAccountsExhausted), .some(.bankedResetAvailable), .some(.desktopRelaunchFailed), .some(.waitingForProcesses), .some(.checkFailed): return .orange
        case .none: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if store.isBusyForActions || store.isCheckingAutoSwitch {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: store.errorMessage == nil ? "info.circle.fill" : "exclamationmark.triangle.fill")
            }
            Text(message)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 4)
            if store.errorMessage != nil {
                Button {
                    store.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(language.text("Đóng thông báo", "Dismiss"))
                .accessibilityLabel(language.text("Đóng thông báo", "Dismiss"))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }
}

enum AppInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

struct AboutView: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openURL) private var openURL

    private var appVersion: String { AppInfo.shortVersion }

    private let authorURL = URL(string: "https://github.com/anlvdt")!
    private let foundationURL = URL(string: "https://github.com/Pimpmuckl/codex-account-switcher")!
    private let codexBarURL = URL(string: "https://github.com/steipete/CodexBar")!
    private let cockpitToolsURL = URL(string: "https://github.com/jlcodes99/cockpit-tools")!
    private let codexProfilesURL = URL(string: "https://github.com/Ducksss/codex-profiles")!
    private let codexSwitchboardURL = URL(string: "https://github.com/vyctorbrzezowski/codex-switchboard")!
    private let vibeUsageURL = URL(string: "https://github.com/vibe-cafe/vibe-usage")!
    private let tokentabURL = URL(string: "https://github.com/damejan80/tokentab")!
    private let codeburnURL = URL(string: "https://github.com/getagentseal/codeburn")!
    private let agentMonitorURL = URL(string: "https://github.com/donvito/agent-monitor")!
    private let codexResetURL = URL(string: "https://codex-reset.com/")!
    private let codexResetsURL = URL(string: "https://codex-resets.com/")!
    private let openAIBrandURL = URL(string: "https://openai.com/brand/")!
    private let codexPricingURL = URL(string: "https://learn.chatgpt.com/docs/pricing")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RosterSecondaryChrome.sectionSpacing) {
                HStack(alignment: .center, spacing: 15) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Codex Roster")
                            .font(RosterSecondaryChrome.title)
                            .lineLimit(1)
                        Text(language.text("Quản lý tài khoản ChatGPT dùng với Codex", "ChatGPT account manager for Codex"))
                            .font(RosterSecondaryChrome.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(language.text("Phiên bản", "Version") + " " + appVersion)
                            .font(RosterSecondaryChrome.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                }

                LanguagePreferencePicker()
                    .padding(14)
                    .background(
                        RosterSecondaryChrome.cardFill,
                        in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius)
                    )

                HStack(spacing: 10) {
                    AboutMetric(icon: "lock.shield.fill", title: "Local-first", detail: language.text("Dữ liệu ở trên Mac", "Data stays on this Mac"))
                    AboutMetric(icon: "waveform.path.ecg", title: language.text("Tín hiệu live", "Live signals"), detail: language.text("Quota · reset · dịch vụ", "Quota · reset · service"))
                    AboutMetric(icon: "macbook", title: "macOS", detail: language.text("Notch native", "Native notch"))
                }

                HStack(alignment: .top, spacing: 14) {
                    AboutPanel(title: language.text("Tóm tắt", "Overview"), icon: "person.3.sequence.fill") {
                        AboutBullet(icon: "person.crop.circle", text: language.text("Nhìn ngay phiên đang dùng, quota, thời điểm reset và banked reset.", "See the active session, quota, reset time, and banked resets at a glance."))
                        AboutBullet(icon: "antenna.radiowaves.left.and.right", text: language.text("Theo dõi live trạng thái OpenAI và Codex Reset outlook công khai.", "Monitor OpenAI service health and the public Codex Reset outlook live."))
                        AboutBullet(icon: "arrow.left.arrow.right.circle", text: language.text("Chuyển nhanh từ notch đến tài khoản còn quota hoặc có banked reset.", "Quick-switch from the notch to accounts with usable quota or banked resets."))
                    }

                    AboutPanel(title: language.text("Quyền riêng tư", "Privacy"), icon: "hand.raised.fill") {
                        AboutBullet(icon: "internaldrive", text: language.text("Snapshot tài khoản và backup được lưu cục bộ trên máy này.", "Account snapshots and backups are stored locally on this Mac."))
                        AboutBullet(icon: "eye.slash", text: language.text("Không đọc mật khẩu, mã xác thực hoặc cookie trình duyệt.", "Never reads passwords, verification codes, or browser cookies."))
                    }
                }

                AboutDisclosurePanel(title: language.text("Keychain & bảo mật cục bộ", "Keychain & local security"), icon: "key.fill") {
                    Text(language.text(
                        "macOS có thể hỏi quyền truy cập mục Keychain \"com.codexroster.app\". Đây là khóa mã hóa cục bộ cho snapshot và bản sao lưu tự động trên máy này — không phải mật khẩu OpenAI.",
                        "macOS may ask for access to Keychain item \"com.codexroster.app\". That is only this Mac's local encryption key for snapshots and automatic backups — not your OpenAI password."
                    ))
                    AboutBullet(
                        icon: "checkmark.shield",
                        text: language.text(
                            "Chọn Allow hoặc Always Allow nếu tên mục là com.codexroster.app. Deny sẽ khiến phiên đã lưu không đọc được.",
                            "Choose Allow or Always Allow when the item is com.codexroster.app. Deny leaves saved sessions unreadable."
                        )
                    )
                    AboutBullet(
                        icon: "terminal",
                        text: language.text(
                            "Khi tự build hoặc chạy cargo test, hộp thoại có thể hiện tên kiểu codex_roster-<hash>; đó vẫn là helper của Codex Roster.",
                            "When you build locally or run cargo test, the dialog may show a name like codex_roster-<hash>; that is still the Codex Roster helper."
                        )
                    )
                }

                AboutDisclosurePanel(title: language.text("Chi tiết tính năng", "Feature details"), icon: "checklist") {
                    AboutFeatureGroup(title: language.text("Tài khoản & phiên", "Accounts & sessions")) {
                        AboutBullet(icon: "person.badge.plus", text: language.text("Mở đăng nhập OpenAI trên trình duyệt, sau đó lưu phiên Codex đang dùng mà không đọc mật khẩu, mã xác thực hoặc cookie trình duyệt.", "Open the OpenAI browser sign-in, then save the active Codex session without reading passwords, verification codes, or browser cookies."))
                        AboutBullet(icon: "pencil", text: language.text("Đặt tên, sửa, tìm kiếm, lưu trữ, khôi phục và xóa từng tài khoản đã lưu.", "Label, edit, search, archive, restore, and remove each saved account."))
                        AboutBullet(icon: "tablecells", text: language.text("Một bảng tài khoản duy nhất trong Tổng quan, kèm tìm kiếm, lọc trạng thái, sắp xếp và thao tác hàng loạt.", "A single account table in Overview with search, status filters, sorting, and bulk actions."))
                    }
                    AboutFeatureGroup(title: language.text("Quota & chuyển tài khoản", "Quota & switching")) {
                        AboutBullet(icon: "gauge.with.dots.needle.50percent", text: language.text("Theo dõi quota Codex, thời điểm reset và gói ChatGPT; làm mới tài khoản đang dùng mỗi phút hoặc kiểm tra toàn bộ theo yêu cầu.", "Track Codex quota, reset timing, and ChatGPT plan; refresh the active account every minute or check every account on demand."))
                        AboutBullet(icon: "arrow.left.arrow.right.circle", text: language.text("Chuyển nhanh từ notch; bao gồm tài khoản 0% đang giữ banked reset.", "Quick-switch from the notch; includes 0% accounts holding a banked reset."))
                        AboutBullet(icon: "arrow.triangle.2.circlepath", text: language.text("Tự động chuyển khi hết quota (tùy chọn): đóng ChatGPT nếu cần, đổi phiên ~/.codex, rồi mở lại Desktop để khớp Roster; không lặp khi mọi tài khoản đều hết quota.", "Optional auto-switch when exhausted: close ChatGPT if needed, switch ~/.codex, then relaunch Desktop to match Roster; never loops when every account is exhausted."))
                        AboutBullet(icon: "arrow.clockwise.icloud", text: language.text("Nút “Mở lại ChatGPT theo phiên này” đóng rồi mở Desktop để khớp ~/.codex ngay.", "“Relaunch ChatGPT with this session” quits and reopens Desktop to match ~/.codex immediately."))
                    }
                    AboutFeatureGroup(title: language.text("Theo dõi & sao lưu", "Monitoring & backup")) {
                        AboutBullet(icon: "chart.bar.xaxis", text: language.text("Thống kê token cục bộ theo ngày, 7 ngày, 30 ngày và 12 tháng từ session logs.", "Read local session logs for token totals by day, 7 days, 30 days, and 12 months."))
                        AboutBullet(icon: "waveform.path.ecg", text: language.text("Đọc Codex Reset outlook từ API công khai, rồi xác nhận riêng bằng quota tài khoản Codex thực tế.", "Read the Codex Reset outlook from the public API, then verify separately against actual Codex account quota."))
                        AboutBullet(icon: "lock.shield", text: language.text("Xuất/nhập file backup có mật khẩu; tự giữ 5 backup phiên đầy đủ được mã hóa bằng khóa Keychain trên máy này.", "Export/import password-protected backups; keep five full session backups encrypted with this Mac's Keychain key."))
                        AboutBullet(icon: "arrow.counterclockwise", text: language.text("Khôi phục danh sách hoặc phiên sao lưu gần nhất sau khi xác nhận.", "Restore the latest account list or saved sessions after confirmation."))
                    }
                    AboutFeatureGroup(title: language.text("Trải nghiệm hệ thống", "System experience")) {
                        AboutBullet(icon: "macbook", text: language.text("Notch là bảng điều khiển chính: quota, chuyển nhanh, tự chuyển, trạng thái dịch vụ, refresh, cài đặt và thoát. Bật/tắt trong Cài đặt, mở bằng ⌃⌥R, đóng bằng Esc.", "The notch is the main control surface: quota, quick switching, auto-switch, service state, refresh, settings, and quit. Toggle it in Settings, open with ⌃⌥R, close with Esc."))
                        AboutBullet(icon: "power", text: language.text("Tùy chọn mở Codex Roster khi đăng nhập macOS; hỗ trợ phím tắt, Dark Mode và song ngữ Việt–Anh (mặc định theo hệ thống).", "Optionally launch at macOS sign-in; supports keyboard shortcuts, Dark Mode, and Vietnamese–English (defaults to system language)."))
                        AboutBullet(icon: "desktopcomputer", text: language.text("macOS là nền tảng duy nhất đang được phát triển và phát hành; app Windows và Linux hiện tạm dừng, mã nguồn được giữ lại để bảo trì trong tương lai.", "macOS is the only actively developed and released platform; Windows and Linux apps are paused, with source retained for future maintenance."))
                    }
                }

                AboutDisclosurePanel(title: language.text("Quota & gói ChatGPT", "ChatGPT plans & quota"), icon: "gauge.with.dots.needle.50percent") {
                    Text(language.text("Codex có trong các gói ChatGPT. Nhãn GPT Free, Plus hoặc Pro chỉ cho biết gói ChatGPT; quota và thời điểm đặt lại thay đổi theo gói, model và mức sử dụng.", "Codex is included with ChatGPT plans. GPT Free, Plus, or Pro identifies the ChatGPT plan; quota and reset timing vary by plan, model, and usage."))
                    Button(language.text("Xem chính sách quota OpenAI", "View OpenAI quota policy")) { openURL(codexPricingURL) }
                        .buttonStyle(.link)
                }

                AboutDisclosurePanel(title: language.text("Tác giả & hỗ trợ", "Author & support"), icon: "bubble.left.and.bubble.right.fill") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(language.text("Phát triển bởi LE AN.", "Developed by LE AN."))
                        }
                        Spacer()
                        Button(language.text("Liên hệ @anlvdt", "Contact @anlvdt")) { openURL(authorURL) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                AboutPanel(title: language.text("Độc lập & nhãn hiệu", "Independence & trademarks"), icon: "checkmark.seal") {
                    Text(language.text(
                        "Codex Roster là ứng dụng macOS độc lập được xây dựng cho cộng đồng Codex; không liên kết, được bảo trợ hay được OpenAI đánh giá.",
                        "Codex Roster is an independent macOS app built for the Codex community; it is not affiliated with, endorsed by, or reviewed by OpenAI."
                    ))
                    Text(language.text(
                        "“Codex”, “ChatGPT”, “OpenAI” và các nhãn hiệu liên quan thuộc về OpenAI; các tên này chỉ được dùng để mô tả khả năng tương thích của ứng dụng.",
                        "“Codex”, “ChatGPT”, “OpenAI”, and related marks belong to OpenAI; these names are used only to describe app compatibility."
                    ))
                    .font(RosterSecondaryChrome.callout)
                    .foregroundStyle(.secondary)
                    Button(language.text("Xem hướng dẫn thương hiệu OpenAI", "View OpenAI brand guidelines")) {
                        openURL(openAIBrandURL)
                    }
                    .buttonStyle(.link)
                }

                AboutDisclosurePanel(title: language.text("Nguồn tham khảo & giấy phép", "References & licenses"), icon: "link") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(language.text(
                            "Đã đối chiếu lại nguồn ngày 22/09/2026 với CREDITS.md. Nền tảng gốc và từng nguồn tham khảo được ghi rõ vai trò, giấy phép và ranh giới sử dụng bên dưới.",
                            "Sources re-audited on September 22, 2026 against CREDITS.md. The original foundation and every reference are listed below with their role, license, and usage boundary."
                        ))
                        .font(RosterSecondaryChrome.callout)
                        .foregroundStyle(.secondary)
                        ReferenceLink(
                            title: "Pimpmuckl / codex-account-switcher",
                            detail: language.text("Nền tảng CLI gốc của Jonathan Liebig; Codex Roster là bản phát triển lại cho macOS.", "Original CLI foundation by Jonathan Liebig; Codex Roster is a macOS product rework."),
                            badge: "MIT · foundation",
                            url: foundationURL
                        )
                        ReferenceLink(
                            title: "steipete / CodexBar",
                            detail: language.text("Tham khảo UX notch, trạng thái quota, reset và schema usage đa provider; triển khai độc lập.", "Reference for notch UX, quota/reset states, and multi-provider usage schemas; independently implemented."),
                            badge: "MIT · UI/UX reference",
                            url: codexBarURL
                        )
                        ReferenceLink(
                            title: "jlcodes99 / cockpit-tools",
                            detail: language.text("Chỉ tham khảo sản phẩm/UI ở mức khái niệm; không sao chép mã nguồn hay tài sản trực quan.", "High-level product/UI reference only; no source code or visual assets copied."),
                            badge: "CC BY-NC-SA 4.0 · reference",
                            url: cockpitToolsURL
                        )
                        ReferenceLink(
                            title: "Ducksss / codex-profiles",
                            detail: language.text("Tham khảo ranh giới profile, workspace và dữ liệu cục bộ; không nhập mã nguồn.", "Reference for profile, workspace, and local-state boundaries; no source imported."),
                            badge: "MIT · boundary reference",
                            url: codexProfilesURL
                        )
                        ReferenceLink(
                            title: "vyctorbrzezowski / codex-switchboard",
                            detail: language.text("Tham khảo nguyên tắc chuyển phiên local-first và an toàn shared-auth; triển khai độc lập.", "Reference for local-first switching and shared-auth safety; independently implemented."),
                            badge: "MIT · safety reference",
                            url: codexSwitchboardURL
                        )
                        ReferenceLink(
                            title: "damejan80 / tokentab",
                            detail: language.text("Tham khảo tổng hợp session log và báo cáo token cục bộ; triển khai độc lập.", "Reference for local session-log aggregation and token reports; independently reimplemented."),
                            badge: "MIT · token accounting research",
                            url: tokentabURL
                        )
                        ReferenceLink(
                            title: "getagentseal / codeburn",
                            detail: language.text("Tham khảo cache accounting, subagent sidechain và fallback token tích lũy; triển khai độc lập.", "Reference for cache accounting, subagent sidechains, and cumulative-token fallback; independently reimplemented."),
                            badge: "MIT · token accounting research",
                            url: codeburnURL
                        )
                        ReferenceLink(
                            title: "donvito / agent-monitor",
                            detail: language.text("Tham khảo cây subagent (thread_source / parent_thread_id) và ước lượng USD theo model; triển khai độc lập.", "Reference for subagent hierarchy (thread_source / parent_thread_id) and per-model USD estimates; independently reimplemented."),
                            badge: "MIT · subagent / pricing research",
                            url: agentMonitorURL
                        )
                        ReferenceLink(
                            title: "VibeCafe / @vibe-cafe/vibe-usage",
                            detail: language.text("Nguồn collector và API usage tùy chọn cho thống kê VibeCafe 7 ngày; Codex Roster tích hợp theo endpoint/format công khai và không nhập mã nguồn upstream.", "Optional collector and usage API source for VibeCafe 7-day statistics; Codex Roster integrates against the public endpoint/format without importing upstream source code."),
                            badge: "MIT · usage integration",
                            url: vibeUsageURL
                        )
                        ReferenceLink(
                            title: "codex-resets.com",
                            detail: language.text("API công khai cho trạng thái / lịch sử reset Codex (source of truth cho cam kết & sự kiện); Data from Codex Resets. Không gửi credential hay quota tài khoản.", "Public API for Codex reset status/history (source of truth for commitment & events); Data from Codex Resets. Never sends credentials or account quota."),
                            badge: "Public API · attribution required",
                            url: codexResetsURL
                        )
                        ReferenceLink(
                            title: "codex-reset.com",
                            detail: language.text("API forecast 24h/48h, timeline, juice và status-history cho Codex Reset outlook.", "Forecast 24h/48h, timeline, juice, and status-history APIs for Codex Reset outlook."),
                            badge: "Public API · forecast",
                            url: codexResetURL
                        )
                        Text(language.text("Ngoại trừ nền tảng MIT được ghi rõ, Codex Roster không đưa mã nguồn, tài sản, credential hay state của các dự án tham khảo vào ứng dụng. Chi tiết đầy đủ: CREDITS.md.", "Except for the credited MIT foundation, Codex Roster does not incorporate source code, assets, credentials, or state from the reference projects. Full detail: CREDITS.md."))
                            .font(RosterSecondaryChrome.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
            .rosterSecondaryPadding()
        }
        .rosterSecondaryContent()
        .navigationTitle(language.text("Giới thiệu Codex Roster", "About Codex Roster"))
    }
}

private struct ReferenceLink: View {
    @Environment(\.openURL) private var openURL
    let title: String
    let detail: String
    let badge: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button { openURL(url) } label: {
                    Label(title, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .font(RosterSecondaryChrome.section.weight(.semibold))

                Text(badge)
                    .font(RosterSecondaryChrome.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text(detail)
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AboutMetric: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
            Text(title).font(RosterSecondaryChrome.section)
            Text(detail)
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(11)
        .background(
            RosterSecondaryChrome.cardFill,
            in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius)
        )
    }
}

private struct AboutPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(RosterSecondaryChrome.section)
                .foregroundStyle(.primary)
            content
                .font(RosterSecondaryChrome.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RosterSecondaryChrome.cardFill,
            in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius)
        )
    }
}

private struct AboutDisclosurePanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(RosterSecondaryChrome.disclosureSpring) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(RosterSecondaryChrome.micro.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Label(title, systemImage: icon)
                        .font(RosterSecondaryChrome.section)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded
                ? AppLanguage.text("Đang mở", "Expanded")
                : AppLanguage.text("Đang đóng", "Collapsed"))
            .accessibilityHint(AppLanguage.text(
                "Nhấn để mở hoặc đóng phần này",
                "Press to expand or collapse this section"
            ))

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content
                        .font(RosterSecondaryChrome.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            }
        }
        .padding(14)
        .background(
            RosterSecondaryChrome.cardFill,
            in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius)
        )
    }
}

private struct AboutBullet: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(RosterSecondaryChrome.body)
            .foregroundStyle(.secondary)
    }
}

private struct AboutFeatureGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(RosterSecondaryChrome.section)
                .foregroundStyle(.primary)
            content
        }
        .padding(.bottom, 4)
    }
}

func copyAccountEmail(_ email: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(email, forType: .string)
}

func copyAccountEmails(_ emails: [String]) {
    guard !emails.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(emails.joined(separator: "\n"), forType: .string)
}

/// Resolve a roster action target by the row's captured account ID.
/// Never use list index, the currently selected account, or "first requiresLogin"
/// — those are classic SwiftUI LazyVStack/LazyVGrid wrong-row Login/delete bugs.
func accountForContextMenuAction(in accounts: [SavedAccount], capturedID: UUID) -> SavedAccount? {
    accounts.first { $0.id == capturedID }
}

/// Account ID to post with `.showReloginAccount`. Always the clicked row when present.
/// Callers without a captured ID must no-op or open add-account — never pick
/// "first requiresLogin" (wrong-row Login bug).
func accountIDForReloginNotification(
    in accounts: [SavedAccount],
    capturedID: UUID?,
    isArchived: (SavedAccount) -> Bool = { $0.archived }
) -> UUID? {
    _ = isArchived
    guard let capturedID else { return nil }
    return accountForContextMenuAction(in: accounts, capturedID: capturedID)?.id
}

struct CopyEmailButton: View {
    let email: String
    var iconSize: CGFloat = 12
    @EnvironmentObject private var language: LanguageStore
    @State private var justCopied = false
    @State private var isHovered = false

    var body: some View {
        Button {
            PrismTheme.triggerHaptic()
            copyAccountEmail(email)
            withAnimation(.easeInOut(duration: 0.15)) {
                justCopied = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    justCopied = false
                }
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(justCopied ? PrismTheme.emerald : (isHovered ? .primary : .secondary.opacity(0.8)))
                .frame(width: max(22, iconSize + 10), height: max(22, iconSize + 10))
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .help(justCopied ? language.text("Đã sao chép!", "Copied!") : language.text("Sao chép email", "Copy email"))
        .accessibilityLabel(language.text("Sao chép email", "Copy email"))
    }
}

func formatTokenMetric(_ tokens: UInt64, in language: AppLanguage) -> String {
    let value = Double(tokens)
    if value >= 1_000_000_000 {
        let scaled = value / 1_000_000_000
        let formatted = language == .vietnamese
            ? String(format: "%.1f", scaled).replacingOccurrences(of: ".", with: ",")
            : String(format: "%.1f", scaled)
        return language == .vietnamese ? "\(formatted) tỷ" : "\(formatted)B"
    } else if value >= 1_000_000 {
        let scaled = value / 1_000_000
        let formatted = language == .vietnamese
            ? String(format: "%.1f", scaled).replacingOccurrences(of: ".", with: ",")
            : String(format: "%.1f", scaled)
        return language == .vietnamese ? "\(formatted) tr" : "\(formatted)M"
    } else if value >= 1_000 {
        let scaled = value / 1_000
        let formatted = language == .vietnamese
            ? String(format: "%.1f", scaled).replacingOccurrences(of: ".", with: ",")
            : String(format: "%.1f", scaled)
        return language == .vietnamese ? "\(formatted) nghìn" : "\(formatted)K"
    } else {
        return "\(tokens)"
    }
}

func formatUsdCost(_ amount: Double, in language: AppLanguage) -> String {
    let formatted = language == .vietnamese
        ? String(format: "%.2f", amount).replacingOccurrences(of: ".", with: ",")
        : String(format: "%.2f", amount)
    return "($\(formatted))"
}

func formatFullTokenNumber(_ tokens: UInt64, in language: AppLanguage) -> String {
    let formatter = NumberFormatter()
    formatter.locale = language.locale
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
}
