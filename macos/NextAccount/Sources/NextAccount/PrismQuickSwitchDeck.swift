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

    var openDashboard: () -> Void = {}
    var openAddAccountFlow: () -> Void = {}
    var openReloginFlow: () -> Void = {}
    var openBackupFlow: (BackupOperation) -> Void = { _ in }
    var openEditAccount: (SavedAccount) -> Void = { _ in }
    var openAbout: () -> Void = {}

    @State private var rosterFilter: AccountTriage? = nil
    @State private var rosterSearch: String = ""
    @State private var justSwitchedID: UUID? = nil

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !$0.archived }
    }

    private var filteredAccounts: [SavedAccount] {
        let matching = store.accounts.filter { account in
            let matchesFilter: Bool = {
                guard let filter = rosterFilter else { return true }
                return account.triage == filter
            }()
            let matchesSearch: Bool = {
                guard !rosterSearch.isEmpty else { return true }
                return account.displayName.localizedCaseInsensitiveContains(rosterSearch)
                    || account.email.localizedCaseInsensitiveContains(rosterSearch)
            }()
            return matchesFilter && matchesSearch
        }
        return store.sortedAccounts(matching)
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
        store.accounts
            .filter { !$0.isActive && !$0.archived && !$0.usageErrorBlocksActivation }
            .sorted { a, b in
                let aQuota = a.usage?.fiveHour?.displayRemainingPercent ?? -1
                let bQuota = b.usage?.fiveHour?.displayRemainingPercent ?? -1
                return aQuota > bQuota
            }
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
        .frame(width: 920, height: 480)
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
        VStack(spacing: 8) {
            // OpenAI Health + Tibo Radar Chip directly below camera notch
            HStack(spacing: 6) {
                let statusIndicator = store.openAIStatus?.indicator ?? "none"
                let isOperational = statusIndicator == "none"
                Circle()
                    .fill(isOperational ? PrismTheme.emerald : PrismTheme.ruby)
                    .frame(width: 7, height: 7)
                Text(isOperational ? "OpenAI OK" : "OpenAI Inc.")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isOperational ? PrismTheme.emerald : PrismTheme.ruby)

                if let outlook = store.resetOutlook {
                    Text("·").foregroundStyle(.tertiary)
                    Text("24H: \(outlook.chance24Hours)%")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(outlook.chance24Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(Capsule().fill(Color.white.opacity(0.07)))

            // Auto-switch quick chip
            HStack(spacing: 5) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(store.autoSwitchWhenExhausted ? PrismTheme.violet : .secondary)

                if store.autoSwitchWhenExhausted, let next = readyCandidates.first {
                    Text("Auto: → \(next.displayName)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PrismTheme.violet)
                        .lineLimit(1)
                } else {
                    Text("Auto-switch: Off")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)

            Spacer(minLength: 2)
        }
        .padding(.top, topNotchClearance)
    }

    private var topNotchClearance: CGFloat {
        let maxInset = NSScreen.screens.map(\.safeAreaInsets.top).max() ?? 0
        return max(maxInset + 16, 50)
    }

    // MARK: - Upper Right Wing (Radar & Telemetry)
    private var upperRightWing: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Radar details & refresh
            HStack {
                Label(language.text("Radar Tibo", "Tibo Radar"), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if let outlook = store.resetOutlook {
                    Text(outlook.windowLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    PrismTheme.triggerHaptic()
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .disabled(store.isBusyForActions)
            }

            // Radar bars (24h & 48h)
            if let outlook = store.resetOutlook {
                HStack(spacing: 8) {
                    miniRadarMetric(title: "24H", percent: outlook.chance24Hours)
                    miniRadarMetric(title: "48H", percent: outlook.chance48Hours)
                }
            }

            // Telemetry line: Today / 7d / VibeCafe
            HStack(spacing: 6) {
                if let summary = store.tokenUsage {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Color.accentColor)
                        Text("\(language.text("Hôm nay", "Today")): \(formatTokenMetric(summary.today, in: language.language))")
                        if let todayCost = summary.todayCostUsd, todayCost > 0 {
                            Text(formatUsdCost(todayCost, in: language.language))
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(PrismTheme.emerald)
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(language.text(
                        "Hôm nay: \(formatFullTokenNumber(summary.today, in: language.language)) token (ước tính \(formatUsdCost(summary.todayCostUsd ?? 0, in: language.language)))",
                        "Today: \(formatFullTokenNumber(summary.today, in: language.language)) tokens (est. \(formatUsdCost(summary.todayCostUsd ?? 0, in: language.language)))"
                    ))

                    Text("·").foregroundStyle(.tertiary)

                    Text("\(language.text("7 ngày", "7d")): \(formatTokenMetric(summary.last7Days, in: language.language))")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(language.text(
                            "7 ngày qua: \(formatFullTokenNumber(summary.last7Days, in: language.language)) token",
                            "Last 7 days: \(formatFullTokenNumber(summary.last7Days, in: language.language)) tokens"
                        ))

                    if let sub = summary.subagentSessions, sub > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        HStack(spacing: 2) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 8.5))
                            Text("\(sub) sub")
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(language.text("\(sub) phiên subagent đã phát hiện", "\(sub) subagent sessions detected"))
                    }
                }

                if let vibe = store.status?.vibeUsage {
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(format: "Vibe: $%.2f", vibe.estimatedCostUsd))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 2)
            }
            .lineLimit(1)
            .padding(.top, 1)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
        )
    }

    // MARK: - Lower Deck: 2-Column Full-Width Account Switchboard
    private var lowerSwitchboardDeck: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header Row: Title, Filter Tabs, Prominent Pin Button, Add Button, Menu
            HStack(spacing: 8) {
                Text(language.text("Danh bạ tài khoản", "Account Roster"))
                    .font(.system(size: 14, weight: .bold))

                Text("(\(store.accounts.count))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                // Filter pills
                filterTab(label: language.text("Tất cả", "All"), filter: nil)
                filterTab(label: language.text("Sẵn sàng", "Ready"), filter: .ready)
                if store.accounts.contains(where: { $0.triage == .needsAction }) {
                    filterTab(label: language.text("Login", "Action"), filter: .needsAction)
                }

                // Prominent Pin Live Pill Button (30pt height)
                Button {
                    PrismTheme.triggerHaptic()
                    withAnimation(PrismTheme.snapSpring) {
                        isPinnedLive.toggle()
                    }
                } label: {
                    HStack(spacing: 4.5) {
                        Image(systemName: isPinnedLive ? "pin.fill" : "pin")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(language.text(isPinnedLive ? "Đang ghim live" : "Ghim live", isPinnedLive ? "Pinned" : "Pin live"))
                            .font(.system(size: 11, weight: isPinnedLive ? .bold : .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(isPinnedLive ? Color.accentColor : Color.white.opacity(0.07))
                            .overlay(Capsule().strokeBorder(isPinnedLive ? Color.accentColor : Color.white.opacity(0.14), lineWidth: 0.8))
                    )
                    .foregroundStyle(isPinnedLive ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [.command])
                .pointingHandCursor()
                .help(language.text("Ghim mở liên tục không tự đóng khi rê chuột ra ngoài (⌘P)", "Pin open continuously without closing on mouse exit (⌘P)"))

                // Add Account Button
                Button {
                    openAddAccountFlow()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(language.text("Thêm tài khoản (⌘N)", "Add account (⌘N)"))

                // Utility Menu
                Menu {
                    Button { openDashboard() } label: {
                        Label(language.text("Mở cửa sổ phụ", "Open detached window"), systemImage: "macwindow")
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
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .pointingHandCursor()
            }

            // 2-Column Account Grid (Cleanly visible with generous spacing)
            ScrollView {
                let columns = [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ]

                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(filteredAccounts) { account in
                        compactGridAccountCard(account, shortcutIndex: switchableShortcutMap[account.id])
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(height: 260)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.8))
        )
    }

    private func filterTab(label: String, filter: AccountTriage?) -> some View {
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

    private func compactGridAccountCard(_ account: SavedAccount, shortcutIndex: Int?) -> some View {
        let quota = account.usage?.fiveHour?.displayRemainingPercent
        let week = account.usage?.weekly?.displayRemainingPercent
        let isJustSwitched = justSwitchedID == account.id

        return HStack(spacing: 8) {
            // Keycap Chip (1..6 for switchable accounts) or Initial
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

            // Name & Email
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

            // Micro Quota Bar & Percent
            // Dual Quota Telemetry (5H & Wk)
            PrismFilamentBar(fivePercent: quota, weekPercent: week, width: 34, height: 3.5, showLabels: true)

            // Action Button
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
                    openReloginFlow()
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
                            justSwitchedID = account.id
                        }
                        store.activate(account, force: true)
                    } label: {
                        Text(language.text("Đổi", "Swap"))
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5.5)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.9))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .keyboardShortcut(KeyEquivalent(Character("\(shortcutIndex)")), modifiers: [])
                } else {
                    Button {
                        PrismTheme.triggerHaptic()
                        withAnimation(PrismTheme.pressFeedback) {
                            justSwitchedID = account.id
                        }
                        store.activate(account, force: true)
                    } label: {
                        Text(language.text("Đổi", "Swap"))
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5.5)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.9))
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
                store.activate(account, force: true)
            } label: {
                Label(language.text("Kích hoạt", "Activate"), systemImage: "bolt.fill")
            }
            Button {
                PrismTheme.triggerHaptic()
                copyAccountEmail(account.email)
            } label: {
                Label(language.text("Sao chép email", "Copy email"), systemImage: "doc.on.doc")
            }
            Button {
                openEditAccount(account)
            } label: {
                Label(language.text("Sửa nhãn", "Edit label"), systemImage: "pencil")
            }
            if account.requiresLogin {
                Button {
                    openReloginFlow()
                } label: {
                    Label(language.text("Đăng nhập lại", "Sign in again"), systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                store.delete(account)
            } label: {
                Label(language.text("Xóa", "Delete"), systemImage: "trash")
            }
        }
    }

    private func miniRadarMetric(title: String, percent: Int) -> some View {
        let tint = percent >= 50 ? PrismTheme.amber : PrismTheme.emerald
        return HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent) / 100.0)))
                }
            }
            .frame(height: 3.5)
            Text("\(percent)%")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.03)))
    }
}
