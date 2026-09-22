import SwiftUI

/// Single tabbed hub for Settings / Operations / About / Backup (replaces multiple popup windows).
struct RosterConsoleView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var language: LanguageStore
    @ObservedObject private var selection = RosterConsoleSelection.shared

    var body: some View {
        VStack(spacing: 0) {
            consoleTabBar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: RosterSecondaryChrome.consoleWidth,
            idealWidth: RosterSecondaryChrome.consoleWidth,
            minHeight: RosterSecondaryChrome.consoleHeight,
            idealHeight: RosterSecondaryChrome.consoleHeight
        )
        .background(.background)
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
                        ForEach(Array(RosterConsoleTab.allCases.suffix(2))) { tab in
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
