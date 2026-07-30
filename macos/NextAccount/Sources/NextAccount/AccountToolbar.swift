import SwiftUI

struct AccountToolbar: ToolbarContent {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @Binding var showingAddAccount: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingAddAccount = true
            } label: {
                Label(language.text("Thêm", "Add"), systemImage: "person.crop.circle.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .disabled(store.isWorking)
            .help(language.text("Đăng nhập tài khoản Codex mới hoặc lưu phiên hiện tại.", "Sign in to a new Codex account or save the current session."))
            .accessibilityLabel(language.text("Thêm tài khoản", "Add account"))

            Button {
                store.refreshUsage()
            } label: {
                Label(language.text("Quota", "Quota"), systemImage: "gauge.with.dots.needle.50percent")
            }
            .labelStyle(.titleAndIcon)
            .disabled(store.accounts.isEmpty || store.isWorking)
            .help(language.text("Cập nhật quota của các tài khoản đã lưu.", "Refresh quota for saved accounts."))
            .accessibilityLabel(language.text("Cập nhật quota", "Refresh usage"))

            Button {
                store.refresh()
            } label: {
                Label(language.text("Làm mới", "Refresh"), systemImage: "arrow.triangle.2.circlepath")
            }
            .labelStyle(.titleAndIcon)
            .disabled(store.isWorking)
            .help(language.text("Tải lại danh sách và trạng thái tài khoản.", "Reload account list and status."))
            .accessibilityLabel(language.text("Tải lại trạng thái", "Reload state"))
        }
    }
}
