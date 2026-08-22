import AppKit
import SwiftUI

struct RouterIntegrationCard: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openURL) private var openURL
    @ObservedObject var router: RouterStore

    private var status: RouterStatusOutput? { router.status }

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

                Button {
                    router.refresh()
                } label: {
                    if router.isRefreshing || router.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help(language.text("Làm mới trạng thái Router", "Refresh Router status"))
                .disabled(router.isRefreshing || router.isWorking)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    routerSummary
                    Spacer(minLength: 12)
                    routerActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    routerSummary
                    routerActions
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

    @ViewBuilder
    private var routerActions: some View {
        HStack(spacing: 8) {
            if let status, status.installed {
                Button(language.text("Chẩn đoán", "Run Doctor")) {
                    router.runDoctor()
                }
                .disabled(router.isWorking || router.isRefreshing)

                Button(language.text("Mở Control Center", "Open Control Center")) {
                    router.openControlCenter()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!status.healthy || router.isWorking || router.isRefreshing)
            } else if status != nil {
                Button(language.text("Xem hướng dẫn cài đặt", "View install guide")) {
                    openURL(status?.repositoryUrl ?? URL(string: "https://github.com/duolahypercho/codex-router")!)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(language.text("Đang kiểm tra…", "Checking…")) {}
                    .disabled(true)
            }
        }
        .controlSize(.small)
    }

    private var statusTitle: String {
        if router.isWorking {
            return language.text("Đang xử lý", "Working")
        }
        if router.isRefreshing && status == nil {
            return language.text("Đang kiểm tra", "Checking")
        }
        guard let status else { return language.text("Chưa kiểm tra", "Not checked") }
        if status.healthy { return language.text("Sẵn sàng", "Ready") }
        if status.installed { return language.text("Cần xử lý", "Needs attention") }
        return language.text("Chưa cài đặt", "Not installed")
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
            return language.text("Cài riêng, kết nối tự động", "Install separately, then auto-detect")
        }
        if status.configured {
            return language.text("Router đã thiết lập", "Router configured")
        }
        return language.text("Chưa hoàn tất thiết lập", "Setup not completed")
    }

    private func localizedDetail(_ detail: String) -> String {
        guard language.language == .vietnamese else { return detail }
        switch status?.state {
        case "ready":
            return "Dịch vụ Router local và tích hợp Codex đang phản hồi."
        case "offline":
            return "Router đã được cài nhưng dịch vụ local chưa sẵn sàng. Hãy chạy Chẩn đoán trước khi đổi provider."
        default:
            return "Cài Codex Router riêng, sau đó quay lại đây để quản lý từ Roster."
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
