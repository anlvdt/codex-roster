import Foundation

/// A second live agent reduced to its 5-hour reading. Shown only while both
/// Desktop apps are running; the focused agent keeps its full telemetry.
struct NotchCompanionQuota: Equatable {
    let screen: NotchScreen
    let shortName: String
    let fivePercent: Int?
    let fiveResetDate: Date?
    let planLabel: String?
    let displayName: String?

    init?(codex account: SavedAccount?) {
        guard let account else { return nil }
        screen = .codex
        shortName = "Codex"
        fivePercent = account.usage?.fiveHour?.displayRemainingPercent
        fiveResetDate = account.usage?.fiveHour?.resetAt.value
        planLabel = account.planLabel
        displayName = account.displayName
    }

    init?(claude account: ProviderAccount?) {
        guard let account else { return nil }
        screen = .claude
        shortName = "Claude"
        fivePercent = account.window("five_hour")?.remainingPercent
        fiveResetDate = account.window("five_hour")?.resetAt?.value
        planLabel = account.planLabel
        displayName = account.displayName
    }
}

/// Only the selected provider supplies compact-notch telemetry, including no-data states.
struct NotchQuotaSnapshot {
    let providerName: String
    let fivePercent: Int?
    let weekPercent: Int?
    let fiveResetDate: Date?
    let weeklyResetDate: Date?
    let bankedCount: Int
    let planLabel: String?
    let displayName: String?

    init(codex account: SavedAccount?) {
        providerName = "Codex"
        fivePercent = account?.usage?.fiveHour?.displayRemainingPercent
        weekPercent = account?.usage?.weekly?.displayRemainingPercent
        fiveResetDate = account?.usage?.fiveHour?.resetAt.value
        weeklyResetDate = account?.usage?.weekly?.resetAt.value
        bankedCount = account?.bankedResetCount ?? 0
        planLabel = account?.planLabel
        displayName = account?.displayName
    }

    init(claude account: ProviderAccount?) {
        providerName = "Claude Code"
        fivePercent = account?.window("five_hour")?.remainingPercent
        weekPercent = account?.window("seven_day")?.remainingPercent
        fiveResetDate = account?.window("five_hour")?.resetAt?.value
        weeklyResetDate = account?.window("seven_day")?.resetAt?.value
        bankedCount = 0
        planLabel = account?.planLabel
        displayName = account?.displayName
    }
}

/// Monotonic cooldown for passive UI refreshes. Explicit refresh remains immediate.
struct PassiveRefreshGate {
    private var lastRequest: TimeInterval?
    let interval: TimeInterval

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func request(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if let lastRequest, now >= lastRequest, now - lastRequest < interval { return false }
        lastRequest = now
        return true
    }
}
