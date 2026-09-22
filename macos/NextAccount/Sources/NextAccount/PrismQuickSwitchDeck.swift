import SwiftUI

/// Panoramic Notch Console for Codex Roster (`NotchRosterLayout.deckWidth` × dynamic height).
/// Frames the MacBook camera notch; dense upper strip + 2-column roster switchboard.
struct PrismQuickSwitchDeck: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var updater: GitHubUpdater
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("codex_roster_notch_pinned_live") private var isPinnedLive = false
    @AppStorage(NotchRosterLayout.rosterExpandedKey) private var isRosterExpanded = false

    var openSettings: () -> Void = {}
    var openOperations: () -> Void = {}
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

    private var rosterSectionCounts: [Int] {
        NotchRosterLayout.planSectionAccountCounts(from: filteredAccounts)
    }

    private var rosterColumnCount: Int {
        NotchRosterLayout.columnCount(
            sectionCounts: rosterSectionCounts,
            expanded: isRosterExpanded
        )
    }

    private var rosterGridHeight: CGFloat {
        NotchRosterLayout.rosterGridHeight(
            sectionCounts: rosterSectionCounts,
            expanded: isRosterExpanded
        )
    }

    private var rosterNeedsScroll: Bool {
        NotchRosterLayout.needsRosterScroll(
            sectionCounts: rosterSectionCounts,
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

    private var hasNextActionCaption: Bool { nextActionCaption != nil }

    private var deckHeight: CGFloat {
        NotchRosterLayout.deckHeight(
            sectionCounts: rosterSectionCounts,
            expanded: isRosterExpanded,
            hasNextActionCaption: hasNextActionCaption
        )
    }

    var body: some View {
        VStack(spacing: NotchRosterLayout.deckSectionSpacing) {
            // Upper Deck: Left Wing | Notch Clearance & Live Pin | Right Wing
            upperDeckFramingNotch

            nextActionCaptionRow

            // Lower Deck: Full-width flexible account switchboard
            lowerSwitchboardDeck
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, NotchRosterLayout.deckHorizontalInset)
        .padding(.top, NotchRosterLayout.deckTopInset)
        .padding(.bottom, NotchRosterLayout.deckBottomInset)
        .frame(
            minWidth: NotchRosterLayout.deckWidth,
            idealWidth: NotchRosterLayout.deckWidth,
            maxWidth: NotchRosterLayout.deckWidth,
            minHeight: deckHeight,
            idealHeight: deckHeight,
            maxHeight: deckHeight,
            alignment: .top
        )
        .animation(PrismTheme.snapSpring, value: isRosterExpanded)
        .animation(PrismTheme.snapSpring, value: filteredAccounts.count)
        .animation(PrismTheme.snapSpring, value: hasNextActionCaption)
        .animation(PrismTheme.snapSpring, value: rosterColumnCount)
    }

    /// Compact “what to do next” line — omitted when all-clear (no mid-deck gap;
    /// deck height only grows when this row is present).
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
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: NotchRosterLayout.nextActionCaptionHeight, alignment: .center)
            .accessibilityLabel(language.text("Việc nên làm tiếp theo", "Next action"))
            .accessibilityValue(caption)
        }
    }

    // MARK: - Upper Deck (Live | Camera gap | Usage) — balanced heights, stretch to fill
    private var upperDeckFramingNotch: some View {
        let geometry = NotchGeometry.detect()
        let centerGapWidth = geometry.hasNotch
            ? geometry.cameraWidth
            : 156
        return HStack(alignment: .top, spacing: 8) {
            upperLeftWing
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Camera clearance column — measured width on notch Macs so wings
            // never sit under the housing; fixed comfort width on non-notch.
            upperCenterNotchGap(geometry: geometry)
                .frame(width: centerGapWidth)
                .frame(maxHeight: .infinity, alignment: .top)

            upperRightWing
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Upper Left Wing (Active identity + compact dual quota)
    private var upperLeftWing: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 7) {
                ZStack {
                    Circle()
                        .fill(PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent).opacity(0.18))
                        .frame(width: 26, height: 26)
                    Image(systemName: (activeAccount?.aiProvider ?? .openAI).icon)
                        .font(PrismTheme.fontCaptionBold)
                        .foregroundStyle(PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(activeAccount?.displayName ?? language.text("Chưa chọn phiên", "No session"))
                            .font(PrismTheme.fontHeadline)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if hasIdentityChips {
                            identityChipsRow
                        }
                        Spacer(minLength: 4)
                        identityActionsRow
                    }

                    HStack(spacing: 4) {
                        Text(activeAccount?.email ?? "—")
                            .font(PrismTheme.fontCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if let email = activeAccount?.email, !email.isEmpty {
                            CopyEmailButton(email: email, iconSize: 11)
                        }
                    }
                }
            }

            PrismDualChamberGauge(
                fiveHour: activeAccount?.usage?.fiveHour,
                weekly: activeAccount?.usage?.weekly,
                showLabels: true,
                compact: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(PrismTheme.surfacePanel)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PrismTheme.surfaceFill, lineWidth: 0.8))
        )
    }

    private var hasIdentityChips: Bool {
        let hasPlan = !(activeAccount?.planLabel ?? "").isEmpty
        let hasBanked = (activeAccount?.bankedResetCount ?? 0) > 0
        let hasLuna = activeAccount?.hasLunaReserve == true
        return hasPlan || hasBanked || hasLuna
    }

    private var identityChipsRow: some View {
        HStack(spacing: 6) {
            if let plan = activeAccount?.planLabel, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(PrismTheme.fontChip)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.accent, opacity: 0.15)))
                    .foregroundStyle(PrismTheme.accent)
                    .fixedSize()
            }

            if let banked = activeAccount?.bankedResetCount, banked > 0 {
                PrismBankedResetCountBadge(
                    count: banked,
                    style: .identity,
                    helpText: language.text(
                        "\(banked) lượt reset dự phòng (banked reset) có sẵn trong Codex",
                        "\(banked) banked rate-limit resets available in Codex"
                    )
                )
            }

            if let active = activeAccount, active.hasLunaReserve {
                let isLunaActive = store.isLunaReserveActive(for: active)
                HStack(spacing: 2.5) {
                    Image(systemName: isLunaActive ? "moon.stars.fill" : "moon.fill")
                        .font(PrismTheme.fontChipIcon)
                    Text(isLunaActive
                        ? language.text("Luna bật", "Luna on")
                        : language.text("Luna", "Luna"))
                        .font(PrismTheme.fontChip)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.autoSwitch)))
                .foregroundStyle(PrismTheme.autoSwitch)
                .fixedSize()
                .help(language.text(
                    isLunaActive ? "Codex đang chạy bằng Luna Reserve (gpt-5.6-luna)" : "Tài khoản có Luna Reserve sẵn sàng sử dụng",
                    isLunaActive ? "Codex is running on Luna Reserve (gpt-5.6-luna)" : "Luna Reserve is available for this account"
                ))
            }

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var identityActionsRow: some View {
        HStack(spacing: 4) {
            if let active = activeAccount, active.hasLunaReserve && !store.isLunaReserveActive(for: active) {
                Button {
                    PrismTheme.triggerHaptic()
                    store.enableLunaReserve(active)
                } label: {
                    Image(systemName: "moon.stars.fill")
                        .font(PrismTheme.fontCaptionBold)
                        .foregroundStyle(PrismTheme.autoSwitch)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(PrismTheme.chipFill(PrismTheme.autoSwitch)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(language.text(
                    "Bật Luna Reserve (gpt-5.6-luna)",
                    "Enable Luna Reserve (gpt-5.6-luna)"
                ))
            }

            Button {
                PrismTheme.triggerHaptic()
                store.resyncChatGPTDesktop()
            } label: {
                Group {
                    if store.isWorking || store.isBusyForActions {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(PrismTheme.fontCaptionBold)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                .background(Circle().fill(PrismTheme.surfaceFill))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(language.text(
                "Mở lại ChatGPT Desktop để đồng bộ phiên",
                "Relaunch ChatGPT Desktop to resync session"
            ))
        }
        .fixedSize()
    }

    // MARK: - Upper Center Notch Gap (tight under camera)
    private func upperCenterNotchGap(geometry: NotchGeometry) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                let statusIndicator = store.openAIStatus?.indicator ?? "none"
                let isOperational = statusIndicator == "none"
                Circle()
                    .fill(isOperational ? PrismTheme.emerald : PrismTheme.ruby)
                    .frame(width: 6, height: 6)
                Text(isOperational
                      ? language.text("OpenAI ổn", "OpenAI OK")
                      : language.text("Sự cố OpenAI", "OpenAI issue"))
                    .font(PrismTheme.fontCaptionBold)
                    .foregroundStyle(isOperational ? PrismTheme.emerald : PrismTheme.ruby)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(PrismTheme.surfaceMuted))

            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.shield.fill")
                        .font(PrismTheme.fontCaptionBold)
                        .foregroundStyle(store.autoSwitchWhenExhausted ? PrismTheme.autoSwitch : .secondary)
                    Text(language.text("Tự chuyển", "Auto-switch"))
                        .font(PrismTheme.fontCaptionBold)
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
                    .font(PrismTheme.fontChip)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PrismTheme.surfaceDim)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                store.autoSwitchWhenExhausted
                                    ? PrismTheme.violet.opacity(0.35)
                                    : PrismTheme.surfaceFill,
                                lineWidth: 0.8
                            )
                    )
            )
        }
        .padding(.top, topNotchClearance(for: geometry))
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

    /// Vertical clearance so center-column controls sit flush under the camera
    /// housing. Accounts for the outer `deckTopInset` so total top offset == inset.
    /// Non-notch: zero extra clearance (only the shared deck top inset).
    private func topNotchClearance(for geometry: NotchGeometry) -> CGFloat {
        guard geometry.hasNotch else { return 0 }
        return max(0, geometry.inset - NotchRosterLayout.deckTopInset)
    }

    // MARK: - Upper Right Wing (Telemetry — denser strip)
    private var upperRightWing: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(language.text("Tiêu thụ", "Usage"), systemImage: "chart.line.uptrend.xyaxis")
                    .font(PrismTheme.fontBodyCompactBold)
                Spacer(minLength: 4)
                if let outlook = store.resetOutlook {
                    resetOutlookBadge(outlook)
                }
                Button {
                    PrismTheme.triggerHaptic()
                    // Longevity-safe: AT-only usage for every saved account
                    // (skips deferred/login rows; never prove_saved_session_refresh).
                    store.refreshUsage(scope: .allSaved)
                    store.refreshTokenUsage(silently: true)
                    store.refreshResetOutlook(silently: true)
                    store.refreshResetTimeline(silently: true)
                    store.refreshResetJuice(silently: true)
                    store.refreshOpenAIStatus(silently: true)
                } label: {
                    Group {
                        if store.isBusyForActions {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(PrismTheme.fontCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
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
                HStack(spacing: 6) {
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
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let juice = store.resetJuice, !juice.efforts.isEmpty {
                HStack(spacing: 6) {
                    Text(language.text("Juice", "Juice"))
                        .font(PrismTheme.fontMicro)
                        .foregroundStyle(.secondary)
                    ForEach(juice.efforts.prefix(4)) { effort in
                        HStack(spacing: 2) {
                            Text(effort.effort.prefix(1).uppercased())
                                .font(PrismTheme.fontMicro)
                                .foregroundStyle(.tertiary)
                            Text("\(effort.current)")
                                .font(PrismTheme.fontChip)
                                .monospacedDigit()
                                .foregroundStyle(
                                    effort.delta > 0 ? PrismTheme.emerald
                                        : effort.delta < 0 ? PrismTheme.ruby
                                        : PrismTheme.textSecondary
                                )
                        }
                    }
                    Spacer(minLength: 0)
                }
                .help(language.text("Mức effort còn lại (codex-reset)", "Remaining effort levels (codex-reset)"))
            }

            if let event = store.resetTimeline?.first {
                HStack(alignment: .top, spacing: 4) {
                    Text(event.date)
                        .font(PrismTheme.fontMicro)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Text(event.summary)
                        .font(PrismTheme.fontChip)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                .help(language.text("Sự kiện reset gần nhất", "Latest reset timeline event"))
            }

            usageWingFooter
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PrismTheme.surfacePanel)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PrismTheme.surfaceFill, lineWidth: 0.8))
        )
    }

    private func resetOutlookBadge(_ outlook: ResetOutlook) -> some View {
        Button {
            PrismTheme.triggerHaptic()
            if let url = outlook.sourceUrl.flatMap(URL.init) {
                openURL(url)
            } else {
                openURL(URL(string: "https://codex-resets.com")!)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(PrismTheme.fontMicro)
                    .foregroundStyle(PrismTheme.accent)
                Text(language.text("Reset:", "Reset:"))
                    .font(PrismTheme.fontMicro)
                    .foregroundStyle(PrismTheme.textSecondary)
                if let signalPercent = outlook.signalPercent {
                    Text(language.text("Tín hiệu \(signalPercent)%", "Signal \(signalPercent)%"))
                        .font(PrismTheme.fontChip)
                        .foregroundStyle(signalPercent >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text("24h \(outlook.chance24Hours)%")
                    .font(PrismTheme.fontChip)
                    .foregroundStyle(outlook.chance24Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                Text("·").foregroundStyle(.tertiary)
                Text("48h \(outlook.chance48Hours)%")
                    .font(PrismTheme.fontChip)
                    .foregroundStyle(outlook.chance48Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(PrismTheme.surfaceMuted)
                    .overlay(Capsule().strokeBorder(PrismTheme.surfaceFill, lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(resetOutlookTooltip(for: outlook))
    }

    private func resetOutlookTooltip(for outlook: ResetOutlook) -> String {
        var lines: [String] = []
        lines.append(language.text(
            "Radar dự báo reset quota toàn hệ thống OpenAI (codex-resets.com)",
            "OpenAI global quota reset radar (codex-resets.com)"
        ))
        if let signal = outlook.signalPercent {
            lines.append(language.text(
                "• Tín hiệu cam kết: \(signal)% (từ cộng đồng / Tibo)",
                "• Commitment signal: \(signal)% (from community / Tibo)"
            ))
        }
        lines.append(language.text(
            "• Xác suất reset trong 24h tới: \(outlook.chance24Hours)%",
            "• 24h reset chance: \(outlook.chance24Hours)%"
        ))
        lines.append(language.text(
            "• Xác suất reset trong 48h tới: \(outlook.chance48Hours)%",
            "• 48h reset chance: \(outlook.chance48Hours)%"
        ))
        if let summary = outlook.signalSummary, !summary.isEmpty {
            lines.append("• " + summary)
        } else if !outlook.windowLabel.isEmpty {
            lines.append(language.text(
                "• Khung giờ: \(outlook.windowLabel)",
                "• Window: \(outlook.windowLabel)"
            ))
        }
        lines.append(language.text(
            "Nhấp để mở codex-resets.com",
            "Click to open codex-resets.com"
        ))
        return lines.joined(separator: "\n")
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
                        .minimumScaleFactor(0.85)
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
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(PrismTheme.fontMicro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(PrismTheme.fontMetricSub)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let accent {
                Text(accent)
                    .font(PrismTheme.fontChip)
                    .foregroundStyle(PrismTheme.emerald)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.surfaceQuiet))
    }

    // MARK: - Lower Deck: Flexible Full-Width Account Switchboard
    private var lowerSwitchboardDeck: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(language.text("Danh bạ", "Roster"))
                    .font(PrismTheme.fontSection)

                Text("\(filteredAccounts.count)/\(store.accounts.filter { !$0.archived }.count)")
                    .font(PrismTheme.fontMono)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(PrismTheme.surfaceSoft))

                if store.totalBankedResetsAcrossRoster > 0 {
                    let total = store.totalBankedResetsAcrossRoster
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(PrismTheme.fontMicro)
                        Text("\(total)")
                            .font(PrismTheme.fontChip)
                            .monospacedDigit()
                        Text(language.text("banked", "banked"))
                            .font(PrismTheme.fontMicroChip)
                    }
                    .foregroundStyle(PrismTheme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.warning, opacity: 0.14)))
                    .help(language.text(
                        "Tổng \(total) banked reset trên toàn roster — chỉ hiển thị, không tự redeem.",
                        "\(total) banked resets across the roster — display only, never auto-redeemed."
                    ))
                }

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
                    if reduceMotion {
                        isRosterExpanded.toggle()
                    } else {
                        withAnimation(PrismTheme.snapSpring) {
                            isRosterExpanded.toggle()
                        }
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
                    if reduceMotion {
                        isPinnedLive.toggle()
                    } else {
                        withAnimation(PrismTheme.snapSpring) {
                            isPinnedLive.toggle()
                        }
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
                    Button { openOperations() } label: {
                        Label(language.text("Vận hành…", "Operations…"), systemImage: "wrench.and.screwdriver")
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
                let columns = Array(
                    repeating: GridItem(
                        .flexible(
                            minimum: NotchRosterLayout.minComfortableCardWidth * 0.72,
                            maximum: .infinity
                        ),
                        spacing: NotchRosterLayout.columnSpacing
                    ),
                    count: rosterColumnCount
                )
                let grouped = Dictionary(grouping: filteredAccounts, by: \.planGroupKey)
                let groupOrder = ["pro", "plus", "team", "other", "free"]
                let sections = groupOrder.compactMap { key -> (key: String, accounts: [SavedAccount])? in
                    guard let accounts = grouped[key], !accounts.isEmpty else { return nil }
                    return (key, store.sortedAccounts(accounts))
                }

                LazyVGrid(columns: columns, spacing: NotchRosterLayout.rowSpacing) {
                    ForEach(sections, id: \.key) { section in
                        if sections.count > 1 {
                            Text(planGroupTitle(section.key))
                                .font(PrismTheme.fontChip)
                                .foregroundStyle(.secondary)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: NotchRosterLayout.sectionHeaderHeight,
                                    maxHeight: NotchRosterLayout.sectionHeaderHeight,
                                    alignment: .leading
                                )
                                .gridCellColumns(rosterColumnCount)
                                .padding(
                                    .top,
                                    section.key == sections.first?.key
                                        ? 0
                                        : NotchRosterLayout.sectionHeaderTopGap
                                )
                        }
                        ForEach(section.accounts) { account in
                            PrismCompactAccountCard(
                                account: account,
                                shortcutIndex: switchableShortcutMap[account.id],
                                justSwitchedID: $justSwitchedID,
                                openEditAccount: openEditAccount,
                                openReloginFlow: openReloginFlow,
                                meterWidth: rosterColumnCount <= 2 ? 56 : 48
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.vertical, NotchRosterLayout.gridVerticalPadding / 2)
            }
            .scrollDisabled(!rosterNeedsScroll)
            .frame(maxWidth: .infinity)
            .frame(height: rosterGridHeight)
        }
        .padding(.horizontal, NotchRosterLayout.switchboardHorizontalInset)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PrismTheme.surfaceQuiet)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PrismTheme.borderSubtle, lineWidth: 0.8))
        )
        .onAppear {
            store.refreshResetOutlook(silently: true)
            store.refreshResetTimeline(silently: true)
            store.refreshResetJuice(silently: true)
        }
    }

    private func planGroupTitle(_ key: String) -> String {
        switch key {
        case "pro": return language.text("Pro", "Pro")
        case "plus": return language.text("Plus", "Plus")
        case "team": return language.text("Team / Business", "Team / Business")
        case "free": return language.text("Free / Go", "Free / Go")
        default: return language.text("Khác", "Other")
        }
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
            if reduceMotion {
                rosterFilter = filter
            } else {
                withAnimation(PrismTheme.snapSpring) {
                    rosterFilter = filter
                }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let account: SavedAccount
    let shortcutIndex: Int?
    @Binding var justSwitchedID: UUID?
    let openEditAccount: (SavedAccount) -> Void
    let openReloginFlow: (UUID) -> Void
    var meterWidth: CGFloat = 48

    var body: some View {
        // Freeze the row identity for Login / menu actions — never use selection
        // or "first account that requires login".
        let targetID = account.id
        let quota = account.usage?.fiveHour?.displayRemainingPercent
        let week = account.usage?.weekly?.displayRemainingPercent
        let isJustSwitched = justSwitchedID == account.id

        return HStack(alignment: .center, spacing: 6) {
            if let shortcutIndex {
                Text("\(shortcutIndex)")
                    .font(PrismTheme.fontMonoBold)
                    .foregroundStyle(PrismTheme.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(PrismTheme.surfaceStrong)
                            .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(PrismTheme.borderStrong, lineWidth: 0.8))
                    )
            } else {
                Text(String(account.displayName.prefix(1)).uppercased())
                    .font(PrismTheme.fontChip)
                    .foregroundStyle(PrismTheme.quotaTint(percent: quota))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(PrismTheme.quotaTint(percent: quota).opacity(0.15)))
            }

            // Text fills remaining width; meters + action stay pinned trailing (no mid-card void).
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(account.displayName)
                        .font(PrismTheme.fontMetricSub)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if account.showsFreePlanChip {
                        Text(language.text("FREE", "FREE"))
                            .font(PrismTheme.fontMicroChip)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(PrismTheme.surfaceStrong))
                            .foregroundStyle(PrismTheme.textSecondary)
                            .help(language.text(
                                "Gói Free/Go — tự chuyển không nhắm tài khoản này",
                                "Free/Go plan — auto-switch will not target this account"
                            ))
                    }

                    if account.bankedResetCount > 0 {
                        let banked = account.bankedResetCount
                        PrismBankedResetCountBadge(
                            count: banked,
                            style: .card,
                            helpText: language.text(
                                "\(banked) lượt banked reset có thể dùng",
                                "\(banked) banked resets available"
                            )
                        )
                    }

                    if account.hasLunaReserve {
                        let isLunaActive = store.isLunaReserveActive(for: account)
                        HStack(spacing: 2) {
                            Image(systemName: isLunaActive ? "moon.stars.fill" : "moon.fill")
                                .font(PrismTheme.fontMicro)
                            Text(isLunaActive ? "Luna" : "Reserve")
                                .font(PrismTheme.fontMicroChip)
                        }
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.autoSwitch)))
                        .foregroundStyle(PrismTheme.autoSwitch)
                        .help(language.text(
                            isLunaActive ? "Codex đang chạy bằng Luna Reserve" : "Tài khoản có Luna Reserve",
                            isLunaActive ? "Codex active on Luna Reserve" : "Account has Luna Reserve"
                        ))
                    }

                        if account.hasWeeklyResetWithin24Hours {
                            HStack(spacing: 2) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(PrismTheme.fontMicro)
                                Text("24h")
                                    .font(PrismTheme.fontMicroChip)
                            }
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.amber, opacity: 0.16)))
                            .foregroundStyle(PrismTheme.amber)
                            .help(language.text(
                                "Weekly reset trong 24 giờ tới",
                                "Weekly reset within the next 24 hours"
                            ))
                        }

                        if let balance = account.creditsBalanceDisplay, account.monthlyQuotaRemainingPercent == nil {
                        Text(language.text("Cr \(balance)", "Cr \(balance)"))
                            .font(PrismTheme.fontMicroChip)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(PrismTheme.chipFill(PrismTheme.accent, opacity: 0.14)))
                            .foregroundStyle(PrismTheme.accent)
                            .help(language.text(
                                "Số dư tín dụng ChatGPT (không có hạn mức tháng % từ API)",
                                "ChatGPT credit balance (no monthly % from API)"
                            ))
                    }
                }

                HStack(spacing: 3) {
                    Text(account.email)
                        .font(PrismTheme.fontCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    CopyEmailButton(email: account.email, iconSize: 11)

                    if let status = rowStatus {
                        Text("·")
                            .font(PrismTheme.fontCaption)
                            .foregroundStyle(.tertiary)
                        Text(status.text)
                            .font(PrismTheme.fontCaption)
                            .foregroundStyle(status.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .help(account.usageStatus(in: language.language))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PrismFilamentBar(
                fivePercent: quota,
                weekPercent: week,
                monthPercent: account.monthlyQuotaRemainingPercent,
                width: meterWidth,
                height: 3,
                showAxisLabels: false,
                showPercents: true
            )
            .fixedSize()

            Group {
                if account.isActive {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(PrismTheme.fontChipIcon)
                        Text(language.text("Dùng", "Active"))
                            .font(PrismTheme.fontCaptionBold)
                    }
                    .foregroundStyle(PrismTheme.emerald)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(PrismTheme.emerald.opacity(0.16)))
                } else if account.requiresLogin {
                    Button {
                        guard accountForContextMenuAction(in: store.accounts, capturedID: targetID) != nil else { return }
                        openReloginFlow(targetID)
                    } label: {
                        Text(language.text("Login", "Login"))
                            .font(PrismTheme.fontCaptionBold)
                            .foregroundStyle(PrismTheme.amber)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(PrismTheme.amber.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                } else if canOfferSwitch {
                    if let shortcutIndex {
                        switchButton(targetID: targetID)
                            .keyboardShortcut(KeyEquivalent(Character("\(shortcutIndex)")), modifiers: [])
                    } else {
                        switchButton(targetID: targetID)
                    }
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: NotchRosterLayout.rowHeight - 2, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
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

    private func switchButton(targetID: UUID) -> some View {
        Button {
            PrismTheme.triggerHaptic()
            if reduceMotion {
                justSwitchedID = targetID
            } else {
                withAnimation(PrismTheme.pressFeedback) {
                    justSwitchedID = targetID
                }
            }
            guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
            store.activate(target, force: true)
        } label: {
            Text(language.text("Đổi", "Switch"))
                .font(PrismTheme.fontCaptionBold)
                .foregroundStyle(PrismTheme.textOnAccent)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(PrismTheme.accent.opacity(0.85))
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .fixedSize()
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
                let count = account.bankedResetCount
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
                    "Hết tuần · \(weekly.relativeReset(in: language.language))",
                    "Wk out · \(weekly.relativeReset(in: language.language))"
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
                "Hết · \(window.relativeReset(in: language.language))",
                "Out · \(window.relativeReset(in: language.language))"
            ),
            PrismTheme.resetProximityTint(window: window, kind: kind)
        )
    }
}
