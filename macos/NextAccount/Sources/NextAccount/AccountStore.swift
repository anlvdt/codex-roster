import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Priority buckets for the triage board, ordered by how urgently the user must
/// act. `rawValue` order is the display order (most urgent first).
enum AccountTriage: Int, CaseIterable {
    case needsAction  // sign-in / recovery / transient error — user must act
    case active       // the live ~/.codex session
    case ready        // healthy quota, ready to switch to
    case resting      // out of quota (may hold a banked reset)
    case archived     // set aside

    var id: Int { rawValue }

    /// SF Symbol shown on the bucket header and on each card badge.
    var systemImage: String {
        switch self {
        case .needsAction: return "exclamationmark.triangle.fill"
        case .active: return "checkmark.circle.fill"
        case .ready: return "bolt.circle.fill"
        case .resting: return "moon.zzz.fill"
        case .archived: return "archivebox"
        }
    }

    var tint: Color {
        switch self {
        case .needsAction: return .orange
        case .active: return .green
        case .ready: return .accentColor
        case .resting: return .secondary
        case .archived: return .secondary
        }
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .needsAction:
            return language == .vietnamese ? "Cần xử lý" : "Needs action"
        case .active:
            return language == .vietnamese ? "Đang dùng" : "In use"
        case .ready:
            return language == .vietnamese ? "Sẵn sàng" : "Ready"
        case .resting:
            return language == .vietnamese ? "Đang nghỉ" : "Resting"
        case .archived:
            return language == .vietnamese ? "Đã lưu trữ" : "Archived"
        }
    }

    /// One line explaining what the bucket means, so the board teaches the
    /// state model instead of relying on color alone.
    func subtitle(in language: AppLanguage) -> String {
        switch self {
        case .needsAction:
            return language == .vietnamese
                ? "Cần bạn đăng nhập lại hoặc kiểm tra trước khi dùng được."
                : "Needs you to sign in again or check before it can be used."
        case .active:
            return language == .vietnamese
                ? "Phiên ~/.codex hiện tại."
                : "The current ~/.codex session."
        case .ready:
            return language == .vietnamese
                ? "Còn quota, chuyển sang được ngay."
                : "Has quota and can be switched to right now."
        case .resting:
            return language == .vietnamese
                ? "Hết quota, đang chờ đặt lại (hoặc còn banked reset để redeem)."
                : "Out of quota, waiting to reset (or holding a banked reset to redeem)."
        case .archived:
            return language == .vietnamese
                ? "Đã cất đi, không tham gia tự động chuyển."
                : "Set aside and excluded from auto-switch."
        }
    }
}

/// Notch / companion roster filter chips. Deferred AT is soft (not needsAction)
/// and gets its own "Unverified" chip so users do not re-login healthy accounts.
enum RosterListFilter: Equatable {
    case all
    case triage(AccountTriage)
    case deferredUnverified

    func matches(_ account: SavedAccount) -> Bool {
        switch self {
        case .all:
            return true
        case .triage(let bucket):
            return account.triage == bucket
        case .deferredUnverified:
            return account.hasDeferredAccessTokenRefresh
        }
    }
}

extension Color {
    /// Shared quota color ramp used by every quota indicator (sidebar, board,
    /// notch) so the thresholds never drift apart.
    static func quotaTint(remainingPercent: Int, exhaustedAt: Int) -> Color {
        if remainingPercent <= exhaustedAt { return .red }
        if remainingPercent < 50 { return .orange }
        return .green
    }
}

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
            return language == .vietnamese ? "Quota trước → Gói" : "Quota first → Plan"
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

    /// Documented macOS force-switch ordering. Callers must preserve the live
    /// session before quitting Desktop so a SIGKILL cannot leave a stale,
    /// already-consumed refresh token as the roster's "latest" snapshot.
    static let forceSwitchOrderedSteps = [
        "preserveLiveSessionBeforeDesktopQuit",
        "prepareForAccountSwitch",
        "clearDesktopWebSessionCache",
        "activate",
        "relaunchAndConfirm",
    ]

    static func arguments(accountID: UUID, forceDesktop: Bool = false) -> [String] {
        var arguments = ["activate", accountID.uuidString]
        if forceDesktop {
            arguments.append("--force")
        }
        return arguments
    }

    static func isProcessSafetyBlock(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("account switch blocked")
            || message.contains("codex appears to be running")
    }

    static func isMissingLiveAuthError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("no live codex auth")
            || (message.contains("no live") && message.contains("auth"))
    }
}

enum CodexActivityDetector {
    static let quietPeriod: TimeInterval = 20

    static func isTurnActive(now: Date = .now) -> Bool {
        guard ChatGPTDesktop.isRunning,
              let latest = latestSessionWrite(now: now) else { return false }
        let age = now.timeIntervalSince(latest)
        return age >= -2 && age <= quietPeriod
    }

    private static func latestSessionWrite(now: Date) -> Date? {
        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let calendar = Calendar.current
        let candidateDays = [now, calendar.date(byAdding: .day, value: -1, to: now)].compactMap { $0 }
        var latest: Date?
        for day in candidateDays {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let directory = sessions
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate else { continue }
                if latest == nil || modified > latest! { latest = modified }
            }
        }
        return latest
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

/// How "Add account" should treat the live Codex / ChatGPT Desktop session.
enum AddAccountMode: String, CaseIterable, Identifiable {
    /// Capture login into a roster snapshot only. Does not touch live `~/.codex`,
    /// does not quit Desktop, and does not activate or auto-resume the new row.
    case enrollOnly
    /// Existing flow: `codex login` against live `~/.codex` (may free login ports
    /// by quitting Desktop), then leave the new credentials as the live session.
    case addAndSwitch

    var id: String { rawValue }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var status: StatusOutput?
    @Published private(set) var accounts: [SavedAccount] = []
    @Published private(set) var autoStartUsageWindows = false
    @Published private(set) var tokenUsage: TokenUsageSummary?
    @Published private(set) var resetOutlook: ResetOutlook?
    @Published private(set) var resetTimeline: [ResetTimelineEvent]?
    @Published private(set) var resetJuice: ResetJuice?
    @Published private(set) var openAIStatus: OpenAIServiceStatus?
    @Published private(set) var providerStates: [ProviderState] = []
    @Published private(set) var autoSwitchWhenExhausted: Bool
    @Published private(set) var autoResumeSession: Bool
    @Published private(set) var autoSwitchState: AutoSwitchState?
    @Published private(set) var isCheckingAutoSwitch = false
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var notchPanelEnabled: Bool
    @Published private(set) var backupStatusMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isSwitching = false
    @Published private(set) var isLoadingTokenUsage = false
    @Published private(set) var isLoadingResetOutlook = false
    @Published private(set) var isLoadingOpenAIStatus = false
    @Published private(set) var isLoadingProviderStatus = false
    @Published private(set) var isRefreshingQuotaInBackground = false
    @Published private(set) var lastQuotaRefreshAt: Date?
    @Published private(set) var accountSortMode: AccountSortMode
    @Published private(set) var newAccountLoginState: NewAccountLoginState = .idle
    @Published private(set) var isPendingLogin = false
    /// Which add path is in flight (nil when idle). Used by the add sheet to resume UI.
    @Published private(set) var pendingAddAccountMode: AddAccountMode?
    /// Short bilingual progress line during Desktop accept / clear+relaunch retry.
    @Published private(set) var switchPhaseMessage: String?
    /// Brief notch/menu caption after Auto-resume opens a remembered workspace.
    @Published private(set) var sessionResumeCaption: String?
    @Published var errorMessage: String?

    private let cli = AccountHubCLI()
    private let archivedAccountsMigrationKeys = ["codexRoster.archivedAccountIDs", "accountHub.archivedAccountIDs"]
    private var legacyArchivedAccountIDs: Set<UUID>
    private let legacyAutoSwitchWhenExhaustedKey = "codexRoster.autoSwitchWhenExhausted"
    /// Survives app relaunch: after banked-reset / all-exhausted, resume when
    /// the live account regains usable quota (timed reset or redeem).
    private let pendingQuotaRecoveryResumeKey = "codexRoster.pendingQuotaRecoveryResume"
    private let accountSortModeKey = "codexRoster.accountSortMode"
    /// One-shot migration: force quota-first so users actually see remaining-quota order.
    private let accountSortModeV2Key = "codexRoster.accountSortMode.v2"
    private let notchPanelEnabledKey = "codexRoster.notchPanelEnabled"
    private var autoSwitchTask: Task<Void, Never>?
    private var quotaRefreshTask: Task<Void, Never>?
    private var vibeUsageTask: Task<Void, Never>?
    private var autoSwitchAllExhaustedNotified = false
    /// Set when decide reports `all_accounts_exhausted` or `banked_reset_available`.
    /// While true, monitoring may still call decide to detect recovery, but must
    /// not close Desktop or apply a switch.
    private var autoSwitchPausedAllExhausted = false
    /// True while waiting for banked-reset redeem (faster poll than natural reset).
    private var autoSwitchPausedForBankedReset = false
    private var autoSwitchCooldownUntil: Date?
    /// Last observed live-account exhaustion — used to detect redeem/reset
    /// transitions on the quota refresh path (independent of auto-switch poll).
    private var lastObservedActiveExhausted: Bool?

    private var pendingQuotaRecoveryResume: Bool {
        get { UserDefaults.standard.bool(forKey: pendingQuotaRecoveryResumeKey) }
        set { UserDefaults.standard.set(newValue, forKey: pendingQuotaRecoveryResumeKey) }
    }
    private var isInteractiveLoginInProgress = false
    private var isAddAccountSession = false
    /// Isolated-home enroll path; mutually exclusive with `isAddAccountSession`.
    private var isEnrollOnlyLogin = false
    private var enrollOnlyCodexHome: URL?
    private var expectedReloginEmail: String?
    private var newAccountLoginWatchTask: Task<Void, Never>?
    /// Desktop apps to reopen after an interactive `codex login` finishes.
    /// Set when we close ChatGPT Desktop to free the fixed login port.
    /// Never set for enroll-only adds.
    private var pendingLoginDesktopRelaunch: ChatGPTDesktop.RelaunchPlan?
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
        autoResumeSession = true
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        notchPanelEnabled = defaults.object(forKey: notchPanelEnabledKey) == nil
            ? true
            : defaults.bool(forKey: notchPanelEnabledKey)
        if defaults.bool(forKey: accountSortModeV2Key),
           let raw = defaults.string(forKey: accountSortModeKey),
           let mode = AccountSortMode(rawValue: raw) {
            accountSortMode = mode
        } else {
            // Migrate once from the old key / plan-first default to quota-first.
            accountSortMode = .quotaThenPlan
            defaults.set(AccountSortMode.quotaThenPlan.rawValue, forKey: accountSortModeKey)
            defaults.set(true, forKey: accountSortModeV2Key)
        }
    }

    func setAccountSortMode(_ mode: AccountSortMode) {
        accountSortMode = mode
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: accountSortModeKey)
        defaults.set(true, forKey: accountSortModeV2Key)
    }

    func setNotchPanelEnabled(_ enabled: Bool) {
        notchPanelEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: notchPanelEnabledKey)
    }

    func sortedAccounts(_ accounts: [SavedAccount]) -> [SavedAccount] {
        accounts.sorted { left, right in
            // Display order is weekly-first via switchQuotaScore (weekly×1000+5H;
            // weekly depleted → -1). Usable-for-switch stays for auto-switch /
            // Ready triage only — not a primary display key.
            if left.switchQuotaScore != right.switchQuotaScore {
                return accountSortIsOrderedByWeeklyQuota(left, right)
            }
            switch accountSortMode {
            case .planThenQuota, .quotaThenPlan:
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
            return .seconds(45)
        }
        // 0% must not poll every few seconds — that made auto-switch close ChatGPT in a
        // loop when decide briefly looked "ready" against a stale sibling row.
        if remaining == 0 { return .seconds(45) }
        if remaining <= 5 { return .seconds(5) }
        if remaining <= 20 { return .seconds(15) }
        return .seconds(45)
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

    func startNewAccountLogin(mode: AddAccountMode = .addAndSwitch) {
        guard !isBusyForActions, newAccountLoginState != .waiting else { return }
        isInteractiveLoginInProgress = true
        isPendingLogin = true
        pendingAddAccountMode = mode
        newAccountLoginState = .waiting
        run {
            switch mode {
            case .enrollOnly:
                try await self.beginEnrollOnlyLogin()
            case .addAndSwitch:
                try await self.beginOrResumeAddAccountLogin(expectedEmail: nil)
            }
        }
    }

    func saveDetectedNewAccount() {
        guard case let .ready(expectedIdentity) = newAccountLoginState, !isBusyForActions else { return }
        newAccountLoginState = .saving
        run {
            if self.isEnrollOnlyLogin {
                try await self.saveEnrollOnlyAccount(expectedIdentity: expectedIdentity)
                return
            }
            let liveStatus: StatusOutput = try await self.cli.decode(StatusOutput.self, arguments: ["status"])
            guard let liveIdentity = liveStatus.currentAccount,
                  liveIdentity.matches(expectedIdentity) else {
                throw CLIError(AppLanguage.text(
                    "Phiên Codex đã thay đổi. Hãy chờ app nhận diện lại tài khoản mới rồi lưu.",
                    "The Codex session changed. Wait for the app to detect the new account again before saving."
                ))
            }
            try await self.load()
            do {
                try self.ensureNotDuplicateNewAccount(liveIdentity)
            } catch {
                if self.isAddAccountSession {
                    _ = try? await self.cli.data(arguments: ["cancel-add-account", "--json"])
                }
                self.clearPendingLoginFlags()
                throw error
            }
            let saveCommand = self.isAddAccountSession ? "save-added-account" : "save"
            let saved: SaveOutput = try await self.cli.decode(SaveOutput.self, arguments: [saveCommand])
            do {
                // Saving is only local evidence. Do not report success until
                // OpenAI accepts the freshly persisted access token.
                _ = try await self.cli.data(arguments: ["usage", saved.account.id.uuidString, "--json"])
            } catch {
                // Soft OK: deferred AT unauthorized means the credential was saved;
                // Desktop will refresh the access token on first use. Do not treat
                // as login failure (mirrors waitForDesktopAcceptance).
                if Self.isDeferredAccessTokenUsageError(error.localizedDescription) {
                    self.clearPendingLoginFlags()
                    self.newAccountLoginState = .saved(liveIdentity)
                    try await self.load()
                    self.lastQuotaRefreshAt = .now
                    return
                }
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
        CodexLoginLauncher.stop()
        clearPendingLoginFlags()
        newAccountLoginState = .idle
    }

    /// Cancel an unfinished add/re-login.
    /// Enroll-only discards the isolated login home and leaves live `~/.codex` alone.
    /// Add-and-switch restores the previous live Codex session via cancel-add-account.
    func cancelPendingLogin() {
        run {
            self.newAccountLoginWatchTask?.cancel()
            self.newAccountLoginWatchTask = nil
            CodexLoginLauncher.stop()
            if self.isEnrollOnlyLogin {
                self.removeEnrollOnlyHome()
            } else {
                _ = try await self.cli.data(arguments: ["cancel-add-account", "--json"])
            }
            self.clearPendingLoginFlags()
            self.newAccountLoginState = .idle
            try await self.load()
        }
    }

    /// Open browser sign-in so the user can refresh an expired saved account.
    func startRelogin(for account: SavedAccount) {
        isInteractiveLoginInProgress = true
        isPendingLogin = true
        pendingAddAccountMode = .addAndSwitch
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
            // ChatGPT Desktop's bundled Codex app-server may hold the fixed
            // loopback ports that `codex login` needs (1455 / fallback 1457).
            // Only quit Desktop when a port is busy — and always save live auth
            // first so we never kill Desktop on top of an unsaved RT.
            if CodexLoginPort.isBusy {
                try await preserveLiveSessionBeforeDesktopQuit()
                await closeDesktopForLogin()
            }
            try await beginAddAccountAfterProcessesDrain()
            began = true
            isAddAccountSession = true
            isEnrollOnlyLogin = false
            expectedReloginEmail = expectedEmail
            isPendingLogin = true
            try CodexLoginLauncher.start(codexHome: nil)
            watchForNewAccount(after: liveStatus.currentAccount)
        } catch {
            if began {
                CodexLoginLauncher.stop()
                _ = try? await cli.data(arguments: ["cancel-add-account", "--json"])
                clearPendingLoginFlags()
                newAccountLoginState = .idle
            } else {
                // Login never started; reopen Desktop if we closed it above.
                relaunchDesktopAfterLogin()
            }
            throw error
        }
    }

    /// Enroll a new account into the roster without replacing live `~/.codex`
    /// or restarting ChatGPT Desktop. Login writes into an isolated CODEX_HOME;
    /// the resulting auth.json is imported as a snapshot only.
    private func beginEnrollOnlyLogin() async throws {
        // Fixed OAuth callback ports — cannot free them without quitting Desktop,
        // which this mode forbids. Fail clearly so the user can pick Add & switch.
        if CodexLoginPort.isBusy {
            throw CLIError(AppLanguage.text(
                "Cổng đăng nhập Codex (1455/1457) đang bị ChatGPT Desktop hoặc tiến trình khác giữ. Chế độ Chỉ thêm không được đóng Desktop — hãy chọn Thêm & chuyển (có thể đóng Desktop để giải phóng cổng), hoặc tạm thoát Desktop rồi thử lại.",
                "Codex login ports (1455/1457) are held by ChatGPT Desktop or another process. Add-only mode will not quit Desktop — choose Add & switch (may quit Desktop to free the ports), or quit Desktop yourself and retry."
            ))
        }
        removeEnrollOnlyHome()
        let home = try Self.makeEnrollOnlyCodexHome()
        enrollOnlyCodexHome = home
        isEnrollOnlyLogin = true
        isAddAccountSession = false
        expectedReloginEmail = nil
        isPendingLogin = true
        do {
            try CodexLoginLauncher.start(codexHome: home)
            watchForEnrollOnlyAccount(at: home)
        } catch {
            CodexLoginLauncher.stop()
            removeEnrollOnlyHome()
            clearPendingLoginFlags()
            newAccountLoginState = .idle
            throw error
        }
    }

    private func resumePendingLogin(expectedEmail: String?) async throws {
        isAddAccountSession = true
        isEnrollOnlyLogin = false
        expectedReloginEmail = expectedEmail
        isInteractiveLoginInProgress = true
        isPendingLogin = true
        newAccountLoginState = .waiting
        let addStatus = try await cli.decode(AddAccountStatusOutput.self, arguments: ["add-account-status"])
        let status = try? await cli.decode(StatusOutput.self, arguments: ["status"])
        if let current = status?.currentAccount,
           addStatus.authChanged,
           expectedEmail.map({ current.email.caseInsensitiveCompare($0) == .orderedSame }) ?? true {
            if shouldRefuseDuplicateEnrollment(current) {
                await abortDuplicateEnrollment(current)
                return
            }
            newAccountLoginState = .ready(current)
            return
        }
        // Free the fixed login port before reopening the browser sign-in,
        // but only quit Desktop when the Codex login ports are actually busy.
        if CodexLoginPort.isBusy {
            try? await preserveLiveSessionBeforeDesktopQuit()
            await closeDesktopForLogin()
        }
        try CodexLoginLauncher.start(codexHome: nil)
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
                if self.shouldRefuseDuplicateEnrollment(current) {
                    await self.abortDuplicateEnrollment(current)
                    return
                }
                self.status = status
                self.newAccountLoginState = .ready(current)
                return
            }
        }
    }

    private func watchForEnrollOnlyAccount(at home: URL) {
        newAccountLoginWatchTask?.cancel()
        let authURL = home.appendingPathComponent("auth.json")
        newAccountLoginWatchTask = Task { [weak self] in
            guard let self else { return }
            var lastSize: Int = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard case .waiting = self.newAccountLoginState else { return }
                guard let data = try? Data(contentsOf: authURL), !data.isEmpty else {
                    continue
                }
                // Wait until the write settles (login can rewrite auth.json).
                if data.count != lastSize {
                    lastSize = data.count
                    continue
                }
                guard let identity = Self.identityFromAuthJSON(data) else { continue }
                if self.shouldRefuseDuplicateEnrollment(identity) {
                    await self.abortDuplicateEnrollment(identity)
                    return
                }
                self.newAccountLoginState = .ready(identity)
                return
            }
        }
    }

    /// Relogin of the same email is a credential refresh, not a duplicate enrollment.
    private func shouldRefuseDuplicateEnrollment(_ identity: AccountIdentity) -> Bool {
        if let expected = expectedReloginEmail,
           identity.email.caseInsensitiveCompare(expected) == .orderedSame {
            return false
        }
        return existingRosterAccount(matching: identity) != nil
    }

    private func existingRosterAccount(matching identity: AccountIdentity) -> SavedAccount? {
        accounts.first { account in
            identity.matches(AccountIdentity(email: account.email, subject: account.subject))
        }
    }

    private func ensureNotDuplicateNewAccount(_ identity: AccountIdentity) throws {
        guard shouldRefuseDuplicateEnrollment(identity) else { return }
        throw CLIError(Self.duplicateAccountAlreadyInRosterMessage)
    }

    private static var duplicateAccountAlreadyInRosterMessage: String {
        AppLanguage.text(
            "Tài khoản đã có trong danh bạ",
            "Account already in roster"
        )
    }

    /// Refuse enrollment of an identity already in the roster: no second row, no switch.
    /// Add-only cleans the temp enroll home; add-and-switch cancels the add session.
    private func abortDuplicateEnrollment(_ identity: AccountIdentity) async {
        CodexLoginLauncher.stop()
        newAccountLoginWatchTask?.cancel()
        newAccountLoginWatchTask = nil
        if isEnrollOnlyLogin {
            removeEnrollOnlyHome()
        } else if isAddAccountSession {
            _ = try? await cli.data(arguments: ["cancel-add-account", "--json"])
        }
        clearPendingLoginFlags()
        let email = identity.email
        newAccountLoginState = .failed(AppLanguage.text(
            "Tài khoản đã có trong danh bạ (\(email)). Không tạo dòng mới và không chuyển tài khoản.",
            "Account already in roster (\(email)). No new row was created and no switch was performed."
        ))
    }

    private func saveEnrollOnlyAccount(expectedIdentity: AccountIdentity) async throws {
        guard let home = enrollOnlyCodexHome else {
            throw CLIError(AppLanguage.text(
                "Không tìm thấy thư mục đăng nhập tạm cho chế độ Chỉ thêm.",
                "The temporary enroll-only login home is missing."
            ))
        }
        do {
            try await load()
            try ensureNotDuplicateNewAccount(expectedIdentity)
        } catch {
            removeEnrollOnlyHome()
            clearPendingLoginFlags()
            throw error
        }
        let authPath = home.appendingPathComponent("auth.json").path
        guard FileManager.default.fileExists(atPath: authPath) else {
            throw CLIError(AppLanguage.text(
                "Chưa có credential trong thư mục đăng nhập tạm. Hãy hoàn tất đăng nhập OpenAI rồi thử lại.",
                "No credential in the temporary login home yet. Finish the OpenAI browser sign-in, then try again."
            ))
        }
        // `decode` always appends `--json`; do not pass it here or clap rejects duplicates.
        let imported: ImportJsonOutput = try await cli.decode(
            ImportJsonOutput.self,
            arguments: ["import-json", authPath]
        )
        guard let account = imported.accounts.first else {
            throw CLIError(AppLanguage.text(
                "Import thành công nhưng không trả về tài khoản.",
                "Import succeeded but returned no account."
            ))
        }
        let identity = AccountIdentity(email: account.email, subject: account.subject)
        guard identity.matches(expectedIdentity) else {
            throw CLIError(AppLanguage.text(
                "Credential vừa lưu là \(account.email), không khớp \(expectedIdentity.email).",
                "Saved credential is \(account.email), which does not match \(expectedIdentity.email)."
            ))
        }
        do {
            _ = try await cli.data(arguments: ["usage", account.id.uuidString, "--json"])
        } catch {
            if Self.isDeferredAccessTokenUsageError(error.localizedDescription) {
                removeEnrollOnlyHome()
                clearPendingLoginFlags()
                newAccountLoginState = .saved(identity)
                try await load()
                lastQuotaRefreshAt = .now
                return
            }
            removeEnrollOnlyHome()
            clearPendingLoginFlags()
            try? await load()
            throw CLIError(AppLanguage.text(
                "OpenAI chưa chấp nhận credential mới. Tài khoản đã được giữ lại nhưng chưa được đánh dấu đăng nhập thành công.",
                "OpenAI did not accept the new credential. The account was preserved but sign-in was not marked successful."
            ))
        }
        removeEnrollOnlyHome()
        clearPendingLoginFlags()
        newAccountLoginState = .saved(identity)
        try await load()
        lastQuotaRefreshAt = .now
    }

    private static func makeEnrollOnlyCodexHome() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base
            .appendingPathComponent("Codex Roster", isDirectory: true)
            .appendingPathComponent("enroll-only-login", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeEnrollOnlyHome() {
        guard let home = enrollOnlyCodexHome else { return }
        enrollOnlyCodexHome = nil
        try? FileManager.default.removeItem(at: home)
    }

    /// Parse email/subject from a Codex auth.json without touching live `~/.codex`.
    private static func identityFromAuthJSON(_ data: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let idToken = tokens["id_token"] as? String,
              let claims = decodeJWTPayload(idToken),
              let email = claims["email"] as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let subject = claims["sub"] as? String
        return AccountIdentity(email: email, subject: subject)
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        if pad > 0 { payload += String(repeating: "=", count: pad) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
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
            // Soft OK: deferred AT unauthorized — credential saved; Desktop owns AT refresh.
            if Self.isDeferredAccessTokenUsageError(error.localizedDescription) {
                clearPendingLoginFlags()
                newAccountLoginState = .idle
                try await load()
                return
            }
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
        isEnrollOnlyLogin = false
        expectedReloginEmail = nil
        isPendingLogin = false
        pendingAddAccountMode = nil
        // Enroll-only never quits Desktop; add-and-switch may have closed it for ports.
        if enrollOnlyCodexHome != nil {
            removeEnrollOnlyHome()
        }
        relaunchDesktopAfterLogin()
    }

    /// Quit ChatGPT Desktop so `codex login` can bind its fixed loopback port
    /// and open the browser sign-in. Records which apps to reopen afterwards.
    /// Callers must probe `CodexLoginPort.isBusy` first and preserve the live
    /// session before invoking this.
    private func closeDesktopForLogin() async {
        guard ChatGPTDesktop.isRunning else { return }
        pendingLoginDesktopRelaunch = try? await ChatGPTDesktop.prepareForAccountSwitch(force: true)
    }

    /// Reopen ChatGPT Desktop after the login flow ends, if we closed it.
    private func relaunchDesktopAfterLogin() {
        guard let plan = pendingLoginDesktopRelaunch else { return }
        pendingLoginDesktopRelaunch = nil
        Task { await plan.launchAndConfirm() }
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
            // Force path: save live auth WHILE Desktop may still be running,
            // then quit (graceful first), then activate (saves again), then relaunch.
            let relaunch: ChatGPTDesktop.RelaunchPlan
            // One full partition clear per switch is required before relaunch;
            // skip a duplicate wipe when the post-quit clear already ran.
            var didClearWebSession = false
            if force {
                try await self.preserveLiveSessionBeforeDesktopQuit()
                relaunch = try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
                // Chromium profile cookies/local storage can keep a logged-out UI
                // even after ~/.codex/auth.json was restored. Clear web session
                // caches only while Desktop is fully quit so launch rehydrates
                // from the restored auth files.
                ChatGPTDesktop.clearWebSessionCacheOnce(didClear: &didClearWebSession)
            } else {
                relaunch = ChatGPTDesktop.RelaunchPlan.preferredDesktop()
            }
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
            // Brief filesystem beat after restore before Desktop opens and
            // races a partial auth.json read.
            try? await Task.sleep(for: .milliseconds(100))
            // Ensure a clear happened before relaunch (no-op if already cleared
            // and Desktop stayed quit).
            ChatGPTDesktop.clearWebSessionCacheOnce(didClear: &didClearWebSession)
            let launched = await relaunch.launchAndConfirm()
            let acceptance: DesktopAcceptanceResult
            if launched {
                acceptance = await self.confirmDesktopAcceptanceWithOneRetry(
                    accountID: activated.account.id,
                    expectedEmail: activated.account.email,
                    relaunch: relaunch
                )
            } else {
                acceptance = .timedOut
            }
            guard acceptance == .accepted else {
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
                throw CLIError(Self.desktopAcceptanceFailureMessage(acceptance))
            }
            self.applyActivatedAccount(activated.account)
            try await self.reloadAccountsAfterSwitch()
            if self.accounts.contains(where: { $0.id == activated.account.id && $0.isActive }) {
                self.lastQuotaRefreshAt = .now
            }
            await self.applySessionResumeIfNeeded(activated.sessionResume, continueExhausted: false)
        }
    }

    /// Persist the live `~/.codex` session into the roster before quitting Desktop.
    /// Ignores missing-auth only; any other save failure aborts the switch so we
    /// never force-quit on top of an unsaved live session.
    private func preserveLiveSessionBeforeDesktopQuit() async throws {
        let authPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let hasLiveAuthFile = FileManager.default.fileExists(atPath: authPath.path)
        do {
            _ = try await cli.data(arguments: ["save", "--json"])
        } catch {
            if AccountActivationSafety.isMissingLiveAuthError(error) || !hasLiveAuthFile {
                return
            }
            throw CLIError(AppLanguage.text(
                "Không thể lưu phiên đang mở trước khi đóng ChatGPT. Chuyển tài khoản đã bị hủy để tránh mất phiên: \(error.localizedDescription)",
                "Could not preserve the live session before quitting ChatGPT. The account switch was aborted to avoid losing the session: \(error.localizedDescription)"
            ))
        }
    }

    /// After a successful activate/auto-switch, reopen a remembered Codex thread.
    ///
    /// - `continueExhausted == true` (auto-switch or same-account quota recovery):
    ///   reopen the thread(s) that hit usage limits and queue continue.
    /// - otherwise (manual Đổi): reopen that account's last remembered workspace/thread.
    private func applySessionResumeIfNeeded(
        _ hint: SessionResumeHint?,
        continueExhausted: Bool
    ) async {
        guard autoResumeSession else { return }
        guard let hint else {
            logSessionResume("no hint from activate/auto-switch JSON continueExhausted=\(continueExhausted)")
            sessionResumeCaption = AppLanguage.text(
                "Auto-resume: không có gợi ý phiên sau khi đổi tài khoản",
                "Auto-resume: no session hint after account switch"
            )
            scheduleSessionResumeCaptionClear()
            return
        }
        guard hint.enabled else { return }
        if continueExhausted {
            let extras = hint.additionalSessions
            logSessionResume(
                "continueExhausted primary=\(hint.sessionId ?? "-") additional=\(extras.count) status=\(hint.status)"
            )
            await resumeInterruptedThreads([hint] + extras)
            return
        }

        switch hint.status {
        case "missing":
            logSessionResume("status=missing continueExhausted=\(continueExhausted)")
            sessionResumeCaption = AppLanguage.text(
                continueExhausted
                    ? "Không tìm thấy thread vừa hết quota để tiếp tục"
                    : "Chưa nhớ thread/workspace cho tài khoản này — mở dự án một lần rồi đổi lại",
                continueExhausted
                    ? "Could not find the usage-limit thread to continue"
                    : "No remembered thread/workspace for this account — open a project once, then switch again"
            )
            scheduleSessionResumeCaptionClear()
            return
        case "cwd_gone":
            // Folder gone, but thread id may still open in Desktop / CLI.
            break
        case "rollout_gone":
            logSessionResume("status=rollout_gone path=\(hint.rolloutPath ?? "-")")
            // Thread id can still resume from state_5 even if rollout path is stale.
            if hint.sessionId == nil || hint.sessionId?.isEmpty == true {
                sessionResumeCaption = AppLanguage.text(
                    "Rollout đã nhớ không còn trên máy",
                    "Remembered rollout is no longer on this Mac"
                )
                scheduleSessionResumeCaptionClear()
                return
            }
        case "ready", "ready_cli":
            break
        default:
            logSessionResume("unexpected status=\(hint.status)")
            sessionResumeCaption = AppLanguage.text(
                "Auto-resume: trạng thái \(hint.status)",
                "Auto-resume: status \(hint.status)"
            )
            scheduleSessionResumeCaptionClear()
            return
        }

        logSessionResume(
            "begin continueExhausted=\(continueExhausted) status=\(hint.status) session=\(hint.sessionId ?? "-") cwd=\(hint.cwd ?? "-")"
        )

        let projectName = hint.cwd.flatMap { path -> String? in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let label = projectName ?? hint.sessionId.map(shortSessionID) ?? "session"
        sessionResumeCaption = AppLanguage.text(
            continueExhausted
                ? "Đang tiếp tục thread hết quota · \(label)"
                : "Đang khôi phục phiên · \(label)",
            continueExhausted
                ? "Continuing usage-limit thread · \(label)"
                : "Resuming session · \(label)"
        )

        // Cold Desktop after web-session clear needs a short settle before
        // deep-link navigation works. Same-account recovery keeps Desktop warm.
        let warmDesktop = ChatGPTDesktop.isRunning
        await waitForDesktopResumeReady(
            minimumSettle: warmDesktop ? .milliseconds(400) : .seconds(2.5),
            maximumWait: warmDesktop ? .seconds(4) : .seconds(8)
        )

        let result = await openRememberedWorkspace(cwd: hint.cwd, sessionID: hint.sessionId)
        logSessionResume("result=\(String(describing: result)) label=\(label) continueExhausted=\(continueExhausted)")
        switch result {
        case .openedThread:
            var queuedContinue = false
            if continueExhausted, let sessionID = hint.sessionId, !sessionID.isEmpty {
                // Deep-link only selects the thread; queue a continue turn so Codex
                // actually resumes work on the new account's quota.
                queuedContinue = await queueContinueMessage(threadID: sessionID)
                logSessionResume("queue continue thread=\(sessionID) ok=\(queuedContinue)")
            }
            if continueExhausted {
                sessionResumeCaption = AppLanguage.text(
                    queuedContinue
                        ? "Đã gửi tiếp tục thread hết quota · \(label)"
                        : "Đã mở thread hết quota · \(label) (chưa gửi được tin tiếp tục)",
                    queuedContinue
                        ? "Queued continue on usage-limit thread · \(label)"
                        : "Opened usage-limit thread · \(label) (continue message not queued)"
                )
            } else {
                sessionResumeCaption = AppLanguage.text(
                    "Đã khôi phục thread · \(label)",
                    "Restored thread · \(label)"
                )
            }
        case .openedDesktop:
            sessionResumeCaption = AppLanguage.text(
                "Đã mở workspace · \(label)",
                "Opened workspace · \(label)"
            )
        case .openedFinder:
            sessionResumeCaption = AppLanguage.text(
                "Đã mở thư mục · \(label) (Desktop deep-link lỗi)",
                "Opened folder · \(label) (Desktop deep-link failed)"
            )
        case .failed:
            if let sessionID = hint.sessionId, !sessionID.isEmpty {
                sessionResumeCaption = AppLanguage.text(
                    "Khôi phục thất bại — `codex resume \(shortSessionID(sessionID))` · \(label)",
                    "Resume failed — `codex resume \(shortSessionID(sessionID))` · \(label)"
                )
            } else {
                sessionResumeCaption = AppLanguage.text(
                    "Không mở được workspace đã nhớ · \(label)",
                    "Could not open the remembered workspace · \(label)"
                )
            }
        }
        scheduleSessionResumeCaptionClear()
    }

    /// Open + queue each exact thread independently; a failure must not skip later threads.
    /// Deep-link open is required — `codex queue` alone often lands unread until Desktop
    /// has the thread selected (proven single-thread path before the batch refactor).
    private func resumeInterruptedThreads(_ hints: [SessionResumeHint]) async {
        var seen = Set<String>()
        let targets = hints.filter {
            guard $0.enabled, let id = $0.sessionId, !id.isEmpty else { return false }
            return seen.insert(id).inserted
        }
        guard !targets.isEmpty else {
            sessionResumeCaption = AppLanguage.text(
                "Không có cuộc hội thoại dang dở cần tiếp tục",
                "No interrupted conversations to resume"
            )
            scheduleSessionResumeCaptionClear()
            return
        }
        logSessionResume(
            "batch begin count=\(targets.count) ids=\(targets.compactMap(\.sessionId).joined(separator: ",")) desktopRunning=\(ChatGPTDesktop.isRunning)"
        )
        let warmDesktop = ChatGPTDesktop.isRunning
        await waitForDesktopResumeReady(
            minimumSettle: warmDesktop ? .milliseconds(400) : .seconds(2.5),
            maximumWait: warmDesktop ? .seconds(4) : .seconds(8)
        )
        let result = await SessionResumeBatch.run(
            threadIDs: targets.compactMap(\.sessionId),
            shouldContinue: { self.autoResumeSession },
            progress: { index, total in
                self.sessionResumeCaption = AppLanguage.text(
                    "Đang tiếp tục cuộc hội thoại \(index)/\(total)",
                    "Resuming conversation \(index)/\(total)"
                )
            },
            enqueue: { id in
                let open = await self.openRememberedWorkspace(cwd: nil, sessionID: id)
                self.logSessionResume("batch open thread=\(id) result=\(String(describing: open))")
                guard case .openedThread = open, self.autoResumeSession, !Task.isCancelled else {
                    return false
                }
                let queued = await self.queueContinueMessage(threadID: id)
                self.logSessionResume("batch continue thread=\(id) queued=\(queued)")
                return queued
            }
        )
        sessionResumeCaption = AppLanguage.text(
            "Đã gửi tiếp tục \(result.succeeded)/\(result.total) cuộc hội thoại",
            "Queued continue for \(result.succeeded)/\(result.total) conversations"
        )
        scheduleSessionResumeCaptionClear()
    }

    /// Same-account quota recovery (timed reset or banked-reset redeem): discover
    /// interrupted threads and continue them without switching accounts.
    private func resumeInterruptedSessionsAfterQuotaRecovery() async {
        guard autoResumeSession else {
            logSessionResume("quota recovery skipped: auto-resume disabled")
            return
        }
        do {
            let hint: SessionResumeHint = try await cli.decode(
                SessionResumeHint.self,
                arguments: ["auto-resume-session", "--continue-interrupted", "--json"]
            )
            guard hint.enabled else {
                logSessionResume("quota recovery: hint disabled")
                return
            }
            let hasPrimary = !(hint.sessionId ?? "").isEmpty
            let hasExtras = hint.additionalSessions.contains { !($0.sessionId ?? "").isEmpty }
            guard hasPrimary || hasExtras else {
                logSessionResume("quota recovery: no interrupted threads to continue")
                return
            }
            logSessionResume(
                "quota recovery resume primary=\(hint.sessionId ?? "-") additional=\(hint.additionalSessions.count) desktopRunning=\(ChatGPTDesktop.isRunning)"
            )
            await applySessionResumeIfNeeded(hint, continueExhausted: true)
        } catch {
            logSessionResume("quota recovery resume failed: \(error.localizedDescription)")
        }
    }

    /// Quota refresh can notice redeem/reset sooner than the paused auto-switch
    /// poll — fire the same-account resume as soon as the live account is usable.
    private func resumeAfterQuotaRefreshIfNeeded() async {
        guard autoResumeSession else { return }
        guard let active = accounts.first(where: { $0.isActive && !isArchived($0) }) else { return }
        let exhausted = active.isExhaustedForSwitch
        let recoveredFromPending = !exhausted && pendingQuotaRecoveryResume
        let recoveredFromTransition = lastObservedActiveExhausted == true && !exhausted
        if exhausted {
            // Arm recovery so a later redeem/reset still resumes after relaunch.
            if active.bankedResetCount > 0 || autoSwitchPausedAllExhausted {
                pendingQuotaRecoveryResume = true
            }
            lastObservedActiveExhausted = true
            return
        }
        lastObservedActiveExhausted = false
        guard recoveredFromPending || recoveredFromTransition else { return }
        logSessionResume(
            "quota refresh detected recovery pending=\(recoveredFromPending) transition=\(recoveredFromTransition) — resuming"
        )
        pendingQuotaRecoveryResume = false
        autoSwitchPausedAllExhausted = false
        autoSwitchPausedForBankedReset = false
        autoSwitchAllExhaustedNotified = false
        if case .bankedResetAvailable = autoSwitchState { autoSwitchState = nil }
        if case .allAccountsExhausted = autoSwitchState { autoSwitchState = nil }
        ResetNotifier.showQuotaRecovered()
        await resumeInterruptedSessionsAfterQuotaRecovery()
    }

    private func scheduleSessionResumeCaptionClear() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            sessionResumeCaption = nil
        }
    }

    private func shortSessionID(_ id: String) -> String {
        guard id.count > 8 else { return id }
        return String(id.prefix(8))
    }

    private enum SessionResumeOpenResult {
        case openedThread
        case openedDesktop
        case openedFinder
        case failed
    }

    /// Wait until Desktop is up long enough for deep-link handlers + app-server.
    private func waitForDesktopResumeReady(
        minimumSettle: Duration,
        maximumWait: Duration
    ) async {
        let start = ContinuousClock.now
        while !ChatGPTDesktop.isRunning {
            if ContinuousClock.now - start > maximumWait { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let elapsed = ContinuousClock.now - start
        if elapsed < minimumSettle {
            try? await Task.sleep(for: minimumSettle - elapsed)
        }
    }

    /// Opens the remembered thread (preferred) or project for the account just switched *to*.
    private func openRememberedWorkspace(cwd: String?, sessionID: String?) async -> SessionResumeOpenResult {
        if let sessionID, !sessionID.isEmpty {
            // Retry: first deliveries during cold hydrate are often dropped.
            // Warm Desktop (same-account recovery) confirms faster.
            let warmDesktop = ChatGPTDesktop.isRunning
            // Warm same-account recovery rarely writes fresh Desktop log lines
            // (thread often already focused). Confirm briefly, then fall through.
            let confirmTimeout = warmDesktop ? 0.9 : 2.0
            let retryGap: Duration = warmDesktop ? .milliseconds(250) : .milliseconds(600)
            let attempts = warmDesktop ? 2 : 4
            var anyDelivered = false
            for attempt in 1...attempts {
                logSessionResume("thread deep-link attempt \(attempt) id=\(sessionID)")
                let openedAt = Date()
                let delivered = await openCodexThreadDeepLink(sessionID: sessionID)
                if delivered {
                    anyDelivered = true
                    if await desktopLogConfirmsThreadOpen(
                        sessionID: sessionID,
                        since: openedAt,
                        timeoutSeconds: confirmTimeout
                    ) {
                        return .openedThread
                    }
                    logSessionResume("open delivered but no Desktop resume evidence yet")
                }
                try? await Task.sleep(for: retryGap)
            }
            if anyDelivered && (warmDesktop || ChatGPTDesktop.isRunning) {
                logSessionResume(
                    "warm Desktop: deep-link delivered without fresh log evidence — treating as opened"
                )
                return .openedThread
            }
            // Final cold-path attempt with stricter log confirmation.
            let openedAt = Date()
            if await openCodexThreadDeepLink(sessionID: sessionID),
               await desktopLogConfirmsThreadOpen(
                sessionID: sessionID,
                since: openedAt,
                timeoutSeconds: 3.0
               ) {
                return .openedThread
            }
            logSessionResume("thread deep-link exhausted without Desktop resume evidence")
        }

        let cwdPath = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cwdPath.isEmpty, FileManager.default.fileExists(atPath: cwdPath) {
            if await runCodexAppWorkspace(cwdPath) {
                return .openedDesktop
            }
            if await openCodexNewThreadDeepLink(cwd: cwdPath) {
                return .openedDesktop
            }
            if await openFolderInFinder(cwdPath) {
                return .openedFinder
            }
        }
        return .failed
    }

    private func runCodexAppWorkspace(_ cwd: String) async -> Bool {
        for binary in codexCLIBinaries where FileManager.default.isExecutableFile(atPath: binary) {
            // `codex app` exits in ~2s when Desktop is already up; treat a clean
            // exit as success. If it is still running past the timeout, kill and
            // still succeed when Desktop is running (workspace handoff started).
            let outcome = await runProcessOutcome(
                executable: binary,
                arguments: ["app", cwd],
                timeoutSeconds: 8
            )
            switch outcome {
            case .exited(0):
                return true
            case .stillRunning:
                if ChatGPTDesktop.isRunning { return true }
            case .exited, .failedToStart:
                continue
            }
        }
        return false
    }

    /// Exact-thread resume — OpenAI-confirmed contract (`codex://threads/<threadId>`).
    private func openCodexThreadDeepLink(sessionID: String) async -> Bool {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) ?? sessionID
        return await openCodexURL("codex://threads/\(encoded)")
    }

    /// After auto-switch, open the blocked thread then queue a user turn so Desktop
    /// actually continues (deep-link alone only navigates). Uses `codex queue`, then
    /// presses the composer Play control required by newer Desktop builds.
    private func queueContinueMessage(threadID: String) async -> Bool {
        let message = "Continue the interrupted task after the account usage-limit switch."
        for binary in codexCLIBinaries where FileManager.default.isExecutableFile(atPath: binary) {
            let outcome = await runProcessCapturingOutput(
                executable: binary,
                arguments: ["queue", "--thread", threadID, "--message", message],
                timeoutSeconds: 20
            )
            switch outcome {
            case let .exited(status, stdout, stderr):
                let combined = stdout + "\n" + stderr
                if status == 0, combined.localizedCaseInsensitiveContains("Queued message") {
                    // Newer Desktop builds park queued turns behind Play
                    // ("Queued messages run now") — press it so resume actually starts.
                    let played = await CodexComposerPlay.press(log: { self.logSessionResume($0) })
                    logSessionResume("codex queue ok; composer Play pressed=\(played)")
                    return true
                }
                logSessionResume(
                    "codex queue exit=\(status) via=\(binary) out=\(String(combined.prefix(240)))"
                )
            case .stillRunning:
                logSessionResume("codex queue still running via=\(binary)")
            case .failedToStart:
                continue
            }
        }
        // Queue failed or unavailable — still try Play in case Desktop already
        // shows a resume/run-now affordance on the focused interrupted thread.
        let played = await CodexComposerPlay.press(log: { self.logSessionResume($0) })
        logSessionResume("codex queue unavailable; composer Play pressed=\(played)")
        return played
    }

    private var codexCLIBinaries: [String] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
    }

    /// Workspace fallback when thread id cannot be opened (opens a new thread at cwd).
    private func openCodexNewThreadDeepLink(cwd: String) async -> Bool {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=")
        let encodedPath = cwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? cwd
        return await openCodexURL("codex://threads/new?path=\(encodedPath)")
    }

    private func openCodexURL(_ url: String) async -> Bool {
        // `com.openai.chat` is stale on current installs — ChatGPT.app is
        // `com.openai.codex`. Prefer resolved IDs that LaunchServices knows.
        let bundleIDs = ChatGPTDesktop.resolvableBundleIDs()
        for bundleID in bundleIDs {
            if await runProcessAndWait(
                executable: "/usr/bin/open",
                arguments: ["-b", bundleID, url],
                timeoutSeconds: 8
            ) {
                return true
            }
        }
        for path in ChatGPTDesktop.knownDesktopAppPaths
        where FileManager.default.fileExists(atPath: path) {
            if await runProcessAndWait(
                executable: "/usr/bin/open",
                arguments: ["-a", path, url],
                timeoutSeconds: 8
            ) {
                return true
            }
        }
        return await runProcessAndWait(
            executable: "/usr/bin/open",
            arguments: [url],
            timeoutSeconds: 8
        )
    }

    private func openFolderInFinder(_ cwd: String) async -> Bool {
        if await runProcessAndWait(
            executable: "/usr/bin/open",
            arguments: [cwd],
            timeoutSeconds: 6
        ) {
            return true
        }
        return await MainActor.run {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        }
    }

    /// Wait for fresh, thread-specific Desktop evidence that the deep-link landed.
    private func desktopLogConfirmsThreadOpen(sessionID: String, since: Date, timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if await desktopLogHasThreadOpen(sessionID: sessionID, since: since) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        } while !Task.isCancelled && Date() < deadline
        return false
    }

    private func desktopLogHasThreadOpen(sessionID: String, since: Date) async -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: false)
                    return
                }
                var candidates: [(Date, URL)] = []
                while let item = enumerator.nextObject() as? URL {
                    guard item.pathExtension == "log" else { continue }
                    let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values?.isRegularFile == true,
                          let modified = values?.contentModificationDate,
                          modified >= since else { continue }
                    candidates.append((modified, item))
                }
                candidates.sort { $0.0 > $1.0 }
                for (_, url) in candidates.prefix(8) {
                    guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                    defer { try? handle.close() }
                    // Read trailing 256 KiB — enough for recent navigation events.
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > 262_144 {
                        try? handle.seek(toOffset: UInt64(size - 262_144))
                    }
                    guard let data = try? handle.readToEnd(),
                          let text = String(data: data, encoding: .utf8) else { continue }
                    if text.split(separator: "\n").contains(where: {
                        DesktopResumeEvidence.matches(String($0), threadID: sessionID, since: since)
                    }) {
                        continuation.resume(returning: true)
                        return
                    }
                }
                continuation.resume(returning: false)
            }
        }
    }

    private func logSessionResume(_ message: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.codexroster.codex-roster", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session-resume.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private enum ProcessRunOutcome {
        case exited(Int32)
        case stillRunning
        case failedToStart
    }

    private enum ProcessCaptureOutcome {
        case exited(status: Int32, stdout: String, stderr: String)
        case stillRunning
        case failedToStart
    }

    private func runProcessOutcome(
        executable: String,
        arguments: [String],
        timeoutSeconds: Double
    ) async -> ProcessRunOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failedToStart)
                    return
                }
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                    continuation.resume(returning: .stillRunning)
                    return
                }
                process.waitUntilExit()
                continuation.resume(returning: .exited(process.terminationStatus))
            }
        }
    }

    private func runProcessCapturingOutput(
        executable: String,
        arguments: [String],
        timeoutSeconds: Double
    ) async -> ProcessCaptureOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failedToStart)
                    return
                }
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                    continuation.resume(returning: .stillRunning)
                    return
                }
                process.waitUntilExit()
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                continuation.resume(
                    returning: .exited(
                        status: process.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    )
                )
            }
        }
    }

    private func runProcessAndWait(
        executable: String,
        arguments: [String],
        timeoutSeconds: Double
    ) async -> Bool {
        switch await runProcessOutcome(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        ) {
        case .exited(0):
            return true
        case .exited, .stillRunning, .failedToStart:
            return false
        }
    }

    var currentCodexModel: String? {
        status?.codexModel
    }

    var isLunaReserveActiveInCodex: Bool {
        guard let model = currentCodexModel?.lowercased() else { return false }
        return model.contains("luna") || model.contains("reserve")
    }

    func isLunaReserveActive(for account: SavedAccount) -> Bool {
        account.isActive && isLunaReserveActiveInCodex
    }

    func enableLunaReserve(_ account: SavedAccount) {
        run(switching: !account.isActive) {
            _ = try await self.cli.data(arguments: ["enable-luna-reserve", account.id.uuidString, "--json"])
            try await self.reloadAccountsAfterSwitch()
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
                    arguments: AccountActivationSafety.arguments(
                        accountID: accountID,
                        forceDesktop: waitForDrain
                    )
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
        throw CLIError(AppLanguage.text(
            "Kiểm tra an toàn khi chuyển tài khoản chưa hoàn tất.",
            "Account switch safety check did not complete."
        ))
    }

    /// Quit ChatGPT Desktop if needed, then reopen it so the UI loads the current `~/.codex` session.
    func resyncChatGPTDesktop() {
        run(switching: true) {
            let relaunch = ChatGPTDesktop.isRunning
                ? try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
                : ChatGPTDesktop.RelaunchPlan.preferredDesktop()
            // Drop stale Electron cookies so relaunch rehydrates from live auth.json.
            ChatGPTDesktop.clearWebSessionCache()
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
        ensureAutomaticFullBackup()
        startResetNotificationMonitoring()
        Task { await self.resumeAddAccountSessionIfNeeded() }
        refresh()
        refreshResetOutlook(silently: true)
        refreshResetTimeline(silently: true)
        refreshResetJuice(silently: true)
        startAutoSwitchMonitoring()
        startQuotaMonitoring()
        startVibeUsageMonitoring()
    }

    private func startVibeUsageMonitoring() {
        guard vibeUsageTask == nil else { return }
        vibeUsageTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if (try? await self.cli.data(arguments: ["vibe-usage", "sync"])) != nil,
                   let refreshed = try? await self.cli.decode(StatusOutput.self, arguments: ["status"]) {
                    self.status = refreshed
                }
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    private func startResetNotificationMonitoring() {
        guard resetNotificationTask == nil else { return }
        ResetNotifier.prepare()
        resetNotificationTask = Task { [weak self] in
            var nextPublicSignalCheck = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if await ResetNotifier.isAuthorized() {
                    // Account-authenticated usage is the source of truth for
                    // personal banked credits and actual quota resets.
                    ResetNotifier.showAccountSignals(
                        self.accounts,
                        autoSwitchEnabled: self.autoSwitchWhenExhausted
                    )
                    ResetNotifier.showOpenAIIncidentIfNeeded(self.openAIStatus)
                    if Date.now >= nextPublicSignalCheck {
                        if let signals = try? await self.cli.decode(
                            [GlobalResetEvent].self,
                            arguments: ["reset-events"]
                        ) {
                            signals.forEach { ResetNotifier.showPublicSignal($0) }
                            self.refreshResetOutlook(silently: true)
                        }
                        nextPublicSignalCheck = Date.now.addingTimeInterval(60)
                    }
                }
                // Usage refreshes separately; checking the local result often
                // makes the banner appear immediately after a signal lands.
                try? await Task.sleep(for: .seconds(2))
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
        pendingAddAccountMode = .addAndSwitch
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
                // Session longevity: skip deferred / login-blocking rows on mass refresh.
                targets = self.accounts.filter {
                    !self.isArchived($0)
                        && !$0.requiresLogin
                        && !$0.requiresLocalRecovery
                        && !$0.hasDeferredAccessTokenRefresh
                }
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
            !$0.archived && !$0.requiresLogin && !$0.requiresLocalRecovery && !$0.hasDeferredAccessTokenRefresh
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
            // Off→on clears the all-exhausted pause so monitoring can retry.
            self.autoSwitchPausedAllExhausted = false
            self.autoSwitchPausedForBankedReset = false
            if enabled {
                Task { await self.checkAutoSwitchWhenExhausted() }
            }
        }
    }

    func setAutoResumeSession(_ enabled: Bool) {
        run {
            _ = try await self.cli.data(
                arguments: ["auto-resume-session", enabled ? "--enable" : "--disable", "--json"]
            )
            self.autoResumeSession = enabled
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
            self.backupStatusMessage = AppLanguage.text(
                "Đã nhập bản sao lưu. Snapshot có thể giữ refresh token cũ hơn phiên Codex đang sống — hãy Save current trước, và đừng kích hoạt hàng vừa khôi phục một cách mù quáng (có thể buộc đăng nhập lại).",
                "Backup imported. Restored snapshots may hold stale refresh tokens vs live Codex — save the current session first, and do not activate restored rows blindly (that can force re-login)."
            )
        }
    }

    func restoreLatestAccountListBackup() {
        run {
            _ = try await self.cli.data(arguments: ["restore-account-list-backup", "--json"])
            try await self.load()
            self.backupStatusMessage = AppLanguage.text(
                "Đã khôi phục danh sách. Snapshot có thể giữ refresh token cũ hơn phiên Codex đang sống — hãy Save current trước, và đừng kích hoạt hàng vừa khôi phục một cách mù quáng (có thể buộc đăng nhập lại).",
                "Account list restored. Restored snapshots may hold stale refresh tokens vs live Codex — save the current session first, and do not activate restored rows blindly (that can force re-login)."
            )
        }
    }

    func restoreLatestFullBackup() {
        run {
            _ = try await self.cli.data(arguments: ["restore-full-backup", "--json"])
            try await self.load()
            self.backupStatusMessage = AppLanguage.text(
                "Đã khôi phục phiên sao lưu. Snapshot có thể giữ refresh token cũ hơn phiên Codex đang sống — hãy Save current trước, và đừng kích hoạt hàng vừa khôi phục một cách mù quáng (có thể buộc đăng nhập lại).",
                "Full backup restored. Restored snapshots may hold stale refresh tokens vs live Codex — save the current session first, and do not activate restored rows blindly (that can force re-login)."
            )
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
            // refresh() is async — wait for an active row before the
            // recovery bootstrap, otherwise we no-op on an empty roster.
            for _ in 0..<40 {
                if self?.accounts.contains(where: \.isActive) == true { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            await self?.bootstrapQuotaRecoveryResumeIfNeeded()
            while !Task.isCancelled {
                await self?.checkAutoSwitchWhenExhausted()
                // While paused, decide still runs (to spot recovery) but poll
                // cadence depends on why we paused:
                // - banked reset: user may redeem any moment → 20s
                // - all exhausted (natural reset): slower → 45s
                let interval: Duration
                if self?.autoSwitchPausedAllExhausted == true {
                    interval = (self?.autoSwitchPausedForBankedReset == true)
                        ? .seconds(20)
                        : .seconds(45)
                } else {
                    interval = self?.quotaPollInterval ?? .seconds(45)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// First launch of the recovery-pending logic: seed exhaustion baseline and
    /// resume once if the live account is already usable with interrupted threads
    /// (covers banked-reset redeem that happened before the flag existed).
    private func bootstrapQuotaRecoveryResumeIfNeeded() async {
        guard autoResumeSession else {
            logSessionResume("bootstrap: skipped — auto-resume off")
            return
        }
        let defaults = UserDefaults.standard
        let firstRun = defaults.object(forKey: pendingQuotaRecoveryResumeKey) == nil
        guard let active = accounts.first(where: { $0.isActive && !isArchived($0) }) else {
            logSessionResume("bootstrap: skipped — no active account yet")
            return
        }
        let exhausted = active.isExhaustedForSwitch
        lastObservedActiveExhausted = exhausted
        if exhausted {
            if active.bankedResetCount > 0 {
                pendingQuotaRecoveryResume = true
                autoSwitchPausedForBankedReset = true
                autoSwitchPausedAllExhausted = true
            }
            if firstRun { defaults.set(pendingQuotaRecoveryResume, forKey: pendingQuotaRecoveryResumeKey) }
            logSessionResume(
                "bootstrap: active exhausted banked=\(active.bankedResetCount) pending=\(pendingQuotaRecoveryResume)"
            )
            return
        }
        if firstRun {
            // Initialize the key so later launches don't re-enter this path.
            defaults.set(false, forKey: pendingQuotaRecoveryResumeKey)
            logSessionResume("bootstrap: probing interrupted threads after upgrade")
            await resumeInterruptedSessionsAfterQuotaRecovery()
            return
        }
        if pendingQuotaRecoveryResume {
            logSessionResume("bootstrap: pending recovery with usable active — resuming")
            pendingQuotaRecoveryResume = false
            await resumeInterruptedSessionsAfterQuotaRecovery()
        } else {
            logSessionResume("bootstrap: active usable, no pending recovery")
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
                try? await Task.sleep(for: self?.quotaPollInterval ?? .seconds(45))
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

    func refreshProviderStatus(silently: Bool = false) {
        guard !isLoadingProviderStatus else { return }
        isLoadingProviderStatus = true
        Task {
            defer { isLoadingProviderStatus = false }
            do {
                let output = try await cli.decode(ProviderStatusOutput.self, arguments: ["providers", "status"])
                providerStates = output.providers
            } catch {
                if !silently { errorMessage = error.localizedDescription }
            }
        }
    }

    func refreshResetTimeline(silently: Bool = false) {
        Task {
            do {
                let payload = try await cli.decode(ResetTimelinePayload.self, arguments: ["reset-timeline"])
                resetTimeline = payload.events
            } catch {
                if !silently { errorMessage = error.localizedDescription }
            }
        }
    }

    func refreshResetJuice(silently: Bool = false) {
        // Codex Resets does not publish effort tiers. Never substitute another source.
        resetJuice = nil
    }

    private func load() async throws {
        async let status: StatusOutput = cli.decode(StatusOutput.self, arguments: ["status"])
        async let accounts: AccountListOutput = cli.decode(AccountListOutput.self, arguments: ["list"])
        async let settings: AutoStartUsageWindowsStatus = cli.decode(AutoStartUsageWindowsStatus.self, arguments: ["auto-start-usage-windows"])
        async let autoSwitch: AutoSwitchOutput = cli.decode(AutoSwitchOutput.self, arguments: ["auto-switch", "--status"])
        async let autoResume: AutoResumeSessionStatus = cli.decode(AutoResumeSessionStatus.self, arguments: ["auto-resume-session"])
        let (loadedStatus, loadedAccounts, loadedSettings, loadedAutoSwitch, loadedAutoResume) = try await (
            status, accounts, settings, autoSwitch, autoResume
        )
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
        self.autoResumeSession = loadedAutoResume.enabled
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
        if let cooldownUntil = autoSwitchCooldownUntil,
           Date.now < cooldownUntil {
            return
        }
        isCheckingAutoSwitch = true
        defer { isCheckingAutoSwitch = false }
        guard !isInteractiveLoginInProgress, !isPendingLogin else {
            autoSwitchState = .waitingForLogin
            return
        }
        do {
            // Always decide first — ChatGPT being open must not hide an exhausted active account.
            // While paused (all exhausted), still decide so recovery can clear the pause,
            // but never close Desktop / apply until a usable candidate exists.
            let decision: AutoSwitchOutput = try await cli.decode(AutoSwitchOutput.self, arguments: ["auto-switch"])
            switch decision.status {
            case "active_has_quota":
                let shouldResume =
                    pendingQuotaRecoveryResume
                    || autoSwitchAllExhaustedNotified
                    || autoSwitchPausedAllExhausted
                pendingQuotaRecoveryResume = false
                autoSwitchAllExhaustedNotified = false
                autoSwitchPausedAllExhausted = false
                autoSwitchPausedForBankedReset = false
                autoSwitchState = nil
                // Notify + auto-resume when quota recovers after being exhausted
                // (timed reset or banked-reset redeem on the same live account).
                if shouldResume {
                    ResetNotifier.showQuotaRecovered()
                    await self.resumeInterruptedSessionsAfterQuotaRecovery()
                } else {
                    logSessionResume("active_has_quota without recovery pending — skip auto-resume")
                }
            case "waiting_for_login":
                autoSwitchState = .waitingForLogin
            case "all_accounts_exhausted":
                autoSwitchPausedAllExhausted = true
                autoSwitchPausedForBankedReset = false
                pendingQuotaRecoveryResume = true
                if !autoSwitchAllExhaustedNotified {
                    autoSwitchState = .allAccountsExhausted
                    autoSwitchAllExhaustedNotified = true
                }
                // Stop switching attempts until active recovers or the user re-enables.
                return
            case "banked_reset_available":
                // UI-only: banked resets are not spendable quota; never auto-switch here.
                // Mark recovery-pending so redeem → usable quota triggers auto-resume
                // even across app relaunches / in-memory flag loss.
                autoSwitchPausedAllExhausted = true
                autoSwitchPausedForBankedReset = true
                pendingQuotaRecoveryResume = true
                autoSwitchState = .bankedResetAvailable(
                    account: decision.candidateDisplayName
                        ?? AppLanguage.text("một tài khoản", "an account"),
                    count: max(decision.bankedResetCount ?? 0, 1),
                    isActive: decision.candidateAccountId == decision.activeAccountId
                )
            case "ready":
                // Account-switch path owns resume via apply session_resume hint.
                pendingQuotaRecoveryResume = false
                autoSwitchPausedAllExhausted = false
                autoSwitchPausedForBankedReset = false
                autoSwitchAllExhaustedNotified = false
                guard !isBusyForActions else { return }
                guard !CodexActivityDetector.isTurnActive() else {
                    autoSwitchState = .generationInProgress
                    return
                }
                isSwitching = true
                defer { isSwitching = false }
                let previousAccountID = decision.activeAccountId
                let candidateName = decision.candidateDisplayName
                    ?? AppLanguage.text("tài khoản khác", "another account")
                // Save live auth first, then close Desktop, switch ~/.codex, reopen.
                // A live Codex CLI must defer switching even after Desktop has quit.
                var relaunch = ChatGPTDesktop.RelaunchPlan.preferredDesktop()
                var didCloseDesktop = false
                var didClearWebSession = false
                if ChatGPTDesktop.isRunning {
                    autoSwitchState = .closingDesktop
                    try await self.preserveLiveSessionBeforeDesktopQuit()
                    relaunch = try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
                    ChatGPTDesktop.clearWebSessionCacheOnce(didClear: &didClearWebSession)
                    didCloseDesktop = true
                }
                autoSwitchState = .switchingAccount
                var applyArguments = ["auto-switch", "--apply"]
                if let candidateId = decision.candidateAccountId {
                    applyArguments += ["--account-id", candidateId.uuidString]
                }
                if didCloseDesktop {
                    applyArguments.append("--force")
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
                try? await Task.sleep(for: .milliseconds(100))
                // Required before relaunch — no-op when the post-quit clear already
                // ran and Desktop stayed quit; still clears when Desktop was already
                // quit at decide time (post-quit branch skipped).
                ChatGPTDesktop.clearWebSessionCacheOnce(didClear: &didClearWebSession)
                var launched = await relaunch.launchAndConfirm()
                var acceptance: DesktopAcceptanceResult = .timedOut
                let expectedEmail = self.accounts.first(where: { $0.id == applied.candidateAccountId })?.email
                    ?? candidateName
                if launched, let candidateID = applied.candidateAccountId {
                    acceptance = await confirmDesktopAcceptanceWithOneRetry(
                        accountID: candidateID,
                        expectedEmail: expectedEmail,
                        relaunch: relaunch
                    )
                } else if !launched {
                    // Launch itself failed — try open again once before giving up.
                    try? await Task.sleep(for: .seconds(1))
                    launched = await relaunch.launchAndConfirm()
                    if launched, let candidateID = applied.candidateAccountId {
                        acceptance = await confirmDesktopAcceptanceWithOneRetry(
                            accountID: candidateID,
                            expectedEmail: expectedEmail,
                            relaunch: relaunch
                        )
                    }
                }
                guard acceptance == .accepted else {
                    do {
                        try await rollbackRejectedTarget(
                            rejectedAccountID: applied.candidateAccountId,
                            previousAccountID: applied.activeAccountId ?? previousAccountID,
                            fallbackRelaunch: relaunch
                        )
                        try? await reloadAccountsAfterSwitch()
                        errorMessage = Self.desktopAcceptanceFailureMessage(acceptance)
                    } catch {
                        errorMessage = AppLanguage.text(
                            "Tài khoản đích bị từ chối và rollback thất bại: \(error.localizedDescription)",
                            "The target account was rejected and rollback failed: \(error.localizedDescription)"
                        )
                    }
                    autoSwitchState = .checkFailed
                    autoSwitchCooldownUntil = Date.now.addingTimeInterval(15)
                    return
                }
                try await reloadAccountsAfterSwitch()
                autoSwitchState = .switched(applied.candidateDisplayName ?? candidateName)
                autoSwitchAllExhaustedNotified = false
                autoSwitchCooldownUntil = Date.now.addingTimeInterval(8)
                await self.applySessionResumeIfNeeded(applied.sessionResume, continueExhausted: true)
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
            await resumeAfterQuotaRefreshIfNeeded()
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
            await resumeAfterQuotaRefreshIfNeeded()
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
                switchPhaseMessage = nil
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

    /// After relaunch: wait for a settled live identity match. Never treat the
    /// first matching `~/.codex` email/ID alone as success — Desktop can still
    /// flash Sign-in. One clear+relaunch retry is allowed when acceptance is weak.
    private func confirmDesktopAcceptanceWithOneRetry(
        accountID: UUID,
        expectedEmail: String,
        relaunch: ChatGPTDesktop.RelaunchPlan
    ) async -> DesktopAcceptanceResult {
        defer { switchPhaseMessage = nil }
        switchPhaseMessage = AppLanguage.text(
            "Đang xác nhận ChatGPT đã nhận phiên…",
            "Confirming ChatGPT accepted the session…"
        )
        let first = await waitForDesktopAcceptance(accountID: accountID, expectedEmail: expectedEmail)
        if first == .accepted || first == .rejected {
            return first
        }

        // Weak / timed-out: one longevity-safe clear+relaunch retry (no RT prove).
        switchPhaseMessage = AppLanguage.text(
            "ChatGPT chưa ổn định — lưu phiên, xóa cache web và mở lại…",
            "ChatGPT unsettled — saving session, clearing web cache, and relaunching…"
        )
        do {
            if ChatGPTDesktop.isRunning {
                try await preserveLiveSessionBeforeDesktopQuit()
                _ = try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
            }
            ChatGPTDesktop.clearWebSessionCache()
            guard await relaunch.launchAndConfirm() else {
                return .timedOut
            }
            switchPhaseMessage = AppLanguage.text(
                "Đang xác nhận lại sau khi mở lại ChatGPT…",
                "Re-confirming after ChatGPT relaunch…"
            )
            return await waitForDesktopAcceptance(accountID: accountID, expectedEmail: expectedEmail)
        } catch {
            return first == .uncertain ? .uncertain : .timedOut
        }
    }

    private func waitForDesktopAcceptance(accountID: UUID, expectedEmail: String) async -> DesktopAcceptanceResult {
        // Give Desktop time to open and either rehydrate from restored auth.json
        // or reject a proven-dead session. Acceptance is based on the LIVE
        // ~/.codex identity — never on a saved-account usage probe (that only
        // checks the snapshot bytes and can report OK while the UI still shows
        // "Sign in to ChatGPT").
        // Fast path: Desktop already running → poll immediately after a short
        // beat. Cold launch still gets a longer head start before the loop.
        if ChatGPTDesktop.isRunning {
            try? await Task.sleep(for: .milliseconds(300))
        } else {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let deadline = ContinuousClock.now + .seconds(10)
        var sawMatchingLiveIdentity = false
        while ContinuousClock.now < deadline {
            guard ChatGPTDesktop.isRunning else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            do {
                let status = try await cli.decode(StatusOutput.self, arguments: ["status"])
                guard let live = status.currentAccount else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let emailMatches = live.email.caseInsensitiveCompare(expectedEmail) == .orderedSame
                let idMatches = status.currentAccountSavedId == accountID
                guard emailMatches || idMatches else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                sawMatchingLiveIdentity = true
                // Settle: first match alone is weak — Desktop may still be on Sign-in.
                try? await Task.sleep(for: .milliseconds(500))
                guard ChatGPTDesktop.isRunning else { continue }
                let settled = try await cli.decode(StatusOutput.self, arguments: ["status"])
                let settledEmail = settled.currentAccount?.email
                let settledEmailMatches = settledEmail.map {
                    $0.caseInsensitiveCompare(expectedEmail) == .orderedSame
                } ?? false
                let settledIDMatches = settled.currentAccountSavedId == accountID
                guard settledEmailMatches || settledIDMatches else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                do {
                    // Live usage probe (no account-id) — AT-only, no RT prove.
                    _ = try await cli.data(arguments: ["usage", "--json"])
                    return .accepted
                } catch {
                    if Self.usageErrorForcesRollback(error.localizedDescription) {
                        return .rejected
                    }
                    // Expired AT / deferred is fine: Desktop owns refresh once
                    // live identity has settled on the target.
                    return .accepted
                }
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        // Never silent false-OK: a fleeting match without settle is uncertain.
        return sawMatchingLiveIdentity ? .uncertain : .timedOut
    }

    private static func desktopAcceptanceFailureMessage(_ result: DesktopAcceptanceResult) -> String {
        switch result {
        case .accepted:
            return AppLanguage.text(
                "ChatGPT không chấp nhận tài khoản đích; phiên trước đã được khôi phục an toàn.",
                "ChatGPT rejected the target account; the previous session was restored safely."
            )
        case .rejected:
            return AppLanguage.text(
                "ChatGPT từ chối phiên đích (cần đăng nhập lại); phiên trước đã được khôi phục.",
                "ChatGPT rejected the target session (sign-in required); the previous session was restored."
            )
        case .uncertain:
            return AppLanguage.text(
                "Phiên ~/.codex đã khớp nhưng ChatGPT chưa xác nhận ổn định (có thể vẫn Sign-in). Phiên trước đã được khôi phục — hãy thử Đổi lại hoặc Mở lại ChatGPT.",
                "Live ~/.codex matched but ChatGPT acceptance is uncertain (Sign-in may still show). Previous session restored — try Switch again or Relaunch ChatGPT."
            )
        case .timedOut:
            return AppLanguage.text(
                "ChatGPT không xác nhận phiên đích kịp thời; phiên trước đã được khôi phục.",
                "ChatGPT did not confirm the target session in time; the previous session was restored."
            )
        }
    }

    /// Whether a `usage` probe error means the target account is genuinely
    /// signed out and the switch must roll back.
    /// Source of truth: `usage_error_requires_login` in `src/usage.rs`.
    /// A plain access-token 401 / deferred `[access_token_unauthorized]` is
    /// deliberately excluded because the saved refresh token was not proven invalid.
    private static func usageErrorForcesRollback(_ message: String) -> Bool {
        usageErrorRequiresLogin(message)
    }

    /// Soft post-login / post-switch AT failure: credential is saved, but the
    /// access token was not yet accepted. Mirror Rust
    /// `usage_error_is_deferred_access_token_refresh`.
    private static func isDeferredAccessTokenUsageError(_ message: String) -> Bool {
        usageErrorIsDeferredAccessTokenRefresh(message)
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
        let relaunch: ChatGPTDesktop.RelaunchPlan
        var didClearWebSession = false
        if ChatGPTDesktop.isRunning {
            try await preserveLiveSessionBeforeDesktopQuit()
            relaunch = try await ChatGPTDesktop.prepareForAccountSwitch(force: true)
            ChatGPTDesktop.clearWebSessionCacheOnce(didClear: &didClearWebSession)
        } else {
            relaunch = fallbackRelaunch
        }
        _ = try await activateAfterProcessesDrain(accountID: previousAccountID, waitForDrain: true)
        try? await Task.sleep(for: .milliseconds(100))
        ChatGPTDesktop.clearWebSessionCacheOnce(didClear: &didClearWebSession)
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

enum DesktopAcceptanceResult: Equatable {
    case accepted
    case rejected
    /// Live identity matched at least once, but Desktop never settled.
    case uncertain
    case timedOut
}

enum AutoSwitchState: Equatable {
    case waitingForLogin
    case allAccountsExhausted
    case bankedResetAvailable(account: String, count: Int, isActive: Bool)
    case closingDesktop
    case switchingAccount
    case relaunchingDesktop
    case desktopRelaunchFailed
    case waitingForProcesses
    case switched(String)
    case checkFailed
    case generationInProgress
}

private struct AccountHubCLI {
    func decode<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
        // Idempotent: callers must not pass `--json` themselves, but tolerate it
        // so a stray flag never becomes `cannot be used multiple times`.
        let jsonArgs = arguments.contains("--json") ? arguments : arguments + ["--json"]
        let data = try await data(arguments: jsonArgs)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let command = arguments.first ?? "requested"
            throw CLIError(AppLanguage.text(
                "Không thể đọc dữ liệu cho \(command). Hãy làm mới Codex Roster rồi thử lại.",
                "Could not decode data for \(command). Refresh Codex Roster and try again."
            ))
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
            throw CLIError(AppLanguage.text(
                "Codex Roster không kịp hoàn tất trong hai phút.",
                "Codex Roster did not finish within two minutes."
            ))
        }
        captures.wait()
        let outputData = outputCapture.data
        guard process.terminationStatus == 0 else {
            let errorData = errorCapture.data
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(detail?.isEmpty == false ? detail! : AppLanguage.text(
                "Lệnh Codex Roster thất bại.",
                "The Codex Roster command failed."
            ))
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

    /// Start `codex login`. When `codexHome` is set, login writes credentials
    /// only into that isolated home (enroll-only); live `~/.codex` is untouched.
    static func start(codexHome: URL?) throws {
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
        var environment = ProcessInfo.processInfo.environment
        if let codexHome {
            environment["CODEX_HOME"] = codexHome.path
        }
        login.environment = environment
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

/// Codex CLI login callback ports (`codex-rs/login/src/server.rs`).
/// DEFAULT_PORT = 1455, FALLBACK_PORT = 1457. Desktop's app-server may hold these.
enum CodexLoginPort {
    static let primary: UInt16 = 1455
    static let fallback: UInt16 = 1457

    static var isBusy: Bool {
        isListening(port: primary) || isListening(port: fallback)
    }

    private static func isListening(port: UInt16) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST | AI_NUMERICSERV,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        guard getaddrinfo("127.0.0.1", portString, &hints, &info) == 0, let info else {
            return false
        }
        defer { freeaddrinfo(info) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // SO_REUSEADDR alone is not enough to detect a live listener; try connect.
        let connected = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
        return connected
    }
}

enum ChatGPTDesktop {
    /// ChatGPT Desktop on macOS currently ships as `com.openai.codex`.
    private static let bundleIdentifiers = ["com.openai.codex", "com.openai.chat"]
    private static let knownAppPaths = [
        "/Applications/ChatGPT.app",
        "/Applications/Codex.app",
    ]
    /// Public read-only view for session-resume deep links.
    static var knownDesktopAppPaths: [String] { knownAppPaths }

    /// Bundle IDs that LaunchServices can actually resolve on this Mac.
    /// Filters out stale ids like `com.openai.chat` when only `com.openai.codex` is installed.
    static func resolvableBundleIDs() -> [String] {
        let resolved = bundleIdentifiers.filter { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
                || knownAppPaths.contains(where: { path in
                    FileManager.default.fileExists(atPath: path)
                        && bundleIdentifier(at: URL(fileURLWithPath: path)) == id
                })
        }
        return resolved.isEmpty ? ["com.openai.codex"] : resolved
    }
    private static let terminatePollInterval: Duration = .milliseconds(50)
    /// Wait long enough for ChatGPT/Codex to flush rotated refresh tokens on
    /// graceful quit before escalating to forceTerminate / SIGKILL.
    private static let gracefulTerminateDeadline: Duration = .seconds(6)
    private static let forceTerminateDeadline: Duration = .seconds(3)
    private static let launchConfirmDeadline: Duration = .seconds(5)

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
            try? await Task.sleep(for: .milliseconds(150))
            await openDesktop()
            if await waitUntilRunning(deadline: .seconds(2)) {
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

        // Prefer a graceful quit so Desktop can flush the latest rotated refresh
        // token to disk. Callers that switch accounts must save the live session
        // before invoking this with force: true.
        for app in runningApps {
            app.terminate()
        }
        if await waitUntilQuit(deadline: gracefulTerminateDeadline) {
            killOrphanDesktopCodexServers()
            return relaunch
        }
        for app in runningApplications {
            app.forceTerminate()
            kill(app.processIdentifier, SIGTERM)
        }
        if await waitUntilQuit(deadline: forceTerminateDeadline) {
            killOrphanDesktopCodexServers()
            return relaunch
        }
        for app in runningApplications {
            app.forceTerminate()
            kill(app.processIdentifier, SIGKILL)
        }
        if await waitUntilQuit(deadline: .seconds(1)) {
            killOrphanDesktopCodexServers()
            return relaunch
        }
        killOrphanDesktopCodexServers()
        throw CLIError(AppLanguage.text(
            "Không thể đóng hoàn toàn ChatGPT Desktop trước khi chuyển tài khoản.",
            "Could not fully quit ChatGPT Desktop before switching accounts."
        ))
    }

    /// Drop Chromium web-session caches so Desktop rehydrates from restored
    /// `~/.codex/auth.json` instead of a stale logged-out cookie jar.
    /// Call only after Desktop processes have fully quit.
    ///
    /// ChatGPT Desktop also keeps a full session under
    /// `Default/Partitions/codex-browser-app` — clearing only the top-level
    /// `Default` / `codex-browser-app` roots leaves Sign-in cookies behind.
    static func clearWebSessionCache() {
        guard !isRunning else { return }
        let supportRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex", isDirectory: true)
        let fm = FileManager.default
        var profileDirs = ["Default", "codex-browser-app"].map {
            supportRoot.appendingPathComponent($0, isDirectory: true)
        }
        let partitionsRoot = supportRoot
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Partitions", isDirectory: true)
        if let partitions = try? fm.contentsOfDirectory(
            at: partitionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            profileDirs.append(contentsOf: partitions.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            })
        }
        let fileNames = [
            "Cookies",
            "Cookies-journal",
            "Network Persistent State",
            "TransportSecurity",
        ]
        let directoryNames = [
            "Local Storage",
            "Session Storage",
            "Service Worker",
            "IndexedDB",
            "Cache Storage",
            "Code Cache",
            "GPUCache",
            "WebStorage",
        ]
        for profile in profileDirs where fm.fileExists(atPath: profile.path) {
            for name in fileNames {
                try? fm.removeItem(at: profile.appendingPathComponent(name))
            }
            for name in directoryNames {
                try? fm.removeItem(at: profile.appendingPathComponent(name, isDirectory: true))
            }
            // Newer Chromium profiles store cookies under Network/.
            let network = profile.appendingPathComponent("Network", isDirectory: true)
            if fm.fileExists(atPath: network.path) {
                for name in fileNames {
                    try? fm.removeItem(at: network.appendingPathComponent(name))
                }
            }
        }
        // Stale singleton locks can make the next launch attach to a half-dead
        // profile and keep showing the sign-in screen.
        for name in ["SingletonLock", "SingletonCookie", "SingletonSocket"] {
            try? fm.removeItem(at: supportRoot.appendingPathComponent(name))
        }
    }

    /// Clear once per switch path. Skips a duplicate wipe when the same switch
    /// already cleared while Desktop stayed quit — still runs before relaunch
    /// when the post-quit clear was skipped (Desktop already quit).
    static func clearWebSessionCacheOnce(didClear: inout Bool) {
        guard !didClear else { return }
        guard !isRunning else { return }
        clearWebSessionCache()
        didClear = true
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

    /// ChatGPT Desktop leaves `~/.codex/plugins/.plugin-appserver/codex app-server`
    /// running after the UI process dies. Those look like a live CLI to Roster
    /// and must be torn down before swapping auth.
    private static func killOrphanDesktopCodexServers() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let marker = "\(home)/.codex/plugins/.plugin-appserver/codex"
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", marker]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            return
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 1 else {
                continue
            }
            kill(pid, SIGTERM)
        }
        usleep(200_000)
        for line in output.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 1 else {
                continue
            }
            kill(pid, SIGKILL)
        }
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
    let vibeUsage: VibeUsageSummary?
    let codexModel: String?

    init(
        currentAccount: AccountIdentity?,
        currentAccountSavedId: UUID? = nil,
        processWarnings: [RunningProcess],
        vibeUsage: VibeUsageSummary? = nil,
        codexModel: String? = nil
    ) {
        self.currentAccount = currentAccount
        self.currentAccountSavedId = currentAccountSavedId
        self.processWarnings = processWarnings
        self.vibeUsage = vibeUsage
        self.codexModel = codexModel
    }
}

struct VibeUsageSummary: Decodable {
    let days: UInt8
    let totalTokens: UInt64
    let estimatedCostUsd: Double
    let sessions: Int
    let activeSeconds: UInt64
    let fetchedAt: RustDate
}

private struct SaveOutput: Decodable {
    let account: SavedAccount
}

private struct ImportJsonOutput: Decodable {
    let format: String
    let created: Int
    let updated: Int
    let accounts: [SavedAccount]
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

struct ProviderStatusOutput: Decodable {
    let providers: [ProviderState]
}

struct ProviderState: Identifiable, Decodable {
    let provider: AIProvider
    let available: Bool
    let identity: AccountIdentity?
    let savedAccounts: Int
    let currentAccountSavedId: UUID?
    let usageError: String?

    var id: AIProvider { provider }
}

struct ActivateOutput: Decodable {
    let account: SavedAccount
    let previousAccountId: UUID?
    let sessionResume: SessionResumeHint?
}

struct SessionResumeHint: Decodable {
    let enabled: Bool
    let accountId: UUID?
    let sessionId: String?
    let cwd: String?
    let rolloutPath: String?
    let status: String
    /// Other interrupted threads from the same auto-switch capture (may be omitted).
    let additionalSessions: [SessionResumeHint]

    private enum CodingKeys: String, CodingKey {
        case enabled, accountId, sessionId, cwd, rolloutPath, status, additionalSessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        accountId = try container.decodeIfPresent(UUID.self, forKey: .accountId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        rolloutPath = try container.decodeIfPresent(String.self, forKey: .rolloutPath)
        status = try container.decode(String.self, forKey: .status)
        additionalSessions = try container.decodeIfPresent([SessionResumeHint].self, forKey: .additionalSessions) ?? []
    }
}

struct TokenUsageSummary: Decodable {
    let today: UInt64
    let last7Days: UInt64
    let last30Days: UInt64
    let last365Days: UInt64
    let allTime: UInt64
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cachedInputTokens: UInt64
    let cacheWriteInputTokens: UInt64
    let reasoningOutputTokens: UInt64
    let cacheHitPercent: UInt8
    let daily: [TokenUsageDay]
    let byModel: [TokenUsageBreakdown]
    let byProject: [TokenUsageBreakdown]
    let sessionsScanned: Int
    let tokenEvents: Int
    let estimatedCostUsd: Double?
    let todayCostUsd: Double?
    let last7DaysCostUsd: Double?
    let last30DaysCostUsd: Double?
    let mainSessions: Int?
    let subagentSessions: Int?
}

struct TokenUsageBreakdown: Identifiable, Decodable {
    let label: String
    let tokens: UInt64
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cachedInputTokens: UInt64
    let cacheWriteInputTokens: UInt64
    let reasoningOutputTokens: UInt64
    let tokenEvents: Int
    let estimatedCostUsd: Double?

    var id: String { label }
}

struct ResetOutlook: Decodable {
    let updatedAt: String
    let lastResetAt: String
    let nextResetAt: String?
    let lastResetIsConfirmed: Bool?
    let windowLabel: String
    let windowTimezone: String?
    let windowStartHour: Int?
    let windowEndHour: Int?
    let signalKind: String?
    let signalSummary: String?
    let sourceUrl: String?
    let sourceFreshness: String?
    let cadenceDays: Double?
    let cadenceAccelerating: Bool?
}

/// Schedule/status copy aligned with codex-resets.com (no 24h/48h/signal %).
enum ResetOutlookPresentation {
    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func headline(_ outlook: ResetOutlook, language: AppLanguage) -> String {
        let kind = outlook.signalKind ?? ""
        let banked = kind.contains("banked")
        let name = banked ? "Banked reset" : "Reset"
        if kind.hasPrefix("scheduled") {
            if let date = parseDate(outlook.nextResetAt) {
                if date <= Date() {
                    return language == .vietnamese
                        ? "\(name): chờ xác nhận"
                        : "\(name): awaiting confirmation"
                }
                let formatter = DateFormatter()
                formatter.locale = language.locale
                formatter.dateFormat = "HH:mm dd/MM"
                let prefix = language == .vietnamese ? "\(name) dự kiến" : "\(name) scheduled"
                return "\(prefix) · \(formatter.string(from: date))"
            }
            return language == .vietnamese
                ? "\(name): đã có thông báo"
                : "\(name): announced"
        }
        if kind.hasPrefix("confirmed") {
            return language == .vietnamese
                ? "\(name): đã xác nhận"
                : "\(name): confirmed"
        }
        return language == .vietnamese
            ? "Reset: đang theo dõi"
            : "Reset: watching"
    }
}

private struct GlobalResetEvent: Decodable {
    let id: String
    let announcedAt: String
    let summary: String
    let url: String
    let kind: String
}

struct ResetTimelineEvent: Decodable, Identifiable {
    let id: String
    let date: String
    let eventType: String
    let summary: String
    let url: String
    let announcedAt: String
    let scope: String?
    let confidence: String?
    let resetKind: String?
}

/// Matches Rust `ResetTimeline` JSON from `codex-roster reset-timeline --json`.
private struct ResetTimelinePayload: Decodable {
    let updatedAt: String?
    let events: [ResetTimelineEvent]
}

struct ResetJuice: Decodable {
    let status: String
    let model: String?
    let checkedAt: String?
    let verifiedEfforts: Int?
    let efforts: [ResetJuiceEffort]
}

struct ResetJuiceEffort: Decodable, Identifiable {
    let effort: String
    let current: Int
    let previous: Int
    let delta: Int
    let verificationState: String?
    var id: String { effort }
}

func trustedResetSourceURL(_ value: String?) -> URL? {
    guard let value,
          let components = URLComponents(string: value),
          components.scheme?.lowercased() == "https",
          components.user == nil,
          components.password == nil,
          components.port == nil,
          components.query == nil,
          components.fragment == nil else { return nil }
    let host = components.host?.lowercased() ?? ""
    if host == "codex-resets.com" || host == "codex-reset.com" {
        return components.url
    }
    guard host == "x.com" else { return nil }
    let path = components.path.split(separator: "/")
    guard path.count == 3,
          path[0].lowercased() == "thsottiaux",
          path[1].lowercased() == "status",
          !path[2].isEmpty,
          path[2].allSatisfy(\.isNumber) else { return nil }
    return components.url
}

/// Legacy alias kept for any remaining call sites / tests mid-rename.
func trustedTiboSourceURL(_ value: String?) -> URL? {
    trustedResetSourceURL(value)
}

private enum ResetNotifier {
    private static let delegate = ResetNotificationDelegate()
    private static let signalStateKey = "codexRoster.resetSignalNotificationState.v1"

    private struct SignalState: Codable, Equatable {
        var seenCreditIDs: Set<String> = []
        var availableCountByAccount: [String: Int] = [:]
        var usageByAccount: [String: UsageObservation] = [:]
        var pendingResetByWindow: [String: PendingReset] = [:]
        /// Last weekly/5H remaining we already warned about (cross edge ≤15%).
        var lowQuotaWarnedPercentByAccount: [String: Int] = [:]
        /// Last OpenAI status indicator we notified about.
        var lastOpenAIIndicator: String?

        private enum CodingKeys: String, CodingKey {
            case seenCreditIDs
            case availableCountByAccount
            case usageByAccount
            case pendingResetByWindow
            case lowQuotaWarnedPercentByAccount
            case lastOpenAIIndicator
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            seenCreditIDs = try values.decodeIfPresent(Set<String>.self, forKey: .seenCreditIDs) ?? []
            availableCountByAccount = try values.decodeIfPresent([String: Int].self, forKey: .availableCountByAccount) ?? [:]
            usageByAccount = try values.decodeIfPresent([String: UsageObservation].self, forKey: .usageByAccount) ?? [:]
            pendingResetByWindow = try values.decodeIfPresent([String: PendingReset].self, forKey: .pendingResetByWindow) ?? [:]
            lowQuotaWarnedPercentByAccount = try values.decodeIfPresent([String: Int].self, forKey: .lowQuotaWarnedPercentByAccount) ?? [:]
            lastOpenAIIndicator = try values.decodeIfPresent(String.self, forKey: .lastOpenAIIndicator)
        }
    }

    private struct UsageObservation: Codable, Equatable {
        let fetchedAt: Date
        let fiveHour: WindowObservation?
        let weekly: WindowObservation?
    }

    private struct WindowObservation: Codable, Equatable {
        let remainingPercent: Int
        let resetAt: Date
    }

    private struct WindowResetChange {
        let label: String
        let previousRemaining: Int
        let currentRemaining: Int
    }

    private struct PendingReset: Codable, Equatable {
        let previousRemaining: Int
        let candidateRemaining: Int
        let candidateResetAt: Date
        let observedAt: Date
    }

    static func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    static func showAccountSignals(
        _ accounts: [SavedAccount],
        autoSwitchEnabled: Bool = false
    ) {
        var state = loadSignalState()
        let previousState = state
        for account in accounts where !account.archived {
            let accountKey = account.id.uuidString
            showNewBankedResets(for: account, accountKey: accountKey, state: &state)
            showDetectedQuotaReset(for: account, accountKey: accountKey, state: &state)
            showLowQuotaWarning(
                for: account,
                accountKey: accountKey,
                autoSwitchEnabled: autoSwitchEnabled,
                state: &state
            )
        }
        if state != previousState {
            saveSignalState(state)
        }
    }

    /// Notify once when OpenAI status leaves operational (`indicator != none`).
    static func showOpenAIIncidentIfNeeded(_ status: OpenAIServiceStatus?) {
        guard let status else { return }
        var state = loadSignalState()
        let previous = state.lastOpenAIIndicator
        state.lastOpenAIIndicator = status.indicator
        defer { saveSignalState(state) }
        guard status.indicator != "none" else { return }
        guard previous != status.indicator else { return }
        enqueue(
            identifier: "codex-roster-openai-\(status.indicator)-\(status.updatedAt)",
            title: AppLanguage.text("Sự cố dịch vụ OpenAI", "OpenAI service issue"),
            subtitle: localizedOpenAIIncidentSubtitle(status.description),
            body: AppLanguage.text(
                "Trạng thái dịch vụ không còn ổn định. Kiểm tra notch hoặc tab Vận hành.",
                "Service status is no longer healthy. Check the notch or the Operations tab."
            )
        )
    }

    static func showPublicSignal(_ signal: GlobalResetEvent) {
        let title = switch signal.kind {
        case "confirmed_banked_reset":
            AppLanguage.text(
                "Codex Reset: đã cấp banked reset",
                "Codex Reset: banked reset confirmed"
            )
        case "scheduled_banked_reset":
            AppLanguage.text(
                "Codex Reset: banked reset sắp tới",
                "Codex Reset: banked reset scheduled"
            )
        case "confirmed_global_reset":
            AppLanguage.text(
                "Codex Reset: đã xác nhận mass reset",
                "Codex Reset: global reset confirmed"
            )
        case "scheduled_global_reset":
            AppLanguage.text(
                "Codex Reset: mass reset sắp tới",
                "Codex Reset: global reset scheduled"
            )
        default:
            AppLanguage.text(
                "Codex Reset: tín hiệu reset mới",
                "Codex Reset: new reset signal"
            )
        }
        enqueue(
            identifier: "codex-roster-reset-\(signal.id)",
            title: title,
            subtitle: "codex-resets.com",
            body: signal.summary,
            url: signal.url
        )
    }

    static func showQuotaRecovered() {
        enqueue(
            identifier: "codex-roster-quota-recovered-\(Int(Date().timeIntervalSince1970))",
            title: AppLanguage.text("Quota đã phục hồi", "Quota recovered"),
            subtitle: AppLanguage.text(
                "Tài khoản có thể sử dụng lại",
                "Account is usable again"
            ),
            body: AppLanguage.text(
                "Quota Codex đã được đặt lại. Bạn có thể tiếp tục làm việc.",
                "Codex quota has been reset. You can continue working."
            )
        )
    }

    private static func showLowQuotaWarning(
        for account: SavedAccount,
        accountKey: String,
        autoSwitchEnabled: Bool,
        state: inout SignalState
    ) {
        // Active account only — avoid fan-out noise across the whole roster.
        guard account.isActive, !account.archived else { return }
        let weekly = account.usage?.weekly?.displayRemainingPercent
        let five = account.usage?.fiveHour?.displayRemainingPercent
        let bottleneck = [weekly, five].compactMap { $0 }.min()
        guard let remaining = bottleneck else { return }
        let previous = state.lowQuotaWarnedPercentByAccount[accountKey]
        // Cross below 15% once; clear when recovered above 25% so a later dip can warn again.
        if remaining > 25 {
            state.lowQuotaWarnedPercentByAccount[accountKey] = remaining
            return
        }
        guard remaining <= 15 else { return }
        if let previous, previous <= 15 { return }
        state.lowQuotaWarnedPercentByAccount[accountKey] = remaining
        let windowLabel: String = {
            if let weekly, weekly == remaining {
                return AppLanguage.text("Tuần", "Weekly")
            }
            return AppLanguage.text("5 giờ", "5-hour")
        }()
        let body = autoSwitchEnabled
            ? AppLanguage.text(
                "\(windowLabel) còn \(remaining)%. Tự chuyển sẽ đổi tài khoản khi hết quota.",
                "\(windowLabel) at \(remaining)%. Auto-switch will change accounts when quota runs out."
            )
            : AppLanguage.text(
                "\(windowLabel) còn \(remaining)%. Cân nhắc chuyển tài khoản từ notch.",
                "\(windowLabel) at \(remaining)%. Consider switching from the notch."
            )
        enqueue(
            identifier: "codex-roster-low-quota-\(accountKey)-\(remaining)",
            title: AppLanguage.text("Quota sắp hết", "Quota running low"),
            subtitle: account.displayName,
            body: body
        )
    }

    private static func showNewBankedResets(
        for account: SavedAccount,
        accountKey: String,
        state: inout SignalState
    ) {
        guard let resets = account.usage?.bankedResets else { return }
        let availableCount = resets.totalAvailableCount
        let availableCredits = (resets.credits ?? []).filter { $0.status == "available" }
        let unseenCredits = availableCredits.filter { !state.seenCreditIDs.contains($0.id) }
        let previousCount = state.availableCountByAccount[accountKey] ?? 0
        let countIncrease = max(0, availableCount - previousCount)
        let newlyGranted = max(unseenCredits.count, countIncrease)

        state.seenCreditIDs.formUnion(availableCredits.map(\.id))
        state.availableCountByAccount[accountKey] = availableCount
        guard newlyGranted > 0 else { return }

        let nearestExpiry = (unseenCredits.isEmpty ? availableCredits : unseenCredits)
            .compactMap { $0.expiresAt?.value }
            .min()
        var body = AppLanguage.text(
            newlyGranted == 1
                ? "\(account.displayName) vừa nhận thêm 1 lượt reset dự phòng Codex."
                : "\(account.displayName) vừa nhận thêm \(newlyGranted) lượt reset dự phòng Codex.",
            newlyGranted == 1
                ? "\(account.displayName) received 1 Codex banked reset."
                : "\(account.displayName) received \(newlyGranted) Codex banked resets."
        )
        if let title = unseenCredits.first?.title, !title.isEmpty {
            body += " \(title)"
        }
        if let nearestExpiry {
            body += AppLanguage.text(
                " Hạn: \(nearestExpiry.formatted(date: .abbreviated, time: .shortened)).",
                " Expires: \(nearestExpiry.formatted(date: .abbreviated, time: .shortened))."
            )
        }
        body += AppLanguage.text(
            " Hiện có \(availableCount) lượt khả dụng.",
            " \(availableCount) currently available."
        )
        enqueue(
            identifier: "codex-roster-banked-\(accountKey)-\(unseenCredits.first?.id ?? String(availableCount))",
            title: AppLanguage.text("Reset dự phòng mới", "New banked reset"),
            subtitle: account.displayName,
            body: body
        )
    }

    private static func showDetectedQuotaReset(
        for account: SavedAccount,
        accountKey: String,
        state: inout SignalState
    ) {
        guard let current = usageObservation(for: account) else { return }
        defer { state.usageByAccount[accountKey] = current }
        guard let previous = state.usageByAccount[accountKey],
              current.fetchedAt > previous.fetchedAt else { return }

        let changes = confirmedResetChanges(
            accountKey: accountKey,
            current: current,
            state: &state
        )
        recordResetCandidates(
            accountKey: accountKey,
            previous: previous,
            current: current,
            state: &state
        )
        guard !changes.isEmpty else { return }
        let detail = changes.map { change in
            AppLanguage.text(
                "\(change.label): \(change.previousRemaining)% → \(change.currentRemaining)%",
                "\(change.label): \(change.previousRemaining)% → \(change.currentRemaining)%"
            )
        }.joined(separator: " · ")
        enqueue(
            identifier: "codex-roster-quota-reset-\(accountKey)-\(Int(current.fetchedAt.timeIntervalSince1970))",
            title: AppLanguage.text(
                "\(account.displayName) đã đặt lại quota",
                "\(account.displayName) quota reset"
            ),
            subtitle: AppLanguage.text(
                "Quota Codex đã được đặt lại",
                "Codex quota has been reset"
            ),
            body: detail
        )
    }

    private static func confirmedResetChanges(
        accountKey: String,
        current: UsageObservation,
        state: inout SignalState
    ) -> [WindowResetChange] {
        var changes: [WindowResetChange] = []
        for (key, label, window) in resetWindows(accountKey: accountKey, observation: current) {
            guard let window, let pending = state.pendingResetByWindow[key] else { continue }
            guard current.fetchedAt > pending.observedAt else { continue }
            if window.remainingPercent >= pending.candidateRemaining - 1,
               window.resetAt >= pending.candidateResetAt {
                changes.append(WindowResetChange(
                    label: label,
                    previousRemaining: pending.previousRemaining,
                    currentRemaining: window.remainingPercent
                ))
                state.pendingResetByWindow.removeValue(forKey: key)
            } else if window.remainingPercent < pending.candidateRemaining - 5 {
                state.pendingResetByWindow.removeValue(forKey: key)
            }
        }
        return changes
    }

    private static func recordResetCandidates(
        accountKey: String,
        previous: UsageObservation,
        current: UsageObservation,
        state: inout SignalState
    ) {
        let previousWindows = resetWindows(accountKey: accountKey, observation: previous)
        let currentWindows = resetWindows(accountKey: accountKey, observation: current)
        for index in currentWindows.indices {
            let (key, _, currentWindow) = currentWindows[index]
            let previousWindow = previousWindows[index].window
            guard state.pendingResetByWindow[key] == nil,
                  resetChange(label: "", previous: previousWindow, current: currentWindow) != nil,
                  let currentWindow else { continue }
            state.pendingResetByWindow[key] = PendingReset(
                previousRemaining: previousWindow?.remainingPercent ?? 0,
                candidateRemaining: currentWindow.remainingPercent,
                candidateResetAt: currentWindow.resetAt,
                observedAt: current.fetchedAt
            )
        }
    }

    private static func resetWindows(
        accountKey: String,
        observation: UsageObservation
    ) -> [(key: String, label: String, window: WindowObservation?)] {
        [
            ("\(accountKey):five-hour", AppLanguage.text("5 giờ", "5-hour"), observation.fiveHour),
            ("\(accountKey):weekly", AppLanguage.text("Tuần", "Weekly"), observation.weekly),
        ]
    }

    /// Map common OpenAI status page phrases into the active UI language.
    private static func localizedOpenAIIncidentSubtitle(_ description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AppLanguage.text("Trạng thái dịch vụ thay đổi", "Service status changed")
        }
        guard AppLanguage.current == .vietnamese else { return trimmed }
        switch trimmed {
        case "All Systems Operational":
            return "Mọi hệ thống đang hoạt động"
        case "Degraded Performance":
            return "Hiệu năng bị giảm"
        case "Partial System Outage":
            return "Gián đoạn một phần"
        case "Major Service Outage":
            return "Gián đoạn nghiêm trọng"
        case "Minor Service Outage":
            return "Gián đoạn nhỏ"
        case "Under Maintenance":
            return "Đang bảo trì"
        default:
            return trimmed
        }
    }

    private static func usageObservation(for account: SavedAccount) -> UsageObservation? {
        guard let usage = account.usage, let fetchedAt = usage.fetchedAt?.value else { return nil }
        return UsageObservation(
            fetchedAt: fetchedAt,
            fiveHour: usage.fiveHour.map {
                WindowObservation(remainingPercent: $0.remainingPercent, resetAt: $0.resetAt.value)
            },
            weekly: usage.weekly.map {
                WindowObservation(remainingPercent: $0.remainingPercent, resetAt: $0.resetAt.value)
            }
        )
    }

    private static func resetChange(
        label: String,
        previous: WindowObservation?,
        current: WindowObservation?
    ) -> WindowResetChange? {
        guard let previous, let current else { return nil }
        let restoredPercent = current.remainingPercent - previous.remainingPercent
        guard restoredPercent >= 5,
              current.resetAt > previous.resetAt
                  || previous.remainingPercent <= UsageWindow.exhaustedRemainingPercent else {
            return nil
        }
        return WindowResetChange(
            label: label,
            previousRemaining: previous.remainingPercent,
            currentRemaining: current.remainingPercent
        )
    }

    private static func enqueue(
        identifier: String,
        title: String,
        subtitle: String,
        body: String,
        url: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        if let url {
            content.userInfo["url"] = url
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        ))
    }

    private static func loadSignalState() -> SignalState {
        guard let data = UserDefaults.standard.data(forKey: signalStateKey),
              let state = try? JSONDecoder().decode(SignalState.self, from: data) else {
            return SignalState()
        }
        return state
    }

    private static func saveSignalState(_ state: SignalState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: signalStateKey)
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
              let url = trustedResetSourceURL(value) else { return }
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
    let costUsd: Double?

    var id: String { date }
}

struct SavedAccount: Identifiable, Decodable {
    let id: UUID
    let provider: String
    let email: String
    let subject: String?
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
            subject: subject,
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
        subject: String? = nil,
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
        self.subject = subject
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
        let windowSummaries = [
            usage?.fiveHour.map {
                language == .vietnamese
                    ? "5 giờ còn \($0.displayRemainingPercent)%"
                    : "5-hour \($0.displayRemainingPercent)% remaining"
            },
            usage?.weekly.map {
                language == .vietnamese
                    ? "tuần còn \($0.displayRemainingPercent)%"
                    : "weekly \($0.displayRemainingPercent)% remaining"
            },
        ].compactMap { $0 }
        if !windowSummaries.isEmpty {
            return language == .vietnamese
                ? "Đã xác minh quota Codex · \(windowSummaries.joined(separator: " · "))"
                : "Codex quota verified · \(windowSummaries.joined(separator: " · "))"
        }
        return language == .vietnamese ? "Chưa cập nhật quota Codex" : "Codex quota not checked"
    }

    var requiresLogin: Bool {
        // Source of truth: `usage_error_requires_login` in `src/usage.rs`.
        usageErrorRequiresLogin(usageError)
    }

    var requiresLocalRecovery: Bool {
        // Source of truth: `usage_error_requires_local_recovery` in `src/usage.rs`.
        usageErrorRequiresLocalRecovery(usageError)
    }

    var hasDeferredAccessTokenRefresh: Bool {
        // Source of truth: `usage_error_is_deferred_access_token_refresh` in `src/usage.rs`.
        usageErrorIsDeferredAccessTokenRefresh(usageError)
    }

    var hasTransientUsageError: Bool {
        usageError != nil
            && !requiresLogin
            && !requiresLocalRecovery
            && !hasDeferredAccessTokenRefresh
    }

    var usageErrorBlocksActivation: Bool {
        activationIsBlockedByUsageError(usageError)
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
        // OpenAI reports the rolling five-hour allowance as `primary_window`.
        // Weekly is a separate, longer-lived cap and must not replace it in UI.
        usage?.fiveHour ?? usage?.weekly
    }

    var paidSubscriptionActiveUntil: Date? {
        let normalizedPlan = (planLabel ?? "").replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let planWords = normalizedPlan.split(whereSeparator: \.isWhitespace)
        guard !planWords.isEmpty,
              !planWords.contains(where: {
                  $0.localizedCaseInsensitiveCompare("free") == .orderedSame
                      || $0.localizedCaseInsensitiveCompare("go") == .orderedSame
              }) else { return nil }
        return usage?.subscriptionActiveUntil?.value
    }

    var quotaWindowsForSwitch: [UsageWindow] {
        [usage?.weekly, usage?.fiveHour].compactMap { $0 }
    }

    var hasUsableCredits: Bool {
        guard let credits = usage?.credits else { return false }
        if credits.unlimited { return true }
        guard credits.hasCredits else { return false }
        let digits = credits.balance.filter { $0.isNumber || $0 == "." }
        return Double(digits).map { $0 > 0 } ?? false
    }

    var isExhaustedForSwitch: Bool {
        if hasUsableCredits { return false }
        // Weekly depletion alone exhausts the account for switch purposes.
        if let weekly = usage?.weekly, weekly.isDepleted { return true }
        return quotaWindowsForSwitch.contains { $0.isDepleted }
    }

    /// Weekly-dominant usability: a depleted weekly window blocks switch even
    /// when 5H still has leftover, unless the account has usable credits.
    var isUsableForSwitch: Bool {
        if hasUsableCredits { return true }
        if let weekly = usage?.weekly {
            if weekly.isDepleted { return false }
            if let fiveHour = usage?.fiveHour {
                return !fiveHour.isDepleted
            }
            return true
        }
        // No weekly window → fall back to five-hour only.
        if let fiveHour = usage?.fiveHour {
            return !fiveHour.isDepleted
        }
        return false
    }

    var canSwitchUsingBankedReset: Bool {
        bankedResetSwitchIsAllowed(
            planLabel: planLabel,
            usageError: usageError,
            availableCount: bankedResetCount
        )
    }

    /// Total redeemable banked resets for this account.
    /// Uses `max(availableCount, available credit rows)` so a truncated details
    /// list or a stale summary field never under-counts.
    var bankedResetCount: Int {
        usage?.bankedResets?.totalAvailableCount ?? 0
    }

    /// Weekly-dominant ranking: `weekly * 1000 + fiveHour` so any weekly gap
    /// outranks any 5H-only difference. Depleted weekly → `-1`.
    /// Usable accounts whose weekly window resets within 24h get a Switchboard-
    /// style urgency boost so they surface above otherwise-equal peers.
    var switchQuotaScore: Int {
        let base: Int = {
            if let weekly = usage?.weekly {
                if weekly.isDepleted { return -1 }
                let five = usage?.fiveHour?.remainingPercent ?? 0
                return weekly.remainingPercent * 1000 + five
            }
            if let fiveHour = usage?.fiveHour {
                return fiveHour.isDepleted ? -1 : fiveHour.remainingPercent
            }
            return -1
        }()
        if base >= 0, isUsableForSwitch, hasWeeklyResetWithin24Hours {
            return base + 1_000_000
        }
        return base
    }

    /// True when the weekly window still has a future reset within 24 hours.
    var hasWeeklyResetWithin24Hours: Bool {
        guard let weekly = usage?.weekly else { return false }
        let resetAt = weekly.resetAt.value
        let now = Date()
        guard resetAt > now else { return false }
        return resetAt.timeIntervalSince(now) <= 24 * 60 * 60
    }

    /// Coarse plan band for roster section headers (Switchboard-style grouping).
    var planGroupKey: String {
        switch planSortRank {
        case 0: return "pro"
        case 1: return "plus"
        case 2: return "team"
        case 3: return "free"
        default: return "other"
        }
    }

    /// Single source of truth for where an account belongs in the triage board.
    /// Every view (sidebar, hero, board) derives grouping from this instead of
    /// re-implementing the same filter chain.
    var triage: AccountTriage {
        if archived { return .archived }
        // Deferred AT refresh is soft: do not force .needsAction. Cached quota
        // still drives Ready/Resting; Codex refreshes the AT on next switch.
        if requiresLogin || requiresLocalRecovery || hasTransientUsageError {
            return .needsAction
        }
        if isActive { return .active }
        if isUsableForSwitch { return .ready }
        return .resting
    }

    /// A `.resting` account can still be switched to when it holds a banked
    /// reset to redeem inside Codex; otherwise it is truly idle.
    var restingHasBankedReset: Bool {
        canSwitchUsingBankedReset
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

    /// Explicit Free/Go label for UI chips — empty/unknown plans stay unlabeled.
    var showsFreePlanChip: Bool {
        planLabelHasFreeOrGoWord(planLabel)
    }

    /// Monthly spend-control remaining % when the usage API publishes `credit_limit`.
    /// Free ChatGPT message caps are not a separate window in this model — do not
    /// invent a monthly % from weekly/5H.
    var monthlyQuotaRemainingPercent: Int? {
        guard let limit = usage?.credits?.creditLimit else { return nil }
        let rounded = Int(limit.remainingPercent.rounded())
        return max(0, min(100, rounded))
    }

    /// Closest non-window signal when monthly % is absent (personal credit balance).
    var creditsBalanceDisplay: String? {
        guard let credits = usage?.credits, credits.hasDisplayableBalance else { return nil }
        if credits.unlimited { return "∞" }
        return credits.balance
    }

    var hasLunaReserve: Bool {
        usage?.lunaReserve != nil
    }

    var isLunaReserveAllowed: Bool {
        usage?.lunaReserve?.allowed == true
    }

    var lunaReserveRemainingPercent: Int? {
        usage?.lunaReserve?.usedPercent.map { max(0, 100 - $0) }
    }

}

func planLabelHasFreeOrGoWord(_ planLabel: String?) -> Bool {
    let normalizedPlan = (planLabel ?? "").replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    let planWords = normalizedPlan.split(whereSeparator: \.isWhitespace)
    return planWords.contains {
        $0.localizedCaseInsensitiveCompare("free") == .orderedSame
            || $0.localizedCaseInsensitiveCompare("go") == .orderedSame
    }
}

func bankedResetSwitchIsAllowed(
    planLabel: String?,
    usageError: String?,
    availableCount: Int
) -> Bool {
    guard availableCount > 0 else { return false }
    guard !activationIsBlockedByUsageError(usageError) else { return false }
    let normalizedPlan = (planLabel ?? "").replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    let planWords = normalizedPlan.split(whereSeparator: \.isWhitespace)
    guard !planWords.isEmpty else { return false }
    return !planLabelHasFreeOrGoWord(planLabel)
}

/// Display roster ordering by weekly-dominant `switchQuotaScore` (higher first).
/// Weekly depleted scores `-1` so 5H leftovers do not float above healthy weekly.
/// Mode tie-breakers apply only when scores tie. Keep `isUsableForSwitch` for
/// auto-switch / Ready filters — not as a primary display sort key.
func accountSortIsOrderedByWeeklyQuota(_ left: SavedAccount, _ right: SavedAccount) -> Bool {
    left.switchQuotaScore > right.switchQuotaScore
}

/// Shared notch roster sizing: collapsed scroll area inside a panoramic deck;
/// expanded shows the full roster without scrolling for typical sizes.
///
/// Expand grows height to fit every account row **and** plan-section header.
/// Two readable columns remain fixed; long rosters scroll in a bounded viewport.
///
/// Pass `hasNextActionCaption: true` only when the caption row is visible so
/// all-clear layouts do not reserve a tall empty footer under Danh bạ.
enum NotchRosterLayout {
    /// Expanded panoramic width (keep in sync with `NotchWindowView.maxExpandedWidth`
    /// and `PrismQuickSwitchDeck` frame).
    static let deckWidth: CGFloat = 1020
    static let collapsedDeckHeight: CGFloat = 498
    static let collapsedRosterHeight: CGFloat = 280
    /// Compact next-action caption between upper wings and roster.
    static let nextActionCaptionHeight: CGFloat = 30
    /// Outer chrome around the panoramic deck (keep in sync with PrismQuickSwitchDeck).
    static let deckHorizontalInset: CGFloat = 12
    static let deckTopInset: CGFloat = deckHorizontalInset
    static let deckBottomInset: CGFloat = deckHorizontalInset
    /// Inner padding of the lower switchboard chrome (keep in sync with deck).
    static let switchboardHorizontalInset: CGFloat = 10
    /// Spacing between upper wings / caption / roster.
    static let deckSectionSpacing: CGFloat = deckHorizontalInset
    /// Comfortable roster cell: identity, text quotas, details, and action.
    static let rowHeight: CGFloat = 68
    /// Plan-band header row — shorter than account cards (avoid empty void).
    static let sectionHeaderHeight: CGFloat = 18
    /// Extra top padding on non-first plan headers in the grid.
    static let sectionHeaderTopGap: CGFloat = 4
    static let rowSpacing: CGFloat = 8
    /// Total vertical padding inside the roster scroll content (top + bottom).
    static let gridVerticalPadding: CGFloat = 4
    static let columnSpacing: CGFloat = 12
    /// Floor so expanded cards do not crush name/email/meters.
    static let minComfortableCardWidth: CGFloat = 290
    static let minColumns = 2
    static let maxColumns = 2
    /// The panel starts at the screen top; preserve the Dock and bottom margin.
    static var availableRosterHeight: CGFloat {
        let geometry = NotchGeometry.detect()
        let screen = NSScreen.screens.first { $0.frame == geometry.screenFrame }
        let available = geometry.screenFrame.maxY - (screen?.visibleFrame.minY ?? geometry.screenFrame.minY) - 12
        let chrome = collapsedDeckHeight - collapsedRosterHeight + nextActionCaptionHeight + deckSectionSpacing
        return max(rowHeight + gridVerticalPadding, available - chrome)
    }
    static let rosterExpandedKey = "codex_roster_notch_roster_expanded"

    /// Usable width inside the LazyVGrid (deck minus outer + switchboard insets).
    static var rosterContentWidth: CGFloat {
        deckWidth - 2 * deckHorizontalInset - 2 * switchboardHorizontalInset
    }

    /// Plan-band section sizes in switchboard display order (non-empty only).
    static func planSectionAccountCounts(from accounts: [SavedAccount]) -> [Int] {
        let groupOrder = ["pro", "plus", "team", "other", "free"]
        let grouped = Dictionary(grouping: accounts, by: \.planGroupKey)
        return groupOrder.compactMap { key in
            guard let list = grouped[key], !list.isEmpty else { return nil }
            return list.count
        }
    }

    /// Contiguous slices: read down a column, then continue in the next one.
    static func columnRanges(accountCount: Int, columns: Int) -> [Range<Int>] {
        let count = max(0, accountCount)
        let cols = max(1, columns)
        let rows = max(1, (count + cols - 1) / cols)
        return (0..<cols).map { column in
            let start = min(count, column * rows)
            return start..<min(count, start + rows)
        }
    }

    /// Section fragments in each column, including continued groups.
    static func columnSectionCounts(sectionCounts: [Int], columns: Int) -> [[Int]] {
        let counts = sectionCounts.filter { $0 > 0 }
        return columnRanges(accountCount: counts.reduce(0, +), columns: columns).map { range in
            var offset = 0
            return counts.compactMap { count in
                defer { offset += count }
                let overlap = min(range.upperBound, offset + count) - max(range.lowerBound, offset)
                return overlap > 0 ? overlap : nil
            }
        }
    }

    static func contentRowCount(sectionCounts: [Int], columns: Int) -> Int {
        let showHeaders = sectionCounts.filter { $0 > 0 }.count > 1
        return max(1, columnSectionCounts(sectionCounts: sectionCounts, columns: columns).map {
            $0.reduce(0, +) + (showHeaders ? $0.count : 0)
        }.max() ?? 0)
    }

    static func accountRowCount(sectionCounts: [Int], columns: Int) -> Int {
        max(1, columnRanges(accountCount: sectionCounts.reduce(0) { $0 + max(0, $1) }, columns: columns)
            .map(\.count).max() ?? 0)
    }

    /// Columns that still keep cards at/above `minComfortableCardWidth`.
    static func maxColumnsForComfortableWidth() -> Int {
        let usable = rosterContentWidth
        let fitted = Int(floor((usable + columnSpacing) / (minComfortableCardWidth + columnSpacing)))
        return max(minColumns, min(maxColumns, fitted))
    }

    /// Preserve readable card width at every roster size.
    static func preferredColumnCount(sectionCounts: [Int]) -> Int { minColumns }

    /// Keep readable widths; long lists scroll instead of squeezing more columns.
    static func columnCount(sectionCounts: [Int], expanded: Bool) -> Int { minColumns }

    /// Expanded lists scroll only when their actual height exceeds the screen.
    static func needsRosterScroll(
        sectionCounts: [Int], expanded: Bool,
        maximumHeight: CGFloat = availableRosterHeight
    ) -> Bool {
        guard expanded else { return true }
        return rosterGridHeight(sectionCounts: sectionCounts, expanded: true, maximumHeight: .greatestFiniteMagnitude) > maximumHeight
    }

    static func rosterGridHeight(
        sectionCounts: [Int], expanded: Bool,
        maximumHeight: CGFloat = availableRosterHeight
    ) -> CGFloat {
        guard expanded else { return collapsedRosterHeight }
        let columns = columnCount(sectionCounts: sectionCounts, expanded: true)
        let showHeaders = sectionCounts.filter { $0 > 0 }.count > 1
        let heights = columnSectionCounts(sectionCounts: sectionCounts, columns: columns).map { counts in
            let headers = showHeaders ? counts.count : 0
            let rows = counts.reduce(0, +)
            return CGFloat(headers) * sectionHeaderHeight
                + CGFloat(max(0, headers - 1)) * sectionHeaderTopGap
                + CGFloat(rows) * rowHeight
                + CGFloat(max(0, headers + rows - 1)) * rowSpacing
                + gridVerticalPadding
        }
        let contentHeight = max(rowHeight + gridVerticalPadding, heights.max() ?? 0)
        return min(contentHeight, max(0, maximumHeight))
    }

    static func rosterGridHeight(accountCount: Int, expanded: Bool) -> CGFloat {
        let counts = accountCount > 0 ? [accountCount] : []
        return rosterGridHeight(sectionCounts: counts, expanded: expanded)
    }

    static func deckHeight(
        sectionCounts: [Int],
        expanded: Bool,
        hasNextActionCaption: Bool = false
    ) -> CGFloat {
        collapsedDeckHeight - collapsedRosterHeight
            + rosterGridHeight(sectionCounts: sectionCounts, expanded: expanded)
            + (hasNextActionCaption ? nextActionCaptionHeight + deckSectionSpacing : 0)
    }

    static func deckHeight(
        accountCount: Int,
        expanded: Bool,
        hasNextActionCaption: Bool = false
    ) -> CGFloat {
        let counts = accountCount > 0 ? [accountCount] : []
        return deckHeight(
            sectionCounts: counts,
            expanded: expanded,
            hasNextActionCaption: hasNextActionCaption
        )
    }
}

func activationIsBlockedByUsageError(_ usageError: String?) -> Bool {
    // Source of truth: `usage_error_blocks_activation` in `src/usage.rs`
    // (= requires_login || requires_local_recovery). Deferred AT unauthorized
    // deliberately does NOT block activation.
    usageErrorRequiresLogin(usageError) || usageErrorRequiresLocalRecovery(usageError)
}

/// Mirrors `usage_error_requires_login` in `src/usage.rs` (source of truth).
func usageErrorRequiresLogin(_ usageError: String?) -> Bool {
    let error = usageError?.lowercased() ?? ""
    return error.contains("login required")
        || error.contains("usage authorization failed")
        || error.contains("snapshot refresh token missing")
        || error.contains("refresh_token_invalidated")
        || error.contains("your session has ended")
        || (error.contains("token refresh failed")
            && (error.contains("invalid_grant")
                || error.contains("refresh token")
                || error.contains("log out")
                || error.contains("sign in")))
}

/// Mirrors `usage_error_requires_local_recovery` in `src/usage.rs` (source of truth).
func usageErrorRequiresLocalRecovery(_ usageError: String?) -> Bool {
    let error = usageError?.lowercased() ?? ""
    return error.contains("local recovery required")
        || error.contains("decrypt")
        || error.contains("credential key")
        || error.contains("snapshot payload")
}

/// Mirrors `usage_error_is_deferred_access_token_refresh` in `src/usage.rs`
/// (source of truth). Soft signal only — never forces Login required.
func usageErrorIsDeferredAccessTokenRefresh(_ usageError: String?) -> Bool {
    let error = usageError?.lowercased() ?? ""
    return error.contains("[access_token_unauthorized]")
        || error.contains("access_token_unauthorized")
}

struct AccountUsage: Decodable {
    let fetchedAt: RustDate?
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let credits: UsageCredits?
    let bankedResets: BankedResetSummary?
    let subscriptionActiveUntil: RustDate?
    let lunaReserve: LunaReserve?
}

struct UsageCredits: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String
    /// Monthly spend-control cap (workspace/team credit pool). Absent for
    /// personal balances.
    let creditLimit: UsageCreditLimit?

    var hasDisplayableBalance: Bool {
        hasCredits && !balance.isEmpty && balance != "null"
    }
}

struct UsageCreditLimit: Decodable {
    let used: Double?
    let limit: Double
    let remainingPercent: Double
    let resetsAt: RustDate?

    /// "45.5 / 100" style summary of the monthly credit pool.
    var displayText: String {
        let format: (Double) -> String = { value in
            value.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", value)
                : String(format: "%.1f", value)
        }
        return "\(format(used ?? 0)) / \(format(limit))"
    }

    func resetDescription(in language: AppLanguage) -> String? {
        guard let resetsAt else { return nil }
        guard resetsAt.value > Date() else {
            return language == .vietnamese ? "Đang chờ đặt lại" : "Reset pending"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = language.locale
        let relative = formatter.localizedString(for: resetsAt.value, relativeTo: Date())
        return language == .vietnamese
            ? "Đặt lại \(relative)"
            : "Resets \(relative)"
    }
}

struct BankedResetSummary: Decodable {
    let availableCount: Int
    let credits: [BankedResetCredit]?

    /// Full redeemable total for display and switch eligibility.
    /// Prefer the taller of the API summary and listed `available` credits.
    var totalAvailableCount: Int {
        let fromField = max(0, availableCount)
        let fromCredits = (credits ?? []).filter {
            $0.status.compare("available", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.count
        return max(fromField, fromCredits)
    }
}

struct BankedResetCredit: Identifiable, Decodable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: RustDate
    let expiresAt: RustDate?
    let title: String?
    let description: String?
}

struct LunaReserve: Decodable, Equatable {
    let allowed: Bool
    let usedPercent: Int?
    let resetAt: RustDate?
    let modelSlug: String?

    static func == (lhs: LunaReserve, rhs: LunaReserve) -> Bool {
        lhs.allowed == rhs.allowed
            && lhs.usedPercent == rhs.usedPercent
            && lhs.resetAt?.value == rhs.resetAt?.value
            && lhs.modelSlug == rhs.modelSlug
    }
}

struct UsageWindow: Decodable {
    /// OpenAI floors `used_percent` server-side, so a window ChatGPT already
    /// blocks reads back as 1% remaining rather than a clean 0%. Treat anything
    /// at or below this remaining threshold as depleted. Mirrors the Rust
    /// `EXHAUSTED_REMAINING_PERCENT`.
    static let exhaustedRemainingPercent = 1

    let remainingPercent: Int
    let resetAt: RustDate

    var isDepleted: Bool { remainingPercent <= Self.exhaustedRemainingPercent }

    /// Remaining quota to show the user. A depleted window (≤1%, which ChatGPT
    /// already blocks) reads as 0 so the UI never implies spendable quota that
    /// isn't there.
    var displayRemainingPercent: Int { isDepleted ? 0 : remainingPercent }

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

    init(value: Date) {
        self.value = value
    }

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

struct AutoResumeSessionStatus: Decodable {
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
    let detail: String?
    let bankedResetCount: Int?
    let sessionResume: SessionResumeHint?
}

enum AIProvider: String, CaseIterable, Identifiable, Decodable {
    case openAI = "open_ai"
    case claude
    case cursor
    case grok

    var id: String { rawValue }

    var name: String {
        switch self {
        case .openAI: "OpenAI / Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .grok: "Grok Build"
        }
    }

    var compactName: String {
        switch self {
        case .openAI: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .grok: "Grok"
        }
    }

    var icon: String {
        switch self {
        case .openAI: "sparkles"
        case .claude: "brain.head.profile"
        case .cursor: "cursorarrow"
        case .grok: "bolt.fill"
        }
    }
}
