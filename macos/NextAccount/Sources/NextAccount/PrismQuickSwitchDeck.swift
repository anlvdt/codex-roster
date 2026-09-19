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
            if !account.isActive && !account.usageErrorBlocksActivation && !account.requiresLogin {
                if nextShortcut <= 6 {
                    map[account.id] = nextShortcut
                    nextShortcut += 1
                }
            }
        }
        return map
    }

    private var readyCandidates: [SavedAccount] {
        store.sortedAccounts(
            store.accounts.filter { !$0.isActive && !$0.archived && !$0.usageErrorBlocksActivation }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            // Upper Deck: Left Wing | Notch Clearance & Live Pin | Right Wing (Height: 132pt)
            upperDeckFramingNotch

            // Lower Deck: Full-width 2-column account switchboard
            lowerSwitchboardDeck
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: 920, height: deckHeight)
        .animation(PrismTheme.snapSpring, value: isRosterExpanded)
        .animation(PrismTheme.snapSpring, value: filteredAccounts.count)
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
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(activeAccount?.displayName ?? language.text("Chưa chọn phiên", "No session"))
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)

                        if let plan = activeAccount?.planLabel, !plan.isEmpty {
                            Text(plan.uppercased())
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                        }

                        if let banked = activeAccount?.usage?.bankedResets?.availableCount, banked > 0 {
                            HStack(spacing: 2.5) {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 9.5))
                                Text("+\(banked) banked")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(Color.orange)
                            .help(language.text(
                                "\(banked) lượt reset dự phòng (banked reset) có sẵn trong Codex",
                                "\(banked) banked rate-limit resets available in Codex"
                            ))
                        }

                        if let active = activeAccount, active.hasLunaReserve {
                            let isLunaActive = store.isLunaReserveActive(for: active)
                            HStack(spacing: 2.5) {
                                Image(systemName: isLunaActive ? "moon.stars.fill" : "moon.fill")
                                    .font(.system(size: 9.5))
                                Text(isLunaActive ? "Luna Active" : "Luna Reserve")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.purple.opacity(0.18)))
                            .foregroundStyle(Color.purple)
                            .help(language.text(
                                isLunaActive ? "Codex đang chạy bằng Luna Reserve (gpt-5.6-luna)" : "Tài khoản có Luna Reserve sẵn sàng sử dụng",
                                isLunaActive ? "Codex is running on Luna Reserve (gpt-5.6-luna)" : "Luna Reserve is available for this account"
                            ))
                        }
                    }

                    HStack(spacing: 5) {
                        Text(activeAccount?.email ?? "—")
                            .font(.system(size: 11.5))
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
                                .font(.system(size: 10, weight: .bold))
                            Text(language.text("Bật Luna", "Enable Luna"))
                                .font(.system(size: 11.5, weight: .bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(
                            Capsule()
                                .fill(Color.purple.opacity(0.18))
                                .overlay(Capsule().strokeBorder(Color.purple.opacity(0.35), lineWidth: 0.8))
                        )
                        .foregroundStyle(Color.purple)
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
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(language.text("Đồng bộ", "Sync"))
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            // Quotas: 5h & Weekly
            HStack(spacing: 10) {
                // 5-Hour Window
                VStack(alignment: .leading, spacing: 4) {
                    let five = activeAccount?.usage?.fiveHour
                    let fivePercent = five?.displayRemainingPercent

                    HStack(alignment: .firstTextBaseline) {
                        Text(language.text("Cửa sổ 5h", "5h window"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let fivePercent {
                            Text("\(fivePercent)%")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                        }
                    }

                    PrismSegmentedBar(percent: fivePercent ?? 0, segments: 5, height: 6)

                    if let five {
                        Text(five.resetDescription(in: language.language))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
                // Weekly Allowance
                VStack(alignment: .leading, spacing: 4) {
                    let week = activeAccount?.usage?.weekly
                    let weekPercent = week?.displayRemainingPercent

                    HStack(alignment: .firstTextBaseline) {
                        Text(language.text("Hạn mức tuần", "Weekly"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let weekPercent {
                            Text("\(weekPercent)%")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(PrismTheme.quotaGradient(percent: weekPercent))
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(weekPercent ?? 0) / 100.0)))
                        }
                    }
                    .frame(height: 6)

                    if let week {
                        Text(week.resetDescription(in: language.language))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOperational ? PrismTheme.emerald : PrismTheme.ruby)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.07)))

            // Auto-switch control (Settings is secondary; notch is primary)
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(store.autoSwitchWhenExhausted ? PrismTheme.violet : .secondary)
                    Text(language.text("Tự chuyển", "Auto-switch"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(store.autoSwitchWhenExhausted ? PrismTheme.violet : .secondary)
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
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                store.autoSwitchWhenExhausted
                                    ? PrismTheme.violet.opacity(0.35)
                                    : Color.white.opacity(0.08),
                                lineWidth: 0.8
                            )
                    )
            )

            Spacer(minLength: 2)
        }
        .padding(.top, topNotchClearance)
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
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if let outlook = store.resetOutlook {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("24h \(outlook.chance24Hours)%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(outlook.chance24Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                        Text("·").foregroundStyle(.tertiary)
                        Text("48h \(outlook.chance48Hours)%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(outlook.chance48Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                    }
                    .help(outlook.windowLabel)
                }
                Button {
                    PrismTheme.triggerHaptic()
                    store.refresh()
                    store.refreshTokenUsage(silently: true)
                    store.refreshResetOutlook(silently: true)
                    store.refreshOpenAIStatus(silently: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(store.isBusyForActions)
                .help(language.text("Làm mới", "Refresh"))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
        )
    }

    private func telemetryPill(title: String, value: String, accent: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .lineLimit(1)
            if let accent {
                Text(accent)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(PrismTheme.emerald)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    // MARK: - Lower Deck: 2-Column Full-Width Account Switchboard
    private var lowerSwitchboardDeck: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(language.text("Danh bạ", "Roster"))
                    .font(.system(size: 14, weight: .bold))

                Text("\(filteredAccounts.count)/\(store.accounts.filter { !$0.archived }.count)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.06)))

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

                Menu {
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
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.8))
        )
    }

    private func toolbarIconButton(
        systemName: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            PrismTheme.triggerHaptic()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(active ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.08))
                )
                .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(help)
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
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color.white.opacity(0.06)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
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
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8))
                    )
            } else {
                Text(String(account.displayName.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PrismTheme.quotaTint(percent: quota))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(PrismTheme.quotaTint(percent: quota).opacity(0.15)))
            }

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    Text(account.displayName)
                        .font(.system(size: 12.5, weight: .bold))
                        .lineLimit(1)

                    if let banked = account.usage?.bankedResets?.availableCount, banked > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.system(size: 8))
                            Text("+\(banked)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(Color.orange)
                        .help(language.text(
                            "\(banked) lượt banked reset có thể dùng",
                            "\(banked) banked resets available"
                        ))
                    }

                    if account.hasLunaReserve {
                        let isLunaActive = store.isLunaReserveActive(for: account)
                        HStack(spacing: 2) {
                            Image(systemName: isLunaActive ? "moon.stars.fill" : "moon.fill")
                                .font(.system(size: 8))
                            Text(isLunaActive ? "Luna" : "Reserve")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.18)))
                        .foregroundStyle(Color.purple)
                        .help(language.text(
                            isLunaActive ? "Codex đang chạy bằng Luna Reserve" : "Tài khoản có Luna Reserve",
                            isLunaActive ? "Codex active on Luna Reserve" : "Account has Luna Reserve"
                        ))
                    }

                    if account.hasDeferredAccessTokenRefresh {
                        Text(language.text("Chưa xác minh", "Unverified"))
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.16)))
                            .foregroundStyle(.secondary)
                            .help(account.usageStatus(in: language.language))
                    }
                }
                HStack(spacing: 4) {
                    Text(account.email)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    CopyEmailButton(email: account.email, iconSize: 11.5)
                }
            }

            Spacer(minLength: 4)

            PrismFilamentBar(fivePercent: quota, weekPercent: week, width: 34, height: 3.5, showLabels: true)

            if account.isActive {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(language.text("Dùng", "Active"))
                        .font(.system(size: 12, weight: .bold))
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
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(PrismTheme.amber)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .background(Capsule().fill(PrismTheme.amber.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else if !account.usageErrorBlocksActivation {
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
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5.5)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.85))
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
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5.5)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.85))
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
                .fill(isJustSwitched ? Color.accentColor.opacity(0.18) : Color.white.opacity(account.isActive ? 0.06 : 0.018))
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
}
