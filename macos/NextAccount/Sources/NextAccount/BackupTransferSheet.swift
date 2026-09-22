import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BackupOperation: Identifiable {
    case export
    case `import`

    var id: String {
        switch self {
        case .export: "export"
        case .import: "import"
        }
    }
}

struct BackupTransferSheet: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    let operation: BackupOperation
    @State private var password = ""
    @State private var confirmation = ""
    @State private var selectedURL: URL?

    private var isExport: Bool {
        if case .export = operation { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(
                isExport
                    ? language.text("Xuất bản sao lưu mã hóa", "Export encrypted backup")
                    : language.text("Nhập bản sao lưu mã hóa", "Import encrypted backup"),
                systemImage: isExport ? "lock.doc.fill" : "lock.doc"
            )
            .font(RosterSecondaryChrome.title)
            .foregroundStyle(.tint)

            Text(language.text(
                "Bản sao lưu chứa phiên đăng nhập Codex. Mật khẩu chỉ dùng để mã hóa hoặc giải mã file này và không được lưu lại.",
                "A backup contains Codex sign-in snapshots. The password is used only to encrypt or decrypt this file and is never stored."
            ))
            .font(RosterSecondaryChrome.body)
            .foregroundStyle(.secondary)

            if !isExport {
                Text(language.text(
                    "Cảnh báo: snapshot nhập vào có thể giữ refresh token cũ hơn phiên Codex đang sống. Hãy Save current trước; đừng kích hoạt hàng vừa nhập một cách mù quáng — có thể buộc đăng nhập lại.",
                    "Warning: imported snapshots may hold stale refresh tokens vs live Codex. Save the current session first; do not activate imported rows blindly — that can force re-login."
                ))
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !isExport {
                HStack {
                    Button(language.text("Chọn file backup…", "Choose backup file…")) {
                        selectedURL = chooseImportFile()
                    }
                    if let selectedURL {
                        Text(selectedURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                            .help(selectedURL.lastPathComponent)
                    }
                }
            }

            SecureField(language.text("Mật khẩu", "Password"), text: $password)
            if isExport {
                SecureField(language.text("Nhập lại mật khẩu", "Confirm password"), text: $confirmation)
            }

            if let backupStatusMessage = store.backupStatusMessage {
                Text(backupStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(language.text("Hủy", "Cancel")) { dismiss() }
                Spacer()
                Button(isExport ? language.text("Xuất backup…", "Export backup…") : language.text("Nhập backup", "Import backup")) {
                    performTransfer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canTransfer || store.isWorking)
            }
        }
        .padding(24)
        .frame(width: RosterSecondaryChrome.sheetWidth)
    }

    private var canTransfer: Bool {
        !password.isEmpty && (!isExport || password == confirmation) && (isExport || selectedURL != nil)
    }

    private func performTransfer() {
        if isExport {
            guard let destination = chooseExportDestination() else { return }
            store.exportBackup(to: destination, password: password)
        } else if let selectedURL {
            store.importBackup(from: selectedURL, password: password)
        }
    }

    private func chooseExportDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "codexroster")!]
        panel.nameFieldStringValue = "Codex Roster Backup.codexroster"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "codexroster")!]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
