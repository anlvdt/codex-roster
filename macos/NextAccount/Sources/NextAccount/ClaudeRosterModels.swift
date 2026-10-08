import Foundation

/// Decoders for the `codex-roster providers …` JSON surface used by the
/// Claude Code tab. Field names rely on `.convertFromSnakeCase` (the shared
/// `AccountHubCLI.decode` sets it); `RustDate` decodes Rust `OffsetDateTime`.

struct ProviderListOutput: Decodable {
    let accounts: [ProviderAccount]
}

struct ProviderAccount: Identifiable, Decodable {
    let id: UUID
    let provider: AIProvider
    let email: String
    let subject: String?
    let name: String?
    let customLabel: String?
    let planLabel: String?
    let isActive: Bool
    let updatedAt: RustDate
    let lastActivatedAt: RustDate?
    let usage: ProviderUsage?
    let usageError: String?
    let canActivate: Bool
    let activationBlockReason: String?

    var displayName: String {
        if let customLabel, !customLabel.isEmpty { return customLabel }
        if let name, !name.isEmpty { return name }
        return email
    }

    /// Claude reports personal orgs as `"<email>'s Organization"` — when the
    /// email is already rendered next to the name, strip the redundant prefix
    /// so the org name fits instead of truncating to "…'s Organ…".
    var shortDisplayName: String {
        let prefix = email + "'s "
        let name = displayName
        guard name.hasPrefix(prefix), name.count > prefix.count else { return name }
        return String(name.dropFirst(prefix.count))
    }

    /// Mirrors `LOGIN_REQUIRED_ERROR_PREFIX` in `src/provider_store.rs`.
    var requiresLogin: Bool {
        usageError?.hasPrefix("login_required") == true
    }

    var requiresResave: Bool { !canActivate }

    var hasFreshUsage: Bool {
        guard usageError == nil, let usage, usage.status == "ok" else { return false }
        let now = Date()
        let maximumAge: TimeInterval = usage.detail?.hasPrefix("Claude Code statusline") == true ? 2 * 60 : 15 * 60
        guard now.timeIntervalSince(usage.fetchedAt.value) < maximumAge,
              usage.fetchedAt.value <= now.addingTimeInterval(60) else { return false }
        return !usage.windows.contains { window in
            guard let reset = window.resetAt?.value else { return false }
            return usage.fetchedAt.value < reset && reset <= now
        }
    }

    /// Conservative utilization across all Claude Code quota windows
    /// (mirrors `claude_binding_utilization` in
    /// `src/app/provider_auto_switch.rs`). `nil` when neither exists.
    var bindingUtilization: Int? {
        let used = (usage?.windows ?? [])
            .filter { $0.key == "five_hour" || $0.key == "seven_day" || $0.key.hasPrefix("seven_day_") }
            .compactMap(\.usedPercent)
        return used.max()
    }

    func window(_ key: String) -> ProviderUsageWindow? {
        usage?.windows.first { $0.key == key }
    }

    var extraWindows: [ProviderUsageWindow] {
        (usage?.windows ?? []).filter {
            $0.key != "five_hour" && $0.key != "seven_day"
        }
    }
}

struct ProviderUsage: Decodable {
    let fetchedAt: RustDate
    let status: String
    let headlineWindow: String?
    let windows: [ProviderUsageWindow]
    let detail: String?
}

struct ProviderUsageWindow: Identifiable, Decodable {
    let key: String
    let label: String
    let usedPercent: Int?
    let remainingPercent: Int?
    let resetAt: RustDate?
    let used: Double?
    let limit: Double?
    let unit: String?
    let expectedUsedPercent: Int?
    let aheadOfPace: Bool?
    let projectedExhaustionAt: RustDate?
    let willLastToReset: Bool?

    var id: String { key }

    func resetDescription(in language: AppLanguage) -> String? {
        guard let resetAt else { return nil }
        guard resetAt.value > Date() else {
            return language == .vietnamese ? "đang chờ đặt lại" : "reset pending"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = language.locale
        let relative = formatter.localizedString(for: resetAt.value, relativeTo: Date())
        let clock = DateFormatter()
        clock.locale = language.locale
        clock.timeZone = .current
        clock.dateFormat = "HH:mm dd/MM"
        let exact = clock.string(from: resetAt.value)
        return language == .vietnamese
            ? "đặt lại \(relative) · \(exact)"
            : "resets \(relative) · \(exact)"
    }
}

struct ProviderAutoSwitchOutput: Decodable {
    let provider: AIProvider
    let enabled: Bool
    let status: String
    let trigger: String?
    let activeAccountId: UUID?
    let candidateAccountId: UUID?
    let candidateDisplayName: String?
    let detail: String?
    let thresholdPercent: Int
    let hysteresisPercent: Int
    let cooldownSeconds: Int
    let strategy: String
}

struct ProviderSaveOutput: Decodable {
    let account: ProviderAccount
    let action: String
}

struct ProviderActivateOutput: Decodable {
    let account: ProviderAccount
    let previousAccountId: UUID?
    let requiresRelaunch: Bool
    let warnings: [String]?
}

struct ClaudeDesktopLoginStatus: Decodable {
    let saved: Bool
    let liveAccountMatches: Bool
}
