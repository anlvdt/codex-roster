import Foundation

/// Explicit UI language choice. `.system` follows macOS preferred languages.
enum LanguagePreference: String, CaseIterable, Identifiable {
    case system
    case vietnamese = "vi"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System / Theo hệ thống"
        case .vietnamese: "Tiếng Việt"
        case .english: "English"
        }
    }

    /// Menu label that stays bilingual regardless of current UI language.
    func pickerLabel(in language: AppLanguage) -> String {
        switch self {
        case .system:
            language == .vietnamese ? "Theo hệ thống" : "System"
        case .vietnamese:
            "Tiếng Việt"
        case .english:
            "English"
        }
    }

    func resolve() -> AppLanguage {
        switch self {
        case .vietnamese: .vietnamese
        case .english: .english
        case .system: AppLanguage.fromSystem()
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case vietnamese = "vi"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vietnamese: "Tiếng Việt"
        case .english: "English"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    fileprivate static let preferenceKey = "codexRoster.language"
    fileprivate static let legacyLanguageKey = "codexRoster.language"

    /// Preference currently stored (system / vi / en).
    static var preference: LanguagePreference {
        get {
            let raw = UserDefaults.standard.string(forKey: preferenceKey)
            if raw == LanguagePreference.system.rawValue { return .system }
            if raw == LanguagePreference.vietnamese.rawValue { return .vietnamese }
            if raw == LanguagePreference.english.rawValue { return .english }
            // Missing key → follow the Mac. Explicit legacy "vi"/"en" still honored.
            if raw == nil { return .system }
            return .vietnamese
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
        }
    }

    /// Language currently resolved for the app (usable outside `LanguageStore`).
    static var current: AppLanguage {
        preference.resolve()
    }

    static func fromSystem() -> AppLanguage {
        let preferred = Locale.preferredLanguages
        if let first = preferred.first?.lowercased(), first.hasPrefix("vi") {
            return .vietnamese
        }
        // Also honor AppleLanguages / current locale region when preferred list is empty.
        let code = Locale.current.language.languageCode?.identifier.lowercased() ?? ""
        if code.hasPrefix("vi") { return .vietnamese }
        return .english
    }

    static func text(_ vietnamese: String, _ english: String) -> String {
        current == .vietnamese ? vietnamese : english
    }
}

@MainActor
final class LanguageStore: ObservableObject {
    @Published var preference: LanguagePreference {
        didSet {
            AppLanguage.preference = preference
            language = preference.resolve()
        }
    }

    @Published private(set) var language: AppLanguage

    private var localeObserver: NSObjectProtocol?

    init() {
        let preference = AppLanguage.preference
        self.preference = preference
        self.language = preference.resolve()
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFromSystemIfNeeded()
            }
        }
    }

    func text(_ vietnamese: String, _ english: String) -> String {
        language == .vietnamese ? vietnamese : english
    }

    func refreshFromSystemIfNeeded() {
        guard preference == .system else { return }
        let resolved = AppLanguage.fromSystem()
        if language != resolved {
            language = resolved
        }
    }
}
