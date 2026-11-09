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
