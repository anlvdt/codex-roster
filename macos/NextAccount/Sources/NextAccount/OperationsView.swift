import SwiftUI

/// Deep-dive operations panel — diagnostics and actions that the notch does not show.
/// Intentionally omits live quota gauges, roster grid, and auto-switch toggles (those live on the notch).
struct OperationsView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @State private var selection: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RosterSecondaryChrome.sectionSpacing) {
                header

                nextActionSection

                attentionSummary

                opsStatusSection

                OpenAIStatusCard()

                GlobalResetOutlookCard()

                TokenUsageOverview()
                    .padding(14)
                    .background(RosterSecondaryChrome.cardFill, in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius))
            }
            .rosterSecondaryPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .rosterSecondaryContent()
        .onAppear {
            store.refreshTokenUsage(silently: true)
            store.refreshOpenAIStatus(silently: true)
            store.refreshResetOutlook(silently: true)
            store.refreshResetTimeline(silently: true)
            store.refreshResetJuice(silently: true)
            store.refreshProviderStatus(silently: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(language.text("Vận hành", "Operations"), systemImage: "wrench.and.screwdriver")
                .font(RosterSecondaryChrome.title)
            Text(language.text(
                "Thông tin sâu hơn notch: việc nên làm, trạng thái vận hành, dịch vụ, radar reset và token cục bộ.",
                "Deeper than the notch: recommended actions, ops status, service health, reset radar, and local token use."
            ))
            .font(RosterSecondaryChrome.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nextActionSection: some View {
        let action = NextAction.resolve(in: store)
        return Group {
            if !action.isAllClear {
                NextActionBanner(
                    selection: $selection,
                    action: action,
                    reloginAll: { accounts in
                        for account in accounts {
                            NotificationCenter.default.post(
                                name: .showReloginAccount,
                                object: account.id.uuidString
                            )
                        }
                    }
                )
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(PrismTheme.emerald)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("Không có việc khẩn", "Nothing urgent"))
                            .font(RosterSecondaryChrome.section)
                        Text(language.text(
                            "Quota và phiên đang ổn. Dùng notch để chuyển tài khoản nhanh khi cần.",
                            "Quota and session look fine. Use the notch for quick switches when needed."
                        ))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(PrismTheme.emerald.opacity(0.10), in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius))
            }
        }
    }

    private var attentionSummary: some View {
        let ready = store.accounts.filter { $0.triage == .ready }.count
        let needsLogin = store.accounts.filter { $0.triage == .needsAction && $0.requiresLogin }.count
        let resting = store.accounts.filter { $0.triage == .resting }.count
        let banked = store.accounts.filter(\.restingHasBankedReset).count
        let deferred = store.accounts.filter(\.hasDeferredAccessTokenRefresh).count

        return VStack(alignment: .leading, spacing: RosterSecondaryChrome.blockSpacing) {
            Text(language.text("Tóm tắt danh bạ", "Roster snapshot"))
                .font(RosterSecondaryChrome.section)
            HStack(spacing: 8) {
                opsChip(language.text("Sẵn sàng \(ready)", "Ready \(ready)"), tint: PrismTheme.emerald)
                opsChip(language.text("Login \(needsLogin)", "Login \(needsLogin)"), tint: needsLogin > 0 ? PrismTheme.amber : PrismTheme.titanium)
                opsChip(language.text("Nghỉ \(resting)", "Resting \(resting)"), tint: PrismTheme.titanium)
                if banked > 0 {
                    opsChip(language.text("Banked \(banked)", "Banked \(banked)"), tint: PrismTheme.warning)
                }
                if deferred > 0 {
                    opsChip(language.text("Chưa XM \(deferred)", "Unverified \(deferred)"), tint: PrismTheme.textSecondary)
                }
            }
            Text(language.text(
                "Chi tiết từng tài khoản và thanh quota nằm trên notch — đây chỉ là số liệu tổng.",
                "Per-account details and quota bars stay on the notch — this is a count-only snapshot."
            ))
            .font(RosterSecondaryChrome.footnote)
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RosterSecondaryChrome.cardFill, in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius))
    }

    private var opsStatusSection: some View {
        VStack(alignment: .leading, spacing: RosterSecondaryChrome.blockSpacing) {
            Text(language.text("Trạng thái vận hành", "Ops status"))
                .font(RosterSecondaryChrome.section)

            if let resume = store.sessionResumeCaption {
                opsStatusRow(
                    icon: "arrow.uturn.backward.circle",
                    title: language.text("Auto-resume", "Auto-resume"),
                    detail: resume
                )
            }
            if let phase = store.switchPhaseMessage {
                opsStatusRow(
                    icon: "arrow.left.arrow.right.circle",
                    title: language.text("Chuyển phiên", "Account switch"),
                    detail: phase
                )
            }
            if let auto = store.autoSwitchState {
                opsStatusRow(
                    icon: "bolt.horizontal.circle",
                    title: language.text("Tự chuyển", "Auto-switch"),
                    detail: autoSwitchDetail(auto)
                )
            }
            if let backup = store.backupStatusMessage {
                opsStatusRow(
                    icon: "externaldrive.badge.timemachine",
                    title: language.text("Sao lưu", "Backup"),
                    detail: backup
                )
            }
            if let last = store.lastQuotaRefreshAt {
                opsStatusRow(
                    icon: "clock.arrow.circlepath",
                    title: language.text("Quota gần nhất", "Last quota refresh"),
                    detail: last.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if store.sessionResumeCaption == nil,
               store.switchPhaseMessage == nil,
               store.autoSwitchState == nil,
               store.backupStatusMessage == nil,
               store.lastQuotaRefreshAt == nil {
                Text(language.text(
                    "Chưa có sự kiện vận hành gần đây.",
                    "No recent operations events."
                ))
                .font(RosterSecondaryChrome.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button(language.text("Kiểm tra ngay", "Run refresh check")) {
                    store.runUsageWindowCheck()
                }
                .controlSize(.small)
                .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
                if store.autoSwitchWhenExhausted {
                    Button(language.text("Kiểm tra & chuyển", "Check & switch")) {
                        store.runAutoSwitchCheck()
                    }
                    .controlSize(.small)
                    .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
                }
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RosterSecondaryChrome.cardFill, in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius))
    }

    private func opsChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(RosterSecondaryChrome.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func opsStatusRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(RosterSecondaryChrome.body)
                .foregroundStyle(PrismTheme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RosterSecondaryChrome.caption.weight(.semibold))
                Text(detail)
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func autoSwitchDetail(_ state: AutoSwitchState) -> String {
        switch state {
        case .waitingForLogin:
            language.text("Tạm dừng khi đang đăng nhập", "Paused while signing in")
        case .allAccountsExhausted:
            language.text("Tất cả tài khoản hết quota — đang chờ phục hồi", "All accounts exhausted — waiting for recovery")
        case .bankedResetAvailable(let account, let count, let isActive):
            if isActive {
                language.text(
                    "\(account) còn \(count) banked reset (đang active)",
                    "\(account) has \(count) banked reset (currently active)"
                )
            } else {
                language.text(
                    "\(account) còn \(count) banked reset chưa redeem",
                    "\(account) has \(count) unredeemed banked reset"
                )
            }
        case .closingDesktop:
            language.text("Đang đóng ChatGPT/Codex…", "Closing ChatGPT/Codex…")
        case .switchingAccount:
            language.text("Đang chuyển phiên ~/.codex…", "Switching ~/.codex session…")
        case .relaunchingDesktop:
            language.text("Đang mở lại ChatGPT…", "Relaunching ChatGPT…")
        case .desktopRelaunchFailed:
            language.text("Đã chuyển phiên nhưng mở lại ChatGPT thất bại", "Session switched but ChatGPT relaunch failed")
        case .waitingForProcesses:
            language.text("Cần đóng ChatGPT thủ công rồi thử lại", "Quit ChatGPT manually, then retry")
        case .switched(let name):
            language.text("Đã chuyển sang \(name)", "Switched to \(name)")
        case .checkFailed:
            language.text("Lần kiểm tra gần nhất thất bại", "Last check failed")
        case .generationInProgress:
            language.text("Chờ Codex hết tạo phản hồi", "Waiting for Codex generation to finish")
        }
    }
}
