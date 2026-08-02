import AppKit
import Darwin
import Foundation
import ServiceManagement

enum AccountSortMode: String, CaseIterable, Identifiable {
    case planThenQuota
    case quotaThenPlan
    case name
    case email

    var id: String { rawValue }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .planThenQuota:
            return language == .vietnamese ? "Gói → Quota" : "Plan → Quota"
        case .quotaThenPlan:
            return language == .vietnamese ? "Quota → Gói" : "Quota → Plan"
        case .name:
            return language == .vietnamese ? "Tên hiển thị" : "Display name"
        case .email:
            return "Email"
        }
    }
}

enum QuotaRefreshScope {
    case activeOnly
    case allSaved
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var status: StatusOutput?
    @Published private(set) var accounts: [SavedAccount] = []
    @Published private(set) var autoStartUsageWindows = false
    @Published private(set) var tokenUsage: TokenUsageSummary?
    @Published private(set) var resetOutlook: ResetOutlook?
    @Published private(set) var openAIStatus: OpenAIServiceStatus?
    @Published private(set) var autoSwitchWhenExhausted: Bool
    @Published private(set) var autoSwitchState: AutoSwitchState?
    @Published private(set) var isCheckingAutoSwitch = false
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var backupStatusMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isSwitching = false
    @Published private(set) var isLoadingTokenUsage = false
    @Published private(set) var isLoadingResetOutlook = false
    @Published private(set) var isLoadingOpenAIStatus = false
    @Published private(set) var isRefreshingQuotaInBackground = false
    @Published private(set) var lastQuotaRefreshAt: Date?
    @Published private(set) var accountSortMode: AccountSortMode
    @Published var errorMessage: String?

    private let cli = AccountHubCLI()
    private let archivedAccountsMigrationKeys = ["codexRoster.archivedAccountIDs", "accountHub.archivedAccountIDs"]
    private var legacyArchivedAccountIDs: Set<UUID>
    private let legacyAutoSwitchWhenExhaustedKey = "codexRoster.autoSwitchWhenExhausted"
    private let accountSortModeKey = "codexRoster.accountSortMode"
    private var autoSwitchTask: Task<Void, Never>?
    private var quotaRefreshTask: Task<Void, Never>?
    private var autoSwitchAllExhaustedNotified = false
    private var isInteractiveLoginInProgress = false
    private var coreBootstrapStarted = false
    private var menuInteractionUntil: Date?
    private var isRefreshingAccountsInBackground = false

    init() {
        let defaults = UserDefaults.standard
        legacyArchivedAccountIDs = Set(
            archivedAccountsMigrationKeys
                .flatMap { defaults.stringArray(forKey: $0) ?? [] }
                .compactMap(UUID.init(uuidString:))
        )
        autoSwitchWhenExhausted = false
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        if let raw = defaults.string(forKey: accountSortModeKey),
           let mode = AccountSortMode(rawValue: raw) {
            accountSortMode = mode
        } else {
            accountSortMode = .planThenQuota
        }
    }

    func setAccountSortMode(_ mode: AccountSortMode) {
        accountSortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: accountSortModeKey)
    }

    func sortedAccounts(_ accounts: [SavedAccount]) -> [SavedAccount] {
        accounts.sorted { left, right in
            switch accountSortMode {
            case .planThenQuota:
                if left.planSortRank != right.planSortRank {
                    return left.planSortRank < right.planSortRank
                }
                if left.switchQuotaScore != right.switchQuotaScore {
                    return left.switchQuotaScore > right.switchQuotaScore
                }
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            case .quotaThenPlan:
                if left.switchQuotaScore != right.switchQuotaScore {
                    return left.switchQuotaScore > right.switchQuotaScore
                }
                if left.planSortRank != right.planSortRank {
                    return left.planSortRank < right.planSortRank
                }
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            case .name:
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            case .email:
                return left.email.localizedCaseInsensitiveCompare(right.email) == .orderedAscending
            }
        }
    }

    var hasRunningCodexProcesses: Bool {
        ChatGPTDesktop.isRunning
    }

    private var quotaPollInterval: Duration {
        guard let remaining = accounts.first(where: { $0.isActive && !isArchived($0) })?
            .primaryQuotaWindow?
            .remainingPercent else {
            return .seconds(60)
        }
        if remaining <= 5 { return .seconds(10) }
        if remaining <= 20 { return .seconds(30) }
        return .seconds(60)
    }

    /// True while a user-driven roster mutation is in flight (not background quota checks).
    var isBusyForActions: Bool {
        isWorking || isSwitching
    }

    func noteMenuInteraction() {
        menuInteractionUntil = Date().addingTimeInterval(2)
    }

    func isArchived(_ account: SavedAccount) -> Bool {
        account.archived
    }

    func archive(_ account: SavedAccount) {
        run {
            _ = try await self.cli.data(arguments: ["archive", account.id.uuidString, "--json"])
            try await self.load()
        }
    }

    func restore(_ account: SavedAccount) {
        run {
            _ = try await self.cli.data(arguments: ["archive", account.id.uuidString, "--restore", "--json"])
            try await self.load()
        }
    }

    func refresh() {
        // Soft reload — do not freeze the dashboard behind the global busy overlay.
        guard !isBusyForActions else { return }
        Task {
            do {
                try await self.load()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func saveCurrentAccount() {
        run {
            _ = try await self.cli.data(arguments: ["save", "--json"])
            self.isInteractiveLoginInProgress = false
            try await self.load()
        }
    }

    func startNewAccountLogin() {
        isInteractiveLoginInProgress = true
        run {
            let liveStatus: StatusOutput = try await self.cli.decode(StatusOutput.self, arguments: ["status"])
            if liveStatus.currentAccount != nil {
                _ = try await self.cli.data(arguments: ["save", "--json"])
            }
            try CodexLoginLauncher.start()
            try await self.load()
        }
    }

    /// Open device login so the user can refresh an expired saved account.
    func startRelogin(for _: SavedAccount) {
        isInteractiveLoginInProgress = true
        run {
            let liveStatus: StatusOutput = try await self.cli.decode(StatusOutput.self, arguments: ["status"])
            // Preserve the currently active session before replacing it with a re-login.
            if liveStatus.currentAccount != nil {
                _ = try await self.cli.data(arguments: ["save", "--json"])
            }
            try CodexLoginLauncher.start()
            try await self.load()
        }
    }

    /// Save the live Codex session after re-login and confirm the target account recovered.
    @MainActor
    func completeRelogin(for account: SavedAccount) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        // Verify the live session email before save so a wrong login cannot upsert another row.
        try await load()
        guard let currentEmail = status?.currentAccount?.email else {
            throw CLIError(AppLanguage.text(
                "Chưa có phiên Codex sau đăng nhập. Hãy hoàn tất OpenAI device login rồi thử lại.",
                "No Codex session after sign-in. Finish OpenAI device login, then try again."
            ))
        }
        guard currentEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw CLIError(AppLanguage.text(
                "Phiên hiện tại là \(currentEmail), không phải \(account.email). Hãy đăng nhập đúng tài khoản rồi lưu lại.",
                "The current session is \(currentEmail), not \(account.email). Sign in as that account, then save again."
            ))
        }
        _ = try await cli.data(arguments: ["save", "--json"])
        isInteractiveLoginInProgress = false
        try await load()
        _ = try? await cli.data(arguments: ["usage", account.id.uuidString, "--json"])
        try await load()
        if accounts.first(where: { $0.id == account.id })?.requiresLogin == true {
            throw CLIError(AppLanguage.text(
                "Tài khoản \(account.email) vẫn cần đăng nhập. Hãy hoàn tất OpenAI device login rồi thử lưu lại.",
                "Account \(account.email) still needs sign-in. Finish OpenAI device login, then save again."
            ))
        }
    }

    func activate(_ account: SavedAccount, force: Bool = false) {
        run(switching: true) {
            let relaunch = force
                ? try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
                : ChatGPTDesktop.RelaunchPlan.preferredDesktop()
            var arguments = ["activate", account.id.uuidString]
            if force { arguments.append("--force") }
            let activated: ActivateOutput = try await self.cli.decode(ActivateOutput.self, arguments: arguments)
            self.applyActivatedAccount(activated.account)
            // Auth is restored. Reopen and verify Desktop in the background so a
            // slow LaunchServices response does not hold the switch UI hostage.
            self.relaunchDesktopInBackground(relaunch)
            let accountID = activated.account.id
            Task {
                try? await self.reloadAccountsAfterSwitch()
                self.refreshUsageAfterSwitch(accountID: accountID)
            }
        }
    }

    /// Quit ChatGPT Desktop if needed, then reopen it so the UI loads the current `~/.codex` session.
    func resyncChatGPTDesktop() {
        run(switching: true) {
            let relaunch = ChatGPTDesktop.isRunning
                ? try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
                : ChatGPTDesktop.RelaunchPlan.preferredDesktop()
            await relaunch.launchAndConfirm()
        }
    }

    func refreshAccountsInBackground() {
        noteMenuInteraction()
        guard !isBusyForActions, !isRefreshingAccountsInBackground else { return }
        isRefreshingAccountsInBackground = true
        Task {
            defer { isRefreshingAccountsInBackground = false }
            do {
                try await reloadAccountsAfterSwitch()
            } catch {
                // Keep cached roster visible; manual refresh can surface the error.
            }
        }
    }

    func startCoreMonitoring() {
        guard !coreBootstrapStarted else { return }
        coreBootstrapStarted = true
        refresh()
        refreshResetOutlook(silently: true)
        startAutoSwitchMonitoring()
        startQuotaMonitoring()
    }

    func delete(_ account: SavedAccount) {
        run {
            _ = try await self.cli.data(arguments: ["delete", account.id.uuidString, "--json"])
            try await self.load()
        }
    }

    func refreshUsage(scope: QuotaRefreshScope = .activeOnly) {
        run {
            let targets: [SavedAccount]
            switch scope {
            case .activeOnly:
                let active = self.accounts.filter { $0.isActive && !self.isArchived($0) }
                targets = active.isEmpty
                    ? Array(self.accounts.filter { !self.isArchived($0) }.prefix(1))
                    : active
            case .allSaved:
                targets = self.accounts.filter { !self.isArchived($0) }
            }
            for account in targets {
                _ = try? await self.cli.data(arguments: ["usage", account.id.uuidString, "--json"])
            }
            try await self.load()
            self.lastQuotaRefreshAt = .now
        }
    }

    func refreshUsage(for account: SavedAccount) {
        run {
            _ = try? await self.cli.data(arguments: ["usage", account.id.uuidString, "--json"])
            try await self.load()
            if account.isActive {
                self.lastQuotaRefreshAt = .now
            }
        }
    }

    func setAutoStartUsageWindows(_ enabled: Bool) {
        run {
            _ = try await self.cli.data(arguments: ["auto-start-usage-windows", enabled ? "--enable" : "--disable", "--json"])
            self.autoStartUsageWindows = enabled
            if enabled {
                await self.refreshActiveQuotaInBackground(allowWhileWorking: true)
            }
        }
    }

    func setAutoSwitchWhenExhausted(_ enabled: Bool) {
        run {
            _ = try await self.cli.data(arguments: ["auto-switch", enabled ? "--enable" : "--disable", "--json"])
            self.autoSwitchWhenExhausted = enabled
            self.autoSwitchState = nil
            self.autoSwitchAllExhaustedNotified = false
            if enabled {
                Task { await self.checkAutoSwitchWhenExhausted() }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        run {
            try LaunchAtLogin.setEnabled(enabled)
            self.launchAtLoginEnabled = LaunchAtLogin.isEnabled
        }
    }

    func exportBackup(to url: URL, password: String) {
        run {
            _ = try await self.cli.data(
                arguments: ["export", url.path, "--password-stdin", "--json"],
                standardInput: password + "\n"
            )
            self.backupStatusMessage = "Đã xuất bản sao lưu mã hóa."
        }
    }

    func importBackup(from url: URL, password: String) {
        run {
            _ = try await self.cli.data(
                arguments: ["import", url.path, "--password-stdin", "--json"],
                standardInput: password + "\n"
            )
            try await self.load()
            self.backupStatusMessage = "Đã nhập bản sao lưu mã hóa."
        }
    }

    func restoreLatestAccountListBackup() {
        run {
            _ = try await self.cli.data(arguments: ["restore-account-list-backup", "--json"])
            try await self.load()
            self.backupStatusMessage = "Đã khôi phục danh sách từ bản sao lưu tự động gần nhất."
        }
    }

    func restoreLatestFullBackup() {
        run {
            _ = try await self.cli.data(arguments: ["restore-full-backup", "--json"])
            try await self.load()
            self.backupStatusMessage = "Đã khôi phục toàn bộ tài khoản và phiên sao lưu tự động gần nhất."
        }
    }

    func ensureAutomaticFullBackup() {
        Task {
            _ = try? await cli.data(arguments: ["create-automatic-full-backup", "--json"])
        }
    }

    func startAutoSwitchMonitoring() {
        guard autoSwitchTask == nil else { return }
        autoSwitchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAutoSwitchWhenExhausted()
                try? await Task.sleep(for: self?.quotaPollInterval ?? .seconds(60))
            }
        }
    }

    func startQuotaMonitoring() {
        guard quotaRefreshTask == nil else { return }
        quotaRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                while (self?.isBusyForActions == true || self?.shouldDeferBackgroundWork == true) && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                await self?.refreshActiveQuotaInBackground()
                try? await Task.sleep(for: self?.quotaPollInterval ?? .seconds(60))
            }
        }
    }

    func runAutoSwitchCheck() {
        Task { await checkAutoSwitchWhenExhausted() }
    }

    func runUsageWindowCheck() {
        run {
            _ = try await self.cli.data(arguments: ["auto-start-usage-windows", "--run", "--json"])
            try await self.load()
        }
    }

    func recoverLegacySnapshots() {
        run {
            _ = try await self.cli.data(arguments: ["recover-legacy-snapshots", "--json"])
            try await self.load()
        }
    }

    func updateAccount(_ account: SavedAccount, label: String) {
        run {
            let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedLabel != (account.customLabel ?? "") {
                _ = try await self.cli.data(arguments: ["set-label", account.id.uuidString, normalizedLabel, "--json"])
            }
            try await self.load()
        }
    }

    func refreshTokenUsage(silently: Bool = false) {
        guard !isLoadingTokenUsage else { return }
        isLoadingTokenUsage = true
        Task {
            defer { isLoadingTokenUsage = false }
            do {
                tokenUsage = try await cli.decode(TokenUsageSummary.self, arguments: ["token-usage"])
            } catch {
                if !silently { errorMessage = error.localizedDescription }
            }
        }
    }

    func refreshResetOutlook(silently: Bool = false) {
        guard !isLoadingResetOutlook else { return }
        isLoadingResetOutlook = true
        Task {
            defer { isLoadingResetOutlook = false }
            do {
                resetOutlook = try await cli.decode(ResetOutlook.self, arguments: ["reset-outlook"])
            } catch {
                if !silently { errorMessage = error.localizedDescription }
            }
        }
    }

    func refreshOpenAIStatus(silently: Bool = false) {
        guard !isLoadingOpenAIStatus else { return }
        isLoadingOpenAIStatus = true
        Task {
            defer { isLoadingOpenAIStatus = false }
            do {
                openAIStatus = try await cli.decode(OpenAIServiceStatus.self, arguments: ["open-ai-status"])
            } catch {
                if !silently { errorMessage = error.localizedDescription }
            }
        }
    }

    private func load() async throws {
        async let status: StatusOutput = cli.decode(StatusOutput.self, arguments: ["status"])
        async let accounts: AccountListOutput = cli.decode(AccountListOutput.self, arguments: ["list"])
        async let settings: AutoStartUsageWindowsStatus = cli.decode(AutoStartUsageWindowsStatus.self, arguments: ["auto-start-usage-windows"])
        async let autoSwitch: AutoSwitchOutput = cli.decode(AutoSwitchOutput.self, arguments: ["auto-switch", "--status"])
        let (loadedStatus, loadedAccounts, loadedSettings, loadedAutoSwitch) = try await (status, accounts, settings, autoSwitch)
        self.status = loadedStatus
        self.accounts = loadedAccounts.accounts
        let pendingLegacyArchives = legacyArchivedAccountIDs.intersection(Set(loadedAccounts.accounts.map(\.id)))
        if !pendingLegacyArchives.isEmpty {
            for accountID in pendingLegacyArchives {
                _ = try? await cli.data(arguments: ["archive", accountID.uuidString, "--json"])
            }
            legacyArchivedAccountIDs.subtract(pendingLegacyArchives)
            for key in archivedAccountsMigrationKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            self.accounts = try await cli.decode(AccountListOutput.self, arguments: ["list"]).accounts
        }
        self.autoStartUsageWindows = loadedSettings.enabled
        if !loadedAutoSwitch.enabled,
           UserDefaults.standard.object(forKey: legacyAutoSwitchWhenExhaustedKey) != nil,
           UserDefaults.standard.bool(forKey: legacyAutoSwitchWhenExhaustedKey) {
            _ = try await cli.data(arguments: ["auto-switch", "--enable", "--json"])
            UserDefaults.standard.removeObject(forKey: legacyAutoSwitchWhenExhaustedKey)
            self.autoSwitchWhenExhausted = true
        } else {
            self.autoSwitchWhenExhausted = loadedAutoSwitch.enabled
        }
    }

    private func checkAutoSwitchWhenExhausted() async {
        guard autoSwitchWhenExhausted, !isBusyForActions, !isCheckingAutoSwitch, !shouldDeferBackgroundWork else { return }
        isCheckingAutoSwitch = true
        defer { isCheckingAutoSwitch = false }
        guard !isInteractiveLoginInProgress else {
            autoSwitchState = .waitingForLogin
            return
        }
        do {
            // Always decide first — ChatGPT being open must not hide an exhausted active account.
            let decision: AutoSwitchOutput = try await cli.decode(AutoSwitchOutput.self, arguments: ["auto-switch"])
            switch decision.status {
            case "active_has_quota":
                autoSwitchAllExhaustedNotified = false
                autoSwitchState = nil
            case "waiting_for_login":
                autoSwitchState = .waitingForLogin
            case "all_accounts_exhausted":
                if !autoSwitchAllExhaustedNotified {
                    autoSwitchState = .allAccountsExhausted
                    autoSwitchAllExhaustedNotified = true
                }
            case "ready":
                guard !isBusyForActions else { return }
                isSwitching = true
                defer { isSwitching = false }
                let candidateName = decision.candidateDisplayName
                    ?? AppLanguage.text("tài khoản khác", "another account")
                // Close Desktop when open, switch ~/.codex, then reopen. A live
                // Codex CLI must defer switching even after Desktop has quit.
                var relaunch = ChatGPTDesktop.RelaunchPlan.preferredDesktop()
                var didCloseDesktop = false
                if ChatGPTDesktop.isRunning {
                    autoSwitchState = .closingDesktop
                    relaunch = try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
                    didCloseDesktop = true
                }
                autoSwitchState = .switchingAccount
                var applyArguments = ["auto-switch", "--apply"]
                if let candidateId = decision.candidateAccountId {
                    applyArguments += ["--account-id", candidateId.uuidString]
                }
                var applied: AutoSwitchOutput = try await cli.decode(AutoSwitchOutput.self, arguments: applyArguments)
                if applied.status == "waiting_for_processes",
                   didCloseDesktop,
                   !ChatGPTDesktop.isRunning {
                    // Give process-table lag a short chance to clear, but never
                    // force through a live Codex CLI process.
                    for _ in 0..<3 where applied.status == "waiting_for_processes" {
                        try? await Task.sleep(for: .milliseconds(150))
                        applied = try await cli.decode(AutoSwitchOutput.self, arguments: applyArguments)
                    }
                }
                guard applied.status == "switched" else {
                    autoSwitchState = applied.status == "waiting_for_processes" ? .waitingForProcesses : .checkFailed
                    // Still try to restore Desktop if we closed it for a failed apply.
                    await relaunch.launchAndConfirm()
                    return
                }
                try await reloadAccountsAfterSwitch()
                autoSwitchState = .relaunchingDesktop
                relaunchDesktopInBackground(relaunch, afterAutoSwitch: true)
                autoSwitchState = .switched(applied.candidateDisplayName ?? candidateName)
                autoSwitchAllExhaustedNotified = false
            default:
                autoSwitchState = .checkFailed
            }
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("đóng") || message.contains("close") || message.contains("chatgpt") || message.contains("codex") {
                autoSwitchState = .waitingForProcesses
            } else {
                autoSwitchState = .checkFailed
            }
        }
    }

    private func refreshActiveQuotaInBackground(allowWhileWorking: Bool = false) async {
        guard autoStartUsageWindows,
              (allowWhileWorking || !isBusyForActions),
              !isCheckingAutoSwitch,
              !isRefreshingQuotaInBackground,
              !shouldDeferBackgroundWork,
              !isInteractiveLoginInProgress,
              let activeAccount = accounts.first(where: { $0.isActive && !isArchived($0) }) else {
            return
        }
        isRefreshingQuotaInBackground = true
        defer { isRefreshingQuotaInBackground = false }
        do {
            _ = try await cli.data(arguments: ["usage", activeAccount.id.uuidString, "--json"])
            try await reloadAccountsAfterSwitch()
            lastQuotaRefreshAt = .now
        } catch {
            // The last verified quota stays visible; manual refresh can surface the error.
        }
    }

    private var shouldDeferBackgroundWork: Bool {
        menuInteractionUntil.map { $0 > Date() } ?? false
    }

    private func run(switching: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusyForActions else { return }
        isWorking = true
        isSwitching = switching
        errorMessage = nil
        Task {
            defer {
                isWorking = false
                isSwitching = false
            }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadAccountsAfterSwitch() async throws {
        async let status: StatusOutput = cli.decode(StatusOutput.self, arguments: ["status"])
        async let accounts: AccountListOutput = cli.decode(AccountListOutput.self, arguments: ["list"])
        let (loadedStatus, loadedAccounts) = try await (status, accounts)
        self.status = loadedStatus
        self.accounts = loadedAccounts.accounts
    }

    private func relaunchDesktopInBackground(
        _ relaunch: ChatGPTDesktop.RelaunchPlan,
        afterAutoSwitch: Bool = false
    ) {
        Task { [weak self] in
            guard await relaunch.launchAndConfirm() else {
                guard let self else { return }
                if afterAutoSwitch {
                    self.autoSwitchState = .desktopRelaunchFailed
                }
                self.errorMessage = AppLanguage.text(
                    "Không thể mở lại ChatGPT. Hãy dùng nút Mở lại ChatGPT theo phiên này.",
                    "Could not relaunch ChatGPT. Use Relaunch ChatGPT with this session."
                )
                return
            }
        }
    }

    private func applyActivatedAccount(_ account: SavedAccount) {
        accounts = accounts.map { existing in
            if existing.id == account.id {
                return account.withActiveState(true)
            }
            return existing.withActiveState(false)
        }
        if !accounts.contains(where: { $0.id == account.id }) {
            accounts.insert(account.withActiveState(true), at: 0)
        }
        status = StatusOutput(
            currentAccount: AccountIdentity(email: account.email),
            processWarnings: status?.processWarnings ?? []
        )
    }

    private func refreshUsageAfterSwitch(accountID: UUID) {
        Task {
            _ = try? await cli.data(arguments: ["usage", accountID.uuidString, "--json"])
            guard !isBusyForActions else { return }
            try? await reloadAccountsAfterSwitch()
            if accounts.contains(where: { $0.id == accountID && $0.isActive }) {
                lastQuotaRefreshAt = .now
            }
        }
    }
}

enum AutoSwitchState: Equatable {
    case waitingForLogin
    case allAccountsExhausted
    case closingDesktop
    case switchingAccount
    case relaunchingDesktop
    case desktopRelaunchFailed
    case waitingForProcesses
    case switched(String)
    case checkFailed
}

private struct AccountHubCLI {
    func decode<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
        let data = try await data(arguments: arguments + ["--json"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let command = arguments.first ?? "requested"
            throw CLIError("Không thể đọc dữ liệu cho \(command). Hãy làm mới Codex Roster rồi thử lại.")
        }
    }

    func data(arguments: [String], standardInput: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.run(arguments: arguments, standardInput: standardInput))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func run(arguments: [String], standardInput: String? = nil) throws -> Data {
        let process = Process()
        let completed = DispatchSemaphore(value: 0)
        let output = Pipe()
        let error = Pipe()
        let input = standardInput.map { _ in Pipe() }
        process.standardOutput = output
        process.standardError = error
        process.standardInput = input

        if let path = ProcessInfo.processInfo.environment["CODEX_ROSTER_CLI_PATH"], !path.isEmpty {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        } else if let path = ProcessInfo.processInfo.environment["ACCOUNT_HUB_CLI_PATH"], !path.isEmpty {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        } else if let path = ProcessInfo.processInfo.environment["NEXT_ACCOUNT_CLI_PATH"], !path.isEmpty {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        } else if let bundled = Bundle.main.url(forAuxiliaryExecutable: "codex-roster") {
            process.executableURL = bundled
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex-roster"] + arguments
        }

        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        let captures = DispatchGroup()
        let outputCapture = PipeCapture()
        let errorCapture = PipeCapture()
        captures.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCapture.read(from: output.fileHandleForReading)
            captures.leave()
        }
        captures.enter()
        DispatchQueue.global(qos: .utility).async {
            errorCapture.read(from: error.fileHandleForReading)
            captures.leave()
        }
        if let standardInput, let input {
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            try? input.fileHandleForWriting.close()
        }
        if completed.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
            output.fileHandleForReading.closeFile()
            error.fileHandleForReading.closeFile()
            _ = captures.wait(timeout: .now() + 2)
            throw CLIError("Codex Roster did not finish within two minutes.")
        }
        captures.wait()
        let outputData = outputCapture.data
        guard process.terminationStatus == 0 else {
            let errorData = errorCapture.data
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(detail?.isEmpty == false ? detail! : "The Codex Roster command failed.")
        }
        return outputData
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func read(from handle: FileHandle) {
        let value = handle.readDataToEndOfFile()
        lock.lock()
        captured = value
        lock.unlock()
    }
}

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum CodexLoginLauncher {
    static func start() throws {
        guard let loginURL = URL(string: "https://auth.openai.com/codex/device") else {
            throw CLIError("Unable to open the OpenAI sign-in page.")
        }
        NSWorkspace.shared.open(loginURL)

        let command = codexLoginCommand()
        let script = "tell application \"Terminal\" to do script \(appleScriptString(command))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
    }

    private static func codexLoginCommand() -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_ROSTER_CODEX_PATH"],
            environment["CODEX_BINARY_PATH"],
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        let executable = candidates
            .compactMap { $0 }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        if let executable {
            return "exec \(shellQuote(executable)) login --device-auth"
        }
        return "exec /usr/bin/env codex login --device-auth"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private enum ChatGPTDesktop {
    /// ChatGPT Desktop on macOS currently ships as `com.openai.codex`.
    private static let bundleIdentifiers = ["com.openai.codex", "com.openai.chat"]
    private static let knownAppPaths = [
        "/Applications/ChatGPT.app",
        "/Applications/Codex.app",
    ]
    private static let terminatePollInterval: Duration = .milliseconds(50)
    private static let forceTerminateDeadline: Duration = .milliseconds(800)
    private static let launchConfirmDeadline: Duration = .seconds(6)

    struct RelaunchPlan {
        let bundleIDs: [String]
        let appURLs: [URL]

        static func preferredDesktop() -> RelaunchPlan {
            let urls = resolvedAppURLs(for: bundleIdentifiers)
            let ids = bundleIdentifiers.filter { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
                    || knownAppPaths.contains(where: { path in
                        FileManager.default.fileExists(atPath: path)
                            && bundleIdentifier(at: URL(fileURLWithPath: path)) == id
                    })
            }
            return RelaunchPlan(
                bundleIDs: ids.isEmpty ? ["com.openai.codex"] : ids,
                appURLs: urls
            )
        }

        /// Open Desktop and wait until it is actually running, with a second attempt.
        @discardableResult
        func launchAndConfirm() async -> Bool {
            // LaunchServices often rejects an immediate reopen after force-quit.
            try? await Task.sleep(for: .milliseconds(350))
            await openDesktop()
            if await waitUntilRunning(deadline: .seconds(3)) {
                return true
            }
            await openDesktop()
            return await waitUntilRunning(deadline: launchConfirmDeadline)
        }

        private func openDesktop() async {
            // `/usr/bin/open` is reliable from a menu-bar accessory app;
            // NSWorkspace.openApplication frequently fails silently there.
            for bundleID in bundleIDs {
                if await openViaLaunchServices(arguments: ["-b", bundleID]) {
                    return
                }
            }
            for appURL in appURLs {
                if await openViaLaunchServices(arguments: ["-a", appURL.path]) {
                    return
                }
            }
            for path in knownAppPaths where FileManager.default.fileExists(atPath: path) {
                if await openViaLaunchServices(arguments: ["-a", path]) {
                    return
                }
            }
        }

        private func openViaLaunchServices(arguments: [String]) async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        process.waitUntilExit()
                        continuation.resume(returning: process.terminationStatus == 0)
                    } catch {
                        continuation.resume(returning: false)
                    }
                }
            }
        }

        private func waitUntilRunning(deadline: Duration) async -> Bool {
            let started = ContinuousClock.now
            while ContinuousClock.now - started < deadline {
                if await MainActor.run(body: { ChatGPTDesktop.isRunning }) {
                    return true
                }
                try? await Task.sleep(for: terminatePollInterval)
            }
            return await MainActor.run(body: { ChatGPTDesktop.isRunning })
        }
    }

    static var isRunning: Bool {
        !runningApplications.isEmpty
    }

    private static var runningApplications: [NSRunningApplication] {
        bundleIdentifiers.flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
    }

    /// Quits ChatGPT Desktop when `force` is true, and returns which apps to reopen.
    @discardableResult
    static func prepareForAccountSwitch(force: Bool = false) async throws -> RelaunchPlan {
        let runningApps = runningApplications
        let runningBundleIDs = Array(Set(runningApps.compactMap(\.bundleIdentifier)))
            .sorted { lhs, rhs in
                bundleIdentifiers.firstIndex(of: lhs) ?? 99 < bundleIdentifiers.firstIndex(of: rhs) ?? 99
            }
        let relaunchIDs = runningBundleIDs.isEmpty ? ["com.openai.codex"] : runningBundleIDs
        let relaunch = RelaunchPlan(
            bundleIDs: relaunchIDs,
            appURLs: resolvedAppURLs(for: relaunchIDs)
        )

        guard !runningApps.isEmpty else { return relaunch }
        guard force else {
            throw CLIError(AppLanguage.text(
                "Codex hoặc ChatGPT đang chạy. Hãy xác nhận chuyển (đóng & mở lại) hoặc đóng app trước.",
                "Codex or ChatGPT is running. Confirm switch (close & relaunch) or quit the app first."
            ))
        }

        // A direct switch is explicitly destructive: quit Desktop immediately, but
        // wait for it to exit before touching the shared Codex auth files.
        for app in runningApps {
            app.forceTerminate()
        }
        if await waitUntilQuit(deadline: forceTerminateDeadline) {
            return relaunch
        }
        for app in runningApplications {
            app.forceTerminate()
        }
        if await waitUntilQuit(deadline: .milliseconds(400)) {
            return relaunch
        }
        throw CLIError(AppLanguage.text(
            "Không thể đóng hoàn toàn ChatGPT Desktop trước khi chuyển tài khoản.",
            "Could not fully quit ChatGPT Desktop before switching accounts."
        ))
    }

    private static func resolvedAppURLs(for bundleIDs: [String]) -> [URL] {
        var urls: [URL] = []
        var seen = Set<URL>()
        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
               seen.insert(url).inserted {
                urls.append(url)
            }
        }
        if urls.isEmpty {
            for path in knownAppPaths {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path), seen.insert(url).inserted {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func bundleIdentifier(at appURL: URL) -> String? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            return nil
        }
        return bundleID
    }

    private static func waitUntilQuit(deadline: Duration) async -> Bool {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < deadline {
            if runningApplications.isEmpty {
                return true
            }
            try? await Task.sleep(for: terminatePollInterval)
        }
        return runningApplications.isEmpty
    }
}

private enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

struct StatusOutput: Decodable {
    let currentAccount: AccountIdentity?
    let processWarnings: [RunningProcess]

    init(currentAccount: AccountIdentity?, processWarnings: [RunningProcess]) {
        self.currentAccount = currentAccount
        self.processWarnings = processWarnings
    }
}

struct AccountIdentity: Decodable {
    let email: String

    init(email: String) {
        self.email = email
    }
}

struct RunningProcess: Decodable {
    let pid: Int
}

struct AccountListOutput: Decodable {
    let accounts: [SavedAccount]
}

struct ActivateOutput: Decodable {
    let account: SavedAccount
}

struct TokenUsageSummary: Decodable {
    let today: UInt64
    let last7Days: UInt64
    let last30Days: UInt64
    let last365Days: UInt64
    let allTime: UInt64
    let daily: [TokenUsageDay]
    let sessionsScanned: Int
    let tokenEvents: Int
}

struct ResetOutlook: Decodable {
    let updatedAt: String
    let lastResetAt: String
    let chance24Hours: Int
    let chance48Hours: Int
    let confidence: String
    let windowLabel: String
}

struct OpenAIServiceStatus: Decodable {
    let indicator: String
    let description: String
    let updatedAt: String
    let codexComponents: [OpenAIServiceComponent]

    var isOperational: Bool {
        indicator == "none"
    }
}

struct OpenAIServiceComponent: Identifiable, Decodable {
    let name: String
    let status: String

    var id: String { name }
    var isOperational: Bool { status == "operational" }
}

struct TokenUsageDay: Identifiable, Decodable {
    let date: String
    let tokens: UInt64

    var id: String { date }
}

struct SavedAccount: Identifiable, Decodable {
    let id: UUID
    let provider: String
    let email: String
    let name: String?
    let customLabel: String?
    let planLabel: String?
    let environment: String
    let isActive: Bool
    let archived: Bool
    let usage: AccountUsage?
    let usageError: String?

    func withActiveState(_ isActive: Bool) -> SavedAccount {
        SavedAccount(
            id: id,
            provider: provider,
            email: email,
            name: name,
            customLabel: customLabel,
            planLabel: planLabel,
            environment: environment,
            isActive: isActive,
            archived: archived,
            usage: usage,
            usageError: usageError
        )
    }

    init(
        id: UUID,
        provider: String,
        email: String,
        name: String?,
        customLabel: String?,
        planLabel: String?,
        environment: String,
        isActive: Bool,
        archived: Bool,
        usage: AccountUsage?,
        usageError: String?
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.name = name
        self.customLabel = customLabel
        self.planLabel = planLabel
        self.environment = environment
        self.isActive = isActive
        self.archived = archived
        self.usage = usage
        self.usageError = usageError
    }

    func usageStatus(in language: AppLanguage) -> String {
        if let usageError { return usageError }
        if let quota = primaryQuotaWindow {
            return language == .vietnamese
                ? "Đã xác minh quota Codex · còn \(quota.remainingPercent)%"
                : "Codex quota verified · \(quota.remainingPercent)% remaining"
        }
        return language == .vietnamese ? "Chưa cập nhật quota Codex" : "Codex quota not checked"
    }

    var requiresLogin: Bool {
        usageError?.localizedCaseInsensitiveContains("login required") == true
    }

    var displayName: String {
        customLabel?.isEmpty == false ? customLabel! : (name?.isEmpty == false ? name! : email)
    }

    var aiProvider: AIProvider {
        AIProvider(rawValue: provider) ?? .openAI
    }

    var primaryQuotaWindow: UsageWindow? {
        usage?.weekly ?? usage?.fiveHour
    }

    var quotaWindowsForSwitch: [UsageWindow] {
        [usage?.weekly, usage?.fiveHour].compactMap { $0 }
    }

    var isExhaustedForSwitch: Bool {
        quotaWindowsForSwitch.contains { $0.remainingPercent == 0 }
    }

    var isUsableForSwitch: Bool {
        !quotaWindowsForSwitch.isEmpty && quotaWindowsForSwitch.allSatisfy { $0.remainingPercent > 0 }
    }

    var switchQuotaScore: Int {
        primaryQuotaWindow?.remainingPercent ?? quotaWindowsForSwitch.map(\.remainingPercent).min() ?? -1
    }

    /// Lower rank sorts first: Pro → Plus → Team/Business → Free → unknown.
    var planSortRank: Int {
        let plan = (planLabel ?? "").lowercased()
        if plan.contains("pro") { return 0 }
        if plan.contains("plus") { return 1 }
        if plan.contains("team") || plan.contains("business") || plan.contains("enterprise") {
            return 2
        }
        if plan.contains("free") || plan.contains("go") { return 3 }
        if plan.isEmpty { return 5 }
        return 4
    }

}

struct AccountUsage: Decodable {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let credits: UsageCredits?
}

struct UsageCredits: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String

    var hasDisplayableBalance: Bool {
        hasCredits && !balance.isEmpty && balance != "null"
    }
}

struct UsageWindow: Decodable {
    let remainingPercent: Int
    let resetAt: RustDate

    func relativeReset(in language: AppLanguage) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = language.locale
        return formatter.localizedString(for: resetAt.value, relativeTo: Date())
    }

    func resetDescription(in language: AppLanguage) -> String {
        guard resetAt.value > Date() else {
            return language == .vietnamese ? "Đang chờ đặt lại" : "Reset pending"
        }
        return language == .vietnamese
            ? "Đặt lại \(relativeReset(in: language))"
            : "Resets \(relativeReset(in: language))"
    }
}

struct RustDate: Decodable {
    let value: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let encoded = try? container.decode(String.self), let value = Self.parseISO8601(encoded) {
            self.value = value
            return
        }

        var values = try container.decode([Int].self)
        guard values.count == 9 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Rust timestamp")
        }
        let year = values.removeFirst()
        let ordinal = values.removeFirst()
        let hour = values.removeFirst()
        let minute = values.removeFirst()
        let second = values.removeFirst()
        let nanosecond = values.removeFirst()
        let offsetSeconds = values[0] * 3_600 + values[1] * 60 + values[2]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let firstDay = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let localDate = calendar.date(
                  byAdding: DateComponents(
                      day: ordinal - 1,
                      hour: hour,
                      minute: minute,
                      second: second,
                      nanosecond: nanosecond
                  ),
                  to: firstDay
              )
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Rust timestamp")
        }
        value = localDate.addingTimeInterval(TimeInterval(-offsetSeconds))
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct AutoStartUsageWindowsStatus: Decodable {
    let enabled: Bool
}

struct AutoSwitchOutput: Decodable {
    let enabled: Bool
    let status: String
    let candidateAccountId: UUID?
    let candidateDisplayName: String?
}

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "open_ai"

    var id: String { rawValue }

    var name: String {
        "OpenAI / Codex"
    }

    var icon: String {
        "sparkles"
    }
}
