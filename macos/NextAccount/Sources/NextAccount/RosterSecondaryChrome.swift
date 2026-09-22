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
