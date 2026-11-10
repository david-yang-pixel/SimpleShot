import Foundation
import ServiceManagement

@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let shortcut = "shortcut"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let skippedVersion = "skippedVersion"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let translationEngine = "translationEngine"
        static let aiKind = "aiKind"
        static let aiBaseURL = "aiBaseURL"
        static let aiModel = "aiModel"
    }

    enum TranslationEngine: String {
        case system, ai
    }

    var translationEngine: TranslationEngine {
        get { TranslationEngine(rawValue: defaults.string(forKey: Key.translationEngine) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.translationEngine) }
    }

    var aiKind: AIProviderKind {
        get { AIProviderKind(rawValue: defaults.string(forKey: Key.aiKind) ?? "") ?? AIPreset.deepSeek.kind }
        set { defaults.set(newValue.rawValue, forKey: Key.aiKind) }
    }

    var aiBaseURL: String {
        get { defaults.string(forKey: Key.aiBaseURL) ?? AIPreset.deepSeek.baseURL }
        set { defaults.set(newValue, forKey: Key.aiBaseURL) }
    }

    var aiModel: String {
        get { defaults.string(forKey: Key.aiModel) ?? AIPreset.deepSeek.model }
        set { defaults.set(newValue, forKey: Key.aiModel) }
    }

    /// 当前的 AI 配置（API Key 从钥匙串读取）
    var aiConfig: AIConfig {
        AIConfig(kind: aiKind, baseURL: aiBaseURL, model: aiModel,
                 apiKey: KeychainStore.apiKey(forBaseURL: aiBaseURL))
    }

    var autoCheckUpdates: Bool {
        get { defaults.object(forKey: Key.autoCheckUpdates) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoCheckUpdates) }
    }

    var skippedVersion: String? {
        get { defaults.string(forKey: Key.skippedVersion) }
        set { defaults.set(newValue, forKey: Key.skippedVersion) }
    }

    var lastUpdateCheck: Date {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    var shortcut: Shortcut {
        get {
            if let data = defaults.data(forKey: Key.shortcut),
               let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
                return s
            }
            return .defaultShortcut
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.shortcut)
        }
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
