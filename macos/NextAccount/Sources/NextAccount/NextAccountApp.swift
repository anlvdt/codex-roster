import AppKit
import SwiftUI

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
    @StateObject private var store = AccountStore()
    @StateObject private var language = LanguageStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Window("Codex Roster", id: "dashboard") {
            ContentView()
                .environmentObject(store)
                .environmentObject(language)
                .environment(\.locale, language.language.locale)
                .task {
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

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(language)
                .environment(\.locale, language.language.locale)
                .task {
                    store.startCoreMonitoring()
                }
        } label: {
            Label(menuBarTitle, systemImage: "person.3.sequence.fill")
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Codex Roster \(menuBarTitle)")
        }
        .menuBarExtraStyle(.window)

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

    private var menuBarTitle: String {
        guard let remaining = store.accounts.first(where: \.isActive)?.primaryQuotaWindow?.remainingPercent else {
            return "—"
        }
        return "\(remaining)%"
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @State private var selection: UUID?
    @State private var accountForDeletion: SavedAccount?
    @State private var accountForEditing: SavedAccount?
    @State private var accountForRelogin: SavedAccount?
    @State private var showingAddAccount = false
    @State private var backupOperation: BackupOperation?

    var body: some View {
        NavigationSplitView {
            AccountSidebar(
                selection: $selection,
                edit: { accountForEditing = $0 },
                archive: { account in
                    store.archive(account)
                    if selection == account.id { selection = nil }
                },
                restore: { store.restore($0) },
                remove: { accountForDeletion = $0 },
                relogin: { accountForRelogin = $0 }
            )
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
                accountForRelogin = account
            } else if let account = store.accounts.first(where: { !store.isArchived($0) && $0.requiresLogin }) {
                selection = account.id
                accountForRelogin = account
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
        .sheet(item: $accountForRelogin) { account in
            ReloginAccountSheet(account: account)
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
                activate: { requestActivation(for: selected) },
                edit: { accountForEditing = selected },
                archive: {
                    store.archive(selected)
                    selection = nil
                },
                restore: { store.restore(selected) },
                remove: { accountForDeletion = selected },
                relogin: { accountForRelogin = selected }
            )
        } else {
            DashboardView(selection: $selection, relogin: { accountForRelogin = $0 })
        }
    }

    private var selectedAccount: SavedAccount? {
        store.accounts.first { $0.id == selection }
    }

}

private struct AccountSidebar: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: UUID?
    let edit: (SavedAccount) -> Void
    let archive: (SavedAccount) -> Void
    let restore: (SavedAccount) -> Void
    let remove: (SavedAccount) -> Void
    let relogin: (SavedAccount) -> Void
    @State private var searchText = ""
    @State private var expandedReadyProviders = Set(AIProvider.allCases.map(\.rawValue))
    @State private var expandedAttentionProviders = Set(AIProvider.allCases.map(\.rawValue))
    @State private var expandedArchived = false

    var body: some View {
        List(selection: $selection) {
            providerSection(.openAI)
            archivedSection
        }
        .navigationTitle("Codex Roster")
        .searchable(text: $searchText, prompt: language.text("Tìm tài khoản", "Search accounts"))
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Label(language.text("Sắp xếp", "Sort"), systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { store.accountSortMode },
                    set: { store.setAccountSortMode($0) }
                )) {
                    ForEach(AccountSortMode.allCases) { mode in
                        Text(mode.title(in: language.language)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
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
            .background(.bar)
        }
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

    private func accounts(for provider: AIProvider) -> [SavedAccount] {
        let accounts = searchText.isEmpty
            ? store.accounts
            : store.accounts.filter { account in
                [account.displayName, account.email, account.planLabel]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .localizedCaseInsensitiveContains(searchText)
            }
        return accounts.filter { $0.aiProvider == provider && !store.isArchived($0) }
    }

    @ViewBuilder
    private func providerSection(_ provider: AIProvider) -> some View {
        let providerAccounts = accounts(for: provider)
        let readyAccounts = store.sortedAccounts(providerAccounts.filter { !$0.requiresLogin })
        let attentionAccounts = store.sortedAccounts(providerAccounts.filter(\.requiresLogin))
        Section {
            if providerAccounts.isEmpty {
                ProviderEmptyRow(provider: provider)
            } else {
                accountGroup(
                    provider: provider,
                    accounts: readyAccounts,
                    state: .ready,
                    title: language.text("Sẵn sàng dùng", "Ready to use"),
                    tint: .green
                )
                if !attentionAccounts.isEmpty {
                    if !readyAccounts.isEmpty { Divider() }
                    accountGroup(
                        provider: provider,
                        accounts: attentionAccounts,
                        state: .attention,
                        title: language.text("Cần đăng nhập", "Needs sign-in"),
                        tint: .orange
                    )
                }
            }
        } header: {
            ProviderSectionHeader(provider: provider, accountCount: providerAccounts.count)
        }
    }

    @ViewBuilder
    private func accountGroup(
        provider: AIProvider,
        accounts: [SavedAccount],
        state: AccountListState,
        title: String,
        tint: Color
    ) -> some View {
        if !accounts.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding(for: provider, state: state)) {
                ForEach(accounts) { account in
                    AccountRow(
                        account: account,
                        isArchived: false,
                        edit: edit,
                        archive: archive,
                        restore: restore,
                        remove: remove,
                        relogin: relogin,
                        selection: $selection
                    )
                        .tag(account.id)
                }
            } label: {
                SidebarStateLabel(title: title, count: accounts.count, tint: tint)
            }
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        let archivedAccounts = store.sortedAccounts(store.accounts.filter(store.isArchived))
        if !archivedAccounts.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $expandedArchived) {
                    ForEach(archivedAccounts) { account in
                        AccountRow(
                            account: account,
                            isArchived: true,
                            edit: edit,
                            archive: archive,
                            restore: restore,
                            remove: remove,
                            relogin: relogin,
                            selection: $selection
                        )
                        .tag(account.id)
                    }
                } label: {
                    SidebarStateLabel(
                        title: language.text("Đã lưu trữ", "Archived"),
                        count: archivedAccounts.count,
                        tint: .secondary
                    )
                }
            }
        }
    }

    private enum AccountListState {
        case ready
        case attention
    }

    private func expansionBinding(for provider: AIProvider, state: AccountListState) -> Binding<Bool> {
        Binding(
            get: {
                switch state {
                case .ready: expandedReadyProviders.contains(provider.rawValue)
                case .attention: expandedAttentionProviders.contains(provider.rawValue)
                }
            },
            set: { isExpanded in
                switch state {
                case .ready:
                    if isExpanded { expandedReadyProviders.insert(provider.rawValue) }
                    else { expandedReadyProviders.remove(provider.rawValue) }
                case .attention:
                    if isExpanded { expandedAttentionProviders.insert(provider.rawValue) }
                    else { expandedAttentionProviders.remove(provider.rawValue) }
                }
            }
        )
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var selection: UUID?
    let relogin: (SavedAccount) -> Void
    @State private var automationExpanded = false
    @State private var confirmingFullBackupRestore = false

    private var readyAccounts: [SavedAccount] {
        store.sortedAccounts(store.accounts.filter { !store.isArchived($0) && !$0.requiresLogin })
    }

    private var attentionAccounts: [SavedAccount] {
        store.sortedAccounts(store.accounts.filter { !store.isArchived($0) && $0.requiresLogin })
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DashboardHero(
                    currentAccount: store.status?.currentAccount?.email,
                    accountCount: store.accounts.count,
                    readyAccounts: readyAccounts,
                    attentionAccounts: attentionAccounts,
                    selection: $selection,
                    relogin: relogin
                )

                ProviderOverview(selection: $selection)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        OpenAIStatusCard()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        GlobalResetOutlookCard()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        OpenAIStatusCard()
                        GlobalResetOutlookCard()
                    }
                }

                TokenUsageOverview()

                DisclosureGroup(isExpanded: $automationExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(language.text("Cập nhật quota tài khoản đang dùng mỗi phút", "Refresh the current account quota every minute"), isOn: Binding(
                            get: { store.autoStartUsageWindows },
                            set: { store.setAutoStartUsageWindows($0) }
                        ))
                        .disabled(store.isWorking)
                        Text(language.text(
                            "Quota được lấy lại từ OpenAI mỗi phút khi app đang mở. Các tài khoản khác giữ kết quả kiểm tra gần nhất; dùng nút Quota để kiểm tra toàn bộ.",
                            "While the app is open, the current account is checked with OpenAI every minute. Other accounts keep their last verified result; use Quota to check all accounts."
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
                        Divider()
                        Toggle(language.text("Mở Codex Roster khi đăng nhập macOS", "Open Codex Roster at login"), isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        .disabled(store.isWorking)
                        Text(language.text("Duy trì menu bar và các kiểm tra tự động sau khi bạn đăng nhập vào máy Mac.", "Keeps the menu bar and automatic checks available after you sign in to your Mac."))
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
                            ? language.text("Quota · mỗi phút", "Quota · every minute")
                            : language.text("Quota · tắt", "Quota · off"))
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

                if !attentionAccounts.isEmpty {
                    GroupBox(language.text("Cần xử lý", "Needs attention")) {
                        VStack(spacing: 0) {
                            ForEach(attentionAccounts.prefix(3)) { account in
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.displayName)
                                        Text(account.email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button {
                                        copyAccountEmail(account.email)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(language.text("Sao chép email", "Copy email"))
                                    Button(language.text("Đăng nhập lại", "Sign in again")) {
                                        selection = account.id
                                        relogin(account)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                    Button(language.text("Xem", "Review")) { selection = account.id }
                                        .buttonStyle(.borderless)
                                }
                                .contextMenu {
                                    Button(language.text("Sao chép email", "Copy email")) {
                                        copyAccountEmail(account.email)
                                    }
                                }
                                .padding(.vertical, 9)
                                if account.id != attentionAccounts.prefix(3).last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                GroupBox(language.text("Trạng thái Codex", "Codex status")) {
                    VStack(alignment: .leading, spacing: 7) {
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
        }
    }
}

private struct DashboardHero: View {
    @EnvironmentObject private var language: LanguageStore
    let currentAccount: String?
    let accountCount: Int
    let readyAccounts: [SavedAccount]
    let attentionAccounts: [SavedAccount]
    @Binding var selection: UUID?
    let relogin: (SavedAccount) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Label(language.text("Tổng quan tài khoản", "Account overview"), systemImage: "person.3.sequence.fill")
                    .font(.title2.weight(.bold))
                Text(language.text("Quản lý tài khoản ChatGPT dùng với Codex.", "Manage ChatGPT accounts used with Codex."))
                    .font(.body)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    HeroCount(value: accountCount, title: language.text("đã lưu", "saved"), tint: .accentColor)
                    HeroCount(value: readyAccounts.count, title: language.text("sẵn dùng", "available"), tint: .green)
                    HeroCount(value: attentionAccounts.count, title: language.text("cần xử lý", "need attention"), tint: attentionAccounts.isEmpty ? .secondary : .orange)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 8) {
                Label(language.text("Phiên Codex", "Codex session"), systemImage: "person.crop.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(currentAccount ?? language.text("Chưa đăng nhập", "Not signed in"))
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(language.text("Theo ~/.codex · khớp ChatGPT sau khi mở lại", "From ~/.codex · matches ChatGPT after relaunch"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let firstAttention = attentionAccounts.first {
                    Button(language.text("Đăng nhập lại \(attentionAccounts.count) tài khoản", "Sign in again for \(attentionAccounts.count) accounts")) {
                        selection = firstAttention.id
                        relogin(firstAttention)
                    }
                    .controlSize(.small)
                } else if let active = readyAccounts.first(where: \.isActive) {
                    Button(language.text("Xem tài khoản hiện tại", "View current account")) {
                        selection = active.id
                    }
                    .controlSize(.small)
                }
            }
            .frame(width: 245, alignment: .leading)
            .padding(16)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(22)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct HeroCount: View {
    let value: Int
    let title: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 74, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(dashboardCardFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(tint)
                .frame(width: 3, height: 28)
                .padding(.leading, 5)
        }
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
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(isLatest ? 1 : 0.80), Color.accentColor.opacity(isLatest ? 0.68 : 0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
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
                    Text(account.email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                    Text("GPT \(plan)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(language.text("Gói ChatGPT: \(plan). Codex có trong các gói ChatGPT; quota thay đổi theo gói, model và mức sử dụng.", "ChatGPT plan: \(plan). Codex is included with ChatGPT plans; quota varies by plan, model, and usage."))
                        .accessibilityLabel(language.text("Gói ChatGPT \(plan)", "ChatGPT plan \(plan)"))
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
        } else if let window = account.primaryQuotaWindow {
            HStack(spacing: 6) {
                ProgressView(value: Double(window.remainingPercent), total: 100)
                    .tint(tint(for: window.remainingPercent))
                    .frame(minWidth: 52, maxWidth: .infinity)
                Text("\(window.remainingPercent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint(for: window.remainingPercent))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityLabel(language.text("Quota còn \(window.remainingPercent) phần trăm, \(compactReset(window, language: language.language))", "\(window.remainingPercent) percent quota remaining, \(compactReset(window, language: language.language))"))
        } else {
            Text(language.text("Chưa có quota", "Quota not checked"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tint(for remaining: Int) -> Color {
        remaining < 20 ? .orange : (remaining < 50 ? .yellow : .green)
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
            Label("OpenAI / Codex", systemImage: "sparkles")
                .font(.headline)
            Text(language.text("Tình trạng đăng nhập và quota Codex của các tài khoản đã lưu.", "Sign-in health and Codex quota for saved accounts."))
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

    private let sourceURL = URL(string: "https://codex-reset.com/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(language.text("Tín hiệu reset cộng đồng", "Community reset outlook"), systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.headline)
                Spacer()
                Button { openURL(sourceURL) } label: {
                    Label("codex-reset.com", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

            if let outlook = store.resetOutlook {
                HStack(spacing: 10) {
                    ResetOutlookMetric(
                        title: language.text("24 giờ tới", "Next 24 hours"),
                        value: "\(outlook.chance24Hours)%",
                        tint: .accentColor
                    )
                    ResetOutlookMetric(
                        title: language.text("48 giờ tới", "Next 48 hours"),
                        value: "\(outlook.chance48Hours)%",
                        tint: .accentColor
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text("Đặt lại gần nhất", "Last global reset"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formattedResetDate(outlook.lastResetAt, language: language.language))
                            .font(.subheadline.weight(.semibold))
                        Text(language.text("Độ tin cậy: \(localizedConfidence(outlook.confidence)) · \(outlook.windowLabel)", "Confidence: \(localizedConfidence(outlook.confidence)) · \(outlook.windowLabel)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Text(language.text("Nguồn độc lập; quota của từng tài khoản trong app vẫn là thông tin chính xác nhất.", "Independent source; each account's quota in the app remains the most accurate signal."))
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

    private func localizedConfidence(_ value: String) -> String {
        guard language.language == .vietnamese else { return value.capitalized }
        return switch value.lowercased() {
        case "high": "Cao"
        case "medium": "Trung bình"
        case "low": "Thấp"
        default: value
        }
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

private struct ProviderStatusRow: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let provider: AIProvider
    @Binding var selection: UUID?

    private var accounts: [SavedAccount] {
        store.accounts.filter { $0.aiProvider == provider && !store.isArchived($0) }
    }

    private var readyAccounts: [SavedAccount] {
        store.sortedAccounts(accounts.filter { !$0.requiresLogin })
    }

    private var attentionCount: Int {
        accounts.filter(\.requiresLogin).count
    }

    private var bestQuotaWindow: UsageWindow? {
        readyAccounts.compactMap(\.primaryQuotaWindow).max { $0.remainingPercent < $1.remainingPercent }
    }

    private var quotaTint: Color {
        guard let bestQuotaWindow else { return .secondary }
        if bestQuotaWindow.remainingPercent < 20 { return .orange }
        if bestQuotaWindow.remainingPercent < 50 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: provider.icon)
                .font(.title3)
                .foregroundStyle(accounts.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name).font(.subheadline.weight(.semibold))
                if accounts.isEmpty {
                    Text(language.text("Chưa có tài khoản đã lưu", "No saved accounts"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(language.text("\(readyAccounts.count) sẵn sàng · \(attentionCount) cần đăng nhập", "\(readyAccounts.count) ready · \(attentionCount) need sign-in"))
                        .font(.caption)
                        .foregroundStyle(attentionCount == 0 ? Color.secondary : Color.orange)
                }
            }

            Spacer(minLength: 12)

            if let bestQuotaWindow {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(language.text("Quota Codex", "Codex quota"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(bestQuotaWindow.remainingPercent)%")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(quotaTint)
                    }
                    ProgressView(value: Double(bestQuotaWindow.remainingPercent), total: 100)
                        .tint(quotaTint)
                        .frame(width: 116)
                    Text(bestQuotaWindow.resetDescription(in: language.language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 140, alignment: .trailing)
            } else if !accounts.isEmpty {
                Text(language.text("Chưa có quota", "Quota not checked"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !accounts.isEmpty {
                Button(language.text("Xem", "View")) {
                    selection = readyAccounts.first?.id ?? accounts.first?.id
                }
                .controlSize(.small)
                if provider == .openAI {
                    Button(language.text("Cập nhật", "Refresh")) {
                        store.refreshUsage(scope: .activeOnly)
                    }
                    .controlSize(.small)
                    .disabled(store.isWorking)
                }
            }
        }
        .padding(.vertical, 14)
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
        } else if let remaining = account.usage?.weekly?.remainingPercent {
            Text("\(remaining)%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(remaining < 20 ? .orange : .secondary)
        } else if let plan = account.planLabel {
            Text(plan)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct AddAccountSheet: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    @State private var loginStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(language.text("Thêm tài khoản", "Add account"), systemImage: "plus.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.tint)

            Text(language.text(
                "Đăng nhập một tài khoản mới hoặc lưu phiên Codex đang dùng.",
                "Sign in to a new account or save the Codex session you are already using."
            ))
            .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(language.text("1. Đăng nhập tài khoản mới", "1. Sign in to a new account"), systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                    Text(language.text(
                        "Trang đăng nhập OpenAI và Terminal sẽ mở. Hoàn tất mã xác thực trong trình duyệt, rồi quay lại đây.",
                        "OpenAI sign-in and Terminal will open. Complete the device verification in your browser, then return here."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Button(language.text("Mở đăng nhập OpenAI", "Open OpenAI sign-in")) {
                        loginStarted = true
                        store.startNewAccountLogin()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isWorking)

                    if loginStarted {
                        Label(language.text(
                            "Đăng nhập đang chờ trong Terminal. Sau khi Codex báo thành công, hãy lưu phiên ở bước 2.",
                            "Sign-in is waiting in Terminal. When Codex confirms success, save the session in step 2."
                        ), systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(language.text("2. Lưu vào Codex Roster", "2. Save to Codex Roster"), systemImage: "tray.and.arrow.down.fill")
                        .font(.headline)
                    Text(store.status?.currentAccount?.email ?? language.text(
                        "Bạn cũng có thể lưu phiên đang đăng nhập mà không cần mở lại trang đăng nhập.",
                        "You can also save the current signed-in session without opening the sign-in page again."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button(language.text("Tải lại trạng thái", "Reload status")) {
                            store.refresh()
                        }
                        .disabled(store.isWorking)
                        Spacer()
                        Button(language.text("Lưu tài khoản đã đăng nhập", "Save signed-in account")) {
                            store.saveCurrentAccount()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isWorking || (!loginStarted && store.status?.currentAccount == nil))
                    }
                }
            }

            Label(language.text(
                "Phiên Codex hiện tại được lưu trước khi đăng nhập mới. Codex Roster không nhận mật khẩu, mã xác thực hoặc cookie của bạn.",
                "The current Codex session is saved before a new sign-in. Codex Roster never receives your password, verification code, or browser cookies."
            ), systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(language.text("Đóng", "Close")) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct AccountDetail: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount
    let activate: () -> Void
    let edit: () -> Void
    let archive: () -> Void
    let restore: () -> Void
    let remove: () -> Void
    let relogin: () -> Void

    private var isArchived: Bool { store.isArchived(account) }

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
                    } else if !isArchived && !account.isActive && !account.requiresLogin {
                        Button(language.text("Chuyển sang tài khoản này", "Activate"), action: activate)
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isWorking)
                    }
                }

                HStack(spacing: 16) {
                    UsageCard(title: language.text("Quota hiện tại", "Current quota"), window: account.usage?.fiveHour)
                    UsageCard(title: language.text("Quota theo chu kỳ", "Quota window"), window: account.usage?.weekly)
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
                        Label(language.text("Phiên Codex của tài khoản này đã hết hạn hoặc bị đăng xuất.", "This account's Codex session expired or was logged out."), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(language.text(
                            "Đăng nhập lại bằng đúng email \(account.email), rồi lưu phiên mới vào Codex Roster.",
                            "Sign in again with \(account.email), then save the new session into Codex Roster."
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
                        GridRow { Text(language.text("Trạng thái", "Status")).foregroundStyle(.secondary); Text(account.usageStatus(in: language.language)) }
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
    }
}

private struct ReloginAccountSheet: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    let account: SavedAccount
    @State private var loginStarted = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(language.text("Đăng nhập lại", "Sign in again"), systemImage: "arrow.triangle.2.circlepath")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(language.text(
                    "Làm mới phiên Codex cho \(account.displayName) (\(account.email)).",
                    "Refresh the Codex session for \(account.displayName) (\(account.email))."
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
                VStack(alignment: .leading, spacing: 10) {
                    Label(language.text("1. Đăng nhập đúng tài khoản này", "1. Sign in with this exact account"), systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                    Text(language.text(
                        "Trang OpenAI và Terminal sẽ mở. Hãy chọn/đăng nhập \(account.email), hoàn tất mã xác thực, rồi quay lại đây.",
                        "OpenAI and Terminal will open. Sign in as \(account.email), finish device verification, then return here."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Button(language.text("Mở đăng nhập OpenAI", "Open OpenAI sign-in")) {
                        localError = nil
                        loginStarted = true
                        store.startRelogin(for: account)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(store.isWorking)

                    if loginStarted {
                        Label(language.text(
                            "Đăng nhập đang chờ trong Terminal. Khi Codex báo thành công, lưu phiên ở bước 2.",
                            "Sign-in is waiting in Terminal. When Codex confirms success, save the session in step 2."
                        ), systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(language.text("2. Lưu phiên mới vào tài khoản này", "2. Save the new session to this account"), systemImage: "tray.and.arrow.down.fill")
                        .font(.headline)
                    Text(store.status?.currentAccount?.email ?? language.text(
                        "Sau khi đăng nhập xong, email phiên hiện tại sẽ hiện ở đây.",
                        "After sign-in finishes, the current session email appears here."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button(language.text("Tải lại trạng thái", "Reload status")) {
                            store.refresh()
                        }
                        .disabled(store.isWorking)
                        Spacer()
                        Button(language.text("Lưu & khôi phục tài khoản", "Save & restore account")) {
                            Task {
                                do {
                                    localError = nil
                                    try await store.completeRelogin(for: account)
                                    dismiss()
                                } catch {
                                    localError = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isWorking || store.status?.currentAccount == nil)
                    }
                }
            }

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Label(language.text(
                "Phiên Codex đang dùng sẽ được lưu trước khi mở đăng nhập mới. Phải đăng nhập đúng \(account.email).",
                "The current Codex session is saved before the new sign-in. You must sign in as \(account.email)."
            ), systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(language.text("Đóng", "Close")) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 560)
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
                Text(language.text("Còn \(window.remainingPercent)%", "\(window.remainingPercent)% remaining"))
                    .font(.title2.weight(.semibold))
                ProgressView(value: Double(window.remainingPercent), total: 100)
                    .tint(window.remainingPercent < 20 ? .orange : .accentColor)
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

private struct MenuBarView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openWindow) private var openWindow

    private var quickSwitchAccounts: [SavedAccount] {
        Array(
            store.sortedAccounts(switchableAccounts.filter { !$0.isActive && !$0.requiresLogin })
                .prefix(5)
        )
    }

    private var switchableAccounts: [SavedAccount] {
        store.accounts.filter {
            !store.isArchived($0) && !$0.requiresLogin && $0.isUsableForSwitch
        }
    }

    private var hiddenQuickSwitchCount: Int {
        max(0, switchableAccounts.filter { !$0.isActive }.count - quickSwitchAccounts.count)
    }

    private var attentionCount: Int {
        store.accounts.filter { !store.isArchived($0) && $0.requiresLogin }.count
    }

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !store.isArchived($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuBarHeader(savedCount: store.accounts.count, attentionCount: attentionCount)

            if store.isBusyForActions || store.isCheckingAutoSwitch || store.errorMessage != nil || store.autoSwitchState != nil {
                MenuBarOperationStatus()
            }

            MenuBarServiceHealth()

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
                    Text(language.text("\(switchableAccounts.filter { !$0.isActive }.count) có quota", "\(switchableAccounts.filter { !$0.isActive }.count) with quota"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if quickSwitchAccounts.isEmpty {
                    Text(language.text("Chưa có tài khoản khác có quota khả dụng để chuyển.", "No other saved account has quota available to switch."))
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
                Button {
                    openDashboard()
                } label: {
                    Label(
                        language.text("Xem thêm \(hiddenQuickSwitchCount) tài khoản", "View \(hiddenQuickSwitchCount) more accounts"),
                        systemImage: "arrow.right"
                    )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(rosterActionBlue)
                .menuBarInteractive()
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

            Toggle(isOn: Binding(
                get: { store.autoSwitchWhenExhausted },
                set: { store.setAutoSwitchWhenExhausted($0) }
            )) {
                Label(language.text("Tự động chuyển khi hết quota", "Auto-switch when quota is exhausted"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .menuBarInteractive()
            .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
            .help(language.text(
                "Hết quota: force-quit ChatGPT, chuyển ~/.codex, rồi mở lại Desktop.",
                "When exhausted: force-quit ChatGPT, switch ~/.codex, then relaunch Desktop."
            ))

            Divider()
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button(language.text("Mở Codex Roster", "Open Codex Roster")) { openDashboard() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .menuBarInteractive()
                Spacer(minLength: 14)
                HStack(spacing: 8) {
                    Button { store.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(language.text("Làm mới", "Refresh"))
                    .frame(width: 30, height: 28)
                    .menuBarInteractive()
                    .disabled(store.isBusyForActions)
                    Button { openAbout() } label: {
                        Image(systemName: "info.circle")
                    }
                    .help(language.text("Giới thiệu", "About"))
                    .frame(width: 30, height: 28)
                    .menuBarInteractive()
                    Button { NSApplication.shared.terminate(nil) } label: {
                        Image(systemName: "power")
                    }
                    .help(language.text("Thoát Codex Roster", "Quit Codex Roster"))
                    .frame(width: 30, height: 28)
                    .menuBarInteractive()
                }
            }
            .padding(.vertical, 2)
        }
        .padding(14)
        .frame(width: 356, alignment: .leading)
        .onAppear {
            store.refreshAccountsInBackground()
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

    private func openAbout() {
        openWindow(id: "about")
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.identifier?.rawValue == "about" })?
                .makeKeyAndOrderFront(nil)
        }
    }
}

private struct MenuBarServiceHealth: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        if let status = store.openAIStatus {
            HStack(spacing: 7) {
                Image(systemName: status.isOperational ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.isOperational ? .green : .orange)
                Text(status.isOperational
                    ? language.text("Dịch vụ OpenAI đang ổn định", "OpenAI services are operational")
                    : status.description)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.isOperational ? Color.secondary : Color.orange)
                Spacer()
                Button { store.refreshOpenAIStatus() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(3)
                .menuBarInteractive()
                .disabled(store.isLoadingOpenAIStatus)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background((status.isOperational ? Color.green : Color.orange).opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
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
        }
    }

    private var tint: Color {
        if store.isBusyForActions || store.isCheckingAutoSwitch { return .secondary }
        if store.errorMessage != nil { return .orange }
        switch store.autoSwitchState {
        case .some(.switched): return .green
        case .some(.closingDesktop), .some(.switchingAccount), .some(.relaunchingDesktop): return .secondary
        case .some(.waitingForLogin), .some(.allAccountsExhausted), .some(.desktopRelaunchFailed), .some(.waitingForProcesses), .some(.checkFailed): return .orange
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.3"
    }
}

private struct MenuBarHeader: View {
    @EnvironmentObject private var language: LanguageStore
    let savedCount: Int
    let attentionCount: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.headline)
                .foregroundStyle(rosterActionBlue)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Codex Roster")
                        .font(.headline)
                    Text("v\(AppInfo.shortVersion)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help(language.text("Phiên bản \(AppInfo.shortVersion)", "Version \(AppInfo.shortVersion)"))
                }
                Text(language.text("OpenAI / Codex · \(savedCount) đã lưu", "OpenAI / Codex · \(savedCount) saved"))
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

private struct MenuBarCurrentSession: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    let account: SavedAccount?
    let email: String?
    let chatGPTRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: account == nil ? "person.crop.circle.badge.questionmark" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(account == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("Phiên Codex (~/.codex)", "Codex session (~/.codex)"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(account?.displayName ?? email ?? language.text("Chưa đăng nhập", "Not signed in"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let account, account.displayName != account.email {
                        Text(account.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
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
                if let quota = account?.primaryQuotaWindow {
                    MenuBarQuota(window: quota)
                }
            }
            if chatGPTRunning {
                Button {
                    store.resyncChatGPTDesktop()
                } label: {
                    Label(
                        language.text("Mở lại ChatGPT theo phiên này", "Relaunch ChatGPT with this session"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(rosterActionBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(rosterActionBlue)
                .disabled(store.isBusyForActions)
                .menuBarInteractive(cornerRadius: 8)
                .help(language.text(
                    "Đóng rồi mở lại ChatGPT để giao diện khớp phiên Codex hiện tại.",
                    "Quit and reopen ChatGPT so the UI matches the current Codex session."
                ))
            } else {
                Button {
                    store.resyncChatGPTDesktop()
                } label: {
                    Label(
                        language.text("Mở ChatGPT theo phiên này", "Open ChatGPT with this session"),
                        systemImage: "play.fill"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(rosterActionBlue)
                .disabled(store.isBusyForActions)
                .menuBarInteractive()
            }
        }
        .padding(11)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
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
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let quota = account.primaryQuotaWindow {
                MenuBarQuota(window: quota)
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
    let window: UsageWindow

    private var tint: Color {
        window.remainingPercent < 20 ? .orange : (window.remainingPercent < 50 ? .yellow : .green)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(window.remainingPercent)%")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(tint)
                .frame(width: 54)
            Text(window.relativeReset(in: language.language))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.88)
        }
        .frame(width: 108, alignment: .trailing)
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
                        Text(language.text("Quản lý tài khoản ChatGPT dùng với Codex", "ChatGPT account manager for Codex"))
                            .foregroundStyle(.secondary)
                        Text(language.text("Phiên bản", "Version") + " " + appVersion)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Picker(language.text("Ngôn ngữ", "Language"), selection: $language.language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                HStack(spacing: 10) {
                    AboutMetric(icon: "person.3.fill", title: language.text("Tài khoản", "Accounts"), detail: "OpenAI / Codex")
                    AboutMetric(icon: "chart.bar.xaxis", title: language.text("Quota", "Quota"), detail: language.text("Theo dõi mức dùng", "Usage tracking"))
                    AboutMetric(icon: "character.bubble", title: "VI / EN", detail: language.text("Tiếng Việt mặc định", "Vietnamese by default"))
                }

                HStack(alignment: .top, spacing: 14) {
                    AboutPanel(title: language.text("Tóm tắt", "Overview"), icon: "person.3.sequence.fill") {
                        Text(language.text("Lưu, theo dõi quota và chuyển tài khoản ChatGPT / Codex.", "Save, track quota, and switch ChatGPT / Codex accounts."))
                        AboutBullet(icon: "chart.bar.xaxis", text: language.text("Quota theo gói, model và mức dùng; hiển thị thời điểm đặt lại từ Codex", "Quota varies by plan, model, and usage; reset timing comes from Codex"))
                        AboutBullet(icon: "arrow.left.arrow.right.circle", text: language.text("Chuyển tài khoản nhanh", "Quick account switching"))
                    }

                    AboutPanel(title: language.text("Quyền riêng tư", "Privacy"), icon: "hand.raised.fill") {
                        Text(language.text("Thông tin tài khoản được lưu trên máy này.", "Account data is stored on this Mac."))
                        Text(language.text("Không chia sẻ dữ liệu tài khoản ra bên ngoài.", "Account data is not shared externally."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                AboutPanel(title: language.text("Thông báo Keychain macOS", "macOS Keychain prompt"), icon: "key.fill") {
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

                AboutPanel(title: language.text("Tất cả tính năng", "Complete feature set"), icon: "checklist") {
                    AboutFeatureGroup(title: language.text("Tài khoản & phiên", "Accounts & sessions")) {
                        AboutBullet(icon: "person.badge.plus", text: language.text("Mở đăng nhập thiết bị OpenAI, sau đó lưu phiên Codex đang dùng mà không đọc mật khẩu, mã xác thực hoặc cookie trình duyệt.", "Open OpenAI device sign-in, then save the active Codex session without reading passwords, verification codes, or browser cookies."))
                        AboutBullet(icon: "pencil", text: language.text("Đặt tên, sửa, tìm kiếm, lưu trữ, khôi phục và xóa từng tài khoản đã lưu.", "Label, edit, search, archive, restore, and remove each saved account."))
                        AboutBullet(icon: "sidebar.left", text: language.text("Nhóm sẵn sàng/cần đăng nhập; sắp xếp theo gói, quota, tên hoặc email; sao chép email nhanh.", "Group ready/needs-sign-in accounts; sort by plan, quota, name, or email; copy email quickly."))
                    }
                    AboutFeatureGroup(title: language.text("Quota & chuyển tài khoản", "Quota & switching")) {
                        AboutBullet(icon: "gauge.with.dots.needle.50percent", text: language.text("Theo dõi quota Codex, thời điểm reset và gói ChatGPT; làm mới tài khoản đang dùng mỗi phút hoặc kiểm tra toàn bộ theo yêu cầu.", "Track Codex quota, reset timing, and ChatGPT plan; refresh the active account every minute or check every account on demand."))
                        AboutBullet(icon: "arrow.left.arrow.right.circle", text: language.text("Chuyển nhanh từ menu bar; sắp xếp theo gói ChatGPT (Pro/Plus/Free) và quota còn lại.", "Quick-switch from the menu bar; sort by ChatGPT plan (Pro/Plus/Free) and remaining quota."))
                        AboutBullet(icon: "arrow.triangle.2.circlepath", text: language.text("Tự động chuyển khi hết quota (tùy chọn): đóng ChatGPT nếu cần, đổi phiên ~/.codex, rồi mở lại Desktop để khớp Roster; không lặp khi mọi tài khoản đều hết quota.", "Optional auto-switch when exhausted: close ChatGPT if needed, switch ~/.codex, then relaunch Desktop to match Roster; never loops when every account is exhausted."))
                        AboutBullet(icon: "arrow.clockwise.icloud", text: language.text("Nút “Mở lại ChatGPT theo phiên này” đóng rồi mở Desktop để khớp ~/.codex ngay.", "“Relaunch ChatGPT with this session” quits and reopens Desktop to match ~/.codex immediately."))
                    }
                    AboutFeatureGroup(title: language.text("Theo dõi & sao lưu", "Monitoring & backup")) {
                        AboutBullet(icon: "chart.bar.xaxis", text: language.text("Thống kê token cục bộ theo ngày, 7 ngày, 30 ngày và 12 tháng từ session logs.", "Read local session logs for token totals by day, 7 days, 30 days, and 12 months."))
                        AboutBullet(icon: "waveform.path.ecg", text: language.text("Theo dõi trạng thái công khai OpenAI và tín hiệu reset cộng đồng, tách biệt với quota tài khoản thực tế.", "Show public OpenAI status and community reset outlook separately from each account's actual quota."))
                        AboutBullet(icon: "lock.shield", text: language.text("Xuất/nhập file backup có mật khẩu; tự giữ 5 backup phiên đầy đủ được mã hóa bằng khóa Keychain trên máy này.", "Export/import password-protected backups; keep five full session backups encrypted with this Mac's Keychain key."))
                        AboutBullet(icon: "arrow.counterclockwise", text: language.text("Khôi phục danh sách hoặc phiên sao lưu gần nhất sau khi xác nhận.", "Restore the latest account list or saved sessions after confirmation."))
                    }
                    AboutFeatureGroup(title: language.text("Trải nghiệm hệ thống", "System experience")) {
                        AboutBullet(icon: "menubar.rectangle", text: language.text("Menu bar hiển thị quota hiện tại, chuyển nhanh, trạng thái dịch vụ, refresh, mở dashboard và thoát ứng dụng.", "Menu bar shows current quota, quick switching, service state, refresh, dashboard access, and quit."))
                        AboutBullet(icon: "power", text: language.text("Tùy chọn mở Codex Roster khi đăng nhập macOS; hỗ trợ phím tắt, Dark Mode và song ngữ Việt–Anh (mặc định Tiếng Việt).", "Optionally launch at macOS sign-in; supports keyboard shortcuts, Dark Mode, and Vietnamese–English (Vietnamese by default)."))
                        AboutBullet(icon: "desktopcomputer", text: language.text("Windows Preview đang phát triển bằng WinUI 3; dashboard và quota có sẵn, còn tự mở lại Codex trên Windows chỉ bật sau khi kiểm chứng an toàn.", "A WinUI 3 Windows Preview is in development; dashboard and quota are available, while Windows Codex relaunch waits for safe real-device validation."))
                    }
                }

                AboutPanel(title: language.text("Quota & gói ChatGPT", "ChatGPT plans & quota"), icon: "gauge.with.dots.needle.50percent") {
                    Text(language.text("Codex có trong các gói ChatGPT. Nhãn GPT Free, Plus hoặc Pro chỉ cho biết gói ChatGPT; quota và thời điểm đặt lại thay đổi theo gói, model và mức sử dụng.", "Codex is included with ChatGPT plans. GPT Free, Plus, or Pro identifies the ChatGPT plan; quota and reset timing vary by plan, model, and usage."))
                    Button(language.text("Xem chính sách quota OpenAI", "View OpenAI quota policy")) { openURL(codexPricingURL) }
                        .buttonStyle(.link)
                }

                AboutPanel(title: language.text("Tác giả & hỗ trợ", "Author & support"), icon: "bubble.left.and.bubble.right.fill") {
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

                DisclosureGroup(language.text("Nguồn tham khảo & giấy phép", "References & licenses")) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(language.text("Codex Roster phát triển từ nền tảng MIT codex-account-switcher của Jonathan Liebig.", "Codex Roster builds on the MIT codex-account-switcher foundation by Jonathan Liebig."))
                        ReferenceLink(title: "Pimpmuckl / codex-account-switcher", url: foundationURL)
                        ReferenceLink(title: "steipete / CodexBar", url: codexBarURL)
                        ReferenceLink(title: "jlcodes99 / cockpit-tools", url: cockpitToolsURL)
                        ReferenceLink(title: "Ducksss / codex-profiles", url: codexProfilesURL)
                        ReferenceLink(title: "vyctorbrzezowski / codex-switchboard", url: codexSwitchboardURL)
                        Text(language.text("Các dự án trên là nguồn cảm hứng để học hỏi và phát triển; Codex Roster có mã nguồn và giao diện riêng.", "These projects informed learning and development; Codex Roster has its own source code and interface."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 470)
        .navigationTitle(language.text("Giới thiệu Codex Roster", "About Codex Roster"))
    }
}

private struct ReferenceLink: View {
    @Environment(\.openURL) private var openURL
    let title: String
    let url: URL

    var body: some View {
        Button { openURL(url) } label: {
            Label(title, systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.link)
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
            Text(title).font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            content
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct AboutBullet: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct AboutFeatureGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
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
