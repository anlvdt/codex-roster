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

            Menu {
                Button(language.text("Tài khoản đang dùng", "Active account only")) {
                    store.refreshUsage(scope: .activeOnly)
                }
                Button(language.text("Tất cả tài khoản đã lưu", "All saved accounts")) {
                    store.refreshUsage(scope: .allSaved)
                }
            } label: {
                Label(language.text("Quota", "Quota"), systemImage: "gauge.with.dots.needle.50percent")
            }
            .labelStyle(.titleAndIcon)
            .disabled(store.accounts.isEmpty || store.isWorking)
            .help(language.text("Cập nhật quota tài khoản đang dùng (mặc định) hoặc toàn bộ danh sách.", "Refresh active-account quota by default, or every saved account."))
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
