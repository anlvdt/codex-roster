import SwiftUI

/// Claude Code account deck shared by the notch and Roster Console.
struct ClaudeRosterView: View {
    var notchLayout = false

    static func notchDeckHeight(accountCount: Int) -> CGFloat {
        let rows = max(1, (accountCount + 1) / 2)
        return min(NotchRosterLayout.collapsedDeckHeight, CGFloat(320 + (rows - 1) * 76))
    }
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore

    @State private var switchTarget: ProviderAccount?
    @State private var deleteTarget: ProviderAccount?
    @State private var labelTarget: ProviderAccount?
    @State private var detailsTarget: ProviderAccount?
    @State private var labelDraft = ""
    @State private var accountSearch = ""
    @State private var accountFilter: AccountFilter = .all
    @State private var showAutoSwitchOptions = false
    @State private var showNotchAutoSettings = false
    @State private var showAddGuide = false
    @AppStorage("claude_roster_auto_resume") private var autoResume = true
    @AppStorage("claude_roster_switch_desktop") private var switchDesktop = true

    private enum AccountFilter: String, CaseIterable {
        case all, ready, action
    }

    private var liveState: ProviderState? {
        store.providerStates.first { $0.provider == .claude }
    }

    private var sortedAccounts: [ProviderAccount] {
        store.claudeAccounts.filter { account in
            let matchesSearch = accountSearch.isEmpty
                || account.displayName.localizedCaseInsensitiveContains(accountSearch)
                || account.email.localizedCaseInsensitiveContains(accountSearch)
            let matchesFilter: Bool
            switch accountFilter {
            case .all: matchesFilter = true
            case .ready: matchesFilter = !account.isActive && account.canActivate
                && account.hasFreshUsage
                && (account.bindingUtilization ?? 100) < (store.claudeAutoSwitch?.thresholdPercent ?? 95)
            case .action: matchesFilter = account.requiresResave
                || account.requiresLogin || account.usageError != nil
                || account.usage?.status != "ok"
            }
            return matchesSearch && matchesFilter
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
                        autoSwitchCard
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
            language.text("Chuyển Claude Code sang tài khoản này?", "Switch Claude Code to this account?"),
            isPresented: Binding(
                get: { switchTarget != nil },
                set: { if !$0 { switchTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = switchTarget {
                let id = target.id
                Button(language.text("Chuyển", "Switch")) {
                    store.activateClaudeAccount(id)
                }
            }
            Button(language.text("Hủy", "Cancel"), role: .cancel) {}
        } message: {
            if let target = switchTarget {
                Text(target.displayName)
            }
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
        }
    }

    // Match the Codex notch deck: live and automation wings frame the camera,
    // while the account switchboard keeps its toolbar visible during scrolling.
    private var notchDeck: some View {
        VStack(spacing: NotchRosterLayout.deckSectionSpacing) {
            HStack(alignment: .top, spacing: 8) {
                notchLiveWing.frame(maxWidth: .infinity, alignment: .topLeading)
                Color.clear
                    .frame(width: NotchGeometry.detect().hasNotch
                        ? NotchGeometry.detect().cameraWidth : 156)
                notchAutomationWing.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 120, alignment: .top)

            notchSwitchboard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, NotchRosterLayout.deckHorizontalInset)
        .padding(.top, NotchRosterLayout.deckTopInset)
        .padding(.bottom, NotchRosterLayout.deckBottomInset)
        .frame(width: NotchRosterLayout.deckWidth,
               height: Self.notchDeckHeight(accountCount: store.claudeAccounts.count),
               alignment: .top)
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
                chip(language.text("Đang dùng", "Live"), tint: PrismTheme.emerald)
            }
            if let active {
                if let window = active.window("five_hour") { summaryQuota(window, label: "5h") }
                if let window = active.window("seven_day") { summaryQuota(window, label: "7d") }
                if !active.hasFreshUsage {
                    // Demoted to a quiet caption — this is informational, not a
                    // banner that deserves the amber spotlight.
                    Text(quotaWarning(active))
                        .font(PrismTheme.fontMicro)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(language.text("Lưu phiên Claude Code để theo dõi quota.", "Save the Claude Code session to track quota."))
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(notchWingShape)
    }

    private var notchAutomationWing: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(language.text("Tự động", "Automation"), systemImage: "arrow.triangle.2.circlepath")
                .font(PrismTheme.fontBodyCompactBold)
            Toggle(language.text("Tự chuyển gần hết quota", "Auto-switch near quota"), isOn: Binding(
                get: { store.claudeAutoSwitch?.enabled == true },
                set: { store.setClaudeAutoSwitch(enabled: $0) }
            ))
            .help(language.text(
                "Tự động chuyển sang tài khoản khác trước khi hạn mức cạn kiệt.",
                "Automatically switch to another account before the quota runs out."
            ))
            Toggle(language.text("Tiếp tục phiên sau khi chuyển", "Resume session after switching"), isOn: $autoResume)
                .help(language.text(
                    "Mở lại hội thoại đang chạy với tài khoản mới sau khi chuyển.",
                    "Reopen the running conversation with the new account after switching."
                ))
            if let auto = store.claudeAutoSwitch {
                Text(autoSwitchStatusText(auto))
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(PrismTheme.fontCaption)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(notchWingShape)
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
                    .lineLimit(2)
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
                    Button(filterTitle(filter)) { accountFilter = filter }
                        .buttonStyle(.plain)
                        .font(PrismTheme.fontChip)
                        .foregroundStyle(accountFilter == filter ? PrismTheme.textPrimary : PrismTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accountFilter == filter ? PrismTheme.surfaceStrong : PrismTheme.surfaceQuiet))
                        .accessibilityAddTraits(accountFilter == filter ? .isSelected : [])
                }
                TextField(language.text("Tìm tên hoặc email", "Search name or email"), text: $accountSearch)
                    .textFieldStyle(.roundedBorder)
                    .font(PrismTheme.fontCaption)
                    .frame(width: 164)
                Button { store.saveLiveClaudeAccount() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help(language.text("Lưu tài khoản đang đăng nhập", "Save signed-in account"))
                .accessibilityLabel(language.text("Lưu tài khoản đang đăng nhập", "Save signed-in account"))
                Button { showAddGuide = true } label: { Image(systemName: "plus") }
                    .help(language.text("Thêm tài khoản", "Add account"))
                    .accessibilityLabel(language.text("Thêm tài khoản", "Add account"))
                Button { store.refreshClaudeUsage(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoadingClaude)
                .help(language.text("Làm mới quota", "Refresh quota"))
                .accessibilityLabel(language.text("Làm mới quota", "Refresh quota"))
                Button { showNotchAutoSettings = true } label: { Image(systemName: "ellipsis") }
                    .help(language.text("Tùy chọn tự chuyển", "Auto-switch options"))
                    .accessibilityLabel(language.text("Tùy chọn tự chuyển", "Auto-switch options"))
                    .popover(isPresented: $showNotchAutoSettings, arrowEdge: .bottom) {
                        autoSwitchCard
                            .frame(width: 400)
                            .padding(8)
                    }
            }
            .buttonStyle(.plain)
            .font(PrismTheme.fontBodyCompactBold)

            ScrollView {
                if store.claudeAccounts.isEmpty {
                    Text(language.text("Đăng nhập Claude Code rồi lưu tài khoản để bắt đầu.", "Sign in to Claude Code and save the account to begin."))
                        .font(PrismTheme.fontCaption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else if sortedAccounts.isEmpty {
                    Text(language.text("Không có tài khoản phù hợp.", "No matching accounts."))
                        .font(PrismTheme.fontCaption)
                        .foregroundStyle(.secondary)
                        .padding(12)
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
        }
    }

    private func notchAccountCard(_ account: ProviderAccount) -> some View {
        HStack(spacing: 8) {
            Text(String(account.displayName.prefix(1)).uppercased())
                .font(PrismTheme.fontAvatar)
                .foregroundStyle(account.isActive ? PrismTheme.emerald : PrismTheme.titanium)
                .frame(width: 24, height: 24)
                .background(Circle().fill(PrismTheme.surfaceStrong))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(account.shortDisplayName)
                        .font(PrismTheme.fontBodyBold)
                        .lineLimit(1)
                    if account.isActive {
                        chip(language.text("Đang dùng", "Live"), tint: PrismTheme.emerald)
                    }
                }
                Text(account.email)
                    .font(PrismTheme.fontCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                notchQuotaLabel(account, key: "five_hour", title: "5h")
                notchQuotaLabel(account, key: "seven_day", title: "7d")
            }
            .frame(width: 76, alignment: .trailing)
            Button { detailsTarget = account } label: {
                Image(systemName: account.requiresResave || account.requiresLogin ? "exclamationmark.circle" : "info.circle")
                    .font(PrismTheme.fontBodyCompact)
                    .foregroundStyle(account.requiresResave || account.requiresLogin ? PrismTheme.amber : PrismTheme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(language.text("Chi tiết tài khoản và quota", "Account and quota details"))
            .accessibilityLabel(language.text("Chi tiết \(account.displayName)", "Details for \(account.displayName)"))
            if account.isActive {
                chip(language.text("Đang dùng", "Active"), tint: PrismTheme.emerald)
                    .frame(width: 65)
            } else {
                Button(language.text("Chuyển", "Switch")) { switchTarget = account }
                    .disabled(!account.canActivate)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: 65)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 68)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(PrismTheme.surfacePanel)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(account.isActive ? PrismTheme.emerald.opacity(0.65) : PrismTheme.borderSubtle,
                              lineWidth: 0.8)))
    }

    private func notchQuotaLabel(_ account: ProviderAccount, key: String, title: String) -> some View {
        let remaining = account.window(key)?.remainingPercent
        return HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(remaining.map { "\($0)%" } ?? "—")
                .foregroundStyle(PrismTheme.quotaTint(percent: remaining))
        }
        .font(PrismTheme.fontCaptionBold)
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
                Button {
                    store.saveLiveClaudeAccount()
                } label: {
                    Text(language.text("Lưu tài khoản đang đăng nhập", "Save signed-in account"))
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
            Text(language.text(
                "Để tự chuyển Desktop: đăng nhập từng tài khoản trong Desktop rồi chọn Lưu đăng nhập Desktop ở menu tài khoản tương ứng. Roster đóng app, khôi phục đăng nhập đã lưu và mở lại; không buộc dừng app.",
                "To switch Desktop automatically: sign in to each account in Desktop, then choose Save Desktop login in that account's menu. Roster quits the app, restores its saved login, and reopens it without force quitting."
            ))
            .font(RosterSecondaryChrome.footnote)
            .foregroundStyle(.secondary)
            Text(language.text(
                "Khi bật tiếp tục phiên: CLI mở bản sao hội thoại gần đây; tab Code Desktop mở lại phiên local được focus gần nhất bằng --desktop --resume. Không tự gửi prompt. Chat Desktop vẫn thuộc tài khoản cũ.",
                "With resume enabled: CLI forks the recent conversation; Desktop Code reopens its last focused local session using --desktop --resume. No prompt is sent. Desktop Chat stays with the original account."
            ))
            .font(RosterSecondaryChrome.footnote)
            .foregroundStyle(.secondary)
            if let message = store.claudeSwitchMessage {
                Text(message)
                    .font(RosterSecondaryChrome.footnote)
                    .foregroundStyle(PrismTheme.amber)
            }
            HStack {
                Button(language.text("Mở lại hội thoại CLI", "Reopen CLI conversation")) {
                    store.reopenClaudeCLI()
                }
                Button(language.text("Khởi động lại Desktop để đăng nhập", "Restart Desktop to sign in")) {
                    store.restartClaudeDesktop()
                }
            }
            .disabled(store.isSwitchingClaude)
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
        if account.usageError?.contains("HTTP 429") == true {
            return language.text("API quota giới hạn yêu cầu (429) · đang chờ thử lại",
                "Quota API rate limited (429) · waiting to retry")
        }
        return language.text("Quota đã lưu · chưa xác minh trực tiếp", "Saved quota · not verified live")
    }

    private func summaryQuota(_ window: ProviderUsageWindow, label: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label ?? window.label)
            Spacer()
            Text("\(window.remainingPercent ?? max(0, 100 - (window.usedPercent ?? 0)))% "
                + language.text("còn", "left"))
                .fontWeight(.semibold)
            if let reset = window.resetDescription(in: language.language) {
                Text("· " + reset).foregroundStyle(.secondary)
            }
        }
        .font(RosterSecondaryChrome.footnote)
    }

    private var addAccountGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("Thêm tài khoản Claude Code", "Add Claude Code account"))
                .font(RosterSecondaryChrome.title)
            Text(language.text(
                "1. Mở Claude Code trong Terminal và gõ /login để đăng nhập tài khoản mới. Không cần /logout trước.",
                "1. Open Claude Code in Terminal and run /login for the new account. No /logout needed."
            ))
            Text(language.text(
                "2. Quay lại đây, bấm Lưu tài khoản đang đăng nhập. App sẽ giữ tài khoản trước để chuyển lại.",
                "2. Return here and click Save signed-in account. The previous account stays in the roster."
            ))
            Text(language.text(
                "3. Dùng nút Chuyển ở thẻ tài khoản và kiểm tra /status trong Claude Code.",
                "3. Use Switch on an account card, then check /status in Claude Code."
            ))
            HStack {
                Spacer()
                Button(language.text("Đóng", "Close")) { showAddGuide = false }
                Button(language.text("Đã đăng nhập — Lưu", "Signed in — Save")) {
                    showAddGuide = false
                    store.saveLiveClaudeAccount()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(RosterSecondaryChrome.caption)
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Auto-switch card

    private var autoSwitchCard: some View {
        VStack(alignment: .leading, spacing: RosterSecondaryChrome.blockSpacing) {
            Toggle(language.text("Mở tài khoản trong Claude Desktop", "Open accounts in Claude Desktop"), isOn: $switchDesktop)
                .toggleStyle(.switch)
                .font(RosterSecondaryChrome.section)
            Text(language.text(
                "Áp dụng cho mọi tài khoản. Đăng nhập Desktop một lần cho từng tài khoản rồi lưu đăng nhập trong menu tài khoản.",
                "Applies to every account. Sign in to each account in Desktop once, then save its Desktop login in the account menu."
            ))
            .font(RosterSecondaryChrome.footnote)
            .foregroundStyle(.secondary)
            Toggle(isOn: Binding(
                get: { store.claudeAutoSwitch?.enabled == true },
                set: { store.setClaudeAutoSwitch(enabled: $0) }
            )) {
                Text(language.text(
                    "Tự chuyển tài khoản khi gần hết quota",
                    "Auto-switch before quota runs out"
                ))
                .font(RosterSecondaryChrome.section)
            }
            .toggleStyle(.switch)

            Toggle(isOn: $autoResume) {
                Text(language.text(
                    "Mở lại hội thoại sau khi chuyển tài khoản",
                    "Reopen conversation after switching accounts"
                ))
                .font(RosterSecondaryChrome.section)
            }
            .toggleStyle(.switch)

            DisclosureGroup(isExpanded: $showAutoSwitchOptions) {
                HStack {
                    Text(language.text(
                        "Chuyển khi đã dùng ≥ \(store.claudeAutoSwitch?.thresholdPercent ?? 95)%",
                        "Switch once usage hits \(store.claudeAutoSwitch?.thresholdPercent ?? 95)%"
                    ))
                    .font(RosterSecondaryChrome.caption)
                    Spacer()
                    Stepper("", value: thresholdBinding, in: 50...100, step: 5)
                        .labelsHidden()
                }
                HStack {
                    Text(language.text(
                        "Độ chênh tối thiểu: \(store.claudeAutoSwitch?.hysteresisPercent ?? 10) điểm",
                        "Minimum headroom gain: \(store.claudeAutoSwitch?.hysteresisPercent ?? 10) points"
                    ))
                    .font(RosterSecondaryChrome.caption)
                    Spacer()
                    Stepper("", value: hysteresisBinding, in: 0...50, step: 5)
                        .labelsHidden()
                }
                HStack {
                    Text(language.text(
                        "Khoảng nghỉ: \(store.claudeAutoSwitch?.cooldownSeconds ?? 300)s",
                        "Cooldown: \(store.claudeAutoSwitch?.cooldownSeconds ?? 300)s"
                    ))
                    .font(RosterSecondaryChrome.caption)
                    Spacer()
                    Stepper("", value: cooldownBinding, in: 0...3600, step: 60)
                        .labelsHidden()
                }
                HStack {
                    Text(language.text("Chiến lược", "Strategy"))
                        .font(RosterSecondaryChrome.caption)
                    Spacer()
                    Picker("", selection: strategyBinding) {
                        Text(language.text("Nhiều quota nhất", "Most quota left")).tag("best")
                        Text(language.text("Dùng hết cái reset sớm nhất", "Burn soonest-resetting first"))
                            .tag("consume-first")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
            } label: {
                Text(language.text("Ngưỡng, khoảng nghỉ và chiến lược", "Threshold, cooldown and strategy"))
                    .font(RosterSecondaryChrome.caption)
            }

            if let auto = store.claudeAutoSwitch {
                Text(autoSwitchStatusText(auto))
                    .font(RosterSecondaryChrome.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RosterSecondaryChrome.cardFill, in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius))
    }

    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { store.claudeAutoSwitch?.thresholdPercent ?? 95 },
            set: { store.setClaudeAutoSwitch(enabled: nil, threshold: $0) }
        )
    }

    private var hysteresisBinding: Binding<Int> {
        Binding(
            get: { store.claudeAutoSwitch?.hysteresisPercent ?? 10 },
            set: { store.setClaudeAutoSwitch(enabled: nil, hysteresis: $0) }
        )
    }

    private var cooldownBinding: Binding<Int> {
        Binding(
            get: { store.claudeAutoSwitch?.cooldownSeconds ?? 300 },
            set: { store.setClaudeAutoSwitch(enabled: nil, cooldown: $0) }
        )
    }

    private var strategyBinding: Binding<String> {
        Binding(
            get: { store.claudeAutoSwitch?.strategy ?? "best" },
            set: { store.setClaudeAutoSwitch(enabled: nil, strategy: $0) }
        )
    }

    private func autoSwitchStatusText(_ output: ProviderAutoSwitchOutput) -> String {
        switch output.status {
        case "disabled":
            language.text("Đang tắt.", "Disabled.")
        case "enabled":
            language.text("Đã bật.", "Enabled.")
        case "waiting_for_login":
            language.text(
                "Chưa đọc được phiên Claude Code — đang chờ.",
                "No readable Claude Code session — waiting."
            )
        case "below_threshold":
            language.text("Quota còn an toàn.", "Quota is still comfortable.")
        case "usage_unavailable":
            output.detail?.contains("HTTP 429") == true
                ? language.text("API quota giới hạn yêu cầu (429); tự thử lại sau.", "Quota API rate limited (429); retrying later.")
                : language.text("Chưa đọc được quota trực tiếp.", "Live quota unavailable.")
        case "cooldown":
            language.text("Đang trong thời gian nghỉ giữa các lần chuyển.", "Cooling down between switches.")
        case "no_candidate":
            language.text("Chưa có tài khoản thay thế đủ quota.", "No qualifying replacement account.")
        case "all_accounts_exhausted":
            language.text("Tất cả tài khoản đã cạn — tạm dừng.", "All accounts exhausted — paused.")
        case "ready":
            language.text(
                "Sẵn sàng chuyển sang \(output.candidateDisplayName ?? "…").",
                "Ready to switch to \(output.candidateDisplayName ?? "…")."
            )
        case "switched":
            language.text(
                "Đã chuyển sang \(output.candidateDisplayName ?? "…").",
                "Switched to \(output.candidateDisplayName ?? "…")."
            )
        case "error":
            language.text("Lỗi: \(output.detail ?? "?")", "Error: \(output.detail ?? "?")")
        default:
            output.detail ?? output.status
        }
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
                }
            }
            TextField(language.text("Tìm tên hoặc email", "Search name or email"), text: $accountSearch)
                .textFieldStyle(.roundedBorder)

            if store.claudeAccounts.isEmpty {
                Text(language.text(
                    "Đăng nhập Claude Code rồi bấm Lưu để thêm tài khoản vào đây.",
                    "Sign in with Claude Code, then Save to add an account here."
                ))
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RosterSecondaryChrome.cardFill, in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius))
            } else if sortedAccounts.isEmpty {
                Text(language.text("Không có tài khoản phù hợp.", "No matching accounts."))
                    .foregroundStyle(.secondary)
                    .padding(14)
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

    private func accountRow(_ account: ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(account.displayName)
                    .font(RosterSecondaryChrome.body.weight(.semibold))
                    .lineLimit(1)
                if account.isActive {
                    chip(language.text("Đang dùng", "Live"), tint: PrismTheme.emerald)
                }
                if let plan = account.planLabel, !plan.isEmpty {
                    chip(plan, tint: PrismTheme.titanium)
                }
                statusChip(account)
                Spacer(minLength: 0)
                Menu {
                    Button(language.text("Lưu đăng nhập Desktop", "Save Desktop login"), systemImage: "desktopcomputer") {
                        store.saveClaudeDesktopLogin(account.id)
                    }
                    .disabled(store.isSwitchingClaude)
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
                Button(language.text("Chuyển", "Switch")) {
                    switchTarget = account
                }
                .disabled(account.requiresResave || store.isSwitchingClaude)
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
