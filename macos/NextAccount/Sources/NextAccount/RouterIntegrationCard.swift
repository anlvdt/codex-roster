import AppKit
import SwiftUI

struct RouterIntegrationCard: View {
    @EnvironmentObject private var language: LanguageStore
    @ObservedObject var router: RouterStore
    @State private var showingProviders = false

    private var status: RouterStatusOutput? { router.status }

    /// Prefer the URL the CLI reports; fall back to the known repository so the
    /// link is present even before the first status check completes.
    private var repositoryURL: URL {
        status?.repositoryUrl
            ?? URL(string: "https://github.com/duolahypercho/codex-router")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(statusTint.opacity(0.13))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusTint)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Codex Router")
                            .font(.headline)
                        RouterStatusBadge(title: statusTitle, tint: statusTint)
                        Spacer(minLength: 8)
                        Link(destination: repositoryURL) {
                            Label("GitHub", systemImage: "arrow.up.forward.square")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .help(language.text(
                            "Mở mã nguồn Codex Router trên GitHub",
                            "Open the Codex Router source on GitHub"
                        ))
                    }
                    Text(language.text(
                        "Dùng model ngoài qua Router, trong khi Roster tiếp tục quản lý tài khoản OpenAI và quota.",
                        "Use external models through Router while Roster continues to manage OpenAI accounts and quota."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if router.isRefreshing || router.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .help(language.text(
                            "Roster đang tự động chuẩn bị Router",
                            "Roster is preparing Router automatically"
                        ))
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                routerSummary
                Spacer(minLength: 12)
                if status?.healthy == true {
                    Button {
                        showingProviders = true
                    } label: {
                        Label(
                            language.text("Thêm model ngoài", "Add external models"),
                            systemImage: "plus.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(router.isWorking || router.isRefreshing)
                } else {
                    Label(
                        language.text("Roster tự quản lý", "Managed by Roster"),
                        systemImage: "gearshape.2.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }

            if let notice = router.notice, !notice.isEmpty {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(statusTint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showingProviders) {
            RouterProvidersSheet(router: router)
        }
    }

    @ViewBuilder
    private var routerSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let version = status?.version {
                Label("v\(version)", systemImage: "shippingbox")
            }
            Label(configurationTitle, systemImage: status?.configured == true ? "checkmark.seal" : "slider.horizontal.3")
            if let detail = status?.detail {
                Text(localizedDetail(detail))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }

    private var statusTitle: String {
        if router.isWorking {
            return language.text("Đang tự xử lý", "Auto-configuring")
        }
        if router.isRefreshing && status == nil {
            return language.text("Đang kiểm tra", "Checking")
        }
        guard let status else { return language.text("Chưa kiểm tra", "Not checked") }
        if status.healthy { return language.text("Sẵn sàng", "Ready") }
        if status.installed { return language.text("Đang tự phục hồi", "Auto-recovering") }
        return language.text("Đang chờ tự cài", "Pending auto-install")
    }

    private var statusTint: Color {
        guard let status else { return .secondary }
        if status.healthy { return .green }
        if status.installed { return .orange }
        return .secondary
    }

    private var configurationTitle: String {
        guard let status else {
            return language.text("Chưa có dữ liệu cấu hình", "Configuration not checked")
        }
        if !status.installed {
            return language.text("Roster sẽ tự cài đặt", "Roster will install automatically")
        }
        if status.configured {
            return language.text("Router đã thiết lập", "Router configured")
        }
        return language.text("Roster đang hoàn tất thiết lập", "Roster is finishing setup")
    }

    private func localizedDetail(_ detail: String) -> String {
        guard language.language == .vietnamese else { return detail }
        switch status?.state {
        case "ready":
            return "Dịch vụ Router local và tích hợp Codex đang phản hồi."
        case "offline":
            return "Dịch vụ local chưa sẵn sàng; Roster sẽ tự sửa dependency, cấu hình và service."
        default:
            return "Không cần thao tác. Roster sẽ tự cài Router ở chế độ native an toàn và tiếp tục kiểm tra nền."
        }
    }
}

private struct RouterProvidersSheet: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var router: RouterStore
    @State private var searchText = ""
    @State private var pendingAnonymousConsent: RouterProviderOutput?

    private var filteredProviders: [RouterProviderOutput] {
        router.providers
            .filter { provider in
                searchText.isEmpty
                    || provider.name.localizedCaseInsensitiveContains(searchText)
                    || provider.id.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { lhs, rhs in
                if lhs.visible != rhs.visible { return lhs.visible }
                if lhs.configured != rhs.configured { return lhs.configured }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var activeCount: Int {
        router.providers.filter(\.visible).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(language.text("Model ngoài", "External models"))
                        .font(.title2.weight(.semibold))
                    Text(language.text(
                        "Roster điều phối giao diện; Router giữ credential và routing. Native GPT luôn được giữ nguyên.",
                        "Roster coordinates the interface; Router owns credentials and routing. Native GPT always remains available."
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
                Button(language.text("Đóng", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(22)

            Divider()

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    language.text("Tìm provider hoặc model service", "Find a provider or model service"),
                    text: $searchText
                )
                .textFieldStyle(.plain)
                Spacer()
                Text(language.text("\(activeCount) đang dùng", "\(activeCount) active"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Button {
                    router.refresh(silently: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(router.isWorking || router.isRefreshing)
                .help(language.text("Đồng bộ từ Router", "Sync from Router"))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            if filteredProviders.isEmpty {
                ContentUnavailableView(
                    language.text("Không tìm thấy provider", "No providers found"),
                    systemImage: "magnifyingglass",
                    description: Text(language.text(
                        "Thử một tên khác hoặc đồng bộ lại Router.",
                        "Try another name or sync Router again."
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredProviders) { provider in
                    RouterProviderRow(
                        provider: provider,
                        isActing: router.isActing(on: provider),
                        action: {
                            if provider.visible {
                                router.disable(provider)
                            } else if provider.requiresExplicitConsent {
                                pendingAnonymousConsent = provider
                            } else {
                                router.connect(provider)
                            }
                        }
                    )
                    .environmentObject(language)
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Label(
                    language.text(
                        "API key và OAuth chỉ đi vào luồng bảo mật của Router; Roster không đọc hoặc lưu chúng.",
                        "API keys and OAuth only enter Router's secure flow; Roster never reads or stores them."
                    ),
                    systemImage: "key.horizontal.fill"
                )
                Label(
                    language.text(
                        "Provider đã bật sẽ xuất hiện cạnh native GPT trong phiên Codex mới.",
                        "Enabled providers appear beside native GPT in new Codex sessions."
                    ),
                    systemImage: "checkmark.shield.fill"
                )
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 590, idealHeight: 650)
        .onAppear { router.refresh(silently: true) }
        .alert(item: $pendingAnonymousConsent) { provider in
            Alert(
                title: Text(language.text("Cho phép provider anonymous?", "Allow anonymous provider?")),
                message: Text(language.text(
                    "Prompt dùng model \(provider.name) sẽ được gửi tới dịch vụ bên thứ ba này mà không có tài khoản/API key. Quota và chính sách do provider kiểm soát.",
                    "Prompts using \(provider.name) will be sent to this third-party service without an account or API key. The provider controls quota and policy."
                )),
                primaryButton: .default(Text(language.text("Đồng ý và bật", "Allow and enable"))) {
                    router.connect(provider, allowAnonymous: true)
                },
                secondaryButton: .cancel(Text(language.text("Huỷ", "Cancel")))
            )
        }
    }
}

private struct RouterProviderRow: View {
    @EnvironmentObject private var language: LanguageStore
    let provider: RouterProviderOutput
    let isActing: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(statusTint.opacity(0.11))
                Image(systemName: providerIcon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(statusTint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(provider.name)
                        .font(.body.weight(.medium))
                    Text(connectionKindTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.09), in: Capsule())
                }
                Text(statusDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            if isActing {
                ProgressView().controlSize(.small)
                    .frame(width: 82)
            } else if provider.visible {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 7)
    }

    private var actionTitle: String {
        if provider.visible { return language.text("Ẩn", "Hide") }
        if provider.configured { return language.text("Bật", "Enable") }
        return language.text("Kết nối…", "Connect…")
    }

    private var statusDescription: String {
        if provider.visible {
            return language.text("Đang hiển thị trong Codex", "Visible in Codex")
        }
        if provider.configured {
            return language.text("Đã kết nối · sẵn sàng bật", "Connected · ready to enable")
        }
        return language.text("Cần kết nối một lần qua luồng bảo mật", "One secure connection required")
    }

    private var statusTint: Color {
        if provider.visible { return .green }
        if provider.configured { return .blue }
        return .secondary
    }

    private var providerIcon: String {
        switch provider.connectionKind {
        case "local": "desktopcomputer"
        case "oauth": "person.badge.key.fill"
        case "anonymous": "network"
        case "custom": "slider.horizontal.3"
        default: "key.fill"
        }
    }

    private var connectionKindTitle: String {
        switch provider.connectionKind {
        case "local": language.text("Local", "Local")
        case "oauth": "OAuth"
        case "anonymous": language.text("Không cần key", "No key")
        case "custom": language.text("Tuỳ chỉnh", "Custom")
        default: "API key"
        }
    }
}

private struct RouterStatusBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.11), in: Capsule())
    }
}
