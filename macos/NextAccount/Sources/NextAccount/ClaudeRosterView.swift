import SwiftUI

/// Claude Code account deck shared by the notch and Roster Console.
struct ClaudeRosterView: View {
    var notchLayout = false
    var notchNavigationWidth: CGFloat = 156
    var onQuotaGuidePresentationChanged: (Bool) -> Void = { _ in }
    var onInteractionPresentationChanged: (Bool) -> Void = { _ in }

    static let notchStatusLineHeight: CGFloat = 16
    static let notchStatusRowHeight: CGFloat = notchStatusLineHeight + 7

    static func notchShowsQuotaCaption(account: ProviderAccount?) -> Bool {
        guard let account else { return false }
        return !account.hasFreshUsage || account.usage?.detail?.hasPrefix("Claude Code statusline") == true
    }

    static func notchDeckHeight(accountCount: Int, hasQuotaCaption: Bool = false, hasMessage: Bool = false) -> CGFloat {
        let rows = max(1, (accountCount + 1) / 2)
        // Match the wings, toolbar and insets; reserve no empty space below cards.
        let statusHeight = CGFloat((hasQuotaCaption ? 1 : 0) + (hasMessage ? 1 : 0)) * notchStatusRowHeight
        let chrome: CGFloat = 150 + statusHeight + NotchRosterLayout.deckTopInset
            + NotchRosterLayout.deckBottomInset + NotchRosterLayout.deckSectionSpacing
            + NotchRosterLayout.switchboardHeaderHeight + 7
            + NotchRosterLayout.switchboardTopInset + NotchRosterLayout.switchboardBottomInset
        let rosterHeight = CGFloat(rows) * NotchRosterLayout.rowHeight
            + CGFloat(rows - 1) * NotchRosterLayout.rowSpacing
        return min(NotchRosterLayout.collapsedDeckHeight, chrome + rosterHeight)
    }
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    @State private var deleteTarget: ProviderAccount?
    @State private var labelTarget: ProviderAccount?
    @State private var detailsTarget: ProviderAccount?
    @State private var labelDraft = ""
    @State private var accountFilter: AccountFilter = .all
    @State private var showAddGuide = false
    @State private var showQuotaGuide = false
    @State private var quotaBridgeMessage: String?
    @State private var loginEmail = ""
    @State private var loginTask: Task<Void, Never>?
    @State private var loginInProgress = false
    @State private var loginMessage: String?
    @State private var loginSucceeded = false

    private var hasPresentedInteraction: Bool {
        deleteTarget != nil || labelTarget != nil
            || detailsTarget != nil || showAddGuide
            || store.claudeErrorMessage != nil
    }

    private enum AccountFilter: String, CaseIterable {
        case all, ready, action
    }

    private var liveState: ProviderState? {
        store.providerStates.first { $0.provider == .claude }
    }

    private var sortedAccounts: [ProviderAccount] {
        store.claudeAccounts.filter { account in
            let matchesFilter: Bool
            switch accountFilter {
            case .all: matchesFilter = true
            case .ready: matchesFilter = !account.isActive && account.canActivate
                && account.hasFreshUsage
                && (account.bindingUtilization ?? 100) < 95
            case .action: matchesFilter = account.requiresResave
                || account.requiresLogin || account.usageError != nil
                || account.usage?.status != "ok" || !account.hasFreshUsage
            }
            return matchesFilter
        }.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.requiresLogin != rhs.requiresLogin { return !lhs.requiresLogin }
            return (lhs.bindingUtilization ?? 0) < (rhs.bindingUtilization ?? 0)
        }
    }

    var body: some View {
        Group {
            if notchLayout {
                notchDeck
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: RosterSecondaryChrome.sectionSpacing) {
                        header
                        liveSummary
                        quotaDetailsPanel
                        accountsSection
                    }
                    .rosterSecondaryPadding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .rosterSecondaryContent()
            }
        }
        .onAppear {
            store.claudeTabDidAppear()
            store.refreshProviderStatus(silently: true)
        }
        .onChange(of: hasPresentedInteraction) { _, shown in
            onInteractionPresentationChanged(shown)
        }
        .alert(
            language.text("Claude cần xử lý", "Claude needs attention"),
            isPresented: Binding(
                get: { store.claudeErrorMessage != nil },
                set: { if !$0 { store.dismissClaudeError() } }
            )
        ) {
            Button(language.text("Đã hiểu", "OK")) {
                store.dismissClaudeError()
            }
        } message: {
            Text(store.claudeErrorMessage ?? "")
        }
        .confirmationDialog(
            language.text("Xóa tài khoản đã lưu?", "Delete saved account?"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = deleteTarget {
                let id = target.id
                Button(language.text("Xóa", "Delete"), role: .destructive) {
                    store.deleteClaudeAccount(id)
                }
            }
            Button(language.text("Hủy", "Cancel"), role: .cancel) {}
        } message: {
            if let target = deleteTarget {
                Text(language.text(
                    "Xóa \(target.displayName) khỏi danh bạ (không ảnh hưởng phiên Claude Code đang chạy).",
                    "Remove \(target.displayName) from the roster (the live Claude Code session is unaffected)."
                ))
            }
        }
        .sheet(item: $labelTarget) { account in
            labelSheet(account)
        }
        .sheet(isPresented: $showAddGuide) {
            addAccountGuide
                .preferredColorScheme(.dark)
        }
        .onChange(of: showAddGuide) { _, shown in
            if !shown { loginTask?.cancel() }
        }
    }

    // Quota and reset details frame the camera,
    // while the account switchboard keeps its toolbar visible during scrolling.
    private var notchDeck: some View {
        VStack(spacing: NotchRosterLayout.deckSectionSpacing) {
            HStack(alignment: .top, spacing: 8) {
                notchLiveWing.frame(maxWidth: .infinity, alignment: .topLeading)
                Color.clear
                    .frame(width: max(NotchGeometry.detect().cameraWidth, notchNavigationWidth))
                quotaDetailsPanel.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 150 + (Self.notchShowsQuotaCaption(account: store.claudeAccounts.first(where: \.isActive))
                ? Self.notchStatusRowHeight : 0), alignment: .top)

            notchSwitchboard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, NotchRosterLayout.deckHorizontalInset)
        .padding(.top, NotchRosterLayout.deckTopInset)
        .padding(.bottom, NotchRosterLayout.deckBottomInset)
        .frame(width: NotchRosterLayout.deckWidth,
               height: Self.notchDeckHeight(
                accountCount: store.claudeAccounts.count,
                hasQuotaCaption: store.claudeLiveAuthStatus?.subscriptionEmail == nil || Self.notchShowsQuotaCaption(account: store.claudeAccounts.first(where: \.isActive)),
                hasMessage: store.claudeSwitchMessage != nil),
               alignment: .top)
    }

    private func liveQuotaBadge(_ account: ProviderAccount?) -> some View {
        let verified = account.map {
            store.claudeLiveAuthStatus?.verifiesQuota(email: $0.email, fresh: $0.hasFreshUsage) == true
        } ?? false
        let text = verified ? language.text("Trực tiếp", "Live")
            : store.claudeLiveAuthStatus == nil ? language.text("Đang kiểm tra", "Checking")
            : store.claudeLiveAuthStatus?.subscriptionEmail == nil ? language.text("Chưa đăng nhập", "Not signed in")
            : language.text("Quota đã lưu", "Cached quota")
        return chip(text, tint: verified ? PrismTheme.emerald : PrismTheme.amber)
    }

    private var notchLiveWing: some View {
        let active = store.claudeAccounts.first(where: \.isActive)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "brain.head.profile")
                    .font(PrismTheme.fontCaptionBold)
                    .foregroundStyle(PrismTheme.emerald)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(PrismTheme.chipFill(PrismTheme.emerald)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        // Long org names ("…'s Organization") wrap to a second
                        // line instead of truncating into "Organi…".
                        Text(active?.shortDisplayName ?? "Claude Code")
                            .font(PrismTheme.fontHeadline)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                        if let plan = active?.planLabel, !plan.isEmpty {
                            chip(plan, tint: PrismTheme.accent)
                        }
                    }
                    if let email = active?.email ?? liveState?.identity?.email {
                        Text(email)
                            .font(PrismTheme.fontCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(language.text("Chưa đăng nhập", "Not signed in"))
                            .font(PrismTheme.fontCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                liveQuotaBadge(active)
            }
            if let active {
                if let window = active.window("five_hour") { summaryQuota(window, label: "5h") }
                if let window = active.window("seven_day") { summaryQuota(window, label: "7d") }
                if !active.hasFreshUsage || store.claudeLiveAuthStatus?.subscriptionEmail == nil {
                    HStack(spacing: 4) {
                        Text(quotaWarning(active))
                            .font(PrismTheme.fontMicro).foregroundStyle(.secondary).lineLimit(1)
                            .help(quotaWarning(active))
                        Spacer(minLength: 0)
                        if store.claudeLiveAuthStatus?.subscriptionEmail == nil {
                            Button(language.text("Đăng nhập", "Sign in")) { store.signInLiveClaude() }
                                .buttonStyle(.borderless).font(PrismTheme.fontMicro)
                                .disabled(store.isSigningInLiveClaude)
                        }
                    }
                    .frame(height: Self.notchStatusLineHeight, alignment: .leading)
                } else if active.usage?.detail?.hasPrefix("Claude Code statusline") == true {
                    Text(language.text("Quota từ CLI · quan sát cục bộ", "CLI quota · local observation"))
                        .font(PrismTheme.fontMicro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: Self.notchStatusLineHeight, alignment: .leading)
                }
            } else {
                HStack {
                    Text(language.text("App tự nhận đăng nhập Claude Code.", "Claude Code login is detected automatically."))
                        .font(PrismTheme.fontCaption).foregroundStyle(.secondary)
                    Button(language.text("Đăng nhập", "Sign in")) { store.signInLiveClaude() }
                        .disabled(store.isSigningInLiveClaude)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(notchWingShape)
    }

    private var quotaDetailsPanel: some View {
        let account = store.claudeAccounts.first(where: \.isActive)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(language.text("Tổng quan sử dụng", "Usage overview"), systemImage: "chart.bar")
                    .font(PrismTheme.fontBodyCompactBold)
                Spacer(minLength: 4)
                Button("CLI quota") { showQuotaGuide = true }
                    .buttonStyle(.plain).foregroundStyle(PrismTheme.accent)
                    .popover(isPresented: $showQuotaGuide) {
                        quotaGuide.background(PrismTheme.notchShell).preferredColorScheme(.dark)
                    }
                    .onChange(of: showQuotaGuide) { _, shown in onQuotaGuidePresentationChanged(shown) }
            }
            quotaOverviewRow(account?.window("five_hour"), title: language.text("5 giờ", "5-hour"))
            quotaOverviewRow(account?.window("seven_day"), title: language.text("Tuần", "Weekly"))
            if let monthly = account?.window("extra_usage") {
                Text(extraWindowText(monthly))
                    .font(PrismTheme.fontCaption).foregroundStyle(.secondary)
                Text(language.text("Hạn mức chi tiêu thêm, không phải quota token tháng.",
                                   "Extra spending cap, not a monthly token quota."))
                    .font(PrismTheme.fontMicro).foregroundStyle(.secondary)
            } else {
                Text(language.text("Tháng: chưa có dữ liệu", "Monthly: no data available"))
                    .font(PrismTheme.fontCaption).foregroundStyle(.secondary)
            }
            Text(language.text("Banked reset: chưa có dữ liệu Claude", "Banked resets: no Claude data available"))
                .font(PrismTheme.fontCaption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: notchLayout ? .infinity : nil, alignment: .topLeading)
        .background(notchWingShape)
    }

    private func quotaOverviewRow(_ window: ProviderUsageWindow?, title: String) -> some View {
        let used = window?.usedPercent
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).frame(width: 48, alignment: .leading)
                ProgressView(value: Double(min(100, max(0, used ?? 0))), total: 100)
                    .tint((used ?? 0) >= 90 ? PrismTheme.danger : PrismTheme.titanium)
                Text(used.map { language.text("\($0)% đã dùng", "\($0)% used") }
                    ?? language.text("Chưa có dữ liệu", "No data"))
                    .fixedSize()
            }
            .font(PrismTheme.fontCaption)
            Text(window?.resetDescription(in: language.language)
                ?? language.text("Chưa có mốc reset", "Reset time unavailable"))
                .font(PrismTheme.fontMicro).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var quotaGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("Quota & đặt lại", "Quota & resets"))
                .font(PrismTheme.fontSection)
            Text(language.text(
                "Cần đăng nhập Claude Code trong Terminal bằng cùng tài khoản. Đăng nhập Claude Desktop riêng không kết nối quota CLI. App tự phát hiện đăng nhập và lưu tài khoản để theo dõi quota.",
                "Sign in to Claude Code in Terminal with the same account. Claude Desktop login alone does not connect CLI quota. The app detects your login and saves the account automatically."))
            Text("claude auth login")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text(language.text(
                "Đọc quota 5 giờ/7 ngày từ status line chính thức của CLI, không gọi API liên tục. Giữ nguyên status line hiện có. Dữ liệu chỉ được xác minh khi còn mới và khớp tài khoản.",
                "Read 5-hour/7-day quota from the CLI's official status line without repeated API calls. Your existing status line is preserved. Data is verified only while fresh and matched to the account."))
            Button(language.text("Kết nối quota CLI", "Connect CLI quota")) {
                Task { @MainActor in
                    do {
                        try await ClaudeQuotaBridgeInstaller.install()
                        quotaBridgeMessage = language.text(
                            "Đã kết nối. Mở phiên CLI mới hoặc resume trong tiến trình mới; quota xuất hiện sau phản hồi đầu tiên.",
                            "Connected. Start a fresh CLI process or resume in one; quota appears after the first response.")
                    } catch { quotaBridgeMessage = error.localizedDescription }
                }
            }
            if let quotaBridgeMessage { Text(quotaBridgeMessage).foregroundStyle(.secondary) }
            Link(language.text("Tài liệu Claude Code", "Claude Code documentation"),
                 destination: URL(string: "https://code.claude.com/docs/en/statusline")!)
        }
        .font(PrismTheme.fontBodyCompact)
        .padding(16)
        .frame(width: 380)
    }

    private var notchWingShape: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(PrismTheme.surfacePanel)
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(PrismTheme.surfaceFill, lineWidth: 0.8))
    }

    private var notchSwitchboard: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let message = store.claudeSwitchMessage {
                Text(message)
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(PrismTheme.amber)
                    .lineLimit(1)
                    .frame(height: Self.notchStatusLineHeight, alignment: .leading)
                    .help(message)
            }
            HStack(spacing: 8) {
                Text(language.text("Danh bạ", "Roster"))
                    .font(PrismTheme.fontSection)
                Text("\(sortedAccounts.count)/\(store.claudeAccounts.count)")
                    .font(PrismTheme.fontMono)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(PrismTheme.surfaceSoft))
                Spacer(minLength: 4)
                ForEach(AccountFilter.allCases, id: \.self) { filter in
                    Button {
                        accountFilter = filter
                    } label: {
                        Text(filterTitle(filter))
                            .font(PrismTheme.fontChip)
                            .foregroundStyle(accountFilter == filter ? PrismTheme.textPrimary : PrismTheme.textBright)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 28)
                            .background(Capsule().fill(accountFilter == filter ? PrismTheme.surfaceStrong : PrismTheme.surfaceQuiet))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityAddTraits(accountFilter == filter ? .isSelected : [])
                }
                Button { store.saveLiveClaudeAccount() } label: {
                    Group {
                        if store.isSavingClaude { ProgressView().controlSize(.small) }
                        else { Image(systemName: "square.and.arrow.down") }
                    }.frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .disabled(store.isSavingClaude)
                .help(language.text("Lưu tài khoản đang đăng nhập", "Save signed-in account"))
                .accessibilityLabel(language.text("Lưu tài khoản đang đăng nhập", "Save signed-in account"))
                Button { showAddGuide = true } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .help(language.text("Thêm tài khoản", "Add account"))
                    .accessibilityLabel(language.text("Thêm tài khoản", "Add account"))
                Button { store.refreshClaudeUsage(force: true) } label: {
                    Group {
                        if store.isLoadingClaude { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .disabled(store.isLoadingClaude)
                .help(language.text("Làm mới quota", "Refresh quota"))
                .accessibilityLabel(language.text("Làm mới quota", "Refresh quota"))
            }
            .buttonStyle(.plain)
            .font(PrismTheme.fontBodyCompactBold)

            ScrollView {
                if sortedAccounts.isEmpty {
                    emptyAccountsState
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: NotchRosterLayout.columnSpacing),
                                        GridItem(.flexible(), spacing: NotchRosterLayout.columnSpacing)],
                              spacing: NotchRosterLayout.rowSpacing) {
                        ForEach(sortedAccounts) { account in notchAccountCard(account) }
                    }
                }
            }
        }
        .padding(.horizontal, NotchRosterLayout.switchboardHorizontalInset)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(PrismTheme.surfaceQuiet)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PrismTheme.borderSubtle, lineWidth: 0.8)))
        .popover(item: $detailsTarget, arrowEdge: .trailing) { account in
            accountRow(account)
                .frame(width: 440)
                .padding(8)
                .background(PrismTheme.notchShell)
                .foregroundStyle(PrismTheme.textPrimary)
                .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func accountSignInButton(_ account: ProviderAccount) -> some View {
        let signingIn = store.isSigningInLiveClaude && store.claudeSignInAccountID == account.id
        let state = ClaudeAccountLoginState.resolve(status: store.claudeLiveAuthStatus, email: account.email)
        if state == .signedIn && !store.isSigningInLiveClaude {
            Label(language.text("Đã đăng nhập CLI", "Signed in to CLI"), systemImage: "checkmark.circle.fill")
                .font(PrismTheme.fontCaptionBold)
                .foregroundStyle(PrismTheme.emerald)
                .fixedSize()
                .help(language.text("Claude Code xác nhận phiên đăng nhập bằng \(account.email). Quota có trạng thái cập nhật riêng.",
                                    "Claude Code confirms a signed-in session as \(account.email). Quota freshness is separate."))
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                Text(language.text(
                    store.isSigningInLiveClaude ? "Đang xác minh phiên…" : state == .signedOut ? "Chưa đăng nhập CLI" : state == .otherSession ? "Không phải phiên CLI hiện tại" : "Chưa xác minh đăng nhập",
                    store.isSigningInLiveClaude ? "Verifying session…" : state == .signedOut ? "Not signed in to CLI" : state == .otherSession ? "Not the current CLI session" : "Login unverified"))
                    .font(PrismTheme.fontMicro)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button { store.signInLiveClaude(account: account) } label: {
                    Label(language.text(signingIn ? "Đang đăng nhập…" : "Đăng nhập",
                                        signingIn ? "Signing in…" : "Sign in"),
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(PrismTheme.accent)
                .controlSize(.small)
                .fixedSize()
                .disabled(store.isSigningInLiveClaude || store.isSwitchingClaude || store.isSavingClaude)
                .help(language.text("Đăng nhập Claude Code bằng \(account.email)", "Sign in to Claude Code as \(account.email)"))
                .accessibilityLabel(language.text("Đăng nhập \(account.email)", "Sign in as \(account.email)"))
            }
        }
    }

    private func notchAccountCard(_ account: ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(String(account.displayName.prefix(1)).uppercased())
                    .font(PrismTheme.fontAvatar)
                    .foregroundStyle(account.isActive ? PrismTheme.emerald : PrismTheme.titanium)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(PrismTheme.surfaceStrong))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.shortDisplayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(account.email)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accountSignInButton(account)
                Button { detailsTarget = account } label: {
                    Image(systemName: account.requiresResave || account.requiresLogin ? "exclamationmark.circle" : "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(account.requiresResave || account.requiresLogin ? PrismTheme.amber : PrismTheme.textBright)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(language.text("Chi tiết tài khoản và quota", "Account and quota details"))
                .accessibilityLabel(language.text("Chi tiết \(account.displayName)", "Details for \(account.displayName)"))
            }
            HStack(spacing: 16) {
                notchQuotaLabel(account, key: "five_hour", title: "5h")
                notchQuotaLabel(account, key: "seven_day", title: "7d")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NotchRosterLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(account.isActive ? PrismTheme.emerald.opacity(0.06) : PrismTheme.surfaceSoft)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(account.isActive ? PrismTheme.emerald.opacity(0.65) : PrismTheme.borderSoft,
                              lineWidth: 1)))
    }

    private func notchQuotaLabel(_ account: ProviderAccount, key: String, title: String) -> some View {
        RosterQuotaMeter(
            title: title,
            remaining: account.window(key)?.remainingPercent,
            remainingLabel: language.text("Quota còn lại", "Remaining quota")
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Claude Code", systemImage: "brain.head.profile")
                .font(RosterSecondaryChrome.title)
            if let identity = liveState?.identity {
                Text(identity.email + (liveState.flatMap { _ in planSuffix } ?? ""))
                    .font(RosterSecondaryChrome.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(language.text(
                    "Chưa đọc được phiên Claude Code đang đăng nhập.",
                    "No signed-in Claude Code session detected."
                ))
                .font(RosterSecondaryChrome.callout)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if store.claudeLiveAuthStatus?.subscriptionEmail == nil {
                    Button(language.text("Đăng nhập", "Sign in")) { store.signInLiveClaude() }
                        .disabled(store.isSigningInLiveClaude)
                } else {
                    Text(language.text("Tự đồng bộ tài khoản", "Account sync is automatic"))
                        .font(RosterSecondaryChrome.footnote).foregroundStyle(.secondary)
                }
                Button {
                    showAddGuide = true
                } label: {
                    Label(language.text("Thêm tài khoản", "Add account"), systemImage: "plus")
                }
                Button {
                    store.refreshClaudeUsage(force: true)
                } label: {
                    HStack(spacing: 5) {
                        if store.isLoadingClaude {
                            ProgressView().controlSize(.mini)
                        }
                        Text(language.text("Làm mới", "Refresh"))
                    }
                }
                .disabled(store.isLoadingClaude)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    private var planSuffix: String {
        guard let plan = store.claudeAccounts.first(where: { $0.isActive })?.planLabel,
              !plan.isEmpty else { return "" }
        return " · \(plan)"
    }

    private var liveSummary: some View {
        let active = store.claudeAccounts.first(where: \.isActive)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text("Đăng nhập CLI đã lưu", "Saved CLI login"))
                    .font(RosterSecondaryChrome.section)
                Text(active?.shortDisplayName ?? language.text("Chưa lưu", "Not saved"))
                    .font(RosterSecondaryChrome.body.weight(.semibold))
                if let active {
                    Text(active.email)
                        .font(RosterSecondaryChrome.footnote)
                        .foregroundStyle(.secondary)
                    if let window = active.window("five_hour") {
                        summaryQuota(window, label: "5h")
                    }
                    if let window = active.window("seven_day") {
                        summaryQuota(window, label: "7d")
                    }
                    if !active.hasFreshUsage {
                        Text(quotaWarning(active))
                            .font(RosterSecondaryChrome.micro)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text("Danh bạ", "Roster"))
                    .font(RosterSecondaryChrome.section)
                Text("\(store.claudeAccounts.count) " + language.text("tài khoản", "accounts"))
                    .font(RosterSecondaryChrome.body.weight(.semibold))
                Text("\(store.claudeAccounts.filter { $0.canActivate && !$0.isActive }.count) "
                    + language.text("có thể chuyển", "switchable"))
                    .font(RosterSecondaryChrome.footnote)
                Text("\(store.claudeAccounts.filter { !$0.canActivate }.count) "
                    + language.text("cần lưu lại", "need re-save"))
                    .font(RosterSecondaryChrome.footnote)
                    .foregroundStyle(PrismTheme.amber)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RosterSecondaryChrome.cardFill,
                    in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius))
    }

    private func quotaWarning(_ account: ProviderAccount) -> String {
        if store.claudeLiveAuthStatus?.subscriptionEmail == nil {
            return store.claudeDetectionMessage ?? language.text(
                "Chờ đăng nhập Claude Code · app sẽ tự đồng bộ", "Waiting for Claude Code login · automatic sync enabled")
        }
        if account.usageError?.contains("claude_cli_auth_missing:") == true
            || account.usageError?.contains("OAuth access token not found") == true {
            return language.text("CLI chưa đăng nhập · bấm Đăng nhập; app sẽ tự đồng bộ",
                "CLI not signed in · click Sign in; the app syncs automatically")
        }
        if account.usageError?.contains("HTTP 429") == true {
            return language.text("API quota giới hạn yêu cầu (429) · đang chờ thử lại",
                "Quota API rate limited (429) · waiting to retry")
        }
        return language.text("Quota đã lưu · chưa xác minh trực tiếp", "Saved quota · not verified live")
    }

    private func summaryQuota(_ window: ProviderUsageWindow, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            RosterQuotaMeter(
                title: label ?? window.label,
                remaining: window.remainingPercent ?? window.usedPercent.map { max(0, 100 - $0) },
                remainingLabel: language.text("Quota còn lại", "Remaining quota")
            )
            if let reset = window.resetDescription(in: language.language) {
                Text(reset)
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var addAccountGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("Thêm tài khoản Claude Code", "Add Claude Code account"))
                .font(RosterSecondaryChrome.title)
            Text(language.text("Đăng nhập trong trình duyệt. App tự xác minh và lưu từng tài khoản; tài khoản đang dùng được giữ nguyên.",
                "Sign in in your browser. The app verifies and saves each account while keeping your current account."))
            TextField(language.text("Email tài khoản (không bắt buộc)", "Account email (optional)"), text: $loginEmail)
                .textFieldStyle(.roundedBorder)
                .disabled(loginInProgress)
            if loginInProgress {
                HStack { ProgressView().controlSize(.small)
                    Text(language.text("Hoàn tất đăng nhập trong trình duyệt…", "Complete sign-in in your browser…")) }
            }
            if let loginMessage {
                Text(loginMessage).foregroundStyle(loginSucceeded ? PrismTheme.emerald : PrismTheme.amber)
                    .textSelection(.enabled)
            }
            HStack {
                Button(language.text("Lưu CLI đang đăng nhập", "Save current CLI login")) { store.saveLiveClaudeAccount() }
                    .disabled(loginInProgress)
                Spacer(minLength: 8)
                Button(language.text(loginInProgress ? "Hủy" : "Đóng", loginInProgress ? "Cancel" : "Close")) {
                    loginTask?.cancel()
                    showAddGuide = false
                }
                Button(language.text(loginSucceeded ? "Thêm tài khoản khác" : "Đăng nhập", loginSucceeded ? "Add another account" : "Sign in")) {
                    loginInProgress = true
                    loginSucceeded = false
                    loginMessage = nil
                    let email = loginEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                    loginTask = Task { @MainActor in
                        defer { loginInProgress = false }
                        do {
                            let savedEmail = try await ClaudeCLIEnrollment.login(email: email)
                            loginSucceeded = true
                            loginEmail = ""
                            loginMessage = language.text("Đã lưu \(savedEmail). Sẵn sàng theo dõi quota.",
                                "Saved \(savedEmail). Quota monitoring is ready.")
                            store.refreshClaudeRoster(silently: true)
                        } catch is CancellationError { }
                        catch { loginMessage = error.localizedDescription }
                    }
                }
                .disabled(loginInProgress)
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(RosterSecondaryChrome.caption)
        .padding(20)
        .frame(width: 520)
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: RosterSecondaryChrome.blockSpacing) {
            HStack {
                Text(language.text("Tài khoản đã lưu", "Saved accounts"))
                    .font(RosterSecondaryChrome.section)
                Text("\(sortedAccounts.count)/\(store.claudeAccounts.count)")
                    .font(RosterSecondaryChrome.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(AccountFilter.allCases, id: \.self) { filter in
                    Button(filterTitle(filter)) {
                        accountFilter = filter
                    }
                    .buttonStyle(.bordered)
                    .tint(accountFilter == filter ? .accentColor : .gray)
                    .accessibilityAddTraits(accountFilter == filter ? .isSelected : [])
                }
            }
            if sortedAccounts.isEmpty {
                emptyAccountsState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 390), spacing: 10)], spacing: 10) {
                    ForEach(sortedAccounts) { account in
                        accountRow(account)
                    }
                }
            }
        }
    }

    private func filterTitle(_ filter: AccountFilter) -> String {
        switch filter {
        case .all: language.text("Tất cả", "All")
        case .ready: language.text("Sẵn sàng", "Ready")
        case .action: language.text("Cần xử lý", "Action")
        }
    }

    private var emptyAccountsState: some View {
        RosterEmptyState(
            title: store.claudeAccounts.isEmpty
                ? language.text("Chưa có tài khoản Claude", "No saved Claude accounts")
                : language.text("Không có tài khoản phù hợp", "No matching accounts"),
            detail: store.claudeAccounts.isEmpty
                ? language.text("Đăng nhập Claude Code, rồi lưu tài khoản để theo dõi quota.", "Sign in to Claude Code, then save the account to track quota.")
                : language.text("Không có tài khoản trong trạng thái này. Xem lại tất cả tài khoản.", "No accounts in this state. View all saved accounts."),
            actionTitle: store.claudeAccounts.isEmpty
                ? language.text("Hướng dẫn thêm", "Add account guide")
                : language.text("Xem tất cả", "Show all")
        ) {
            if store.claudeAccounts.isEmpty {
                showAddGuide = true
            } else {
                accountFilter = .all
            }
        }
    }

    private func accountRow(_ account: ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(account.displayName)
                    .font(RosterSecondaryChrome.body.weight(.semibold))
                    .lineLimit(1)
                if account.isActive {
                    chip(language.text("Đang chọn", "Selected"), tint: PrismTheme.emerald)
                }
                if let plan = account.planLabel, !plan.isEmpty {
                    chip(plan, tint: PrismTheme.titanium)
                }
                statusChip(account)
                Spacer(minLength: 0)
                accountSignInButton(account)
                Menu {
                    Button(language.text("Đặt nhãn", "Set label"), systemImage: "pencil") {
                        labelDraft = account.customLabel ?? ""
                        labelTarget = account
                    }
                    Button(language.text("Xóa tài khoản", "Delete account"), systemImage: "trash", role: .destructive) {
                        deleteTarget = account
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .accessibilityLabel(language.text("Tác vụ tài khoản", "Account actions"))
            }
            Text(account.email)
                .font(RosterSecondaryChrome.footnote)
                .foregroundStyle(.secondary)

            usageBar(account, key: "five_hour")
            usageBar(account, key: "seven_day")
            usageBar(account, key: "seven_day_sonnet")
            usageBar(account, key: "seven_day_opus")

            ForEach(account.extraWindows.filter { $0.key == "extra_usage" }) { window in
                Text(extraWindowText(window))
                    .font(RosterSecondaryChrome.footnote)
                    .foregroundStyle(.secondary)
            }
            if account.window("extra_usage") != nil {
                Text(language.text(
                    "Số còn lại là khoảng trống tới hạn mức chi tiêu tháng, không phải số dư credit nạp trước.",
                    "Remaining is headroom to the monthly spending cap, not prepaid credit balance."
                ))
                .font(RosterSecondaryChrome.micro)
                .foregroundStyle(.secondary)
            }

            if account.requiresLogin, let error = account.usageError {
                Text(error)
                    .font(RosterSecondaryChrome.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = account.activationBlockReason {
                Text(language.text("Cần lưu lại: \(reason)", "Re-save required: \(reason)"))
                    .font(RosterSecondaryChrome.micro)
                    .foregroundStyle(PrismTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let fetched = account.usage?.fetchedAt.value {
                Text(language.text("Quota cập nhật: ", "Quota updated: ")
                     + fetched.formatted(date: .omitted, time: .shortened))
                    .font(RosterSecondaryChrome.micro)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(notchLayout ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: notchLayout ? 9 : RosterSecondaryChrome.cardRadius)
                .fill(notchLayout ? PrismTheme.surfacePanel : PrismTheme.surfaceSoft)
                .overlay(RoundedRectangle(cornerRadius: notchLayout ? 9 : RosterSecondaryChrome.cardRadius)
                    .strokeBorder(PrismTheme.borderSubtle, lineWidth: 0.8))
        )
        .contextMenu {
            Button(language.text("Đặt nhãn", "Set label")) {
                labelDraft = account.customLabel ?? ""
                labelTarget = account
            }
            Divider()
            Button(language.text("Xóa", "Delete"), role: .destructive) {
                deleteTarget = account
            }
        }
    }

    private func statusChip(_ account: ProviderAccount) -> AnyView? {
        if account.usageError?.contains("claude_cli_auth_missing:") == true
            || account.usageError?.contains("OAuth access token not found") == true {
            return AnyView(chip(language.text("CLI chưa đăng nhập", "CLI not signed in"), tint: PrismTheme.amber))
        }
        if account.usageError?.contains("HTTP 429") == true {
            return AnyView(chip(language.text("API quota giới hạn (429)", "Quota API limited (429)"), tint: PrismTheme.amber))
        }
        if account.usageError?.hasPrefix("live_token_waiting") == true {
            return AnyView(chip(
                language.text("Chờ Claude Code làm mới token", "Waiting for Claude Code to refresh"),
                tint: PrismTheme.amber
            ))
        }
        if account.requiresResave {
            return AnyView(chip(language.text("Cần lưu lại", "Re-save required"), tint: PrismTheme.amber))
        }
        if account.requiresLogin {
            return AnyView(chip(language.text("Cần đăng nhập lại", "Sign in again"), tint: PrismTheme.danger))
        }
        switch account.usage?.status {
        case "ok":
            if account.hasFreshUsage { return nil }
            let age = Date().timeIntervalSince(account.usage?.fetchedAt.value ?? Date())
            return AnyView(chip(
                language.text("cũ · \(max(0, Int(age / 60)))m", "stale · \(max(0, Int(age / 60)))m"),
                tint: PrismTheme.amber
            ))
        case "stale":
            let age = Date().timeIntervalSince(account.usage?.fetchedAt.value ?? Date())
            let minutes = max(0, Int(age / 60))
            return AnyView(chip(
                language.text("cũ · \(minutes)m", "stale · \(minutes)m"),
                tint: PrismTheme.amber
            ))
        case "credential_expired":
            return AnyView(chip(
                account.isActive
                    ? language.text("Chờ Claude Code làm mới token", "Waiting for Claude Code to refresh")
                    : language.text("Token hết hạn", "Token expired"),
                tint: PrismTheme.amber
            ))
        case "needs_auth":
            return AnyView(chip(language.text("Cần đăng nhập lại", "Sign in again"), tint: PrismTheme.danger))
        case .none:
            return AnyView(chip(language.text("Chưa có dữ liệu", "No data yet"), tint: PrismTheme.titanium))
        default:
            return AnyView(chip(account.usage?.status ?? "?", tint: PrismTheme.titanium))
        }
    }

    private func usageBar(_ account: ProviderAccount, key: String) -> AnyView {
        guard let window = account.window(key) else { return AnyView(EmptyView()) }
        let used = window.usedPercent ?? 0
        let tint: Color = used >= 90 ? PrismTheme.danger : used >= 60 ? PrismTheme.amber : PrismTheme.emerald
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(window.label)
                        .font(RosterSecondaryChrome.footnote)
                    Spacer(minLength: 0)
                    Text(language.text(
                        "đã dùng \(used)% · còn \(window.remainingPercent ?? max(0, 100 - used))%",
                        "\(used)% used · \(window.remainingPercent ?? max(0, 100 - used))% left"
                    ))
                        .font(RosterSecondaryChrome.footnote.weight(.semibold))
                        .foregroundStyle(tint)
                    if window.aheadOfPace == true {
                        Text(language.text("(vượt nhịp)", "(ahead of pace)"))
                            .font(RosterSecondaryChrome.footnote)
                            .foregroundStyle(PrismTheme.amber)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(PrismTheme.surfaceFill)
                        Capsule()
                            .fill(tint)
                            .frame(width: geo.size.width * min(1, max(0, Double(used) / 100)))
                    }
                }
                .frame(height: 6)
                if let reset = window.resetDescription(in: language.language) {
                    Text(reset)
                        .font(RosterSecondaryChrome.micro)
                        .foregroundStyle(.secondary)
                }
            }
        )
    }

    private func extraWindowText(_ window: ProviderUsageWindow) -> String {
        if window.key == "extra_usage" {
            var parts = [language.text("Chi tiêu thêm trong tháng", "Monthly extra usage")]
            if let used = window.used {
                parts.append(language.text("đã dùng \(Int(used))", "\(Int(used)) used"))
            }
            if let used = window.used, let limit = window.limit {
                parts.append(language.text(
                    "còn \(Int(max(0, limit - used))) tới hạn mức",
                    "\(Int(max(0, limit - used))) to spending cap"
                ))
            }
            if let reset = window.resetDescription(in: language.language) {
                parts.append(reset)
            }
            return parts.joined(separator: " · ")
        }
        var parts = [window.label]
        if let used = window.usedPercent {
            parts.append("\(used)%")
        } else if let used = window.used, let limit = window.limit {
            parts.append("\(Int(used)) / \(Int(limit)) \(window.unit ?? "")".trimmingCharacters(in: .whitespaces))
        }
        if let reset = window.resetDescription(in: language.language) {
            parts.append(reset)
        }
        if window.aheadOfPace == true {
            parts.append(language.text("(vượt nhịp)", "(ahead of pace)"))
        }
        return parts.joined(separator: " · ")
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(RosterSecondaryChrome.micro.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func labelSheet(_ account: ProviderAccount) -> some View {
        let id = account.id
        return VStack(alignment: .leading, spacing: 12) {
            Text(language.text("Nhãn tài khoản", "Account label"))
                .font(RosterSecondaryChrome.title)
            TextField(language.text("Nhãn (để trống để xóa)", "Label (empty to clear)"), text: $labelDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(language.text("Hủy", "Cancel"), role: .cancel) {
                    labelTarget = nil
                }
                Button(language.text("Lưu", "Save")) {
                    store.setClaudeLabel(id, label: labelDraft)
                    labelTarget = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
