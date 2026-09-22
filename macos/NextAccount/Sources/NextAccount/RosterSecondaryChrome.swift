import SwiftUI

/// Shared sizing and type scale for the secondary console (Settings / Operations / About / Backup).
enum RosterSecondaryChrome {
    static let consoleWidth: CGFloat = 720
    static let consoleHeight: CGFloat = 780
    /// Legacy aliases kept so older call sites / previews still compile.
    static let windowWidth: CGFloat = consoleWidth
    static let settingsHeight: CGFloat = consoleHeight
    static let operationsWidth: CGFloat = consoleWidth
    static let operationsHeight: CGFloat = consoleHeight
    static let aboutWidth: CGFloat = consoleWidth
    static let aboutHeight: CGFloat = consoleHeight
    static let sheetWidth: CGFloat = 540

    static let contentPadding: CGFloat = 22
    static let sectionSpacing: CGFloat = 16
    static let blockSpacing: CGFloat = 8

    static let title = Font.system(size: 17, weight: .semibold)
    static let section = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let callout = Font.system(size: 12.5, weight: .regular)
    static let caption = Font.system(size: 11.5, weight: .regular)
    static let footnote = Font.system(size: 11, weight: .regular)
    /// Dense secondary metrics (status chips, micro labels) — ~10pt
    static let micro = Font.system(size: 10, weight: .regular)
    /// Banner / status SF Symbol (~22pt)
    static let iconLarge = Font.system(size: 22, weight: .regular)
    /// Compact metric figure (~20pt)
    static let metric = Font.system(size: 20, weight: .semibold)
    /// Emphasized metric figure (~22pt rounded)
    static let metricLarge = Font.system(size: 22, weight: .bold, design: .rounded)

    static let cardFill = AnyShapeStyle(.ultraThinMaterial)
    static let cardRadius: CGFloat = 12

    /// Critically damped spring for secondary chrome expand/collapse.
    static let disclosureSpring = Animation.spring(response: 0.28, dampingFraction: 1.0)
}

extension View {
    /// Fill the console content area (no fixed outer frame — the hub owns sizing).
    func rosterSecondaryContent() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func rosterSecondaryPadding() -> some View {
        padding(RosterSecondaryChrome.contentPadding)
    }
}

/// Shared language preference control for Settings / About.
struct LanguagePreferencePicker: View {
    @EnvironmentObject private var language: LanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: RosterSecondaryChrome.blockSpacing) {
            Text(language.text("Ngôn ngữ", "Language"))
                .font(RosterSecondaryChrome.section)
            Picker(selection: $language.preference) {
                ForEach(LanguagePreference.allCases) { option in
                    Text(option.pickerLabel(in: language.language)).tag(option)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(language.text(
                "Theo hệ thống: dùng ngôn ngữ ưu tiên trong Cài đặt Hệ thống → Ngôn ngữ & Vùng.",
                "System: follows Preferred Languages in System Settings → Language & Region."
            ))
            .font(RosterSecondaryChrome.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Tabs inside the single secondary console window.
enum RosterConsoleTab: String, CaseIterable, Identifiable {
    case settings
    case operations
    case about
    case exportBackup
    case importBackup

    var id: String { rawValue }

    static let windowID = "roster-console"

    @MainActor
    func title(in language: LanguageStore) -> String {
        switch self {
        case .settings:
            language.text("Cài đặt", "Settings")
        case .operations:
            language.text("Vận hành", "Operations")
        case .about:
            language.text("Giới thiệu", "About")
        case .exportBackup:
            language.text("Xuất backup", "Export")
        case .importBackup:
            language.text("Nhập backup", "Import")
        }
    }

    var systemImage: String {
        switch self {
        case .settings: "gearshape"
        case .operations: "wrench.and.screwdriver"
        case .about: "info.circle"
        case .exportBackup: "square.and.arrow.up"
        case .importBackup: "square.and.arrow.down"
        }
    }
}

/// Live tab selection shared across entry points and the console window.
@MainActor
final class RosterConsoleSelection: ObservableObject {
    static let shared = RosterConsoleSelection()

    @Published var tab: RosterConsoleTab = .settings

    func select(_ tab: RosterConsoleTab) {
        self.tab = tab
    }
}

extension Notification.Name {
    /// Open (or raise) the roster console and select a tab. `object` is `RosterConsoleTab.rawValue`.
    static let openRosterConsole = Notification.Name("codexRoster.openRosterConsole")
}

/// Present the single secondary hub above the notch and select a tab.
@MainActor
enum RosterConsolePresenter {
    static func open(_ tab: RosterConsoleTab, using openWindow: OpenWindowAction) {
        RosterConsoleSelection.shared.select(tab)
        openWindow(id: RosterConsoleTab.windowID)
        RosterWindowSurface.presentNamedWindow(id: RosterConsoleTab.windowID)
    }

    /// For Commands / menu actions that lack `OpenWindowAction` — listeners with `openWindow` handle it.
    static func request(_ tab: RosterConsoleTab) {
        RosterConsoleSelection.shared.select(tab)
        NotificationCenter.default.post(name: .openRosterConsole, object: tab.rawValue)
    }
}
