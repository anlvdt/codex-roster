import Foundation

enum NotchQuotaVerification: Equatable {
    case verified
    case cached
    case unverified
    /// Last successful numbers kept, but the poll is older than the freshness window.
    case stale(ageSeconds: Int)

    func caption(in language: AppLanguage) -> String? {
        switch self {
        case .verified:
            return nil
        case .cached:
            return language == .vietnamese ? "Cache · chưa xác minh" : "Cached · unverified"
        case .unverified:
            return language == .vietnamese ? "Chưa xác minh" : "Unverified"
        case .stale(let age):
            let minutes = max(1, age / 60)
            return language == .vietnamese
                ? "Stale · \(minutes)p trước"
                : "Stale · \(minutes)m ago"
        }
    }

    /// Dense notch-ear label (avoid clipping the 126pt wing).
    func compactCaption(in language: AppLanguage) -> String? {
        switch self {
        case .verified:
            return nil
        case .cached:
            return language == .vietnamese ? "cache" : "cache"
        case .unverified:
            return "?"
        case .stale:
            return "stale"
        }
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

/// Only the selected provider supplies compact-notch telemetry, including no-data states.
struct NotchQuotaSnapshot {
    let providerName: String
    let fivePercent: Int?
    let weekPercent: Int?
    /// Short label for the primary window: 5H on Plus/Pro, 1M on Free/Go.
    let primaryLabel: String
    /// False for Free/Go plans, which have no weekly limit.
    let showsWeekly: Bool
    let fiveResetDate: Date?
    let weeklyResetDate: Date?
    let bankedCount: Int
    let planLabel: String?
    let displayName: String?
    let verification: NotchQuotaVerification
    let fetchedAt: Date?

    /// Treat usage older than this as stale for the notch badge.
    static let staleAfterSeconds: TimeInterval = 10 * 60

    init(codex account: SavedAccount?) {
        providerName = "Codex"
        fivePercent = account?.usage?.fiveHour?.displayRemainingPercent
        weekPercent = account?.usage?.weekly?.displayRemainingPercent
        primaryLabel = account?.usage?.primaryWindowLabel ?? "5H"
        showsWeekly = account?.usage?.showsWeeklyWindow ?? true
        fiveResetDate = account?.usage?.fiveHour?.resetAt.value
        weeklyResetDate = account?.usage?.weekly?.resetAt.value
        bankedCount = account?.bankedResetCount ?? 0
        planLabel = account?.planLabel
        displayName = account?.displayName
        fetchedAt = account?.usage?.fetchedAt?.value
        if account?.usage == nil {
            verification = .unverified
        } else if let fetchedAt,
                  Date().timeIntervalSince(fetchedAt) > Self.staleAfterSeconds {
            verification = .stale(ageSeconds: Int(Date().timeIntervalSince(fetchedAt)))
        } else if account?.usageError == nil {
            verification = .verified
        } else {
            verification = .cached
        }
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
