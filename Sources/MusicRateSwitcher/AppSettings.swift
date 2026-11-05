import Foundation
import RateSwitcherCore

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon
    case compact
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return "图标"
        case .compact: return "紧凑"
        case .detailed: return "详细"
        }
    }
}

final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let autoSwitch = "autoSwitch"
        static let selectedDeviceUID = "selectedDeviceUID"
        static let showRateInMenuBar = "showRateInMenuBar"
        static let menuBarStyle = "menuBarStyle"
        static let didMigrateLegacyDefaults = "didMigrateLegacyDefaults"
    }

    private let defaults = UserDefaults.standard

    private init() {
        migrateLegacyDefaultsIfNeeded()
        defaults.register(defaults: [
            Key.autoSwitch: true,
            Key.showRateInMenuBar: true
        ])
    }

    var autoSwitch: Bool {
        get { defaults.bool(forKey: Key.autoSwitch) }
        set { defaults.set(newValue, forKey: Key.autoSwitch) }
    }

    var selectedDeviceUID: String? {
        get { defaults.string(forKey: Key.selectedDeviceUID) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.selectedDeviceUID) }
            else { defaults.removeObject(forKey: Key.selectedDeviceUID) }
        }
    }

    var showRateInMenuBar: Bool {
        get { defaults.bool(forKey: Key.showRateInMenuBar) }
        set { defaults.set(newValue, forKey: Key.showRateInMenuBar) }
    }

    /// Falls back to the legacy `showRateInMenuBar` switch for users upgrading from 1.2.
    var menuBarStyle: MenuBarStyle {
        get {
            if let raw = defaults.string(forKey: Key.menuBarStyle), let style = MenuBarStyle(rawValue: raw) { return style }
            return showRateInMenuBar ? .compact : .icon
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.menuBarStyle)
            showRateInMenuBar = newValue != .icon
        }
    }

    // AM is the only source; old per-player preferences cannot disable it.
    func isSourceEnabled(_ player: MusicPlayerID) -> Bool { player == .appleMusic }

    private func migrateLegacyDefaultsIfNeeded() {
        guard defaults.object(forKey: Key.didMigrateLegacyDefaults) == nil else { return }
        if let old = UserDefaults(suiteName: "io.github.netease-rate-switcher") {
            for key in [Key.autoSwitch, Key.selectedDeviceUID, Key.showRateInMenuBar] {
                if defaults.object(forKey: key) == nil, let value = old.object(forKey: key) {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: Key.didMigrateLegacyDefaults)
    }
}
