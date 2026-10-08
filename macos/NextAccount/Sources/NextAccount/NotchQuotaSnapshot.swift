import Foundation

enum NotchQuotaVerification: Equatable {
    case verified
    case cached
    case unverified

    func caption(in language: AppLanguage) -> String? {
        switch self {
        case .verified: nil
        case .cached: language == .vietnamese ? "Cache · chưa xác minh" : "Cached · unverified"
        case .unverified: language == .vietnamese ? "Chưa xác minh" : "Unverified"
        }
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
    let verification: NotchQuotaVerification

    init(codex account: SavedAccount?) {
        providerName = "Codex"
        fivePercent = account?.usage?.fiveHour?.displayRemainingPercent
        weekPercent = account?.usage?.weekly?.displayRemainingPercent
        fiveResetDate = account?.usage?.fiveHour?.resetAt.value
        weeklyResetDate = account?.usage?.weekly?.resetAt.value
        bankedCount = account?.bankedResetCount ?? 0
        planLabel = account?.planLabel
        displayName = account?.displayName
        verification = account?.usage == nil ? .unverified : (account?.usageError == nil ? .verified : .cached)
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
