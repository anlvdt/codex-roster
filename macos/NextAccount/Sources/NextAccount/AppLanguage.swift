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
}

@MainActor
final class LanguageStore: ObservableObject {
    private static let storageKey = "codexRoster.language"

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        language = AppLanguage(rawValue: stored ?? "") ?? .vietnamese
    }

    func text(_ vietnamese: String, _ english: String) -> String {
        language == .vietnamese ? vietnamese : english
    }
}
