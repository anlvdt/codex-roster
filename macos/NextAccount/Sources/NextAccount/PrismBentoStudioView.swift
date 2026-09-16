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
        .padding(11)
        .frame(minWidth: 370, idealWidth: 390, maxWidth: 420, minHeight: 420, idealHeight: 450, maxHeight: 480)
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

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(activeAccount?.displayName ?? language.text("Chưa chọn phiên", "No session"))
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)

                        if let plan = activeAccount?.planLabel, !plan.isEmpty {
                            Text(plan.uppercased())
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(activeAccount?.email ?? "—")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let email = activeAccount?.email, !email.isEmpty {
                            CopyEmailButton(email: email, iconSize: 8.5)
                        }
                    }
                }

                Spacer()

                // Sync ChatGPT 1-Click Button
                Button {
                    PrismTheme.triggerHaptic()
                    store.resyncChatGPTDesktop()
                } label: {
                    HStack(spacing: 3) {
                        if store.isWorking || store.isBusyForActions {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(language.text("Đồng bộ", "Sync"))
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
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
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let fivePercent {
                            Text("\(fivePercent)%")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: fivePercent))
                        } else {
                            Text("—").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
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
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let weekPercent {
                            Text("\(weekPercent)%")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(PrismTheme.quotaTint(percent: weekPercent))
                        } else {
                            Text("—").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
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
            HStack(spacing: 8) {
                if let summary = store.tokenUsage {
                    HStack(spacing: 3) {
                        Text(language.text("Hôm nay: \(summary.today)", "Today: \(summary.today)"))
                        if let todayCost = summary.todayCostUsd, todayCost > 0 {
                            Text(String(format: "($%.2f)", todayCost))
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(PrismTheme.emerald)
                        }
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(language.text("7d: \(summary.last7Days)", "7d: \(summary.last7Days)"))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    if let sub = summary.subagentSessions, sub > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        HStack(spacing: 2) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 7.5))
                            Text("\(sub) sub")
                        }
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .help(language.text("\(sub) phiên subagent phát hiện", "\(sub) subagent sessions detected"))
                    }
                }

                if let vibe = store.status?.vibeUsage {
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(format: "Vibe: $%.2f", vibe.estimatedCostUsd))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    PrismTheme.triggerHaptic()
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5))
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
            HStack(spacing: 5) {
                Text(language.text("Tài khoản", "Accounts"))
                    .font(.system(size: 11.5, weight: .bold))

                Text("(\(store.accounts.count))")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                // Filter tabs
                filterTab(label: language.text("Tất cả", "All"), filter: nil)
                filterTab(label: language.text("Sẵn sàng", "Ready"), filter: .ready)
                if store.accounts.contains(where: { $0.triage == .needsAction }) {
                    filterTab(label: language.text("Login", "Action"), filter: .needsAction)
                }

                // Add Account Button
                Button {
                    openAddAccount()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(language.text("Thêm tài khoản (⌘N)", "Add account (⌘N)"))
            }

            // Compact Account List (Row height ~32pt)
            ScrollView {
                LazyVStack(spacing: 3.5) {
                    ForEach(Array(filteredAccounts.enumerated()), id: \.element.id) { index, account in
                        accountRow(account, index: index + 1)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 185)
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
                .font(.system(size: 8.5, weight: isSelected ? .bold : .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.05)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func accountRow(_ account: SavedAccount, index: Int) -> some View {
        let quota = account.usage?.fiveHour?.displayRemainingPercent
        let week = account.usage?.weekly?.displayRemainingPercent

        return HStack(spacing: 6) {
            // Roster Sequence Number
            Text("\(index)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.8))
                .frame(width: 14, alignment: .trailing)

            // Initial Avatar
            Text(String(account.displayName.prefix(1)).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(PrismTheme.quotaTint(percent: quota))
                .frame(width: 18, height: 18)
                .background(Circle().fill(PrismTheme.quotaTint(percent: quota).opacity(0.14)))
            // Name & Email
            VStack(alignment: .leading, spacing: 0.5) {
                Text(account.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(account.email)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    CopyEmailButton(email: account.email, iconSize: 8)
                }
            }

            Spacer(minLength: 2)

            // Dual Quota Telemetry (5H & Wk)
            PrismFilamentBar(fivePercent: quota, weekPercent: week, width: 28, height: 2.5, showLabels: true)

            // Action Button
            if account.isActive {
                Text(language.text("Đang dùng", "Active"))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(PrismTheme.emerald)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(PrismTheme.emerald.opacity(0.16)))
            } else if account.requiresLogin {
                Button {
                    relogin(account)
                } label: {
                    Text(language.text("Login", "Login"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PrismTheme.amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(PrismTheme.amber.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else if !account.usageErrorBlocksActivation {
                Button {
                    PrismTheme.triggerHaptic()
                    store.activate(account, force: true)
                } label: {
                    Text(language.text("Đổi", "Swap"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(account.isActive ? 0.05 : 0.015))
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
                editAccount(account)
            } label: {
                Label(language.text("Sửa nhãn", "Edit label"), systemImage: "pencil")
            }
            if account.requiresLogin {
                Button {
                    relogin(account)
                } label: {
                    Label(language.text("Đăng nhập lại", "Sign in again"), systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                deleteAccount(account)
            } label: {
                Label(language.text("Xóa", "Delete"), systemImage: "trash")
            }
        }
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
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                        Text("24H: \(outlook.chance24Hours)%")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(outlook.chance24Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                    Text("·").foregroundStyle(.tertiary)
                    Text("48H: \(outlook.chance48Hours)%")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(outlook.chance48Hours >= 50 ? PrismTheme.amber : PrismTheme.emerald)
                    }
                }

                Spacer()

                // OpenAI API Health
                HStack(spacing: 4) {
                    let statusIndicator = store.openAIStatus?.indicator ?? "none"
                    let isOperational = statusIndicator == "none"
                    Circle().fill(isOperational ? PrismTheme.emerald : PrismTheme.ruby).frame(width: 5.5, height: 5.5)
                    Text(isOperational ? language.text("OpenAI Bình thường", "OpenAI Normal") : language.text("Sự cố", "Incident"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(isOperational ? PrismTheme.emerald : PrismTheme.ruby)
                }
            }

            Divider().opacity(0.3)

            // Row 2: Auto-Switch & Providers
            HStack(spacing: 8) {
                // Auto-Switch Toggle
                HStack(spacing: 4) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(store.autoSwitchWhenExhausted ? PrismTheme.violet : .secondary)

                    if store.autoSwitchWhenExhausted, let next = readyCandidates.first {
                        Text("→ \(next.displayName)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PrismTheme.violet)
                            .lineLimit(1)
                    } else {
                        Text(language.text("Tự động chuyển: Tắt", "Auto-switch: Off"))
                            .font(.system(size: 9))
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
                        let isLive = store.providerStates.first { $0.provider == provider }?.available == true
                        let count = store.accounts.filter { $0.provider == provider.rawValue }.count
                        HStack(spacing: 2) {
                            Image(systemName: provider.icon)
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(isLive ? PrismTheme.emerald : .secondary)
                            Text("\(count)")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
        }
        .padding(9)
        .prismGlass(cornerRadius: 11)
    }
}
