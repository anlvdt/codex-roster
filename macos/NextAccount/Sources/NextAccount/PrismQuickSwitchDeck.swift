import SwiftUI

/// Restored Approved Panoramic Notch Console for Codex Roster (920pt × 425pt).
/// Symmetrically frames the MacBook camera notch at the top and expands into the
/// 2-column account switchboard with generous typography and buttons.
struct PrismQuickSwitchDeck: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var updater: GitHubUpdater
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("codex_roster_notch_pinned_live") private var isPinnedLive = false
    @AppStorage(NotchRosterLayout.rosterExpandedKey) private var isRosterExpanded = false

    var openSettings: () -> Void = {}
    var openAddAccountFlow: () -> Void = {}
    /// Must receive the clicked row's account ID — never pick "first requiresLogin".
    var openReloginFlow: (UUID) -> Void = { _ in }
    var openBackupFlow: (BackupOperation) -> Void = { _ in }
    var openEditAccount: (SavedAccount) -> Void = { _ in }
    var openAbout: () -> Void = {}

    @State private var rosterFilter: RosterListFilter = .all
    @State private var rosterSearch: String = ""
    @State private var justSwitchedID: UUID? = nil

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !$0.archived }
    }

    private var filteredAccounts: [SavedAccount] {
        let matching = store.accounts.filter { account in
            let matchesFilter = rosterFilter.matches(account)
            let matchesSearch: Bool = {
                guard !rosterSearch.isEmpty else { return true }
                return account.displayName.localizedCaseInsensitiveContains(rosterSearch)
                    || account.email.localizedCaseInsensitiveContains(rosterSearch)
            }()
            return matchesFilter && matchesSearch
        }
        return store.sortedAccounts(matching)
    }

    private var rosterGridHeight: CGFloat {
        NotchRosterLayout.rosterGridHeight(
            accountCount: filteredAccounts.count,
            expanded: isRosterExpanded
        )
    }

    private var deckHeight: CGFloat {
        NotchRosterLayout.deckHeight(
            accountCount: filteredAccounts.count,
            expanded: isRosterExpanded
        )
    }

    private var switchableShortcutMap: [UUID: Int] {
        var map: [UUID: Int] = [:]
        var nextShortcut = 1
        for account in filteredAccounts {
            // Shortcuts only for accounts that can actually be switched to —
            // usable quota or a redeemable banked reset (not exhausted-only).
            let canSwitch = account.isUsableForSwitch || account.restingHasBankedReset
            if !account.isActive && canSwitch && !account.requiresLogin && !account.usageErrorBlocksActivation {
                if nextShortcut <= 6 {
                    map[account.id] = nextShortcut
                    nextShortcut += 1
                }
            }
        }
        return map
    }

    /// Auto-switch "Ready → X" candidates must be usable — not merely unblocked.
    private var readyCandidates: [SavedAccount] {
        store.sortedAccounts(store.accounts.filter { $0.triage == .ready })
    }

    private var nextActionCaption: String? {
        if let resume = store.sessionResumeCaption {
            return resume
        }
        return NextAction.resolve(in: store).compactCaption(language: language)
    }

    var body: some View {
        VStack(spacing: NotchRosterLayout.deckSectionSpacing) {
            // Upper Deck: Left Wing | Notch Clearance & Live Pin | Right Wing
            upperDeckFramingNotch

            nextActionCaptionRow

            // Lower Deck: Full-width 2-column account switchboard
            lowerSwitchboardDeck

            // Leftover deck budget (incl. hidden next-action) stays under the roster
            // so upper panels sit tight above "Danh bạ" and the card has bottom air.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchRosterLayout.deckHorizontalInset)
        .padding(.top, NotchRosterLayout.deckTopInset)
        .padding(.bottom, NotchRosterLayout.deckBottomInset)
        .frame(width: 920, height: deckHeight, alignment: .top)
        .animation(PrismTheme.snapSpring, value: isRosterExpanded)
        .animation(PrismTheme.snapSpring, value: filteredAccounts.count)
    }

    /// Compact “what to do next” line — omitted when all-clear so it does not
    /// open a dead mid-deck gap (height budget remains in `deckHeight` for fit).
    @ViewBuilder
    private var nextActionCaptionRow: some View {
        if let caption = nextActionCaption {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(PrismTheme.fontCaptionBold)
                    .foregroundStyle(PrismTheme.accent)
                Text(caption)
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(PrismTheme.textBright)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: NotchRosterLayout.nextActionCaptionHeight, alignment: .center)
            .accessibilityLabel(language.text("Việc nên làm tiếp theo", "Next action"))
            .accessibilityValue(caption)
        }
    }

    // MARK: - Upper Deck (Left Wing 340pt | Center 188pt | Right Wing 340pt)
    private var upperDeckFramingNotch: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left Ear Wing: Active Session Identity & Quotas
            upperLeftWing
                .frame(maxWidth: .infinity)

            // Center Notch Gap: Sits comfortably below the physical camera housing (170pt)
            upperCenterNotchGap
                .frame(width: 170)

            // Right Ear Wing: Radar, Telemetry & Automation
            upperRightWing
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Upper Left Wing (Active Identity & Quota Gauges)
    private var upperLeftWing: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Identity Row
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent).opacity(0.18))
                        .frame(width: 36, height: 36)

                    Image(systemName: (activeAccount?.aiProvider ?? .openAI).icon)
                        .font(PrismTheme.fontTitle)
                        .foregroundStyle(PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(activeAccount?.displayName ?? language.text("Chưa chọn phiên", "No session"))
                            .font(PrismTheme.fontHeadline)
                            .lineLimit(1)

                        if let plan = activeAccount?.planLabel, !plan.isEmpty {
                            Text(plan.uppercased())
                                .font(PrismTheme.fontChip)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.accent, opacity: 0.15)))
                                .foregroundStyle(PrismTheme.accent)
                        }

                        if let banked = activeAccount?.usage?.bankedResets?.availableCount, banked > 0 {
                            HStack(spacing: 2.5) {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(PrismTheme.fontChipIcon)
                                Text("+\(banked) banked")
                                    .font(PrismTheme.fontChip)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.warning)))
                            .foregroundStyle(PrismTheme.warning)
                            .help(language.text(
                                "\(banked) lượt reset dự phòng (banked reset) có sẵn trong Codex",
                                "\(banked) banked rate-limit resets available in Codex"
                            ))
                        }

                        if let active = activeAccount, active.hasLunaReserve {
                            let isLunaActive = store.isLunaReserveActive(for: active)
                            HStack(spacing: 2.5) {
                                Image(systemName: isLunaActive ? "moon.stars.fill" : "moon.fill")
                                    .font(PrismTheme.fontChipIcon)
                                Text(isLunaActive ? "Luna Active" : "Luna Reserve")
                                    .font(PrismTheme.fontChip)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.autoSwitch)))
                            .foregroundStyle(PrismTheme.autoSwitch)
                            .help(language.text(
                                isLunaActive ? "Codex đang chạy bằng Luna Reserve (gpt-5.6-luna)" : "Tài khoản có Luna Reserve sẵn sàng sử dụng",
                                isLunaActive ? "Codex is running on Luna Reserve (gpt-5.6-luna)" : "Luna Reserve is available for this account"
                            ))
                        }
                    }

                    HStack(spacing: 5) {
                        Text(activeAccount?.email ?? "—")
                            .font(PrismTheme.fontBody)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let email = activeAccount?.email, !email.isEmpty {
                            CopyEmailButton(email: email, iconSize: 12)
                        }
                    }
                }

                Spacer()

                if let active = activeAccount, active.hasLunaReserve && !store.isLunaReserveActive(for: active) {
                    Button {
                        PrismTheme.triggerHaptic()
                        store.enableLunaReserve(active)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.stars.fill")
                                .font(PrismTheme.fontCaptionBold)
                            Text(language.text("Bật Luna", "Enable Luna"))
                                .font(PrismTheme.fontBodyBold)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(
                            Capsule()
                                .fill(PrismTheme.chipFill(PrismTheme.autoSwitch))
                                .overlay(Capsule().strokeBorder(PrismTheme.chipStroke(PrismTheme.autoSwitch), lineWidth: 0.8))
                        )
                        .foregroundStyle(PrismTheme.autoSwitch)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(language.text(
                        "Kích hoạt Luna Reserve (gpt-5.6-luna) cho Codex",
                        "Activate Luna Reserve (gpt-5.6-luna) for Codex"
                    ))
                }

                // Sync button
                Button {
                    PrismTheme.triggerHaptic()
                    store.resyncChatGPTDesktop()
                } label: {
                    HStack(spacing: 4) {
                        if store.isWorking || store.isBusyForActions {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(PrismTheme.fontCaptionBold)
                        }
                        Text(language.text("Mở lại ChatGPT", "Relaunch ChatGPT"))
                            .font(PrismTheme.fontBodySemibold)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        Capsule()
                            .fill(PrismTheme.surfaceFill)
                            .overlay(Capsule().strokeBorder(PrismTheme.borderSoft, lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(language.text(
                    "Đóng và mở lại ChatGPT Desktop để đồng bộ phiên đang chạy",
                    "Quit and relaunch ChatGPT Desktop to resync the live session"
                ))
            }

            // Quotas: 5h & Weekly (+ monthly when credit_limit exists)
            HStack(spacing: 10) {
                // 5-Hour Window
                VStack(alignment: .leading, spacing: 4) {
                    let five = activeAccount?.usage?.fiveHour
                    let fivePercent = five?.displayRemainingPercent

                    HStack(alignment: .firstTextBaseline) {
                        Text(language.text("Cửa sổ 5h", "5h window"))
                            .font(PrismTheme.fontBody)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let fivePercent {
                            Text("\(fivePercent)%")
                                .font(PrismTheme.fontMetricLarge)
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                        }
                    }

                    PrismSegmentedBar(percent: fivePercent ?? 0, segments: 5, height: 6)

                    if let five {
                        Text(five.resetDescription(in: language.language))
                            .font(PrismTheme.fontCaptionRegular)
                            .foregroundStyle(
                                PrismTheme.resetProximityTint(window: five, kind: .fiveHour)
                            )
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(PrismTheme.surfaceQuiet))
                // Weekly Allowance
                VStack(alignment: .leading, spacing: 4) {
                    let week = activeAccount?.usage?.weekly
                    let weekPercent = week?.displayRemainingPercent

                    HStack(alignment: .firstTextBaseline) {
                        Text(language.text("Hạn mức tuần", "Weekly"))
                            .font(PrismTheme.fontBody)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let weekPercent {
                            Text("\(weekPercent)%")
                                .font(PrismTheme.fontMetricLarge)
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(PrismTheme.trackFill)
                            Capsule()
                                .fill(PrismTheme.quotaGradient(percent: weekPercent))
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(weekPercent ?? 0) / 100.0)))
                        }
                    }
                    .frame(height: 6)

                    if let week {
                        Text(week.resetDescription(in: language.language))
                            .font(PrismTheme.fontCaptionRegular)
                            .foregroundStyle(
                                PrismTheme.resetProximityTint(window: week, kind: .weekly)
                            )
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(PrismTheme.surfaceQuiet))

                if let monthPercent = activeAccount?.monthlyQuotaRemainingPercent {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(language.text("Hạn mức tháng", "Monthly"))
                                .font(PrismTheme.fontBody)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(monthPercent)%")
                                .font(PrismTheme.fontMetricLarge)
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: monthPercent))
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PrismTheme.trackFill)
                                Capsule()
                                    .fill(PrismTheme.quotaGradient(percent: monthPercent))
                                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(monthPercent) / 100.0)))
                            }
                        }
                        .frame(height: 6)

                        if let limit = activeAccount?.usage?.credits?.creditLimit {
                            if let reset = limit.resetDescription(in: language.language) {
                                Text(reset)
                                    .font(PrismTheme.fontCaptionRegular)
                                    .foregroundStyle(
                                        PrismTheme.resetProximityTint(
                                            resetAt: limit.resetsAt?.value,
                                            kind: .monthly
                                        )
                                    )
                                    .lineLimit(1)
                            }
                            Text(limit.displayText)
                                .font(PrismTheme.fontCaptionRegular)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(language.text("Hạn mức tháng từ API", "Monthly cap from API"))
                                .font(PrismTheme.fontCaptionRegular)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(PrismTheme.surfaceQuiet))
                } else if let active = activeAccount, active.showsFreePlanChip {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text("Gói Free", "Free plan"))
                            .font(PrismTheme.fontBody)
                            .foregroundStyle(.secondary)
                        Text(language.text(
                            "Không có % tháng từ API",
                            "No monthly % from API"
                        ))
                            .font(PrismTheme.fontCaptionRegular)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let balance = active.creditsBalanceDisplay {
                            Text(language.text("Tín dụng: \(balance)", "Credits: \(balance)"))
                                .font(PrismTheme.fontCaption)
                                .foregroundStyle(PrismTheme.accent)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(PrismTheme.surfaceQuiet))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PrismTheme.surfacePanel)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PrismTheme.surfaceFill, lineWidth: 0.8))
        )
    }

    // MARK: - Upper Center Notch Gap (Padded safely below Camera Notch)
    private var upperCenterNotchGap: some View {
        VStack(spacing: 10) {
            // Service health — one capsule under the camera
            HStack(spacing: 6) {
                let statusIndicator = store.openAIStatus?.indicator ?? "none"
                let isOperational = statusIndicator == "none"
                Circle()
                    .fill(isOperational ? PrismTheme.emerald : PrismTheme.ruby)
                    .frame(width: 7, height: 7)
                Text(isOperational
                      ? language.text("OpenAI ổn", "OpenAI OK")
                      : language.text("Sự cố OpenAI", "OpenAI issue"))
                    .font(PrismTheme.fontBodyCompact)
                    .foregroundStyle(isOperational ? PrismTheme.emerald : PrismTheme.ruby)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(PrismTheme.surfaceMuted))

            // Auto-switch control (Settings is secondary; notch is primary)
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.shield.fill")
                        .font(PrismTheme.fontBodyCompactBold)
                        .foregroundStyle(store.autoSwitchWhenExhausted ? PrismTheme.autoSwitch : .secondary)
                    Text(language.text("Tự chuyển", "Auto-switch"))
                        .font(PrismTheme.fontBodyCompact)
                        .foregroundStyle(store.autoSwitchWhenExhausted ? PrismTheme.autoSwitch : .secondary)
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(
                        get: { store.autoSwitchWhenExhausted },
                        set: { store.setAutoSwitchWhenExhausted($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }

                Text(autoSwitchStatusCaption)
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PrismTheme.surfaceDim)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                store.autoSwitchWhenExhausted
                                    ? PrismTheme.violet.opacity(0.35)
                                    : PrismTheme.surfaceFill,
                                lineWidth: 0.8
                            )
                    )
            )
        }
        .padding(.top, topNotchClearance)
        // Intrinsic height only — do not absorb leftover deck space here
        // (that opened the oversized gap above "Danh bạ").
        .fixedSize(horizontal: false, vertical: true)
    }

    private var autoSwitchStatusCaption: String {
        if !store.autoSwitchWhenExhausted {
            return language.text("Tắt — chỉ chuyển tay", "Off — manual switch only")
        }
        if store.isCheckingAutoSwitch {
            return language.text("Đang kiểm tra…", "Checking…")
        }
        switch store.autoSwitchState {
        case .some(.allAccountsExhausted):
            return language.text("Tạm dừng — hết quota", "Paused — all exhausted")
        case .some(.bankedResetAvailable(let account, let count, _)):
            return language.text("Banked ×\(count) · \(account)", "Banked ×\(count) · \(account)")
        case .some(.switched(let name)):
            return language.text("Đã chuyển → \(name)", "Switched → \(name)")
        case .some(.switchingAccount), .some(.closingDesktop), .some(.relaunchingDesktop):
            return language.text("Đang chuyển…", "Switching…")
        case .some(.waitingForProcesses):
            return language.text("Đóng ChatGPT thủ công", "Quit ChatGPT manually")
        case .some(.generationInProgress):
            return language.text("Chờ phiên yên…", "Waiting for idle…")
        case .some(.waitingForLogin):
            return language.text("Tạm dừng khi đăng nhập", "Paused while signing in")
        case .some(.desktopRelaunchFailed), .some(.checkFailed):
            return language.text("Lỗi — thử lại", "Failed — retry")
        case .none:
            if let next = readyCandidates.first {
                return language.text("Sẵn sàng → \(next.displayName)", "Ready → \(next.displayName)")
            }
            return language.text("Chưa có ứng viên usable", "No usable candidate")
        }
    }

    private var topNotchClearance: CGFloat {
        let maxInset = NSScreen.screens.map(\.safeAreaInsets.top).max() ?? 0
        return max(maxInset + 16, 50)
    }

    // MARK: - Upper Right Wing (Telemetry — Tibo lives once in the center strip)
    private var upperRightWing: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(language.text("Tiêu thụ", "Usage"), systemImage: "chart.line.uptrend.xyaxis")
                    .font(PrismTheme.fontSubheadline)
                Spacer()
                if let outlook = store.resetOutlook {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(PrismTheme.fontCaptionRegular)
                            .foregroundStyle(.secondary)
                        Text("24h \(outlook.chance24Hours)%")
                            .font(PrismTheme.fontChip)
                            .foregroundStyle(outlook.chance24Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                        Text("·").foregroundStyle(.tertiary)
                        Text("48h \(outlook.chance48Hours)%")
                            .font(PrismTheme.fontChip)
                            .foregroundStyle(outlook.chance48Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                    }
                    .help(outlook.windowLabel)
                }
                Button {
                    PrismTheme.triggerHaptic()
                    // Longevity-safe: AT-only usage for every saved account
                    // (skips deferred/login rows; never prove_saved_session_refresh).
                    store.refreshUsage(scope: .allSaved)
                    store.refreshTokenUsage(silently: true)
                    store.refreshResetOutlook(silently: true)
                    store.refreshOpenAIStatus(silently: true)
                } label: {
                    Group {
                        if store.isBusyForActions {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(PrismTheme.fontBodyCompact)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(PrismTheme.surfaceSoft))
                }
                .buttonStyle(.plain)
                .disabled(store.isBusyForActions || store.accounts.isEmpty)
                .help(language.text(
                    "Làm mới tất cả quota tài khoản (chỉ access token)",
                    "Refresh all account quotas (access token only)"
                ))
                .accessibilityLabel(language.text("Làm mới tất cả", "Refresh all"))
            }

            if let summary = store.tokenUsage {
                HStack(spacing: 8) {
                    telemetryPill(
                        title: language.text("Hôm nay", "Today"),
                        value: formatTokenMetric(summary.today, in: language.language),
                        accent: summary.todayCostUsd.flatMap { $0 > 0 ? formatUsdCost($0, in: language.language) : nil }
                    )
                    telemetryPill(
                        title: language.text("7 ngày", "7 days"),
                        value: formatTokenMetric(summary.last7Days, in: language.language),
                        accent: summary.last7DaysCostUsd.flatMap { $0 > 0 ? formatUsdCost($0, in: language.language) : nil }
                    )
                    if let sub = summary.subagentSessions, sub > 0 {
                        telemetryPill(
                            title: "Sub",
                            value: "\(sub)",
                            accent: nil
                        )
                    }
                    if let vibe = store.status?.vibeUsage {
                        telemetryPill(
                            title: "Vibe",
                            value: String(format: "$%.2f", vibe.estimatedCostUsd),
                            accent: nil
                        )
                    }
                }
            } else {
                Text(language.text("Chưa có dữ liệu token", "No token data yet"))
                    .font(PrismTheme.fontBodyCompactMedium)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }

            // Fills the short-wing gap under Usage: repo + live app version.
            usageWingFooter
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PrismTheme.surfacePanel)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PrismTheme.surfaceFill, lineWidth: 0.8))
        )
    }

    private var githubRepoURL: URL {
        URL(string: "https://github.com/anlvdt/codex-roster")!
    }

    private var usageWingFooter: some View {
        HStack(spacing: 8) {
            Button {
                PrismTheme.triggerHaptic()
                openURL(githubRepoURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(PrismTheme.fontMicro)
                    Text("anlvdt/codex-roster")
                        .font(PrismTheme.fontCaption)
                        .lineLimit(1)
                }
                .foregroundStyle(PrismTheme.accent)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(githubRepoURL.absoluteString)
            .accessibilityLabel(language.text("Mở repo GitHub", "Open GitHub repository"))

            Spacer(minLength: 4)

            Text("v\(AppInfo.shortVersion)")
                .font(PrismTheme.fontMono)
                .foregroundStyle(PrismTheme.textSecondary)
                .help(language.text(
                    "Phiên bản \(AppInfo.shortVersion)",
                    "Version \(AppInfo.shortVersion)"
                ))
        }
        .padding(.top, 2)
    }

    private func telemetryPill(title: String, value: String, accent: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(PrismTheme.fontChipIcon)
                .foregroundStyle(.secondary)
            Text(value)
                .font(PrismTheme.fontMetric)
                .lineLimit(1)
            if let accent {
                Text(accent)
                    .font(PrismTheme.fontChip)
                    .foregroundStyle(PrismTheme.emerald)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PrismTheme.surfacePanel))
    }

    // MARK: - Lower Deck: 2-Column Full-Width Account Switchboard
    private var lowerSwitchboardDeck: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(language.text("Danh bạ", "Roster"))
                    .font(PrismTheme.fontSection)

                Text("\(filteredAccounts.count)/\(store.accounts.filter { !$0.archived }.count)")
                    .font(PrismTheme.fontMono)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(PrismTheme.surfaceSoft))

                Spacer(minLength: 6)

                filterTab(label: language.text("Tất cả", "All"), filter: .all)
                filterTab(label: language.text("Sẵn sàng", "Ready"), filter: .triage(.ready))
                if store.accounts.contains(where: { $0.hasDeferredAccessTokenRefresh }) {
                    filterTab(label: language.text("Chưa XM", "Unverified"), filter: .deferredUnverified)
                }
                if store.accounts.contains(where: { $0.triage == .needsAction }) {
                    filterTab(label: language.text("Login", "Action"), filter: .triage(.needsAction))
                }

                toolbarIconButton(
                    systemName: isRosterExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    active: isRosterExpanded,
                    help: language.text(
                        "Xem tất cả account không cần scroll",
                        "See every account without scrolling"
                    )
                ) {
                    withAnimation(PrismTheme.snapSpring) {
                        isRosterExpanded.toggle()
                    }
                }

                toolbarIconButton(
                    systemName: isPinnedLive ? "pin.fill" : "pin",
                    active: isPinnedLive,
                    help: language.text(
                        "Ghim mở liên tục (⌘P)",
                        "Pin open continuously (⌘P)"
                    )
                ) {
                    withAnimation(PrismTheme.snapSpring) {
                        isPinnedLive.toggle()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command])

                toolbarIconButton(
                    systemName: "plus",
                    active: false,
                    help: language.text("Thêm tài khoản (⌘⇧N)", "Add account (⌘⇧N)")
                ) {
                    openAddAccountFlow()
                }

                toolbarIconButton(
                    systemName: "arrow.clockwise",
                    active: false,
                    help: language.text("Làm mới tất cả", "Refresh all"),
                    busy: store.isBusyForActions,
                    disabled: store.isBusyForActions || store.accounts.isEmpty
                ) {
                    // Longevity-safe: AT-only usage for every saved account.
                    store.refreshUsage(scope: .allSaved)
                }

                Menu {
                    Button {
                        store.refreshUsage(scope: .allSaved)
                    } label: {
                        Label(
                            language.text("Làm mới tất cả", "Refresh all"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(store.isBusyForActions || store.accounts.isEmpty)
                    Divider()
                    Button { openSettings() } label: {
                        Label(language.text("Cài đặt…", "Settings…"), systemImage: "gearshape")
                    }
                    Button { openBackupFlow(.export) } label: {
                        Label(language.text("Sao lưu", "Export backup"), systemImage: "square.and.arrow.up")
                    }
                    Button { openBackupFlow(.import) } label: {
                        Label(language.text("Phục hồi", "Import backup"), systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button { updater.checkForUpdates(currentVersion: AppInfo.shortVersion) } label: {
                        Label(language.text("Kiểm tra cập nhật", "Check for updates"), systemImage: "arrow.down.app")
                    }
                    Button { openAbout() } label: {
                        Label(language.text("Giới thiệu", "About"), systemImage: "info.circle")
                    }
                    Divider()
                    Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                        Label(language.text("Thoát", "Quit"), systemImage: "power")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(PrismTheme.fontBodyCompactBold)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(PrismTheme.surfaceFill))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .pointingHandCursor()
            }

            ScrollView {
                let columns = [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ]

                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(filteredAccounts) { account in
                        PrismCompactAccountCard(
                            account: account,
                            shortcutIndex: switchableShortcutMap[account.id],
                            justSwitchedID: $justSwitchedID,
                            openEditAccount: openEditAccount,
                            openReloginFlow: openReloginFlow
                        )
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(height: rosterGridHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PrismTheme.surfaceQuiet)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PrismTheme.borderSubtle, lineWidth: 0.8))
        )
    }

    private func toolbarIconButton(
        systemName: String,
        active: Bool,
        help: String,
        busy: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            PrismTheme.triggerHaptic()
            action()
        } label: {
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemName)
                        .font(PrismTheme.fontBodyCompactBold)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(active ? PrismTheme.accent.opacity(0.9) : PrismTheme.surfaceFill)
            )
            .foregroundStyle(active ? PrismTheme.textOnAccent : Color.primary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(help)
        .disabled(disabled || busy)
        .accessibilityLabel(help)
    }

    private func filterTab(label: String, filter: RosterListFilter) -> some View {
        let isSelected = rosterFilter == filter
        return Button {
            PrismTheme.triggerHaptic()
            withAnimation(PrismTheme.snapSpring) {
                rosterFilter = filter
            }
        } label: {
            Text(label)
                .font(isSelected ? PrismTheme.fontBodyCompactBold : PrismTheme.fontBodyCompactMedium)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(isSelected ? PrismTheme.accent : PrismTheme.surfaceSoft))
                .foregroundStyle(isSelected ? PrismTheme.textOnAccent : Color.primary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

/// Dedicated card so LazyVGrid context menus capture this card's account ID,
/// not a recycled parent-helper closure from another switchboard cell.
private struct PrismCompactAccountCard: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    let account: SavedAccount
    let shortcutIndex: Int?
    @Binding var justSwitchedID: UUID?
    let openEditAccount: (SavedAccount) -> Void
    let openReloginFlow: (UUID) -> Void

    var body: some View {
        // Freeze the row identity for Login / menu actions — never use selection
        // or "first account that requires login".
        let targetID = account.id
        let quota = account.usage?.fiveHour?.displayRemainingPercent
        let week = account.usage?.weekly?.displayRemainingPercent
        let isJustSwitched = justSwitchedID == account.id

        return HStack(spacing: 8) {
            if let shortcutIndex {
                Text("\(shortcutIndex)")
                    .font(PrismTheme.fontMonoBold)
                    .foregroundStyle(PrismTheme.textPrimary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(PrismTheme.surfaceStrong)
                            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(PrismTheme.borderStrong, lineWidth: 0.8))
                    )
            } else {
                Text(String(account.displayName.prefix(1)).uppercased())
                    .font(PrismTheme.fontBodyCompactBold)
                    .foregroundStyle(PrismTheme.quotaTint(percent: quota))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(PrismTheme.quotaTint(percent: quota).opacity(0.15)))
            }

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    Text(account.displayName)
                        .font(PrismTheme.fontMetric)
                        .lineLimit(1)

                    if account.showsFreePlanChip {
                        Text(language.text("FREE", "FREE"))
                            .font(PrismTheme.fontMicroChip)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(PrismTheme.surfaceStrong))
                            .foregroundStyle(PrismTheme.textSecondary)
                            .help(language.text(
                                "Gói Free/Go — tự chuyển không nhắm tài khoản này",
                                "Free/Go plan — auto-switch will not target this account"
                            ))
                    }

                    if let banked = account.usage?.bankedResets?.availableCount, banked > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(PrismTheme.fontMicro)
                            Text("+\(banked)")
                                .font(PrismTheme.fontChip)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.warning)))
                        .foregroundStyle(PrismTheme.warning)
                        .help(language.text(
                            "\(banked) lượt banked reset có thể dùng",
                            "\(banked) banked resets available"
                        ))
                    }

                    if account.hasLunaReserve {
                        let isLunaActive = store.isLunaReserveActive(for: account)
                        HStack(spacing: 2) {
                            Image(systemName: isLunaActive ? "moon.stars.fill" : "moon.fill")
                                .font(PrismTheme.fontMicro)
                            Text(isLunaActive ? "Luna" : "Reserve")
                                .font(PrismTheme.fontMicroChip)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.autoSwitch)))
                        .foregroundStyle(PrismTheme.autoSwitch)
                        .help(language.text(
                            isLunaActive ? "Codex đang chạy bằng Luna Reserve" : "Tài khoản có Luna Reserve",
                            isLunaActive ? "Codex active on Luna Reserve" : "Account has Luna Reserve"
                        ))
                    }

                    if let balance = account.creditsBalanceDisplay, account.monthlyQuotaRemainingPercent == nil {
                        Text(language.text("Cr \(balance)", "Cr \(balance)"))
                            .font(PrismTheme.fontMicroChip)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.accent, opacity: 0.14)))
                            .foregroundStyle(PrismTheme.accent)
                            .help(language.text(
                                "Số dư tín dụng ChatGPT (không có hạn mức tháng % từ API)",
                                "ChatGPT credit balance (no monthly % from API)"
                            ))
                    }
                }

                HStack(spacing: 4) {
                    Text(account.email)
                        .font(PrismTheme.fontCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    CopyEmailButton(email: account.email, iconSize: 11.5)
                }

                if let status = rowStatus {
                    Text(status.text)
                        .font(PrismTheme.fontChip)
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                        .help(account.usageStatus(in: language.language))
                }
            }

            Spacer(minLength: 4)

            PrismFilamentBar(
                fivePercent: quota,
                weekPercent: week,
                monthPercent: account.monthlyQuotaRemainingPercent,
                width: 34,
                height: 3.5,
                showLabels: true
            )

            if account.isActive {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(PrismTheme.fontCaptionBold)
                    Text(language.text("Dùng", "Active"))
                        .font(PrismTheme.fontMetricSub)
                }
                .foregroundStyle(PrismTheme.emerald)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(Capsule().fill(PrismTheme.emerald.opacity(0.16)))
            } else if account.requiresLogin {
                Button {
                    guard accountForContextMenuAction(in: store.accounts, capturedID: targetID) != nil else { return }
                    openReloginFlow(targetID)
                } label: {
                    Text(language.text("Login", "Login"))
                        .font(PrismTheme.fontMetric)
                        .foregroundStyle(PrismTheme.amber)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .background(Capsule().fill(PrismTheme.amber.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else if canOfferSwitch {
                if let shortcutIndex {
                    Button {
                        PrismTheme.triggerHaptic()
                        withAnimation(PrismTheme.pressFeedback) {
                            justSwitchedID = targetID
                        }
                        guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                        store.activate(target, force: true)
                    } label: {
                        Text(language.text("Đổi", "Switch"))
                            .font(PrismTheme.fontMetric)
                            .foregroundStyle(PrismTheme.textOnAccent)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5.5)
                            .background(
                                Capsule()
                                    .fill(PrismTheme.accent.opacity(0.85))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .keyboardShortcut(KeyEquivalent(Character("\(shortcutIndex)")), modifiers: [])
                } else {
                    Button {
                        PrismTheme.triggerHaptic()
                        withAnimation(PrismTheme.pressFeedback) {
                            justSwitchedID = targetID
                        }
                        guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                        store.activate(target, force: true)
                    } label: {
                        Text(language.text("Đổi", "Switch"))
                            .font(PrismTheme.fontMetric)
                            .foregroundStyle(PrismTheme.textOnAccent)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5.5)
                            .background(
                                Capsule()
                                    .fill(PrismTheme.accent.opacity(0.85))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isJustSwitched ? PrismTheme.chipFill(PrismTheme.accent) : (account.isActive ? PrismTheme.surfaceSoft : PrismTheme.surfaceFaint))
        )
        .contextMenu {
            Button {
                guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                store.activate(target, force: true)
            } label: {
                Label(language.text("Kích hoạt", "Activate"), systemImage: "bolt.fill")
            }
            Button {
                PrismTheme.triggerHaptic()
                guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                copyAccountEmail(target.email)
            } label: {
                Label(language.text("Sao chép email", "Copy email"), systemImage: "doc.on.doc")
            }
            Button {
                guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                openEditAccount(target)
            } label: {
                Label(language.text("Sửa nhãn", "Edit label"), systemImage: "pencil")
            }
            if account.hasLunaReserve && !store.isLunaReserveActive(for: account) {
                Button {
                    PrismTheme.triggerHaptic()
                    guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                    store.enableLunaReserve(target)
                } label: {
                    Label(language.text("Bật Luna Reserve", "Enable Luna Reserve"), systemImage: "moon.stars.fill")
                }
            }
            if account.requiresLogin {
                Button {
                    guard accountForContextMenuAction(in: store.accounts, capturedID: targetID) != nil else { return }
                    openReloginFlow(targetID)
                } label: {
                    Label(language.text("Đăng nhập lại", "Sign in again"), systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                store.delete(target)
            } label: {
                Label(language.text("Xóa", "Delete"), systemImage: "trash")
            }
        }
        .id(targetID)
    }

    /// Manual Switch when activation is not blocked — Free/exhausted rows stay
    /// switchable by hand. Shortcuts / Ready / auto-switch keep `isUsableForSwitch`.
    private var canOfferSwitch: Bool {
        !account.usageErrorBlocksActivation
    }

    /// Explicit row state so users don't infer from 0% bars alone.
    private var rowStatus: (text: String, tint: Color)? {
        if account.isActive { return nil }
        if account.requiresLogin {
            return (language.text("Cần đăng nhập", "Needs Login"), PrismTheme.amber)
        }
        if account.requiresLocalRecovery {
            return (language.text("Cần phục hồi", "Needs recovery"), PrismTheme.ruby)
        }
        if account.hasTransientUsageError {
            return (language.text("Quota tạm thời lỗi", "Quota unavailable"), PrismTheme.amber)
        }
        if !account.isUsableForSwitch {
            if account.restingHasBankedReset {
                let count = account.usage?.bankedResets?.availableCount ?? 0
                return (language.text("Banked ×\(count)", "Banked ×\(count)"), PrismTheme.warning)
            }
            return exhaustedStatus
        }
        if account.hasDeferredAccessTokenRefresh {
            return (language.text("Chưa xác minh", "Unverified"), PrismTheme.textSecondary)
        }
        return nil
    }

    private var exhaustedStatus: (text: String, tint: Color) {
        if let weekly = account.usage?.weekly, weekly.isDepleted {
            return (
                language.text(
                    "Hết tuần · \(weekly.resetDescription(in: language.language))",
                    "Weekly exhausted · \(weekly.resetDescription(in: language.language))"
                ),
                PrismTheme.resetProximityTint(window: weekly, kind: .weekly)
            )
        }
        guard let window = account.quotaWindowsForSwitch.min(by: { $0.resetAt.value < $1.resetAt.value }) else {
            return (language.text("Hết quota", "Out of quota"), PrismTheme.textSecondary)
        }
        let kind: QuotaResetWindowKind = {
            if let weekly = account.usage?.weekly,
               weekly.resetAt.value == window.resetAt.value {
                return .weekly
            }
            return .fiveHour
        }()
        return (
            language.text(
                "Hết · \(window.resetDescription(in: language.language))",
                "Exhausted · \(window.resetDescription(in: language.language))"
            ),
            PrismTheme.resetProximityTint(window: window, kind: kind)
        )
    }
}
