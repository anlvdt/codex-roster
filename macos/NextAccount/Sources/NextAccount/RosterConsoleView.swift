import AppKit
import SwiftUI

/// Single tabbed hub for Settings / Operations / About / Backup (replaces multiple popup windows).
struct RosterConsoleView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @ObservedObject private var selection = RosterConsoleSelection.shared

    var body: some View {
        VStack(spacing: 0) {
            consoleTabBar
            if let toast = store.toast {
                RosterToastBanner(toast: toast) { store.toast = nil }
                Divider()
            }
            if let warning = store.statusWarnings.first {
                RosterToastBanner(
                    toast: RosterToast(text: warning, kind: .failure),
                    dismiss: { store.dismissStatusWarnings() }
                )
                Divider()
            }
            Divider()
            tabContent
                .rosterConsoleTypography()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: RosterSecondaryChrome.consoleWidth,
            idealWidth: RosterSecondaryChrome.consoleWidth,
            minHeight: RosterSecondaryChrome.consoleHeight,
            idealHeight: RosterSecondaryChrome.consoleHeight
        )
        .background(.background)
        // Console-triggered failures (export/import/restore/refresh) must be
        // visible where they happened, not only on the notch window (audit FLOW-2).
        .alert("Codex Roster", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(language.text("Sao chép chi tiết", "Copy details")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.errorMessage ?? "", forType: .string)
                store.errorMessage = nil
            }
            Button(language.text("Đồng ý", "OK"), role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        // SwiftUI `Window(title:)` does not refresh when LanguageStore changes.
        .background {
            SyncNamedWindowTitle(
                title: language.text("Bảng điều khiển", "Roster Console"),
                windowID: RosterConsoleTab.windowID
            )
        }
        .onChange(of: language.language) { _, _ in
            RosterWindowSurface.syncConsoleWindowTitle(
                language.text("Bảng điều khiển", "Roster Console")
            )
        }
    }

    private var consoleTabBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text("Bảng điều khiển", "Roster Console"))
                .font(RosterSecondaryChrome.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(RosterConsoleTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(Array(RosterConsoleTab.allCases.prefix(3))) { tab in
                            tabButton(tab)
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(RosterConsoleTab.allCases.suffix(3))) { tab in
                            tabButton(tab)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, RosterSecondaryChrome.contentPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RosterSecondaryChrome.cardFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("Bảng điều khiển", "Roster Console"))
    }

    @ViewBuilder
    private func tabButton(_ tab: RosterConsoleTab) -> some View {
        let isSelected = selection.tab == tab
        Button {
            PrismTheme.triggerHaptic()
            selection.select(tab)
        } label: {
            Label(tab.title(in: language), systemImage: tab.systemImage)
                .font(RosterSecondaryChrome.footnote.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(tab.title(in: language))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selection.tab {
        case .settings:
            AutomationSettingsView()
                .environmentObject(store)
                .environmentObject(language)
        case .operations:
            OperationsView()
                .environmentObject(store)
                .environmentObject(language)
        case .about:
            AboutView()
                .environmentObject(language)
        case .exportBackup:
            BackupTransferPane(operation: .export)
                .environmentObject(store)
                .environmentObject(language)
        case .importBackup:
            BackupTransferPane(operation: .import)
                .environmentObject(store)
                .environmentObject(language)
        }
    }
}

/// Opens/raises the console when Commands or other surfaces post `.openRosterConsole`.
struct RosterConsoleOpenBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openRosterConsole)) { notification in
                if let raw = notification.object as? String,
                   let tab = RosterConsoleTab(rawValue: raw) {
                    RosterConsoleSelection.shared.select(tab)
                }
                openWindow(id: RosterConsoleTab.windowID)
                RosterWindowSurface.presentNamedWindow(id: RosterConsoleTab.windowID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportBackup)) { _ in
                RosterConsolePresenter.open(.exportBackup, using: openWindow)
            }
            .onReceive(NotificationCenter.default.publisher(for: .importBackup)) { _ in
                RosterConsolePresenter.open(.importBackup, using: openWindow)
            }
    }
}

extension View {
    func rosterConsoleOpenBridge() -> some View {
        modifier(RosterConsoleOpenBridge())
    }
}

/// Transient confirmation banner. Success and failure use different glyphs and
/// semantic colours so it still reads in Light Mode (audit FLOW-2/VIS-1).
struct RosterToastBanner: View {
    let toast: RosterToast
    let dismiss: () -> Void
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.kind == .success ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
            Text(toast.text)
                .font(.callout)
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("Đóng thông báo", "Dismiss notification"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .combine)
    }
}
