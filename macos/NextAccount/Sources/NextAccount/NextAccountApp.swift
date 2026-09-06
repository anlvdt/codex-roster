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

private extension Notification.Name {
    static let showAddAccount = Notification.Name("codexRoster.showAddAccount")
    static let showReloginAccount = Notification.Name("codexRoster.showReloginAccount")
    static let exportBackup = Notification.Name("codexRoster.exportBackup")
    static let importBackup = Notification.Name("codexRoster.importBackup")
}

private let dashboardCardFill = Color(nsColor: .controlBackgroundColor)
private let rosterActionBlue = Color(nsColor: .systemBlue)

private struct PointingHandCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
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

private extension View {
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
    @StateObject private var store = AccountStore()
    @StateObject private var language = LanguageStore()
    @StateObject private var updater = GitHubUpdater()

    init() {
        guard Self.instanceGuard != nil else {
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
                .environmentObject(store)
                .environmentObject(language)
                .environmentObject(updater)
                .environment(\.locale, language.language.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.top)

        Window("Codex Roster", id: "dashboard") {
            ContentView()
                .environmentObject(store)
                .environmentObject(language)
                .environmentObject(updater)
                .environment(\.locale, language.language.locale)
                .task {
                    store.startCoreMonitoring()
                    store.refreshTokenUsage(silently: true)
                    store.refreshResetOutlook(silently: true)
                    store.refreshOpenAIStatus(silently: true)
                    store.ensureAutomaticFullBackup()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(language.text("Thêm tài khoản…", "Add account…")) {
                    NotificationCenter.default.post(name: .showAddAccount, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button(language.text("Xuất bản sao lưu…", "Export backup…")) {
                    NotificationCenter.default.post(name: .exportBackup, object: nil)
                }
                Button(language.text("Nhập bản sao lưu…", "Import backup…")) {
                    NotificationCenter.default.post(name: .importBackup, object: nil)
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

        Window(language.text("Giới thiệu", "About"), id: "about") {
            AboutView()
                .environmentObject(language)
                .environment(\.locale, language.language.locale)
        }
        .defaultSize(width: 560, height: 720)

        Settings {
            AboutView()
                .environmentObject(language)
                .environment(\.locale, language.language.locale)
        }
    }

}

struct ContentView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @State private var selection: UUID?
    @State private var accountForDeletion: SavedAccount?
    @State private var accountForEditing: SavedAccount?
    @State private var accountForRelogin: SavedAccount?
    @State private var reloginQueue: [UUID] = []
    @State private var showingAddAccount = false
    @State private var backupOperation: BackupOperation?

    var body: some View {
        NavigationSplitView {
            AccountSidebar(selection: $selection)
        } detail: {
            detailContent
        }
        .toolbar { AccountToolbar(showingAddAccount: $showingAddAccount) }
        .onReceive(NotificationCenter.default.publisher(for: .showAddAccount)) { _ in
            showingAddAccount = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showReloginAccount)) { notification in
            let id = (notification.object as? String).flatMap(UUID.init(uuidString:))
                ?? notification.object as? UUID
            if let id, let account = store.accounts.first(where: { $0.id == id }) {
                selection = id
                presentRelogin(account)
            } else if let account = store.accounts.first(where: { !store.isArchived($0) && $0.requiresLogin }) {
                selection = account.id
                presentRelogin(account)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportBackup)) { _ in
            backupOperation = .export
        }
        .onReceive(NotificationCenter.default.publisher(for: .importBackup)) { _ in
            backupOperation = .import
        }
        .overlay {
            if store.isBusyForActions {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .sheet(isPresented: $showingAddAccount) {
            AddAccountSheet()
                .environmentObject(store)
                .environmentObject(language)
        }
        .sheet(item: $accountForRelogin, onDismiss: presentNextQueuedRelogin) { account in
            ReloginAccountSheet(
                account: account,
                queuedCount: reloginQueue.count,
                cancelQueue: { reloginQueue.removeAll() }
            )
                .environmentObject(store)
                .environmentObject(language)
        }
        .sheet(item: $backupOperation) { operation in
            BackupTransferSheet(operation: operation)
                .environmentObject(store)
                .environmentObject(language)
        }
        .sheet(item: $accountForEditing) { account in
            AccountEditorSheet(account: account)
                .environmentObject(store)
                .environmentObject(language)
        }
        .alert("Codex Roster", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(language.text("Đồng ý", "OK"), role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            language.text("Xóa tài khoản đã lưu?", "Remove saved account?"),
            isPresented: Binding(
                get: { accountForDeletion != nil },
                set: { if !$0 { accountForDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(language.text("Xóa", "Remove"), role: .destructive) {
                if let accountForDeletion {
                    store.delete(accountForDeletion)
                }
                accountForDeletion = nil
            }
            Button(language.text("Hủy", "Cancel"), role: .cancel) { accountForDeletion = nil }
        } message: {
            Text(language.text("Thao tác này xóa \(accountForDeletion?.email ?? "tài khoản này") khỏi Codex Roster.", "This removes \(accountForDeletion?.email ?? "this account") from Codex Roster."))
        }
    }

    private func requestActivation(for account: SavedAccount) {
        store.activate(account, force: true)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selected = selectedAccount {
            AccountDetail(
                account: selected,
                home: { selection = nil },
                activate: { requestActivation(for: selected) },
                edit: { accountForEditing = selected },
                archive: {
                    store.archive(selected)
                    selection = nil
                },
                restore: { store.restore(selected) },
                remove: { accountForDeletion = selected },
                relogin: { presentRelogin(selected) }
            )
        } else {
            DashboardView(
                selection: $selection,
                relogin: presentRelogin,
                reloginAll: startReloginQueue
            )
        }
    }

    private var selectedAccount: SavedAccount? {
        store.accounts.first { $0.id == selection }
    }

    private func presentRelogin(_ account: SavedAccount) {
        reloginQueue.removeAll()
        selection = account.id
        accountForRelogin = account
    }

    private func startReloginQueue(_ accounts: [SavedAccount]) {
        let pending = accounts.filter { !store.isArchived($0) && $0.requiresLogin }
        guard let first = pending.first else { return }
        reloginQueue = pending.dropFirst().map(\.id)
        selection = first.id
        accountForRelogin = first
    }

    private func presentNextQueuedRelogin() {
        while let nextID = reloginQueue.first {
            reloginQueue.removeFirst()
            guard let account = store.accounts.first(where: {
                $0.id == nextID && !store.isArchived($0) && $0.requiresLogin
            }) else { continue }
            selection = account.id
            DispatchQueue.main.async {
                accountForRelogin = account
            }
            return
        }
    }

}

private struct AccountSidebar: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            Section {
                Button { selection = nil } label: {
                    Label(language.text("Tổng quan", "Overview"), systemImage: "house")
                }
                .buttonStyle(.plain)
            }
            Section {
                if let activeAccount {
                    Button { selection = activeAccount.id } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(language.text("Đang sử dụng", "Active session"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(activeAccount.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                    .help(activeAccount.displayName)
                            }
                            Spacer(minLength: 4)
                            if activeAccount.primaryQuotaWindow != nil {
                                VStack(alignment: .trailing, spacing: 1) {
                                    if let window = activeAccount.usage?.fiveHour {
                                        Text("5h \(window.displayRemainingPercent)%")
                                            .foregroundStyle(quotaTint(window.remainingPercent))
                                    }
                                    if let window = activeAccount.usage?.weekly {
                                        Text(language.text("Tuần \(window.displayRemainingPercent)%", "Week \(window.displayRemainingPercent)%"))
                                            .foregroundStyle(quotaTint(window.remainingPercent))
                                    }
                                }
                                .font(.caption2.monospacedDigit().weight(.semibold))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(AccountTriage.allCases, id: \.self) { bucket in
                    let count = count(for: bucket)
                    // The active session already has its own row above, and the
                    // two set-aside buckets only earn a row once they exist.
                    if bucket != .active, count > 0 || bucket == .ready || bucket == .needsAction {
                        sidebarSignal(
                            bucket.title(in: language.language),
                            count: count,
                            icon: bucket.systemImage,
                            tint: bucket.tint
                        )
                    }
                }
            } header: {
                Text(language.text("Tín hiệu", "Signals"))
            } footer: {
                Text(language.text(
                    "Danh sách và bộ lọc nằm trong Tổng quan.",
                    "The account list and filters live in Overview."
                ))
            }
        }
        .navigationTitle("Codex Roster")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        .safeAreaInset(edge: .bottom) {
            Button(action: openAboutWindow) {
                Label(language.text("Giới thiệu", "About"), systemImage: "heart.text.square")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.bar)
        }
    }

    private var activeAccount: SavedAccount? {
        store.accounts.first(where: \.isActive)
    }

    private func count(for bucket: AccountTriage) -> Int {
        store.accounts.filter { $0.triage == bucket }.count
    }

    private func sidebarSignal(_ title: String, count: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func quotaTint(_ remainingPercent: Int) -> Color {
        Color.quotaTint(
            remainingPercent: remainingPercent,
            exhaustedAt: UsageWindow.exhaustedRemainingPercent
        )
    }

    private func openAboutWindow() {
        openWindow(id: "about")
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.identifier?.rawValue == "about" })?
                .makeKeyAndOrderFront(nil)
        }
    }

}

private struct DashboardView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?
    let relogin: (SavedAccount) -> Void
    let reloginAll: ([SavedAccount]) -> Void
    @State private var automationExpanded = false
    @State private var confirmingFullBackupRestore = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DashboardHero(
                    currentAccount: store.status?.currentAccount?.email,
                    accountCount: store.accounts.count,
                    activeAccount: store.accounts.first(where: \.isActive),
                    selection: $selection
                )

                NextActionBanner(
                    selection: $selection,
                    reloginAll: reloginAll
                )

                AccountTriageBoard(
                    selection: $selection,
                    relogin: relogin,
                    reloginAll: reloginAll
                )

                VStack(alignment: .leading, spacing: 12) {
                    OpenAIStatusCard()
                    GlobalResetOutlookCard()
                }

                TokenUsageOverview()

                DisclosureGroup(isExpanded: $automationExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(language.text("Tự động kiểm tra cửa sổ quota đến hạn", "Automatically check due quota windows"), isOn: Binding(
                            get: { store.autoStartUsageWindows },
                            set: { store.setAutoStartUsageWindows($0) }
                        ))
                        .disabled(store.isWorking)
                        Text(language.text(
                            "Kiểm tra các cửa sổ quota tuần đã đến hạn theo lịch nền. Việc này không đăng nhập lại các tài khoản không hoạt động; theo dõi quota live vẫn chạy riêng khi app hoạt động.",
                            "Checks due weekly quota windows in the background. It does not sign into inactive accounts; live quota monitoring runs separately while the app is active."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if store.isRefreshingQuotaInBackground {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(language.text("Đang cập nhật quota…", "Updating quota…"))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if let lastQuotaRefreshAt = store.lastQuotaRefreshAt {
                            Text(language.text(
                                "Đã cập nhật \(lastQuotaRefreshAt.formatted(date: .omitted, time: .shortened))",
                                "Updated \(lastQuotaRefreshAt.formatted(date: .omitted, time: .shortened))"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Divider()
                        Toggle(language.text("Tự động chuyển khi hết quota", "Auto-switch when quota is exhausted"), isOn: Binding(
                            get: { store.autoSwitchWhenExhausted },
                            set: { store.setAutoSwitchWhenExhausted($0) }
                        ))
                        .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
                        Text(language.text(
                            "Khi tài khoản Codex (~/.codex) còn 0%: tìm tài khoản còn quota → force-quit ChatGPT → chuyển phiên → mở lại Desktop. Nhãn phiên theo ~/.codex, không đọc cookie đăng nhập riêng trong ChatGPT.",
                            "When the Codex account (~/.codex) hits 0%: find an account with quota → force-quit ChatGPT → switch session → relaunch Desktop. The session label follows ~/.codex and does not read a separate ChatGPT cookie login."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let autoSwitchState = store.autoSwitchState {
                            Text(autoSwitchStatusText(autoSwitchState))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle(language.text("Mở Codex Roster khi đăng nhập macOS", "Open Codex Roster at login"), isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        .disabled(store.isWorking)
                        Text(language.text("Duy trì notch và các kiểm tra tự động sau khi bạn đăng nhập vào máy Mac.", "Keeps the notch and automatic checks available after you sign in to your Mac."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(language.text("Kiểm tra ngay", "Run refresh check now")) {
                                store.runUsageWindowCheck()
                            }
                            .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
                            if store.autoSwitchWhenExhausted {
                                Button(language.text("Kiểm tra & chuyển", "Check & switch")) {
                                    store.runAutoSwitchCheck()
                                }
                                .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
                            }
                            Spacer()
                            Button(language.text("Khôi phục tài khoản cũ", "Recover older accounts")) {
                                store.recoverLegacySnapshots()
                            }
                            .disabled(store.isWorking)
                        }
                        .controlSize(.small)
                        Button(language.text("Khôi phục phiên sao lưu", "Restore saved sessions")) {
                            confirmingFullBackupRestore = true
                        }
                        .controlSize(.small)
                        .disabled(store.isWorking)
                        Text(language.text("Tự động giữ 5 bản sao đầy đủ được mã hóa bằng khóa trong Keychain của máy này; khôi phục xong có thể đăng nhập lại Codex.", "Keeps 5 full backups encrypted with this Mac's Keychain key; restored accounts can sign in to Codex again."))
                        Text(language.text(
                            "Nếu macOS hỏi quyền Keychain cho \"com.codexroster.app\", hãy Allow / Always Allow — đó là khóa mã hóa cục bộ, không phải mật khẩu OpenAI. Xem Giới thiệu để biết thêm.",
                            "If macOS asks for Keychain access to \"com.codexroster.app\", choose Allow / Always Allow — that is the local encryption key, not your OpenAI password. See About for details."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Label(language.text("Tự động hóa", "Automation"), systemImage: "gearshape.2")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(store.autoStartUsageWindows
                            ? language.text("Cửa sổ quota · bật", "Quota windows · on")
                            : language.text("Cửa sổ quota · tắt", "Quota windows · off"))
                            .font(.caption)
                            .foregroundStyle(store.autoStartUsageWindows ? Color.green : Color.secondary)
                    }
                }
                .padding(14)
                .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 13))
                .confirmationDialog(
                    language.text("Khôi phục phiên sao lưu?", "Restore saved sessions?"),
                    isPresented: $confirmingFullBackupRestore,
                    titleVisibility: .visible
                ) {
                    Button(language.text("Khôi phục", "Restore"), role: .destructive) {
                        store.restoreLatestFullBackup()
                    }
                    Button(language.text("Hủy", "Cancel"), role: .cancel) {}
                } message: {
                    Text(language.text("Danh sách hiện tại sẽ được thay bằng bản sao tự động gần nhất trên máy này.", "The current account list will be replaced by this Mac's most recent automatic backup."))
                }

                GroupBox(language.text("An toàn phiên Codex", "Codex session safety")) {
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
                        if store.hasRunningCodexProcesses {
                            Label(language.text("\(store.status?.processWarnings.count ?? 0) tiến trình Codex đang chạy", "\(store.status?.processWarnings.count ?? 0) Codex processes are running"), systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Label(language.text("Sẵn sàng chuyển tài khoản", "Ready to switch accounts"), systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: max(0, min(geometry.size.width - 48, 1_240)), alignment: .leading)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationTitle(language.text("Tổng quan", "Overview"))
    }

    private func autoSwitchStatusText(_ state: AutoSwitchState) -> String {
        switch state {
        case .waitingForLogin:
            language.text("Tự động chuyển tạm dừng trong khi bạn đăng nhập.", "Auto-switch is paused while you sign in.")
        case .allAccountsExhausted:
            language.text("Tất cả tài khoản đã hết quota; tự động chuyển sẽ thử lại sau.", "All accounts are out of quota; auto-switch will try again later.")
        case .bankedResetAvailable(let account, let count, let isActive):
            if isActive {
                language.text(
                    "\(account) đã hết quota nhưng còn \(count) banked reset. App giữ reset an toàn, không tự tiêu; hãy dùng reset trong Codex rồi Auto-switch sẽ kiểm tra lại.",
                    "\(account) is out of quota but has \(count) banked reset. The app preserves it instead of spending it silently; redeem it in Codex and Auto-switch will check again."
                )
            } else {
                language.text(
                    "Không còn account có quota dùng ngay; \(account) còn \(count) banked reset chưa redeem. Auto-switch không chuyển sang account vẫn 0%.",
                    "No account has immediately usable quota; \(account) has \(count) unredeemed banked reset. Auto-switch will not move to an account that is still at 0%."
                )
            }
        case .closingDesktop:
            language.text("Đang đóng ChatGPT/Codex trước khi chuyển tài khoản hết quota…", "Closing ChatGPT/Codex before switching the exhausted account…")
        case .switchingAccount:
            language.text("Đang chuyển phiên ~/.codex sang tài khoản còn quota…", "Switching the ~/.codex session to an account with quota…")
        case .relaunchingDesktop:
            language.text("Đang mở lại ChatGPT để khớp phiên Codex vừa chuyển…", "Relaunching ChatGPT to match the switched Codex session…")
        case .desktopRelaunchFailed:
            language.text("Đã chuyển phiên nhưng không thể mở lại ChatGPT. Hãy thử nút Mở lại ChatGPT.", "The session switched, but ChatGPT could not be relaunched. Try Relaunch ChatGPT.")
        case .waitingForProcesses:
            language.text("Không đóng được ChatGPT/Codex; hãy đóng thủ công rồi bấm Kiểm tra & chuyển.", "Could not quit ChatGPT/Codex; quit it manually, then tap Check & switch.")
        case .switched(let name):
            language.text("Đã tự động chuyển sang \(name) và mở lại ChatGPT.", "Automatically switched to \(name) and relaunched ChatGPT.")
        case .checkFailed:
            language.text("Không thể kiểm tra/chuyển quota tự động. Thử Kiểm tra & chuyển.", "Could not auto-check/switch quota. Try Check & switch.")
        case .generationInProgress:
            language.text("Codex đang tạo phản hồi; Auto-switch chờ phiên yên trước khi chuyển.", "Codex is generating a response; Auto-switch is waiting for the session to become idle.")
        }
    }
}

/// The single most useful thing the user can do right now. Derived from the
/// same `AccountTriage` buckets the board renders, so the banner can never
/// recommend something the board contradicts.
private enum NextAction {
    case addAccount
    case switchTo(SavedAccount)
    case redeemBankedReset(SavedAccount)
    case waitForReset(SavedAccount)
    case signIn([SavedAccount])
    case recover(SavedAccount)
    case retryQuota([SavedAccount])
    case allClear(SavedAccount?)
}

private struct NextActionBanner: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?
    let reloginAll: ([SavedAccount]) -> Void

    var body: some View {
        let action = nextAction
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon(for: action))
                .font(.title2)
                .foregroundStyle(tint(for: action))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline(for: action))
                    .font(.headline)
                Text(detail(for: action))
                    .font(.caption)
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

    /// Priority order: being blocked *right now* outranks housekeeping on other
    /// accounts, so an exhausted live session is resolved before sign-ins.
    private var nextAction: NextAction {
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

    private func soonestReset(among accounts: [SavedAccount]) -> SavedAccount? {
        accounts
            .compactMap { account -> (SavedAccount, Date)? in
                guard let reset = account.quotaWindowsForSwitch.map(\.resetAt.value).min() else { return nil }
                return (account, reset)
            }
            .min { $0.1 < $1.1 }?
            .0
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
        case .retryQuota: .yellow
        case .allClear: .green
        }
    }

    private func headline(for action: NextAction) -> String {
        switch action {
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

    private func detail(for action: NextAction) -> String {
        switch action {
        case .addAccount:
            language.text(
                "Roster chưa có tài khoản nào để chuyển đổi.",
                "Roster has no accounts to switch between yet."
            )
        case .switchTo(let account):
            language.text(
                "Phiên hiện tại không dùng được; \(account.displayName) còn \(quotaSummary(account)).",
                "The current session is unusable; \(account.displayName) has \(quotaSummary(account))."
            )
        case .redeemBankedReset(let account):
            language.text(
                "Không còn tài khoản nào còn quota. \(account.displayName) giữ \(account.usage?.bankedResets?.availableCount ?? 0) banked reset — chuyển sang rồi redeem trong Codex.",
                "No account has quota left. \(account.displayName) holds \(account.usage?.bankedResets?.availableCount ?? 0) banked reset — switch there, then redeem it inside Codex."
            )
        case .waitForReset(let account):
            language.text(
                "Cửa sổ sớm nhất là \(account.displayName), \(resetSummary(account)).",
                "The earliest window belongs to \(account.displayName), \(resetSummary(account))."
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
                    "Còn \(quotaSummary(active)). Không có việc gì cần bạn xử lý.",
                    "\(quotaSummary(active)) left. Nothing needs your attention."
                )
            } else {
                language.text(
                    "Không có tài khoản nào cần xử lý.",
                    "No account needs attention."
                )
            }
        }
    }

    @ViewBuilder
    private func button(for action: NextAction) -> some View {
        switch action {
        case .addAccount:
            EmptyView()
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

    private func quotaSummary(_ account: SavedAccount) -> String {
        let parts = [
            account.usage?.fiveHour.map { language.text("5 giờ \($0.displayRemainingPercent)%", "5-hour \($0.displayRemainingPercent)%") },
            account.usage?.weekly.map { language.text("tuần \($0.displayRemainingPercent)%", "weekly \($0.displayRemainingPercent)%") },
        ].compactMap { $0 }
        if parts.isEmpty {
            return language.text("quota chưa xác minh", "unverified quota")
        }
        return parts.joined(separator: " · ")
    }

    private func resetSummary(_ account: SavedAccount) -> String {
        guard let window = account.quotaWindowsForSwitch.min(by: { $0.resetAt.value < $1.resetAt.value }) else {
            return language.text("chưa rõ thời điểm đặt lại", "with no known reset time")
        }
        return window.resetDescription(in: language.language).lowercased()
    }
}

private struct AccountTriageBoard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?
    let relogin: (SavedAccount) -> Void
    let reloginAll: ([SavedAccount]) -> Void
    @State private var searchText = ""
    @State private var focus: AccountTriage?
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
            filterChips
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

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(AccountTriage.allCases, id: \.self) { bucket in
                // Counted before the focus filter, so focusing one state does
                // not blank out every other chip.
                let count = searchedAccounts.filter { $0.triage == bucket }.count
                if count > 0 || focus == bucket {
                    Button {
                        focus = (focus == bucket) ? nil : bucket
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: bucket.systemImage)
                            Text(bucket.title(in: language.language))
                            Text("\(count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            focus == bucket ? bucket.tint.opacity(0.20) : Color.secondary.opacity(0.10),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                focus == bucket ? bucket.tint.opacity(0.55) : .clear,
                                lineWidth: 1
                            )
                        )
                        .foregroundStyle(focus == bucket ? bucket.tint : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(bucket.subtitle(in: language.language))
                }
            }
            Spacer(minLength: 0)
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

            Button(language.text("Quota", "Refresh")) {
                store.refreshUsage(for: refreshableAccounts)
            }
            .disabled(refreshableAccounts.isEmpty || store.isBusyForActions)
            if !selectedReloginAccounts.isEmpty {
                Button(language.text(
                    "Login lại \(selectedReloginAccounts.count)",
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
                            relogin: { relogin(account) }
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
    let relogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                if isSelecting {
                    Toggle(isOn: Binding(get: { isSelected }, set: { _ in toggleSelection() })) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
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
                    .foregroundStyle(activeUntil < Date() ? Color.red : Color.secondary)
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
        if let summary = account.usage?.bankedResets, max(0, summary.availableCount) > 0 {
            let count = max(0, summary.availableCount)
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
    private var primaryAction: some View {
        switch bucket {
        case .needsAction:
            if account.requiresLogin {
                Button(language.text("Login lại", "Sign in"), action: relogin)
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
        if account.hasTransientUsageError { return .yellow }
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


private struct DashboardHero: View {
    @EnvironmentObject private var language: LanguageStore
    let currentAccount: String?
    let accountCount: Int
    let activeAccount: SavedAccount?
    @Binding var selection: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Label(language.text("Tổng quan tài khoản", "Account overview"), systemImage: "person.3.sequence.fill")
                    .font(.title2.weight(.bold))
                Text(language.text("Quản lý tài khoản ChatGPT dùng với Codex.", "Manage ChatGPT accounts used with Codex."))
                    .font(.body)
                    .foregroundStyle(.secondary)

                Label(language.text("\(accountCount) tài khoản đã lưu", "\(accountCount) saved accounts"), systemImage: "tray.full")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 8) {
                Label(language.text("Phiên Codex", "Codex session"), systemImage: "person.crop.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(currentAccount ?? language.text("Chưa đăng nhập", "Not signed in"))
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                Text(language.text("Theo ~/.codex · không khởi động lại khi đăng nhập", "From ~/.codex · no restart during sign-in"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let activeAccount {
                    Button(language.text("Xem tài khoản hiện tại", "View current account")) {
                        selection = activeAccount.id
                    }
                    .controlSize(.small)
                }
            }
            .frame(minWidth: 245, maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(22)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TokenUsageOverview: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.text("Mức dùng Codex trên máy này", "Local Codex usage"), systemImage: "chart.bar.xaxis")
                .font(.headline)
            Text(language.text("Thống kê token theo các phiên sử dụng gần đây.", "Token activity from recent sessions."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let summary = store.tokenUsage {
                VStack(alignment: .leading, spacing: 14) {
                    if let vibe = store.status?.vibeUsage {
                        HStack(spacing: 10) {
                            TokenMetric(title: "VibeCafe 7d", tokens: vibe.totalTokens)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(language.text("Chi phí ước tính", "Estimated cost"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "$%.2f", vibe.estimatedCostUsd))
                                    .font(.title3.weight(.semibold))
                                Text("\(vibe.sessions) sessions · \(String(format: "%.1f", Double(vibe.activeSeconds) / 3600))h")
                                    .font(.caption2)
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
                        .font(.caption)
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
                .font(.subheadline)
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
                .font(.subheadline.weight(.semibold))

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
            .font(.caption)
            .foregroundStyle(.secondary)

            if !summary.byModel.isEmpty {
                TokenUsageRanking(title: language.text("Theo model", "By model"), entries: summary.byModel)
            }
            if !summary.byProject.isEmpty {
                TokenUsageRanking(title: language.text("Theo dự án", "By project"), entries: summary.byProject)
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
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(compactTokenCount(tokens, in: language.language))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TokenUsageRanking: View {
    @EnvironmentObject private var language: LanguageStore
    let title: String
    let entries: [TokenUsageBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(entries.prefix(3)) { entry in
                HStack(spacing: 8) {
                    Text(entry.label)
                        .lineLimit(1)
                    Spacer()
                    Text(compactTokenCount(entry.tokens, in: language.language))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
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
                    .font(.system(size: 7))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(compactTokenCount(tokens, in: language.language))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(language.text("token", "tokens"))
                .font(.caption)
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
                        .font(.subheadline.weight(.semibold))
                    Text(language.text("Trung bình \(compactTokenCount(average, in: language.language)) token/ngày", "Average \(compactTokenCount(average, in: language.language)) tokens/day"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(language.text("Cao nhất", "Peak"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(compactTokenCount(maximum, in: language.language))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
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
        .background(
            LinearGradient(
                colors: [dashboardCardFill, dashboardCardFill],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14)
        )
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
                .font(.caption.monospacedDigit())
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
                .font(.caption.weight(isLatest ? .semibold : .regular))
                .foregroundStyle(isLatest ? Color.accentColor : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(day.date)
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

    let formatter = NumberFormatter()
    formatter.locale = language.locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 1
    return "\(formatter.string(from: NSNumber(value: scaledValue)) ?? "\(scaledValue)") \(unit)"
}

private struct AccountRow: View {
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount
    let isArchived: Bool
    let edit: (SavedAccount) -> Void
    let archive: (SavedAccount) -> Void
    let restore: (SavedAccount) -> Void
    let remove: (SavedAccount) -> Void
    let relogin: (SavedAccount) -> Void
    @Binding var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: account.isActive ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(account.isActive ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help(account.displayName)
                    Text(account.email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                        .textSelection(.enabled)
                        .help(language.text("Nhấp đúp hoặc dùng menu để sao chép email", "Double-click or use the menu to copy email"))
                }
                Spacer(minLength: 4)
                accountActionsMenu
            }
            .contextMenu {
                Button(language.text("Sao chép email", "Copy email")) {
                    copyAccountEmail(account.email)
                }
            }

            HStack(spacing: 8) {
                SidebarQuotaMeter(account: account)
                if let plan = account.planLabel {
                    Text(account.paidSubscriptionActiveUntil.map {
                        "GPT \(plan) · \(compactSubscriptionUntil($0, language: language.language))"
                    } ?? "GPT \(plan)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(language.text("Gói ChatGPT: \(plan). Codex có trong các gói ChatGPT; quota thay đổi theo gói, model và mức sử dụng.", "ChatGPT plan: \(plan). Codex is included with ChatGPT plans; quota varies by plan, model, and usage."))
                        .accessibilityLabel(language.text("Gói ChatGPT \(plan)", "ChatGPT plan \(plan)"))
                }
                if let resets = account.usage?.bankedResets {
                    Label("\(max(0, resets.availableCount))", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(resets.availableCount > 0 ? Color.accentColor : Color.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(language.text(
                            "Banked reset khả dụng: \(max(0, resets.availableCount))",
                            "Available banked resets: \(max(0, resets.availableCount))"
                        ))
                        .accessibilityLabel(language.text(
                            "Có \(max(0, resets.availableCount)) lượt banked reset",
                            "\(max(0, resets.availableCount)) banked resets available"
                        ))
                }
            }
        }
    }

    private var accountActionsMenu: some View {
        Menu {
            Button(language.text("Xem chi tiết", "View details")) { selection = account.id }
            Button(language.text("Sao chép email", "Copy email")) {
                copyAccountEmail(account.email)
            }
            if !isArchived && account.requiresLogin {
                Button(language.text("Đăng nhập lại…", "Sign in again…")) { relogin(account) }
            }
            Button(language.text("Sửa", "Edit")) { edit(account) }
            if isArchived {
                Button(language.text("Khôi phục", "Restore")) { restore(account) }
            } else {
                Button(language.text("Lưu trữ", "Archive")) { archive(account) }
            }
            Divider()
            Button(language.text("Xóa", "Remove"), role: .destructive) { remove(account) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 28, height: 28)
                .background(Color(nsColor: .tertiaryLabelColor).opacity(0.22), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuIndicator(.hidden)
        .help(language.text("Thao tác tài khoản", "Account actions"))
    }
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
                .tint(tint(for: window.remainingPercent))
                .frame(minWidth: 46, maxWidth: .infinity)
            Text("\(window.displayRemainingPercent)%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint(for: window.remainingPercent))
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

    private func tint(for remaining: Int) -> Color {
        if remaining <= UsageWindow.exhaustedRemainingPercent { return .red }
        return remaining < 20 ? .orange : (remaining < 50 ? .yellow : .green)
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

private struct ProviderEmptyRow: View {
    @EnvironmentObject private var language: LanguageStore
    let provider: AIProvider

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: provider.icon)
                .foregroundStyle(.secondary)
            Text(language.text("Chưa có tài khoản đã lưu", "No saved accounts"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 3)
    }
}

private struct ProviderSectionHeader: View {
    let provider: AIProvider
    let accountCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: provider.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            Text(provider.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text("\(accountCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .textCase(nil)
    }
}

private struct SidebarStateLabel: View {
    let title: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.top, 4)
    }
}

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
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
        }
        .onAppear {
            store.refreshProviderStatus(silently: true)
        }
    }
}

private struct OpenAIStatusCard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openURL) private var openURL

    private let sourceURL = URL(string: "https://status.openai.com/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(language.text("Trạng thái dịch vụ OpenAI", "OpenAI service status"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
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
                    Text(localizedOpenAIStatus(status.description))
                        .font(.body.weight(.semibold))
                    Spacer()
                    Button(language.text("Cập nhật", "Refresh")) { store.refreshOpenAIStatus() }
                        .controlSize(.small)
                        .disabled(store.isLoadingOpenAIStatus)
                }

                if !status.codexComponents.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(status.codexComponents) { component in
                            Label(component.name, systemImage: component.isOperational ? "circle.fill" : "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(component.isOperational ? Color.secondary : Color.orange)
                                .lineLimit(1)
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 15))
    }

    private func localizedOpenAIStatus(_ description: String) -> String {
        guard language.language == .vietnamese, description == "All Systems Operational" else {
            return description
        }
        return "Mọi hệ thống đang hoạt động"
    }
}

private struct GlobalResetOutlookCard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openURL) private var openURL

    private let sourceURL = URL(string: "https://x.com/thsottiaux")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(language.text("Tibo reset radar", "Tibo reset radar"), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Button {
                    openURL(outlookSourceURL ?? sourceURL)
                } label: {
                    Label("@thsottiaux", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

            if let outlook = store.resetOutlook {
                let isConfirmedReset = outlook.lastResetIsConfirmed == true
                let urgencyColor = forecastColor(max(outlook.chance24Hours, outlook.chance48Hours), high: .orange)

                // Forecast scores with color-coded urgency
                HStack(spacing: 12) {
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
                        value: formatWindowForVietnam(outlook),
                        tint: .secondary
                    )
                }

                // Confidence indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(urgencyColor)
                        .frame(width: 8, height: 8)
                    Text(language.text(
                        "Độ tin cậy: \(localizedConfidence(outlook.confidence))",
                        "Confidence: \(localizedConfidence(outlook.confidence))"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if isConfirmedReset {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(language.text("Đã xác nhận", "Confirmed"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }

                // Cadence info
                if let cadenceDays = outlook.cadenceDays {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text(language.text(
                            "Nhịp reset: ~\(String(format: "%.1f", cadenceDays)) ngày",
                            "Reset cadence: ~\(String(format: "%.1f", cadenceDays)) days"
                        ))
                        if outlook.cadenceAccelerating == true {
                            Text(language.text("(tăng nhanh)", "(accelerating)"))
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Last reset / signal
                VStack(alignment: .leading, spacing: 2) {
                    Text(isConfirmedReset
                        ? language.text("Lần reset gần nhất", "Last reset")
                        : language.text("Tín hiệu gần nhất", "Latest signal"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(formattedResetDate(outlook.lastResetAt, language: language.language))
                            .font(.subheadline.weight(.semibold))
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(formattedRelativeResetDate(
                                outlook.lastResetAt,
                                relativeTo: context.date,
                                language: language.language
                            ))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Expected reset
                if let scheduledResetAt = outlook.nextResetAt {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(language.text("Reset dự kiến", "Expected reset"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formattedVietnamResetDate(scheduledResetAt, language: language.language))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                if let summary = outlook.signalSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                // Recent Reset Timeline
                if let timeline = store.resetTimeline, !timeline.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("Lịch sử reset", "Reset history"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(timeline.prefix(2)) { event in
                            HStack {
                                Text(event.date)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text(event.summary.prefix(50).description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // Juice Levels
                if let juice = store.resetJuice, !juice.efforts.isEmpty {
                    HStack(spacing: 12) {
                        Text(language.text("Effort", "Effort"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(juice.efforts.prefix(4)) { effort in
                            HStack(spacing: 2) {
                                Text(effort.effort.prefix(1).uppercased())
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text("\(effort.current)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(effort.delta > 0 ? .green : effort.delta < 0 ? .red : .secondary)
                            }
                        }
                    }
                }

                HStack {
                    Text(language.text("Quota tài khoản là xác nhận cuối cùng.", "Account quota is the final confirmation."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(language.text("Cập nhật", "Refresh")) { store.refreshResetOutlook() }
                        .controlSize(.small)
                        .disabled(store.isLoadingResetOutlook)
                }
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 15))
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
        trustedTiboSourceURL(store.resetOutlook?.sourceUrl)
    }
}

private struct ResetOutlookMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(width: 112, alignment: .leading)
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

private func formatWindowForVietnam(_ outlook: ResetOutlook) -> String {
    // API returns UTC time window (e.g., 11 PM - 2 AM UTC)
    // Convert to Vietnam time (UTC+7)
    let vnOffset = 7
    guard let startHour = outlook.windowStartHour, let endHour = outlook.windowEndHour else {
        return outlook.windowLabel
    }
    let startVN = (startHour + vnOffset) % 24
    let endVN = (endHour + vnOffset) % 24
    return "\(formatHour(startVN)) - \(formatHour(endVN))"
}

private func formatHour(_ hour: Int) -> String {
    switch hour {
    case 0: return "12 AM"
    case 12: return "12 PM"
    case 1..<12: return "\(hour) AM"
    default: return "\(hour - 12) PM"
    }
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

    let vietnamTimeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = vietnamTimeZone
    let components = calendar.dateComponents([.hour, .weekday], from: date)

    let posixLocale = Locale(identifier: "en_US_POSIX")
    let timeFormatter = DateFormatter()
    timeFormatter.locale = posixLocale
    timeFormatter.timeZone = vietnamTimeZone
    let dateFormatter = DateFormatter()
    dateFormatter.locale = posixLocale
    dateFormatter.timeZone = vietnamTimeZone
    let symbolFormatter = DateFormatter()
    symbolFormatter.locale = language.locale
    symbolFormatter.timeZone = vietnamTimeZone

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
    return "around \(timeFormatter.string(from: date)) \(weekday), \(dateFormatter.string(from: date)) Vietnam time"
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
                            .foregroundStyle(attentionCount == 0 ? Color.secondary : Color.orange)
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
                        .foregroundStyle(hasLiveSession ? Color.secondary : Color.orange)
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
                .disabled(store.isWorking)
            } else if provider != .openAI {
                Label(
                    hasLiveSession ? language.text("Live", "Live") : language.text("Offline", "Offline"),
                    systemImage: hasLiveSession ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(hasLiveSession ? Color.green : Color.secondary)
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

private struct UsagePill: View {
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount

    var body: some View {
        if account.usageError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(language.text("Hãy đăng nhập lại trước khi dùng tài khoản đã lưu này.", "Sign in again before using this saved account."))
        } else if account.primaryQuotaWindow != nil {
            HStack(spacing: 6) {
                if let window = account.usage?.fiveHour {
                    usageText("5h", window: window)
                }
                if let window = account.usage?.weekly {
                    usageText(language.text("Tuần", "Week"), window: window)
                }
            }
        } else if let plan = account.planLabel {
            Text(plan)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func usageText(_ label: String, window: UsageWindow) -> some View {
        Text("\(label) \(window.displayRemainingPercent)%")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(window.isDepleted ? .red : (window.remainingPercent < 20 ? .orange : .secondary))
    }
}

private struct AddAccountSheet: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    @State private var didStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(language.text("Thêm tài khoản", "Add account"), systemImage: "plus.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.tint)

            Text(language.text(
                "Hoàn tất đăng nhập OpenAI trong cửa sổ vừa mở. Roster sẽ tự nhận diện và lưu tài khoản mới.",
                "Finish signing in to OpenAI in the window that just opened. Roster will detect and save the new account automatically."
            ))
            .foregroundStyle(.secondary)

            GroupBox {
                HStack(spacing: 12) {
                    if isFinished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(progressTitle).font(.headline)
                        Text(saveStatusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if case let .saved(identity) = store.newAccountLoginState {
                Label(language.text(
                    "Đã lưu \(identity.email) vào Codex Roster.",
                    "Saved \(identity.email) to Codex Roster."
                ), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else if case let .failed(message) = store.newAccountLoginState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Label(language.text(
                "Phiên Codex hiện tại được sao lưu trước khi đăng nhập mới. Hủy sẽ khôi phục phiên trước.",
                "The current Codex session is backed up before a new sign-in. Cancel restores the previous session."
            ), systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack {
                if case .failed = store.newAccountLoginState {
                    Button(language.text("Thử lại", "Try again")) {
                        store.resetNewAccountLogin()
                        store.startNewAccountLogin()
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
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(store.isPendingLogin)
        .onAppear {
            guard !didStart else { return }
            didStart = true
            if case .idle = store.newAccountLoginState {
                store.startNewAccountLogin()
            } else if case .ready = store.newAccountLoginState {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    store.saveDetectedNewAccount()
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
                    try? await Task.sleep(for: .milliseconds(650))
                    dismiss()
                }
            }
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
            return language.text("Không cần bấm thêm — Roster đang theo dõi phiên Codex.", "No more clicks needed — Roster is watching the Codex session.")
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
    let remove: () -> Void
    let relogin: () -> Void

    private var isArchived: Bool { store.isArchived(account) }
    private var serverSessionRevoked: Bool {
        account.usageError?.localizedCaseInsensitiveContains("[server_session_revoked]") == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
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
                    Spacer()
                    Button(language.text("Sửa", "Edit"), action: edit)
                    .disabled(store.isWorking)
                    Button(isArchived ? language.text("Khôi phục", "Restore") : language.text("Lưu trữ", "Archive")) {
                        isArchived ? restore() : archive()
                    }
                    .disabled(store.isWorking)
                    Button(language.text("Xóa", "Remove"), role: .destructive, action: remove)
                        .disabled(store.isWorking)
                    if !isArchived && account.requiresLogin {
                        Button(language.text("Đăng nhập lại", "Sign in again"), action: relogin)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(store.isWorking)
                    } else if !isArchived && !account.isActive
                                && !account.requiresLogin && !account.requiresLocalRecovery {
                        Button(language.text("Chuyển sang tài khoản này", "Activate"), action: activate)
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isWorking)
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

                if let credits = account.usage?.credits, credits.unlimited || credits.hasDisplayableBalance {
                    GroupBox(language.text("Tín dụng ChatGPT", "ChatGPT credits")) {
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
                        Button(language.text("Bắt đầu đăng nhập lại…", "Start sign-in again…"), action: relogin)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(store.isWorking || isArchived)
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
                    .disabled(store.isWorking || isArchived)
                }
            }
            .padding(32)
        }
        .navigationTitle(account.email)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: home) {
                    Label(language.text("Tổng quan", "Overview"), systemImage: "house")
                }
                .help(language.text("Quay về trang tổng quan", "Return to overview"))
            }
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
        if account.hasTransientUsageError { return .yellow }
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
            tint: account.hasTransientUsageError ? .yellow : .accentColor
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

private struct ReloginAccountSheet: View {
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
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(language.text(
                    "Đăng nhập \(account.email) trong cửa sổ vừa mở. Roster sẽ tự xác minh và cập nhật phiên này.",
                    "Sign in as \(account.email) in the window that just opened. Roster will verify and update this session automatically."
                ))
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
                            .font(.headline)
                        Text(isCompleting
                            ? language.text("Đang lưu phiên và kiểm tra lại quota…", "Saving the session and checking quota…")
                            : language.text("Không cần tải lại hay bấm Lưu — Roster tự hoàn tất khi nhận diện \(account.email).", "No reload or Save click needed — Roster finishes when it detects \(account.email)."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                .font(.footnote.weight(.medium))
                .foregroundStyle(.tint)
            }

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Label(language.text(
                "Phiên Codex đang dùng được sao lưu trước khi mở đăng nhập mới. Hủy sẽ khôi phục phiên trước. Phải đăng nhập đúng \(account.email).",
                "The current Codex session is backed up before the new sign-in. Cancel restores it. You must sign in as \(account.email)."
            ), systemImage: "lock.shield")
            .font(.footnote)
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
        .frame(width: 500)
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
    }
}

private struct AccountEditorSheet: View {
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
                .font(.title2.weight(.bold))
                .foregroundStyle(.tint)
            Text(account.email)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                TextField(language.text("Tên hiển thị", "Display name"), text: $label, prompt: Text(account.name ?? account.email))
            }
            .formStyle(.grouped)

            Text(language.text(
                "Đặt tên để dễ nhận biết tài khoản.",
                "Choose a name that makes the account easy to recognize."
            ))
            .font(.caption)
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
        .frame(width: 480)
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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct BankedResetCard: View {
    @EnvironmentObject private var language: LanguageStore
    let summary: BankedResetSummary

    private var availableCount: Int { max(0, summary.availableCount) }
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
                        .font(.caption2.weight(.semibold))
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
                        .foregroundStyle(expiry < Date() ? Color.red : Color.secondary)
                    } else {
                        Text(language.text("Không có ngày hết hạn", "No expiry reported"))
                    }
                }
                .font(.caption2)
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

    private var quickSwitchAccounts: [SavedAccount] {
        Array(switchTargets.prefix(3))
    }

    private var remainingSwitchAccounts: [SavedAccount] {
        Array(switchTargets.dropFirst(3))
    }

    private var switchTargets: [SavedAccount] {
        store.sortedAccounts(switchableAccounts.filter { !$0.isActive })
    }

    private var switchableAccounts: [SavedAccount] {
        store.accounts.filter {
            !store.isArchived($0)
                && !$0.usageErrorBlocksActivation
                && ($0.isUsableForSwitch || $0.canSwitchUsingBankedReset)
        }
    }

    private var hiddenQuickSwitchCount: Int {
        remainingSwitchAccounts.count
    }

    private var attentionCount: Int {
        store.accounts.filter { !store.isArchived($0) && $0.requiresLogin }.count
    }

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !store.isArchived($0) }
    }

    private var totalSavedProviderAccounts: Int {
        guard !store.providerStates.isEmpty else { return store.accounts.count }
        return store.providerStates.reduce(0) { $0 + $1.savedAccounts }
    }

    private var liveProviderCount: Int {
        store.providerStates.filter(\.available).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuBarHeader(
                savedCount: totalSavedProviderAccounts,
                liveProviderCount: liveProviderCount,
                attentionCount: attentionCount
            )

            if store.isBusyForActions || store.isCheckingAutoSwitch || store.errorMessage != nil || store.autoSwitchState != nil {
                MenuBarOperationStatus()
            }

            if store.isPendingLogin {
                HStack(spacing: 7) {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(.blue)
                    Text(language.text(
                        "Đang thêm/đăng nhập lại tài khoản. Hủy để khôi phục phiên trước.",
                        "Adding or re-signing an account. Cancel to restore the previous session."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(language.text("Hủy", "Cancel")) {
                        store.cancelPendingLogin()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            }

            MenuBarCurrentSession(
                account: activeAccount,
                email: store.status?.currentAccount?.email,
                chatGPTRunning: store.hasRunningCodexProcesses
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(language.text("Chuyển nhanh", "Quick switch"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(language.text("\(switchTargets.count) khả dụng", "\(switchTargets.count) available"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if quickSwitchAccounts.isEmpty {
                    Text(language.text("Chưa có tài khoản khác đủ điều kiện để chuyển.", "No other saved account is available to switch."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 3) {
                        ForEach(quickSwitchAccounts) { account in
                            Button { requestActivation(account) } label: {
                                MenuBarAccountRow(account: account)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .menuBarInteractive(cornerRadius: 9)
                            .disabled(store.isBusyForActions)
                        }
                    }
                }
            }

            if hiddenQuickSwitchCount > 0 {
                Menu {
                    ForEach(remainingSwitchAccounts) { account in
                        Button {
                            requestActivation(account)
                        } label: {
                            Text(account.displayName)
                        }
                    }
                } label: {
                    Label(
                        language.text("Chuyển sang \(hiddenQuickSwitchCount) tài khoản khác", "Switch to \(hiddenQuickSwitchCount) more accounts"),
                        systemImage: "ellipsis.circle"
                    )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(rosterActionBlue)
                .menuBarInteractive()
                .disabled(store.isBusyForActions)
            }

            if attentionCount > 0 {
                Button { openReloginFlow() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(language.text("\(attentionCount) tài khoản cần đăng nhập", "\(attentionCount) accounts need sign-in"))
                        Spacer()
                        Text(language.text("Đăng nhập lại", "Sign in again"))
                            .font(.caption2.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .menuBarInteractive(cornerRadius: 9)
            }

            MenuBarLiveSignals()
            MenuBarUpdateStatus()

            Divider()
                .padding(.top, 4)
            HStack(spacing: 8) {
                Button { refreshMenuBar() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .menuBarInteractive()
                .disabled(store.isBusyForActions || store.isLoadingOpenAIStatus || store.isLoadingResetOutlook)
                .help(language.text("Làm mới tài khoản và tín hiệu live", "Refresh accounts and live signals"))

                Button { openDashboard() } label: {
                    Label(language.text("Mở Codex Roster", "Open Codex Roster"), systemImage: "square.grid.2x2")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .menuBarInteractive()
                .help(language.text("Mở bảng điều khiển đầy đủ.", "Open the full dashboard."))

                Menu {
                    Button { openAddAccountFlow() } label: {
                        Label(language.text("Thêm tài khoản", "Add account"), systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(store.isWorking || store.isPendingLogin)

                    Toggle(isOn: Binding(
                        get: { store.autoSwitchWhenExhausted },
                        set: { store.setAutoSwitchWhenExhausted($0) }
                    )) {
                        Label(language.text("Tự động chuyển khi hết quota", "Auto-switch when exhausted"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)

                    Toggle(isOn: Binding(
                        get: { store.autoStartUsageWindows },
                        set: { store.setAutoStartUsageWindows($0) }
                    )) {
                        Label(language.text("Kiểm tra cửa sổ quota tự động", "Automatic quota window checks"), systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(store.isWorking)

                    Button { store.runUsageWindowCheck() } label: {
                        Label(language.text("Chạy kiểm tra quota", "Run quota check"), systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)

                    Divider()

                    Button { updater.checkForUpdates(currentVersion: AppInfo.shortVersion) } label: {
                        Label(language.text("Kiểm tra cập nhật", "Check for updates"), systemImage: "arrow.down.app")
                    }
                    .disabled(updater.state.isBusy)
                    Button { openAbout() } label: {
                        Label(language.text("Giới thiệu", "About"), systemImage: "info.circle")
                    }

                    Divider()

                    Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                        Label(language.text("Thoát Codex Roster", "Quit Codex Roster"), systemImage: "power")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuBarInteractive()
                .help(language.text("Tác vụ khác", "More actions"))
            }
            .padding(.vertical, 2)
        }
        .padding(14)
        .frame(width: 356, alignment: .leading)
        .onAppear {
            refreshMenuBar()
        }
    }

    private func requestActivation(_ account: SavedAccount) {
        store.noteMenuInteraction()
        store.activate(account, force: true)
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

    private func openReloginFlow() {
        let accountID = store.accounts.first { !store.isArchived($0) && $0.requiresLogin }?.id
        openDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .showReloginAccount, object: accountID?.uuidString)
        }
    }

    private func openAddAccountFlow() {
        openDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .showAddAccount, object: nil)
        }
    }

    private func openAbout() {
        openWindow(id: "about")
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.identifier?.rawValue == "about" })?
                .makeKeyAndOrderFront(nil)
        }
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
                        .font(.caption2.weight(.semibold))
                    Text(openAIStatusText)
                        .font(.caption2)
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
                    Text("Tibo radar")
                        .font(.caption2.weight(.semibold))
                    Text(resetSignalText)
                        .font(.caption2.monospacedDigit())
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
        return "\(outlook.chance24Hours)% / 24h"
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
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))

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
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }
}

private enum AppInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.9"
    }
}

private struct MenuBarHeader: View {
    @EnvironmentObject private var language: LanguageStore
    let savedCount: Int
    let liveProviderCount: Int
    let attentionCount: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.headline)
                .foregroundStyle(rosterActionBlue)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex Roster")
                    .font(.headline)
                Text(language.text(
                    "\(liveProviderCount)/4 provider live · \(savedCount) đã lưu",
                    "\(liveProviderCount)/4 providers live · \(savedCount) saved"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .help(language.text("Tài khoản cần đăng nhập", "Accounts needing sign-in"))
            }
        }
    }
}

private struct MenuBarProviderStrip: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    private var liveCount: Int {
        store.providerStates.filter(\.available).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(language.text("Providers", "Providers"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isLoadingProviderStatus && store.providerStates.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text(language.text("\(liveCount)/4 live", "\(liveCount)/4 live"))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(liveCount > 0 ? Color.green : Color.secondary)
                }
            }

            HStack(spacing: 6) {
                ForEach(AIProvider.allCases) { provider in
                    providerBadge(provider)
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.58), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func providerBadge(_ provider: AIProvider) -> some View {
        let state = store.providerStates.first { $0.provider == provider }
        let isLive = state?.available == true
        let savedCount = state?.savedAccounts ?? (provider == .openAI ? store.accounts.count : 0)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: provider.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isLive ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                Circle()
                    .fill(isLive ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 6, height: 6)
            }
            Text(provider.compactName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(language.text("\(savedCount) lưu", "\(savedCount) saved"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isLive ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        .help(providerHelp(provider, state: state))
    }

    private func providerHelp(_ provider: AIProvider, state: ProviderState?) -> String {
        guard let state else {
            return language.text("Đang kiểm tra \(provider.name)", "Checking \(provider.name)")
        }
        if let email = state.identity?.email, state.available {
            return language.text("\(provider.name) đang live: \(email)", "\(provider.name) live: \(email)")
        }
        if let error = state.usageError, !error.isEmpty {
            return error
        }
        return language.text("\(provider.name) chưa có phiên local đang hoạt động", "No active local \(provider.name) session")
    }
}

private struct MenuBarCurrentSession: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount?
    let email: String?
    let chatGPTRunning: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: account == nil ? "person.crop.circle.badge.questionmark" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(account == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("Phiên Codex", "Codex session"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(account?.displayName ?? email ?? language.text("Chưa đăng nhập", "Not signed in"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let account, account.displayName != account.email {
                    Text(account.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Label(
                        chatGPTRunning
                            ? language.text("ChatGPT đang mở", "ChatGPT running")
                            : language.text("ChatGPT đang đóng", "ChatGPT closed"),
                        systemImage: "circle.fill"
                    )
                    .foregroundStyle(chatGPTRunning ? Color.green : Color.secondary)

                    if let count = account?.usage?.bankedResets?.availableCount, count > 0 {
                        Label(
                            language.text("\(count) lượt reset", "\(count) banked"),
                            systemImage: "arrow.counterclockwise.circle.fill"
                        )
                        .foregroundStyle(rosterActionBlue)
                    }
                }
                .font(.caption2.weight(.medium))
            }
            Spacer(minLength: 2)
            if let emailToCopy = account?.email ?? email {
                Button {
                    copyAccountEmail(emailToCopy)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help(language.text("Sao chép email", "Copy email"))
                .menuBarInteractive()
            }
            Button {
                store.resyncChatGPTDesktop()
            } label: {
                Image(systemName: chatGPTRunning ? "arrow.triangle.2.circlepath" : "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(rosterActionBlue)
            .disabled(store.isBusyForActions)
            .menuBarInteractive()
            .help(chatGPTRunning
                ? language.text("Đồng bộ lại ChatGPT theo phiên này", "Resync ChatGPT with this session")
                : language.text("Mở ChatGPT theo phiên này", "Open ChatGPT with this session"))
            if let account, account.primaryQuotaWindow != nil {
                MenuBarQuota(account: account)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        .contextMenu {
            if let emailToCopy = account?.email ?? email {
                Button(language.text("Sao chép email", "Copy email")) {
                    copyAccountEmail(emailToCopy)
                }
            }
            Button(language.text("Mở lại ChatGPT theo phiên này", "Relaunch ChatGPT with this session")) {
                store.resyncChatGPTDesktop()
            }
            .disabled(store.isBusyForActions)
        }
    }
}

private struct MenuBarAccountRow: View {
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .foregroundStyle(rosterActionBlue)
                .font(.body)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(account.displayName)
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            if let resets = account.usage?.bankedResets, max(0, resets.availableCount) > 0 {
                Label("\(max(0, resets.availableCount))", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(language.text(
                        "Banked reset khả dụng: \(max(0, resets.availableCount))",
                        "Available banked resets: \(max(0, resets.availableCount))"
                    ))
                    .accessibilityLabel(language.text(
                        "Có \(max(0, resets.availableCount)) lượt banked reset",
                        "\(max(0, resets.availableCount)) banked resets available"
                    ))
            }
            if account.primaryQuotaWindow != nil {
                MenuBarQuota(account: account)
            } else {
                Text(language.text("Chưa có quota", "No quota"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button(language.text("Sao chép email", "Copy email")) {
                copyAccountEmail(account.email)
            }
        }
    }
}

private struct MenuBarQuota: View {
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount

    private func tint(_ window: UsageWindow) -> Color {
        Color.quotaTint(
            remainingPercent: window.remainingPercent,
            exhaustedAt: UsageWindow.exhaustedRemainingPercent
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let window = account.usage?.fiveHour {
                quotaLine(language.text("5 giờ", "5-hour"), window: window)
            }
            if let window = account.usage?.weekly {
                quotaLine(language.text("Tuần", "Weekly"), window: window)
            }
        }
        .frame(width: 148, alignment: .trailing)
    }

    private func quotaLine(_ label: String, window: UsageWindow) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(window.displayRemainingPercent)%")
                .fontWeight(.bold)
                .foregroundStyle(tint(window))
            Text(compactReset(window, language: language.language))
                .foregroundStyle(.secondary)
        }
        .font(.caption2.monospacedDigit())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(language.text(
            "\(label) còn \(window.displayRemainingPercent) phần trăm, \(compactReset(window, language: language.language))",
            "\(label) \(window.displayRemainingPercent) percent remaining, \(compactReset(window, language: language.language))"
        ))
    }
}

private struct AboutView: View {
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
    private let tiboXURL = URL(string: "https://x.com/thsottiaux")!
    private let openAIBrandURL = URL(string: "https://openai.com/brand/")!
    private let codexPricingURL = URL(string: "https://learn.chatgpt.com/docs/pricing")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 15) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Codex Roster")
                            .font(.title.weight(.bold))
                            .lineLimit(1)
                        Text(language.text("Quản lý tài khoản ChatGPT dùng với Codex", "ChatGPT account manager for Codex"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(language.text("Phiên bản", "Version") + " " + appVersion)
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    Picker(language.text("Ngôn ngữ", "Language"), selection: $language.language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                HStack(spacing: 10) {
                    AboutMetric(icon: "lock.shield.fill", title: "Local-first", detail: language.text("Dữ liệu ở trên Mac", "Data stays on this Mac"))
                    AboutMetric(icon: "waveform.path.ecg", title: language.text("Tín hiệu live", "Live signals"), detail: language.text("Quota · reset · dịch vụ", "Quota · reset · service"))
                    AboutMetric(icon: "macbook", title: "macOS", detail: language.text("Notch native", "Native notch"))
                }

                HStack(alignment: .top, spacing: 14) {
                    AboutPanel(title: language.text("Tóm tắt", "Overview"), icon: "person.3.sequence.fill") {
                        AboutBullet(icon: "person.crop.circle", text: language.text("Nhìn ngay phiên đang dùng, quota, thời điểm reset và banked reset.", "See the active session, quota, reset time, and banked resets at a glance."))
                        AboutBullet(icon: "antenna.radiowaves.left.and.right", text: language.text("Theo dõi live trạng thái OpenAI và tín hiệu reset công khai của Tibo.", "Monitor OpenAI service health and Tibo's public reset signals live."))
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
                        AboutBullet(icon: "waveform.path.ecg", text: language.text("Đọc trực tiếp tín hiệu reset công khai của Tibo trên X, rồi xác nhận riêng bằng quota tài khoản thực tế.", "Read Tibo's public reset signals directly from X, then verify separately against actual account quota."))
                        AboutBullet(icon: "lock.shield", text: language.text("Xuất/nhập file backup có mật khẩu; tự giữ 5 backup phiên đầy đủ được mã hóa bằng khóa Keychain trên máy này.", "Export/import password-protected backups; keep five full session backups encrypted with this Mac's Keychain key."))
                        AboutBullet(icon: "arrow.counterclockwise", text: language.text("Khôi phục danh sách hoặc phiên sao lưu gần nhất sau khi xác nhận.", "Restore the latest account list or saved sessions after confirmation."))
                    }
                    AboutFeatureGroup(title: language.text("Trải nghiệm hệ thống", "System experience")) {
                        AboutBullet(icon: "macbook", text: language.text("Notch hiển thị quota hiện tại, chuyển nhanh, trạng thái dịch vụ, refresh, mở dashboard và thoát ứng dụng.", "The notch shows current quota, quick switching, service state, refresh, dashboard access, and quit."))
                        AboutBullet(icon: "power", text: language.text("Tùy chọn mở Codex Roster khi đăng nhập macOS; hỗ trợ phím tắt, Dark Mode và song ngữ Việt–Anh (mặc định Tiếng Việt).", "Optionally launch at macOS sign-in; supports keyboard shortcuts, Dark Mode, and Vietnamese–English (Vietnamese by default)."))
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
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    Button(language.text("Xem hướng dẫn thương hiệu OpenAI", "View OpenAI brand guidelines")) {
                        openURL(openAIBrandURL)
                    }
                    .buttonStyle(.link)
                }

                AboutDisclosurePanel(title: language.text("Nguồn tham khảo & giấy phép", "References & licenses"), icon: "link") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(language.text(
                            "Đã đối chiếu lại nguồn ngày 22/08/2026. Nền tảng gốc và từng nguồn tham khảo được ghi rõ vai trò, giấy phép và ranh giới sử dụng bên dưới.",
                            "Sources re-audited on August 22, 2026. The original foundation and every reference are listed below with their role, license, and usage boundary."
                        ))
                        ReferenceLink(
                            title: "Pimpmuckl / codex-account-switcher",
                            detail: language.text("Nền tảng CLI gốc của Jonathan Liebig; Codex Roster là bản phát triển lại cho macOS.", "Original CLI foundation by Jonathan Liebig; Codex Roster is a macOS product rework."),
                            badge: "MIT · foundation",
                            url: foundationURL
                        )
                        ReferenceLink(
                            title: "steipete / CodexBar",
                            detail: language.text("Tham khảo UX notch, trạng thái quota và cách trình bày thời điểm reset; triển khai độc lập.", "Reference for notch UX, quota states, and reset-time presentation; independently implemented."),
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
                            title: "VibeCafe / @vibe-cafe/vibe-usage",
                            detail: language.text("Nguồn collector và API usage tùy chọn cho thống kê VibeCafe 7 ngày; Codex Roster tích hợp theo endpoint/format công khai và không nhập mã nguồn upstream.", "Optional collector and usage API source for VibeCafe 7-day statistics; Codex Roster integrates against the public endpoint/format without importing upstream source code."),
                            badge: "MIT · usage integration",
                            url: vibeUsageURL
                        )
                        ReferenceLink(
                            title: "Tibo / @thsottiaux",
                            detail: language.text("Nguồn tín hiệu reset công khai được đọc trực tiếp từ hồ sơ X; quota tài khoản vẫn là xác nhận cuối cùng.", "Public reset signals read directly from the X profile; account quota remains the final confirmation."),
                            badge: "X public profile · signal source",
                            url: tiboXURL
                        )
                        Text(language.text("Ngoại trừ nền tảng MIT được ghi rõ, Codex Roster không đưa mã nguồn, tài sản, credential hay state của các dự án tham khảo vào ứng dụng.", "Except for the credited MIT foundation, Codex Roster does not incorporate source code, assets, credentials, or state from the reference projects."))
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 560)
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
                .font(.system(size: 15, weight: .semibold))

                Text(badge)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text(detail)
                .font(.system(size: 15))
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
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(11)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct AboutPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
            content
                .font(.system(size: 15))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct AboutDisclosurePanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                content
                    .font(.system(size: 15))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct AboutBullet: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
    }
}

private struct AboutFeatureGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
            content
        }
        .padding(.bottom, 4)
    }
}

private func copyAccountEmail(_ email: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(email, forType: .string)
}

private func copyAccountEmails(_ emails: [String]) {
    guard !emails.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(emails.joined(separator: "\n"), forType: .string)
}
