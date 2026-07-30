import AppKit
import Foundation
import ServiceManagement

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
    @Published private(set) var isLoadingTokenUsage = false
    @Published private(set) var isLoadingResetOutlook = false
    @Published private(set) var isLoadingOpenAIStatus = false
    @Published private(set) var isRefreshingQuotaInBackground = false
    @Published private(set) var lastQuotaRefreshAt: Date?
    @Published var errorMessage: String?

    private let cli = AccountHubCLI()
    private let archivedAccountsMigrationKeys = ["codexRoster.archivedAccountIDs", "accountHub.archivedAccountIDs"]
    private var legacyArchivedAccountIDs: Set<UUID>
    private let autoSwitchWhenExhaustedKey = "codexRoster.autoSwitchWhenExhausted"
    private let activeQuotaPollInterval: Duration = .seconds(60)
    private var autoSwitchTask: Task<Void, Never>?
    private var quotaRefreshTask: Task<Void, Never>?
    private var autoSwitchAllExhaustedNotified = false
    private var isInteractiveLoginInProgress = false

    init() {
        let defaults = UserDefaults.standard
        legacyArchivedAccountIDs = Set(
            archivedAccountsMigrationKeys
                .flatMap { defaults.stringArray(forKey: $0) ?? [] }
                .compactMap(UUID.init(uuidString:))
        )
        autoSwitchWhenExhausted = defaults.bool(forKey: autoSwitchWhenExhaustedKey)
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    var hasRunningCodexProcesses: Bool {
        !(status?.processWarnings.isEmpty ?? true)
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
        run {
            try await self.load()
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

    func activate(_ account: SavedAccount, force: Bool = false) {
        run {
            if force {
                try await ChatGPTDesktop.prepareForAccountSwitch()
            }
            var arguments = ["activate", account.id.uuidString, "--json"]
            if force { arguments.append("--force") }
            _ = try await self.cli.data(arguments: arguments)
            try await self.load()
            try await ChatGPTDesktop.launch()
        }
    }

    func delete(_ account: SavedAccount) {
        run {
            _ = try await self.cli.data(arguments: ["delete", account.id.uuidString, "--json"])
            try await self.load()
        }
    }

    func refreshUsage() {
        run {
            for account in self.accounts {
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
        autoSwitchWhenExhausted = enabled
        UserDefaults.standard.set(enabled, forKey: autoSwitchWhenExhaustedKey)
        autoSwitchState = nil
        autoSwitchAllExhaustedNotified = false
        if enabled {
            Task { await checkAutoSwitchWhenExhausted() }
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
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func startQuotaMonitoring() {
        guard quotaRefreshTask == nil else { return }
        quotaRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshActiveQuotaInBackground()
                try? await Task.sleep(for: self?.activeQuotaPollInterval ?? .seconds(60))
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
        let (loadedStatus, loadedAccounts, loadedSettings) = try await (status, accounts, settings)
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
    }

    private func checkAutoSwitchWhenExhausted() async {
        guard autoSwitchWhenExhausted, !isWorking, !isCheckingAutoSwitch else { return }
        isCheckingAutoSwitch = true
        isWorking = true
        defer {
            isCheckingAutoSwitch = false
            isWorking = false
        }
        guard !isInteractiveLoginInProgress else {
            autoSwitchState = .waitingForLogin
            return
        }
        do {
            _ = try await cli.data(arguments: ["usage", "--json"])
            try await load()
            guard let active = accounts.first(where: \.isActive),
                  active.isExhaustedForSwitch else {
                autoSwitchAllExhaustedNotified = false
                autoSwitchState = nil
                return
            }

            var refreshedCandidateIDs = Set<UUID>()
            for account in accounts where account.id != active.id && !isArchived(account) && !account.requiresLogin {
                if (try? await cli.data(arguments: ["usage", account.id.uuidString, "--json"])) != nil {
                    refreshedCandidateIDs.insert(account.id)
                }
            }
            try await load()

            guard let replacement = accounts
                .filter({ $0.id != active.id && !isArchived($0) && !$0.requiresLogin })
                .filter({ refreshedCandidateIDs.contains($0.id) && $0.isUsableForSwitch })
                .sorted(by: {
                    if $0.switchQuotaScore != $1.switchQuotaScore {
                        return $0.switchQuotaScore > $1.switchQuotaScore
                    }
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                })
                .first else {
                if !autoSwitchAllExhaustedNotified {
                    autoSwitchState = .allAccountsExhausted
                    autoSwitchAllExhaustedNotified = true
                }
                return
            }

            try await ChatGPTDesktop.prepareForAccountSwitch()
            _ = try await cli.data(arguments: ["activate", replacement.id.uuidString, "--force", "--json"])
            try await load()
            try await ChatGPTDesktop.launch()
            autoSwitchState = .switched(replacement.displayName)
            autoSwitchAllExhaustedNotified = false
        } catch {
            autoSwitchState = .checkFailed
        }
    }

    private func refreshActiveQuotaInBackground(allowWhileWorking: Bool = false) async {
        guard autoStartUsageWindows,
              (allowWhileWorking || !isWorking),
              !isCheckingAutoSwitch,
              !isRefreshingQuotaInBackground,
              !isInteractiveLoginInProgress,
              let activeAccount = accounts.first(where: { $0.isActive && !isArchived($0) }) else {
            return
        }
        isRefreshingQuotaInBackground = true
        defer { isRefreshingQuotaInBackground = false }
        do {
            _ = try await cli.data(arguments: ["usage", activeAccount.id.uuidString, "--json"])
            try await load()
            lastQuotaRefreshAt = .now
        } catch {
            // The last verified quota stays visible; manual refresh can surface the error.
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

enum AutoSwitchState: Equatable {
    case waitingForLogin
    case allAccountsExhausted
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

        try process.run()
        if let standardInput, let input {
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            try? input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(detail?.isEmpty == false ? detail! : "The Codex Roster command failed.")
        }
        return outputData
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
    private static let bundleIdentifier = "com.openai.codex"

    static func prepareForAccountSwitch() async throws {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for app in runningApps {
            app.terminate()
        }
        try? await Task.sleep(for: .milliseconds(900))
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.forceTerminate()
        }
        try? await Task.sleep(for: .milliseconds(350))
    }

    static func launch() async throws {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
                .map(URL.init(fileURLWithPath:))
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        guard let appURL else {
            throw CLIError("Không tìm thấy ChatGPT hoặc Codex Desktop trên máy này.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
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
}

struct AccountIdentity: Decodable {
    let email: String
}

struct RunningProcess: Decodable {
    let pid: Int
}

struct AccountListOutput: Decodable {
    let accounts: [SavedAccount]
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
        quotaWindowsForSwitch.map(\.remainingPercent).min() ?? 0
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
