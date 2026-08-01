import Foundation

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

    fileprivate static let storageKey = "codexRoster.language"

    /// Language currently stored for the app (usable outside `LanguageStore`).
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .vietnamese
    }

    static func text(_ vietnamese: String, _ english: String) -> String {
        current == .vietnamese ? vietnamese : english
    }
}

@MainActor
final class LanguageStore: ObservableObject {
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey) }
    }

    init() {
        language = AppLanguage.current
    }

    func text(_ vietnamese: String, _ english: String) -> String {
        language == .vietnamese ? vietnamese : english
    }
}
