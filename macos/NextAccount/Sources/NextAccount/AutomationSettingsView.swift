import SwiftUI

/// Automation and recovery are settings, not status, so they answer to the
/// standard Settings shortcut instead of trailing the Overview scroll.
struct AutomationSettingsView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @State private var confirmingFullBackupRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RosterSecondaryChrome.sectionSpacing) {
                Label(language.text("Cài đặt", "Settings"), systemImage: "gearshape.2")
                    .font(RosterSecondaryChrome.title)

                LanguagePreferencePicker()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RosterSecondaryChrome.cardFill,
                        in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius)
                    )

                settingsSection(
                    title: language.text("Tự động hóa", "Automation"),
                    caption: language.text(
                        "Notch giữ quota và chuyển nhanh; phần này chỉ bật/tắt hành vi nền.",
                        "The notch owns quota and quick-switch; this panel only toggles background behavior."
                    )
                ) {
                    Toggle(
                        language.text(
                            "Tự động kiểm tra cửa sổ quota đến hạn",
                            "Automatically check due quota windows"
                        ),
                        isOn: Binding(
                            get: { store.autoStartUsageWindows },
                            set: { store.setAutoStartUsageWindows($0) }
                        )
                    )
                    .disabled(store.isWorking)
                    Text(language.text(
                        "Quét nền các cửa sổ tuần đã đến hạn — không đăng nhập tài khoản nghỉ.",
                        "Background scan of due weekly windows — does not sign into resting accounts."
                    ))
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.secondary)

                    if store.isRefreshingQuotaInBackground {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(language.text("Đang cập nhật quota…", "Updating quota…"))
                        }
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                    } else if let lastQuotaRefreshAt = store.lastQuotaRefreshAt {
                        Text(language.text(
                            "Đã cập nhật \(lastQuotaRefreshAt.formatted(date: .omitted, time: .shortened))",
                            "Updated \(lastQuotaRefreshAt.formatted(date: .omitted, time: .shortened))"
                        ))
                        .font(RosterSecondaryChrome.caption)
                        .foregroundStyle(.secondary)
                    }

                    Toggle(
                        language.text(
                            "Tự động chuyển khi hết quota",
                            "Auto-switch when quota is exhausted"
                        ),
                        isOn: Binding(
                            get: { store.autoSwitchWhenExhausted },
                            set: { store.setAutoSwitchWhenExhausted($0) }
                        )
                    )
                    .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
                    Text(language.text(
                        "Hết quota → đóng ChatGPT → đổi ~/.codex → mở lại Desktop. Chi tiết xem Vận hành.",
                        "Exhausted → quit ChatGPT → switch ~/.codex → relaunch Desktop. See Operations for details."
                    ))
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.secondary)

                    Toggle(
                        language.text("Tự khôi phục phiên (Auto-resume)", "Auto-resume session"),
                        isOn: Binding(
                            get: { store.autoResumeSession },
                            set: { store.setAutoResumeSession($0) }
                        )
                    )
                    .disabled(store.isBusyForActions)
                    Text(language.text(
                        "Sau auto-switch: mở lại thread bị chặn và gửi tin tiếp tục qua `codex queue`.",
                        "After auto-switch: reopen the blocked thread and queue a continue message via `codex queue`."
                    ))
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.secondary)
                }

                settingsSection(
                    title: language.text("Giao diện & khởi động", "Appearance & launch"),
                    caption: nil
                ) {
                    Toggle(
                        language.text(
                            "Mở Codex Roster khi đăng nhập macOS",
                            "Open Codex Roster at login"
                        ),
                        isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        )
                    )
                    .disabled(store.isWorking)
                    Toggle(
                        language.text(
                            "Hiện notch quota trên cùng màn hình",
                            "Show the quota notch at the top of the screen"
                        ),
                        isOn: Binding(
                            get: { store.notchPanelEnabled },
                            set: { store.setNotchPanelEnabled($0) }
                        )
                    )
                    Text(language.text(
                        "⌃⌥R mở/đóng notch · Esc đóng.",
                        "⌃⌥R toggles the notch · Esc closes it."
                    ))
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.secondary)
                }

                settingsSection(
                    title: language.text("Bảo trì", "Maintenance"),
                    caption: language.text(
                        "Sao lưu đầy đủ được mã hóa bằng Keychain máy này (tối đa 5 bản).",
                        "Full backups are encrypted with this Mac's Keychain key (keeps 5)."
                    )
                ) {
                    HStack {
                        Button(language.text("Kiểm tra ngay", "Run refresh check now")) {
                            store.runUsageWindowCheck()
                        }
                        .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
                        if store.autoSwitchWhenExhausted {
                            Button(language.text("Kiểm tra & chuyển", "Check & switch")) {
                                store.runAutoSwitchCheck()
                            }
                            .disabled(store.isBusyForActions || store.isCheckingAutoSwitch)
                        }
                        Spacer()
                    }
                    .controlSize(.small)

                    HStack {
                        Button(language.text("Khôi phục tài khoản cũ", "Recover older accounts")) {
                            store.recoverLegacySnapshots()
                        }
                        .disabled(store.isWorking)
                        Button(language.text("Khôi phục phiên sao lưu", "Restore saved sessions")) {
                            confirmingFullBackupRestore = true
                        }
                        .disabled(store.isWorking)
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }
            .rosterSecondaryPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .rosterSecondaryContent()
        .confirmationDialog(
            language.text("Khôi phục phiên sao lưu?", "Restore saved sessions?"),
            isPresented: $confirmingFullBackupRestore,
            titleVisibility: .visible
        ) {
            Button(language.text("Khôi phục", "Restore"), role: .destructive) {
                store.restoreLatestFullBackup()
            }
            Button(language.text("Hủy", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text(
                "Danh sách hiện tại sẽ được thay bằng bản sao tự động gần nhất trên máy này. Hãy lưu lại tài khoản hiện tại trước; không nên kích hoạt ngay các hàng vừa khôi phục khi chưa kiểm tra.",
                "The current list will be replaced by this Mac's latest automatic backup. Save current first; do not activate restored rows blindly."
            ))
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        title: String,
        caption: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RosterSecondaryChrome.blockSpacing) {
            Text(title)
                .font(RosterSecondaryChrome.section)
            if let caption {
                Text(caption)
                    .font(RosterSecondaryChrome.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RosterSecondaryChrome.cardFill,
            in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius)
        )
    }
}
