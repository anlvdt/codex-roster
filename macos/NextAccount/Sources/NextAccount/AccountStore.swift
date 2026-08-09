import AppKit
import Darwin
import Foundation
import ServiceManagement
import UserNotifications

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

enum AccountActivationSafety {
    static let processDrainAttempts = 20

    static func arguments(accountID: UUID) -> [String] {
        ["activate", accountID.uuidString]
    }

    static func isProcessSafetyBlock(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("account switch blocked")
            || message.contains("codex appears to be running")
    }
}

enum NewAccountLoginState: Equatable {
    case idle
    case waiting
    case ready(AccountIdentity)
    case saving
    case saved(AccountIdentity)
    case failed(String)
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
    @Published private(set) var newAccountLoginState: NewAccountLoginState = .idle
    @Published private(set) var isPendingLogin = false
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
    private var isAddAccountSession = false
    private var expectedReloginEmail: String?
    private var newAccountLoginWatchTask: Task<Void, Never>?
    private var resetNotificationTask: Task<Void, Never>?
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

    func setArchived(_ accounts: [SavedAccount], archived: Bool) {
        let targets = accounts.filter { $0.archived != archived && !$0.isActive }
        guard !targets.isEmpty else { return }
        run {
            var failures = 0
            for account in targets {
                var arguments = ["archive", account.id.uuidString]
                if !archived { arguments.append("--restore") }
                do {
                    _ = try await self.cli.data(arguments: arguments + ["--json"])
                } catch {
                    failures += 1
                }
            }
            try await self.load()
            if failures > 0 {
                throw CLIError(AppLanguage.text(
                    "Đã xử lý \(targets.count - failures)/\(targets.count) tài khoản.",
                    "Updated \(targets.count - failures)/\(targets.count) accounts."
                ))
            }
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
            guard !self.isAddAccountSession else {
                throw CLIError(AppLanguage.text(
                    "Đăng nhập đang diễn ra. Hãy hoàn tất bước xác minh trong cửa sổ đăng nhập thay vì lưu phiên thủ công.",
                    "A login is in progress. Finish verification in the login window instead of saving the session manually."
                ))
            }
            _ = try await self.cli.data(arguments: ["save", "--json"])
            try await self.load()
        }
    }

    func startNewAccountLogin() {
        guard !isBusyForActions, newAccountLoginState != .waiting else { return }
        isInteractiveLoginInProgress = true
        isPendingLogin = true
        newAccountLoginState = .waiting
        run {
            try await self.beginOrResumeAddAccountLogin(expectedEmail: nil)
        }
    }

    func saveDetectedNewAccount() {
        guard case let .ready(expectedIdentity) = newAccountLoginState, !isBusyForActions else { return }
        newAccountLoginState = .saving
        run {
            let liveStatus: StatusOutput = try await self.cli.decode(StatusOutput.self, arguments: ["status"])
            guard let liveIdentity = liveStatus.currentAccount,
                  liveIdentity.matches(expectedIdentity) else {
                throw CLIError(AppLanguage.text(
                    "Phiên Codex đã thay đổi. Hãy chờ app nhận diện lại tài khoản mới rồi lưu.",
                    "The Codex session changed. Wait for the app to detect the new account again before saving."
                ))
            }
            let saveCommand = self.isAddAccountSession ? "save-added-account" : "save"
            let saved: SaveOutput = try await self.cli.decode(SaveOutput.self, arguments: [saveCommand])
            do {
                // Saving is only local evidence. Do not report success until
                // OpenAI accepts the freshly persisted access token.
                _ = try await self.cli.data(arguments: ["usage", saved.account.id.uuidString, "--json"])
            } catch {
                self.clearPendingLoginFlags()
                try? await self.load()
                throw CLIError(AppLanguage.text(
                    "OpenAI chưa chấp nhận credential mới. Tài khoản đã được giữ lại nhưng chưa được đánh dấu đăng nhập thành công.",
                    "OpenAI did not accept the new credential. The account was preserved but sign-in was not marked successful."
                ))
            }
            self.clearPendingLoginFlags()
            self.newAccountLoginState = .saved(liveIdentity)
            try await self.load()
            self.lastQuotaRefreshAt = .now
        }
    }

    func resetNewAccountLogin() {
        newAccountLoginWatchTask?.cancel()
        newAccountLoginWatchTask = nil
        clearPendingLoginFlags()
        newAccountLoginState = .idle
    }

    /// Cancel an unfinished add/re-login and restore the previous live Codex session.
    func cancelPendingLogin() {
        run {
            self.newAccountLoginWatchTask?.cancel()
            self.newAccountLoginWatchTask = nil
            CodexLoginLauncher.stop()
            _ = try await self.cli.data(arguments: ["cancel-add-account", "--json"])
            self.clearPendingLoginFlags()
            self.newAccountLoginState = .idle
            try await self.load()
        }
    }

    /// Open browser sign-in so the user can refresh an expired saved account.
    func startRelogin(for account: SavedAccount) {
        isInteractiveLoginInProgress = true
        isPendingLogin = true
        newAccountLoginState = .waiting
        run {
            try await self.beginOrResumeAddAccountLogin(expectedEmail: account.email)
        }
    }

    private func beginOrResumeAddAccountLogin(expectedEmail: String?) async throws {
        let addStatus = try await cli.decode(AddAccountStatusOutput.self, arguments: ["add-account-status"])
        if addStatus.active || isAddAccountSession {
            try await resumePendingLogin(expectedEmail: expectedEmail)
            return
        }

        let liveStatus = try await cli.decode(StatusOutput.self, arguments: ["status"])
        var began = false
        do {
            try await beginAddAccountAfterProcessesDrain()
            began = true
            isAddAccountSession = true
            expectedReloginEmail = expectedEmail
            isPendingLogin = true
            try CodexLoginLauncher.start()
            watchForNewAccount(after: liveStatus.currentAccount)
        } catch {
            if began {
                CodexLoginLauncher.stop()
                _ = try? await cli.data(arguments: ["cancel-add-account", "--json"])
                clearPendingLoginFlags()
                newAccountLoginState = .idle
            }
            throw error
        }
    }

    private func resumePendingLogin(expectedEmail: String?) async throws {
        isAddAccountSession = true
        expectedReloginEmail = expectedEmail
        isInteractiveLoginInProgress = true
        isPendingLogin = true
        newAccountLoginState = .waiting
        let addStatus = try await cli.decode(AddAccountStatusOutput.self, arguments: ["add-account-status"])
        let status = try? await cli.decode(StatusOutput.self, arguments: ["status"])
        if let current = status?.currentAccount,
           addStatus.authChanged,
           expectedEmail.map({ current.email.caseInsensitiveCompare($0) == .orderedSame }) ?? true {
            newAccountLoginState = .ready(current)
            return
        }
        try CodexLoginLauncher.start()
        watchForNewAccount(after: nil)
    }

    private func watchForNewAccount(after _: AccountIdentity?) {
        newAccountLoginWatchTask?.cancel()
        newAccountLoginWatchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard case .waiting = self.newAccountLoginState else { return }
                guard let addStatus = try? await self.cli.decode(AddAccountStatusOutput.self, arguments: ["add-account-status"]),
                      addStatus.active,
                      addStatus.authChanged,
                      let status = try? await self.cli.decode(StatusOutput.self, arguments: ["status"]),
                      let current = status.currentAccount else {
                    continue
                }
                if let expected = self.expectedReloginEmail,
                   current.email.caseInsensitiveCompare(expected) != .orderedSame {
                    continue
                }
                self.status = status
                self.newAccountLoginState = .ready(current)
                return
            }
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
                "Chưa có phiên Codex sau đăng nhập. Hãy hoàn tất đăng nhập OpenAI trên trình duyệt rồi thử lại.",
                "No Codex session after sign-in. Finish the OpenAI browser sign-in, then try again."
            ))
        }
        guard currentEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw CLIError(AppLanguage.text(
                "Phiên hiện tại là \(currentEmail), không phải \(account.email). Hãy đăng nhập đúng tài khoản rồi lưu lại.",
                "The current session is \(currentEmail), not \(account.email). Sign in as that account, then save again."
            ))
        }
        let saveCommand = isAddAccountSession ? "save-added-account" : "save"
        _ = try await cli.data(arguments: [saveCommand, "--json"])
        do {
            _ = try await cli.data(arguments: ["usage", account.id.uuidString, "--json"])
        } catch {
            clearPendingLoginFlags()
            try? await load()
            throw CLIError(AppLanguage.text(
                "OpenAI chưa chấp nhận credential mới của \(account.email). Tài khoản vẫn được giữ nguyên và hàng đợi sẽ không chuyển tiếp.",
                "OpenAI did not accept the new credential for \(account.email). The account was preserved and the queue will not advance."
            ))
        }
        clearPendingLoginFlags()
        newAccountLoginState = .idle
        try await load()
    }

    private func clearPendingLoginFlags() {
        CodexLoginLauncher.stop()
        isInteractiveLoginInProgress = false
        isAddAccountSession = false
        expectedReloginEmail = nil
        isPendingLogin = false
    }

    private func beginAddAccountAfterProcessesDrain() async throws {
        for attempt in 0..<AccountActivationSafety.processDrainAttempts {
            do {
                _ = try await cli.data(arguments: ["begin-add-account", "--json"])
                return
            } catch {
                guard AccountActivationSafety.isProcessSafetyBlock(error),
                      attempt + 1 < AccountActivationSafety.processDrainAttempts else {
                    throw error
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func activate(_ account: SavedAccount, force: Bool = false) {
        run(switching: true) {
            let desktopWasRunning = ChatGPTDesktop.isRunning
            let relaunch = force
                ? try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
                : ChatGPTDesktop.RelaunchPlan.preferredDesktop()
            let activated: ActivateOutput
            do {
                activated = try await self.activateAfterProcessesDrain(
                    accountID: account.id,
                    waitForDrain: force
                )
            } catch {
                // Desktop may already be closed while an independent Codex CLI
                // correctly blocks the switch. Restore the previous app/session.
                if desktopWasRunning {
                    await relaunch.launchAndConfirm()
                }
                throw error
            }
            let launched = await relaunch.launchAndConfirm()
            let accepted: Bool
            if launched {
                accepted = await self.waitForDesktopAcceptance(accountID: activated.account.id)
            } else {
                accepted = false
            }
            guard accepted else {
                do {
                    try await self.rollbackRejectedTarget(
                        rejectedAccountID: activated.account.id,
                        previousAccountID: activated.previousAccountId,
                        fallbackRelaunch: relaunch
                    )
                    try? await self.reloadAccountsAfterSwitch()
                } catch {
                    throw CLIError(AppLanguage.text(
                        "ChatGPT không chấp nhận tài khoản đích và không thể tự khôi phục phiên trước: \(error.localizedDescription)",
                        "ChatGPT rejected the target account and the previous session could not be restored automatically: \(error.localizedDescription)"
                    ))
                }
                throw CLIError(AppLanguage.text(
                    "ChatGPT không chấp nhận tài khoản đích; phiên trước đã được khôi phục an toàn.",
                    "ChatGPT rejected the target account; the previous session was restored safely."
                ))
            }
            self.applyActivatedAccount(activated.account)
            try await self.reloadAccountsAfterSwitch()
            if self.accounts.contains(where: { $0.id == activated.account.id && $0.isActive }) {
                self.lastQuotaRefreshAt = .now
            }
        }
    }

    private func activateAfterProcessesDrain(
        accountID: UUID,
        waitForDrain: Bool
    ) async throws -> ActivateOutput {
        for attempt in 0..<AccountActivationSafety.processDrainAttempts {
            do {
                return try await cli.decode(
                    ActivateOutput.self,
                    arguments: AccountActivationSafety.arguments(accountID: accountID)
                )
            } catch {
                guard waitForDrain,
                      AccountActivationSafety.isProcessSafetyBlock(error),
                      attempt + 1 < AccountActivationSafety.processDrainAttempts else {
                    throw error
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        throw CLIError("Account switch safety check did not complete.")
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
        startResetNotificationMonitoring()
        Task { await self.resumeAddAccountSessionIfNeeded() }
        refresh()
        refreshResetOutlook(silently: true)
        startAutoSwitchMonitoring()
        startQuotaMonitoring()
    }

    private func startResetNotificationMonitoring() {
        guard resetNotificationTask == nil else { return }
        ResetNotifier.prepare()
        resetNotificationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await ResetNotifier.isAuthorized(),
                   let events = try? await self.cli.decode(
                    [GlobalResetEvent].self,
                    arguments: ["reset-events", "--json"]
                ) {
                    ResetNotifier.show(events)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func resumeAddAccountSessionIfNeeded() async {
        guard let addStatus = try? await cli.decode(AddAccountStatusOutput.self, arguments: ["add-account-status"]),
              addStatus.active else {
            return
        }
        isAddAccountSession = true
        isInteractiveLoginInProgress = true
        isPendingLogin = true
        newAccountLoginState = .waiting
        if addStatus.authChanged,
           let current = try? await cli.decode(StatusOutput.self, arguments: ["status"]).currentAccount {
            newAccountLoginState = .ready(current)
        } else {
            watchForNewAccount(after: nil)
        }
    }

    func delete(_ account: SavedAccount) {
        run {
            _ = try await self.cli.data(arguments: ["delete", account.id.uuidString, "--json"])
            try await self.load()
        }
    }

    func delete(_ accounts: [SavedAccount]) {
        let targets = accounts.filter { !$0.isActive }
        guard !targets.isEmpty else { return }
        run {
            var failures = 0
            for account in targets {
                do {
                    _ = try await self.cli.data(arguments: ["delete", account.id.uuidString, "--json"])
                } catch {
                    failures += 1
                }
            }
            try await self.load()
            if failures > 0 {
                throw CLIError(AppLanguage.text(
                    "Đã xóa \(targets.count - failures)/\(targets.count) tài khoản.",
                    "Removed \(targets.count - failures)/\(targets.count) accounts."
                ))
            }
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

    func refreshUsage(for accounts: [SavedAccount]) {
        let targets = accounts.filter {
            !$0.archived && !$0.requiresLogin && !$0.requiresLocalRecovery
        }
        guard !targets.isEmpty else { return }
        run {
            var failures = 0
            for account in targets {
                do {
                    _ = try await self.cli.data(arguments: ["usage", account.id.uuidString, "--json"])
                } catch {
                    failures += 1
                }
            }
            try await self.load()
            self.lastQuotaRefreshAt = .now
            if failures > 0 {
                throw CLIError(AppLanguage.text(
                    "Đã xác minh \(targets.count - failures)/\(targets.count) tài khoản; dữ liệu tốt gần nhất được giữ nguyên cho phần còn lại.",
                    "Verified \(targets.count - failures)/\(targets.count) accounts; the last known good data was kept for the rest."
                ))
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
                await self?.refreshRosterQuotaInBackground()
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
        applyRoster(status: loadedStatus, accounts: loadedAccounts.accounts)
        let pendingLegacyArchives = legacyArchivedAccountIDs.intersection(Set(loadedAccounts.accounts.map(\.id)))
        if !pendingLegacyArchives.isEmpty {
            for accountID in pendingLegacyArchives {
                _ = try? await cli.data(arguments: ["archive", accountID.uuidString, "--json"])
            }
            legacyArchivedAccountIDs.subtract(pendingLegacyArchives)
            for key in archivedAccountsMigrationKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            let refreshedAccounts = try await cli.decode(AccountListOutput.self, arguments: ["list"])
            applyRoster(status: loadedStatus, accounts: refreshedAccounts.accounts)
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
        guard !isInteractiveLoginInProgress, !isPendingLogin else {
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
                let previousAccountID = decision.activeAccountId
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
                autoSwitchState = .relaunchingDesktop
                let launched = await relaunch.launchAndConfirm()
                let accepted: Bool
                if launched, let candidateID = applied.candidateAccountId {
                    accepted = await waitForDesktopAcceptance(accountID: candidateID)
                } else {
                    accepted = false
                }
                guard accepted else {
                    do {
                        try await rollbackRejectedTarget(
                            rejectedAccountID: applied.candidateAccountId,
                            previousAccountID: applied.activeAccountId ?? previousAccountID,
                            fallbackRelaunch: relaunch
                        )
                        try? await reloadAccountsAfterSwitch()
                        errorMessage = AppLanguage.text(
                            "ChatGPT không chấp nhận tài khoản tự động chọn; phiên trước đã được khôi phục.",
                            "ChatGPT rejected the automatically selected account; the previous session was restored."
                        )
                    } catch {
                        errorMessage = AppLanguage.text(
                            "Tài khoản đích bị từ chối và rollback thất bại: \(error.localizedDescription)",
                            "The target account was rejected and rollback failed: \(error.localizedDescription)"
                        )
                    }
                    autoSwitchState = .checkFailed
                    return
                }
                try await reloadAccountsAfterSwitch()
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

    /// Background poll refresh for the whole roster: re-query the active account
    /// plus any stale saved account so an off-schedule ChatGPT reset surfaces
    /// across the list. Not gated on the usage-window setting — quota freshness
    /// should not depend on it.
    private func refreshRosterQuotaInBackground() async {
        guard !isBusyForActions,
              !isCheckingAutoSwitch,
              !isRefreshingQuotaInBackground,
              !shouldDeferBackgroundWork,
              !isInteractiveLoginInProgress,
              !isPendingLogin else {
            return
        }
        isRefreshingQuotaInBackground = true
        defer { isRefreshingQuotaInBackground = false }
        do {
            _ = try await cli.data(arguments: ["refresh-usage", "--json"])
            try await reloadAccountsAfterSwitch()
            lastQuotaRefreshAt = .now
        } catch {
            // The last verified quota stays visible; manual refresh can surface the error.
        }
    }

    private func refreshActiveQuotaInBackground(allowWhileWorking: Bool = false) async {
        guard autoStartUsageWindows,
              (allowWhileWorking || !isBusyForActions),
              !isCheckingAutoSwitch,
              !isRefreshingQuotaInBackground,
              !shouldDeferBackgroundWork,
              !isInteractiveLoginInProgress,
              !isPendingLogin,
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
                if case .waiting = newAccountLoginState {
                    newAccountLoginState = .failed(error.localizedDescription)
                    clearPendingLoginFlags()
                } else if case .saving = newAccountLoginState {
                    newAccountLoginState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func reloadAccountsAfterSwitch() async throws {
        async let status: StatusOutput = cli.decode(StatusOutput.self, arguments: ["status"])
        async let accounts: AccountListOutput = cli.decode(AccountListOutput.self, arguments: ["list"])
        let (loadedStatus, loadedAccounts) = try await (status, accounts)
        applyRoster(status: loadedStatus, accounts: loadedAccounts.accounts)
    }

    private func waitForDesktopAcceptance(accountID: UUID) async -> Bool {
        // Give the official Desktop auth manager first ownership of the restored
        // refresh token before Roster performs a read-only access-token probe.
        try? await Task.sleep(for: .seconds(2))
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(12) {
            if (try? await cli.data(arguments: [
                "usage", accountID.uuidString, "--json",
            ])) != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func rollbackRejectedTarget(
        rejectedAccountID: UUID?,
        previousAccountID: UUID?,
        fallbackRelaunch: ChatGPTDesktop.RelaunchPlan
    ) async throws {
        guard let previousAccountID, previousAccountID != rejectedAccountID else {
            throw CLIError(AppLanguage.text(
                "Không tìm thấy điểm khôi phục của phiên trước.",
                "The previous session rollback point is unavailable."
            ))
        }
        let relaunch = ChatGPTDesktop.isRunning
            ? try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
            : fallbackRelaunch
        _ = try await activateAfterProcessesDrain(accountID: previousAccountID, waitForDrain: true)
        guard await relaunch.launchAndConfirm() else {
            throw CLIError(AppLanguage.text(
                "Đã phục hồi dữ liệu phiên trước nhưng không thể mở lại ChatGPT.",
                "The previous session data was restored, but ChatGPT could not be relaunched."
            ))
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
            currentAccountSavedId: account.id,
            processWarnings: status?.processWarnings ?? []
        )
    }

    private func applyRoster(status: StatusOutput, accounts: [SavedAccount]) {
        self.status = status
        self.accounts = accounts.map { account in
            account.withActiveState(account.id == status.currentAccountSavedId)
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

@MainActor
private enum CodexLoginLauncher {
    private static var process: Process?

    static func start() throws {
        // `codex login` opens its own browser sign-in (loopback/PKCE) — no device
        // code. Run it quietly: the browser is the only UI the user needs.
        stop()
        let login = Process()
        if let executable = resolvedCodexExecutable() {
            login.executableURL = URL(fileURLWithPath: executable)
            login.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login"]
        } else {
            login.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            login.arguments = ["codex", "-c", "cli_auth_credentials_store=\"file\"", "login"]
        }
        login.currentDirectoryURL = FileManager.default.temporaryDirectory
        login.standardOutput = FileHandle.nullDevice
        login.standardError = FileHandle.nullDevice
        try login.run()
        process = login
    }

    static func stop() {
        guard let login = process else { return }
        process = nil
        if login.isRunning {
            login.terminate()
        }
    }

    private static func resolvedCodexExecutable() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_ROSTER_CODEX_PATH"],
            environment["CODEX_BINARY_PATH"],
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .compactMap { $0 }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
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
    private static let forceTerminateDeadline: Duration = .seconds(3)
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
            kill(app.processIdentifier, SIGTERM)
        }
        if await waitUntilQuit(deadline: forceTerminateDeadline) {
            return relaunch
        }
        for app in runningApplications {
            app.forceTerminate()
            kill(app.processIdentifier, SIGKILL)
        }
        if await waitUntilQuit(deadline: .seconds(1)) {
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
    let currentAccountSavedId: UUID?
    let processWarnings: [RunningProcess]

    init(
        currentAccount: AccountIdentity?,
        currentAccountSavedId: UUID? = nil,
        processWarnings: [RunningProcess]
    ) {
        self.currentAccount = currentAccount
        self.currentAccountSavedId = currentAccountSavedId
        self.processWarnings = processWarnings
    }
}

private struct SaveOutput: Decodable {
    let account: SavedAccount
}

struct AccountIdentity: Decodable, Equatable {
    let email: String
    let subject: String?

    init(email: String, subject: String? = nil) {
        self.email = email
        self.subject = subject
    }

    func matches(_ other: AccountIdentity) -> Bool {
        switch (subject, other.subject) {
        case let (.some(left), .some(right)):
            return left == right
        default:
            return email.caseInsensitiveCompare(other.email) == .orderedSame
        }
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
    let previousAccountId: UUID?
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

struct GlobalResetEvent: Decodable, Identifiable {
    let id: String
    let announcedAt: String
    let summary: String
    let url: String

    enum CodingKeys: String, CodingKey {
        case id, summary, url
        case announcedAt = "announced_at"
    }
}

private enum ResetNotifier {
    private static let delegate = ResetNotificationDelegate()

    static func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    static func show(_ events: [GlobalResetEvent]) {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = AppLanguage.text(
                "ChatGPT vừa có đợt mass reset",
                "ChatGPT mass reset detected"
            )
            content.subtitle = AppLanguage.text(
                "Quota Codex và ChatGPT Work đang được đặt lại",
                "Codex and ChatGPT Work quota is being reset"
            )
            content.body = event.summary
            content.sound = .default
            content.userInfo = ["url": event.url]
            center.add(UNNotificationRequest(
                identifier: "codex-roster-reset-\(event.id)",
                content: content,
                trigger: nil
            ))
        }
    }
}

private final class ResetNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let value = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
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
    let createdAt: RustDate?
    let updatedAt: RustDate?
    let lastActivatedAt: RustDate?
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
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastActivatedAt: lastActivatedAt,
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
        createdAt: RustDate? = nil,
        updatedAt: RustDate? = nil,
        lastActivatedAt: RustDate? = nil,
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivatedAt = lastActivatedAt
        self.usage = usage
        self.usageError = usageError
    }

    func usageStatus(in language: AppLanguage) -> String {
        if hasDeferredAccessTokenRefresh {
            return language == .vietnamese
                ? "Access token sẽ được làm mới an toàn khi chuyển tài khoản"
                : "Access token will refresh safely on the next switch"
        }
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

    var requiresLocalRecovery: Bool {
        usageError?.localizedCaseInsensitiveContains("local recovery required") == true
    }

    var hasDeferredAccessTokenRefresh: Bool {
        usageError?.localizedCaseInsensitiveContains("[access_token_unauthorized]") == true
    }

    var hasTransientUsageError: Bool {
        usageError != nil
            && !requiresLogin
            && !requiresLocalRecovery
            && !hasDeferredAccessTokenRefresh
    }

    var lastVerifiedAt: Date? {
        usage?.fetchedAt?.value
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
    let fetchedAt: RustDate?
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

struct AddAccountStatusOutput: Decodable {
    let active: Bool
    let authChanged: Bool
}

struct AutoSwitchOutput: Decodable {
    let enabled: Bool
    let status: String
    let activeAccountId: UUID?
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
