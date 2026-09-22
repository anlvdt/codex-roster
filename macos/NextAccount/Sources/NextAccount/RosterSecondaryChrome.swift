import SwiftUI

/// Shared sizing and type scale for secondary windows (Settings, Operations, About, sheets).
enum RosterSecondaryChrome {
    static let windowWidth: CGFloat = 560
    static let settingsHeight: CGFloat = 640
    static let operationsWidth: CGFloat = 720
    static let operationsHeight: CGFloat = 860
    static let aboutWidth: CGFloat = 680
    static let aboutHeight: CGFloat = 600
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

    static let cardFill = AnyShapeStyle(.ultraThinMaterial)
    static let cardRadius: CGFloat = 12
}

extension View {
    /// Standard secondary-window frame used by Settings / Operations / About.
    func rosterSecondaryFrame(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height)
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

/// Related secondary surfaces that should link to each other bidirectionally.
enum RosterSecondaryNavTarget: String, CaseIterable, Identifiable {
    case settings
    case operations
    case about
    case exportBackup
    case importBackup

    var id: String { rawValue }

    var windowID: String? {
        switch self {
        case .settings: "settings"
        case .operations: "operations"
        case .about: "about"
        case .exportBackup, .importBackup: nil
        }
    }

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
            language.text("Xuất backup", "Export backup")
        case .importBackup:
            language.text("Nhập backup", "Import backup")
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

/// Compact cross-links so Settings / Operations / About / Backup are not dead ends.
struct RosterSecondaryLinkBar: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// Surface currently showing this bar (rendered as current, not tappable).
    var current: RosterSecondaryNavTarget?
    /// When true (sheets), dismiss before jumping to a named window.
    var dismissBeforeNavigate: Bool = false

    private var destinations: [RosterSecondaryNavTarget] {
        RosterSecondaryNavTarget.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language.text("Cửa sổ liên quan", "Related windows"))
                .font(RosterSecondaryChrome.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(destinations) { destination in
                        linkControl(for: destination)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(Array(destinations.prefix(3))) { destination in
                            linkControl(for: destination)
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(destinations.suffix(2))) { destination in
                            linkControl(for: destination)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RosterSecondaryChrome.cardFill,
            in: RoundedRectangle(cornerRadius: RosterSecondaryChrome.cardRadius)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("Cửa sổ liên quan", "Related windows"))
    }

    @ViewBuilder
    private func linkControl(for destination: RosterSecondaryNavTarget) -> some View {
        let isCurrent = destination == current
        if isCurrent {
            Label(destination.title(in: language), systemImage: destination.systemImage)
                .font(RosterSecondaryChrome.footnote.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button {
                navigate(to: destination)
            } label: {
                Label(destination.title(in: language), systemImage: destination.systemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(destination.title(in: language))
        }
    }

    private func navigate(to destination: RosterSecondaryNavTarget) {
        if dismissBeforeNavigate {
            dismiss()
        }
        switch destination {
        case .settings, .operations, .about:
            guard let windowID = destination.windowID else { return }
            openWindow(id: windowID)
            RosterWindowSurface.presentNamedWindow(id: windowID)
        case .exportBackup:
            NotificationCenter.default.post(name: .exportBackup, object: nil)
        case .importBackup:
            NotificationCenter.default.post(name: .importBackup, object: nil)
        }
    }
}
