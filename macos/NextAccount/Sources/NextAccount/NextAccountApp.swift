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

/// The single most useful thing the user can do right now. Derived from
/// `AccountTriage` buckets so Ops/notch never recommend contradictory actions.
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

    /// Ops drops the banner entirely when nothing needs the user.
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
                TokenBreakdownMetric(title: language.text("Suy luận", "Reasoning"), tokens: summary.reasoningOutputTokens)
            }

            HStack(spacing: 6) {
                Text(language.text("Cache hit", "Cache hit"))
                Text("\(summary.cacheHitPercent)%")
                    .fontWeight(.semibold)
                Text("·")
                    .foregroundStyle(.secondary)
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
                        Text("·").foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
    guard language == .vietnamese else {
        return description
    }
    switch description {
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
        return description
    }
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
                Label(language.text("Dự báo reset OpenAI", "OpenAI reset outlook"), systemImage: "antenna.radiowaves.left.and.right")
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
                let status = ResetOutlookPresentation.headline(outlook, language: language.language)
                let statusTint: Color = {
                    let kind = outlook.signalKind ?? ""
                    if kind.hasPrefix("confirmed") || isConfirmedReset { return .green }
                    if kind.hasPrefix("scheduled") { return .orange }
                    return .secondary
                }()

                // Match codex-resets.com: status + schedule, not forecast %.
                HStack(alignment: .top, spacing: 12) {
                    ResetOutlookMetric(
                        title: language.text("Trạng thái", "Status"),
                        value: status,
                        tint: statusTint
                    )
                    if let scheduledResetAt = outlook.nextResetAt {
                        ResetOutlookMetric(
                            title: language.text("Reset dự kiến", "Expected reset"),
                            value: formattedVietnamResetDate(scheduledResetAt, language: language.language),
                            tint: .orange
                        )
                    }
                    ResetOutlookMetric(
                        title: language.text("Reset gần nhất", "Latest reset"),
                        value: formattedResetDate(outlook.lastResetAt, language: language.language),
                        tint: .secondary
                    )
                    if !outlook.windowLabel.isEmpty {
                        ResetOutlookMetric(
                            title: language.text("Giờ thường reset", "Reset window"),
                            value: formatResetWindow(outlook, language: language.language),
                            tint: .secondary
                        )
                    }
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusTint == .secondary ? Color.accentColor : statusTint)
                        .frame(width: 8, height: 8)
                    Text(language.text(
                        "Dữ liệu từ Codex Resets (codex-resets.com)",
                        "Data from Codex Resets (codex-resets.com)"
                    ))
                    if isConfirmedReset {
                        Text("·").foregroundStyle(.secondary)
                        Text(language.text("Đã xác nhận", "Confirmed"))
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                    }

                    Spacer(minLength: 8)

                    Button(language.text("Chi tiết", "Details")) {
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
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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
                            detail: language.text("API phụ: timeline / juice / forecast (không hiện % 24h/48h trên notch hay Operations; UI chính lấy lịch từ codex-resets.com).", "Secondary API: timeline / juice / forecast (% 24h/48h not shown on notch or Operations; primary schedule comes from codex-resets.com)."),
                            badge: "Public API · optional detail",
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
