import SwiftUI

/// Bảng Thống Kê Các Chỉ Số Cần Thiết (Essential Metrics Statistics Table).
/// Surfaces all vital telemetry: Account status, Active Model, Quotas, Token Costs ($),
/// Luna Reserve readiness, Banked Resets, and OpenAI / Tibo Radar Health.
struct PrismMetricsTableView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.colorScheme) private var colorScheme

    private var activeAccount: SavedAccount? {
        store.accounts.first { $0.isActive && !$0.archived }
    }

    private var readyAccounts: [SavedAccount] {
        store.accounts.filter { !$0.archived && $0.triage == .ready }
    }

    private var actionAccounts: [SavedAccount] {
        store.accounts.filter { !$0.archived && $0.requiresLogin }
    }

    private var lunaAccounts: [SavedAccount] {
        store.accounts.filter { !$0.archived && $0.hasLunaReserve }
    }

    private var totalBankedResets: Int {
        store.accounts.reduce(0) { $0 + ($1.usage?.bankedResets?.availableCount ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // 1. KPI Summary Cards Grid (4 columns)
                kpiSummaryGrid

                // 2. Active Session & Model Status Table
                activeModelMatrix

                // 3. Token & Cost Telemetry Table
                tokenTelemetryTable

                // 4. Accounts Breakdown Matrix
                accountsBreakdownTable
            }
            .padding(.vertical, 2)
        }
        .frame(height: 195)
    }

    // MARK: - 1. KPI Summary Cards Grid
    private var kpiSummaryGrid: some View {
        HStack(spacing: 6) {
            kpiCard(
                title: language.text("Sẵn sàng", "Ready"),
                value: "\(readyAccounts.count)/\(store.accounts.count)",
                icon: "person.2.fill",
                tint: readyAccounts.isEmpty ? PrismTheme.ruby : PrismTheme.emerald
            )

            kpiCard(
                title: language.text("Luna", "Luna"),
                value: lunaAccounts.isEmpty ? "0" : "\(lunaAccounts.count)",
                icon: "moon.stars.fill",
                tint: lunaAccounts.isEmpty ? .secondary : Color.purple,
                badge: store.isLunaReserveActiveInCodex ? language.text("Bật", "On") : nil
            )

            kpiCard(
                title: language.text("Banked", "Banked"),
                value: "\(totalBankedResets)",
                icon: "arrow.counterclockwise.circle.fill",
                tint: totalBankedResets > 0 ? Color.orange : .secondary
            )

            kpiCard(
                title: language.text("OpenAI", "OpenAI"),
                value: (store.openAIStatus?.indicator ?? "none") == "none" ? "OK" : language.text("Lỗi", "Issue"),
                icon: "shield.checkered",
                tint: (store.openAIStatus?.indicator ?? "none") == "none" ? PrismTheme.emerald : PrismTheme.ruby
            )
        }
    }

    private func kpiCard(title: String, value: String, icon: String, tint: Color, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)

                if let badge {
                    Text(badge)
                        .font(.system(size: 7.5, weight: .bold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.18)))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 2. Active Session & Model Status Table
    private var activeModelMatrix: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(language.text("Phiên hiện tại & Model", "Active Session & Model"), systemImage: "cpu")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let model = store.currentCodexModel {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(PrismTheme.emerald)
                        Text(model)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }

            // Metrics Row
            HStack(spacing: 8) {
                metricPill(
                    label: language.text("5h Quota", "5h Quota"),
                    value: activeAccount?.usage?.fiveHour.map { "\($0.displayRemainingPercent)%" } ?? "—",
                    subtext: activeAccount?.usage?.fiveHour?.relativeReset(in: language.language),
                    tint: PrismTheme.quotaTint(percent: activeAccount?.usage?.fiveHour?.displayRemainingPercent)
                )

                metricPill(
                    label: language.text("Hạn mức tuần", "Weekly"),
                    value: activeAccount?.usage?.weekly.map { "\($0.displayRemainingPercent)%" } ?? "—",
                    subtext: activeAccount?.usage?.weekly?.relativeReset(in: language.language),
                    tint: PrismTheme.quotaTint(percent: activeAccount?.usage?.weekly?.displayRemainingPercent)
                )

                if let active = activeAccount, active.hasLunaReserve {
                    metricPill(
                        label: "Luna Reserve",
                        value: store.isLunaReserveActiveInCodex ? language.text("Đang bật", "Active") : language.text("Chờ bật", "Standby"),
                        subtext: active.lunaReserveRemainingPercent.map { "\($0)%" } ?? "100%",
                        tint: Color.purple
                    )
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    private func metricPill(label: String, value: String, subtext: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                if let subtext {
                    Text(subtext)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
    }

    // MARK: - 3. Token & Cost Telemetry Table
    private var tokenTelemetryTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(language.text("Tiêu thụ Token & Chi phí", "Tokens & Cost Telemetry"), systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let vibe = store.status?.vibeUsage {
                    Text(String(format: "Vibe: $%.2f", vibe.estimatedCostUsd))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = store.tokenUsage {
                HStack(spacing: 8) {
                    metricPill(
                        label: language.text("Hôm nay", "Today"),
                        value: formatTokenMetric(summary.today, in: language.language),
                        subtext: summary.todayCostUsd.map { formatUsdCost($0, in: language.language) },
                        tint: Color.accentColor
                    )

                    metricPill(
                        label: language.text("7 ngày qua", "Last 7 Days"),
                        value: formatTokenMetric(summary.last7Days, in: language.language),
                        subtext: summary.last7DaysCostUsd.map { formatUsdCost($0, in: language.language) },
                        tint: PrismTheme.emerald
                    )

                    metricPill(
                        label: language.text("Subagents", "Subagents"),
                        value: "\(summary.subagentSessions ?? 0)",
                        subtext: language.text("phiên", "sessions"),
                        tint: Color.cyan
                    )
                }
            } else {
                Text(language.text("Đang tải dữ liệu tiêu thụ token…", "Loading token telemetry…"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    // MARK: - 4. Accounts Breakdown Matrix
    private var accountsBreakdownTable: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(language.text("Bảng phân bổ tài khoản", "Account Allocation Matrix"))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.accounts.count) \(language.text("tài khoản", "total"))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 2) {
                ForEach(store.sortedAccounts(store.accounts.filter { !$0.archived })) { account in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(account.isActive ? PrismTheme.emerald : (account.requiresLogin ? PrismTheme.amber : Color.secondary.opacity(0.4)))
                            .frame(width: 5, height: 5)

                        Text(account.displayName)
                            .font(.system(size: 10, weight: account.isActive ? .bold : .medium))
                            .lineLimit(1)
                            .frame(width: 100, alignment: .leading)

                        Text(account.planLabel ?? "—")
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)

                        // 5h Quota
                        let five = account.usage?.fiveHour?.displayRemainingPercent
                        Text(five.map { "\($0)%" } ?? "—")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(PrismTheme.quotaTint(percent: five))
                            .frame(width: 38, alignment: .trailing)

                        Spacer()

                        // Luna or Banked
                        if account.hasLunaReserve {
                            let isLunaActive = store.isLunaReserveActive(for: account)
                            HStack(spacing: 2) {
                                Image(systemName: isLunaActive ? "moon.stars.fill" : "moon.fill")
                                Text(isLunaActive ? "Active" : "Luna")
                            }
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.purple)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.16)))
                        } else if let banked = account.usage?.bankedResets?.availableCount, banked > 0 {
                            Text("+\(banked)b")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.16)))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(account.isActive ? 0.05 : 0.015)))
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }
}
