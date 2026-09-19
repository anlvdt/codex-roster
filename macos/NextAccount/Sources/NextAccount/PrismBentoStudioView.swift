import SwiftUI

/// Compact, elegant Apple-grade companion window for Codex Roster.
/// Measures a pocket-sized 390pt × 450pt with high-density tactile controls.
struct PrismBentoStudioView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selection: UUID?
    let relogin: (SavedAccount) -> Void
    let reloginAll: ([SavedAccount]) -> Void
    var openAddAccount: () -> Void = {}
    var openBackup: (BackupOperation) -> Void = { _ in }
    var editAccount: (SavedAccount) -> Void = { _ in }
    var deleteAccount: (SavedAccount) -> Void = { _ in }

    @State private var rosterFilter: AccountTriage? = nil
    @State private var rosterSearch: String = ""
    @State private var isShowingMetricsTable = false

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

    private var readyCandidates: [SavedAccount] {
        store.accounts
            .filter { !$0.isActive && !$0.archived && !$0.usageErrorBlocksActivation }
            .sorted { ($0.usage?.fiveHour?.displayRemainingPercent ?? 0) > ($1.usage?.fiveHour?.displayRemainingPercent ?? 0) }
    }

    var body: some View {
        VStack(spacing: 8) {
            // 1. Hero Active Session Card
            heroActiveCard

            // 2. Account Roster Switcher Card
            accountRosterCard

            // 3. Radar, Service Health & Automation Card
            radarAndAutomationCard
        }
        .padding(10)
        .frame(width: 415, height: 490)
        .background(
            ZStack {
                (colorScheme == .dark ? PrismTheme.darkBackground : PrismTheme.lightBackground)
                    .ignoresSafeArea()

                RadialGradient(
                    colors: [
                        PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent).opacity(0.06),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 400
                )
                .ignoresSafeArea()
            }
        )
    }

    // MARK: - 1. Hero Active Session Card
    private var heroActiveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top Row: Identity + Sync Button
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent).opacity(0.18))
                        .frame(width: 30, height: 30)

                    Image(systemName: (activeAccount?.aiProvider ?? .openAI).icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent))
                }
                .overlay(
                    Circle().strokeBorder(PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent).opacity(0.35), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(activeAccount?.displayName ?? language.text("Chưa chọn phiên", "No session"))
                            .font(.system(size: 14.5, weight: .bold))
                            .lineLimit(1)

                        if let plan = activeAccount?.planLabel, !plan.isEmpty {
                            Text(plan.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                .foregroundStyle(Color.accentColor)
                        }

                        if let banked = activeAccount?.usage?.bankedResets?.availableCount, banked > 0 {
                            HStack(spacing: 2.5) {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 9))
                                Text("+\(banked) banked")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
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
                                    .font(.system(size: 9))
                                Text(isLunaActive ? "Luna Active" : "Luna Reserve")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
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
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
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

                // Sync ChatGPT 1-Click Button
                Button {
                    PrismTheme.triggerHaptic()
                    store.resyncChatGPTDesktop()
                } label: {
                    HStack(spacing: 4) {
                        if store.isWorking || store.isBusyForActions {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(language.text("Đồng bộ", "Sync"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Divider().opacity(0.3)

            // Quota Display (5-Hour & Weekly)
            HStack(spacing: 12) {
                // 5-Hour Window
                VStack(alignment: .leading, spacing: 3) {
                    let five = activeAccount?.usage?.fiveHour
                    let fivePercent = five?.displayRemainingPercent

                    HStack(alignment: .firstTextBaseline) {
                        Text(language.text("Cửa sổ 5h", "5h window"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let fivePercent {
                            Text("\(fivePercent)%")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                        } else {
                            Text("—").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }

                    PrismSegmentedBar(percent: fivePercent ?? 0, segments: 5, height: 5)

                    if let five {
                        Text(five.resetDescription(in: language.language))
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                // Weekly Allowance
                VStack(alignment: .leading, spacing: 3) {
                    let week = activeAccount?.usage?.weekly
                    let weekPercent = week?.displayRemainingPercent

                    HStack(alignment: .firstTextBaseline) {
                        Text(language.text("Hạn mức tuần", "Weekly"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let weekPercent {
                            Text("\(weekPercent)%")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                        } else {
                            Text("—").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
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
                    .frame(height: 5)

                    if let week {
                        Text(week.resetDescription(in: language.language))
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Minimalist Telemetry Row
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
                        HStack(spacing: 2.5) {
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

                Spacer(minLength: 4)

                Button {
                    PrismTheme.triggerHaptic()
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(store.isBusyForActions)
            }
        }
        .padding(10)
        .prismGlass(cornerRadius: 12)
    }

    // MARK: - 2. Account Roster Switcher Card
    private var accountRosterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header Row: Title, Filter Tabs, Add Button
            HStack(spacing: 6) {
                Text(language.text("Tài khoản", "Accounts"))
                    .font(.system(size: 13, weight: .bold))

                Text("(\(store.accounts.count))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                // Toggle Metrics Table Button
                Button {
                    PrismTheme.triggerHaptic()
                    withAnimation(PrismTheme.snapSpring) {
                        isShowingMetricsTable.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isShowingMetricsTable ? "list.bullet" : "chart.bar.xaxis")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(language.text(
                            isShowingMetricsTable ? "Danh bạ" : "Chỉ số",
                            isShowingMetricsTable ? "Roster" : "Metrics"
                        ))
                        .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(isShowingMetricsTable ? Color.purple : Color.primary.opacity(0.06)))
                    .foregroundStyle(isShowingMetricsTable ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(language.text(
                    isShowingMetricsTable ? "Quay lại danh bạ tài khoản" : "Xem bảng thống kê các chỉ số cần thiết",
                    isShowingMetricsTable ? "Return to account roster" : "View essential metrics statistics table"
                ))

                if !isShowingMetricsTable {
                    // Filter tabs
                    filterTab(label: language.text("Tất cả", "All"), filter: nil)
                    filterTab(label: language.text("Sẵn sàng", "Ready"), filter: .ready)
                    if store.accounts.contains(where: { $0.triage == .needsAction }) {
                        filterTab(label: language.text("Login", "Action"), filter: .needsAction)
                    }
                }
                // Add Account Button
                Button {
                    openAddAccount()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(language.text("Thêm tài khoản (⌘N)", "Add account (⌘N)"))
            }
            .lineLimit(1)

            if isShowingMetricsTable {
                PrismMetricsTableView()
            } else {
                // Compact Account List (Row height ~32pt)
                ScrollView {
                    LazyVStack(spacing: 3.5) {
                        ForEach(Array(filteredAccounts.enumerated()), id: \.element.id) { index, account in
                            PrismAccountRosterRow(
                                account: account,
                                index: index + 1,
                                relogin: relogin,
                                editAccount: editAccount,
                                deleteAccount: deleteAccount
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: 195)
            }
        }
        .padding(10)
        .prismGlass(cornerRadius: 12)
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
                .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.05)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - 3. Radar, Service Health & Automation Card
    private var radarAndAutomationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: Tibo Radar & OpenAI API Status
            HStack(spacing: 8) {
                // Tibo Radar
                if let outlook = store.resetOutlook {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("24H: \(outlook.chance24Hours)%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(outlook.chance24Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                    Text("·").foregroundStyle(.tertiary)
                    Text("48H: \(outlook.chance48Hours)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(outlook.chance48Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                    }
                }

                Spacer()

                // OpenAI API Health
                HStack(spacing: 4) {
                    let statusIndicator = store.openAIStatus?.indicator ?? "none"
                    let isOperational = statusIndicator == "none"
                    Circle().fill(isOperational ? PrismTheme.emerald : PrismTheme.ruby).frame(width: 6.5, height: 6.5)
                    Text(isOperational ? language.text("OpenAI Bình thường", "OpenAI Normal") : language.text("Sự cố", "Incident"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isOperational ? PrismTheme.emerald : PrismTheme.ruby)
                }
            }

            Divider().opacity(0.3)

            // Row 2: Auto-Switch & Providers
            HStack(spacing: 8) {
                // Auto-Switch Toggle
                HStack(spacing: 5) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(store.autoSwitchWhenExhausted ? PrismTheme.violet : .secondary)

                    if store.autoSwitchWhenExhausted, let next = readyCandidates.first {
                        Text(language.text("Tự chuyển ➔ \(next.displayName)", "Auto-swap ➔ \(next.displayName)"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(PrismTheme.violet)
                            .lineLimit(1)
                            .help(language.text("Tự động chuyển sang \(next.displayName) khi tài khoản hiện tại hết quota", "Auto-switch to \(next.displayName) when active quota is exhausted"))
                    } else {
                        Text(language.text("Tự chuyển: Tắt", "Auto-swap: Off"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }

                    Toggle("", isOn: Binding(
                        get: { store.autoSwitchWhenExhausted },
                        set: { store.setAutoSwitchWhenExhausted($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                Spacer()

                // 4 Provider badges
                HStack(spacing: 3) {
                    ForEach(AIProvider.allCases) { provider in
                        providerBadge(provider)
                    }
                }
            }
        }
        .padding(11)
        .prismGlass(cornerRadius: 11)
    }

    private func providerBadge(_ provider: AIProvider) -> some View {
        let isLive = store.providerStates.first { $0.provider == provider }?.available == true
        let count = store.accounts.filter { $0.provider == provider.rawValue }.count
        return HStack(spacing: 2.5) {
            Image(systemName: provider.icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isLive ? PrismTheme.emerald : .secondary)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
        .help("\(provider.compactName): \(count) \(language.text("tài khoản", "accounts"))")
    }
}

/// Dedicated row view so LazyVStack context menus capture this row's account ID,
/// not a recycled parent-helper closure from another roster row.
private struct PrismAccountRosterRow: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    let account: SavedAccount
    let index: Int
    let relogin: (SavedAccount) -> Void
    let editAccount: (SavedAccount) -> Void
    let deleteAccount: (SavedAccount) -> Void

    var body: some View {
        // Freeze the row identity for menu actions — never use selection or list index.
        let targetID = account.id
        let quota = account.usage?.fiveHour?.displayRemainingPercent
        let week = account.usage?.weekly?.displayRemainingPercent

        return HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.8))
                .frame(width: 16, alignment: .trailing)

            Text(String(account.displayName.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(PrismTheme.quotaTint(percent: quota))
                .frame(width: 24, height: 24)
                .background(Circle().fill(PrismTheme.quotaTint(percent: quota).opacity(0.14)))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)

                    if let banked = account.usage?.bankedResets?.availableCount, banked > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.system(size: 8))
                            Text("+\(banked)")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
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
                            isLunaActive ? "Codex đang chạy Luna Reserve" : "Tài khoản có Luna Reserve",
                            isLunaActive ? "Codex active on Luna Reserve" : "Account has Luna Reserve"
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

            PrismFilamentBar(fivePercent: quota, weekPercent: week, width: 32, height: 3, showLabels: true)

            if account.isActive {
                Text(language.text("Đang dùng", "Active"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PrismTheme.emerald)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(PrismTheme.emerald.opacity(0.16)))
            } else if account.requiresLogin {
                Button {
                    guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                    relogin(target)
                } label: {
                    Text(language.text("Login", "Login"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PrismTheme.amber)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(PrismTheme.amber.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else if !account.usageErrorBlocksActivation {
                Button {
                    PrismTheme.triggerHaptic()
                    guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                    store.activate(target, force: true)
                } label: {
                    Text(language.text("Đổi", "Swap"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(account.isActive ? 0.05 : 0.015))
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
                editAccount(target)
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
                    guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                    relogin(target)
                } label: {
                    Label(language.text("Đăng nhập lại", "Sign in again"), systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                guard let target = accountForContextMenuAction(in: store.accounts, capturedID: targetID) else { return }
                deleteAccount(target)
            } label: {
                Label(language.text("Xóa", "Delete"), systemImage: "trash")
            }
        }
        .id(targetID)
    }
}
