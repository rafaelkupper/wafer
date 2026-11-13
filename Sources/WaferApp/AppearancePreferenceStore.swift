import AppKit
import Foundation
import WaferCore

extension Notification.Name {
    static let appearancePreferenceDidChange = Notification.Name("AppearancePreferenceStore.appearancePreferenceDidChange")
}

enum AppearanceSelection: Equatable, Sendable {
    case system
    case light
    case dark
    case custom(String)

    init(rawValue: String) {
        switch rawValue {
        case Self.light.rawValue:
            self = .light
        case Self.dark.rawValue:
            self = .dark
        case let value where value.hasPrefix("custom:"):
            self = .custom(String(value.dropFirst("custom:".count)))
        default:
            self = .system
        }
    }

    var rawValue: String {
        switch self {
        case .system:
            "system"
        case .light:
            "light"
        case .dark:
            "dark"
        case .custom(let name):
            "custom:\(name)"
        }
    }

    var menuTitle: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        case .custom(let name):
            name
        }
    }

    static let builtInMenuSelections: [AppearanceSelection] = [.system, .light, .dark]
}

@MainActor
final class AppearancePreferenceStore {
    static let shared = AppearancePreferenceStore()

    private enum DefaultsKey {
        static let appearanceSelection = "appearanceSelection"
    }

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let themeLibrary: ThemeLibrary
    private let systemIsDark: @MainActor () -> Bool
    private let missingCustomThemeNotifier: @MainActor (String) -> Void
    private var notifiedMissingCustomThemeNames: Set<String> = []

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        themeLibrary: ThemeLibrary = .shared,
        missingCustomThemeNotifier: @escaping @MainActor (String) -> Void = AppearancePreferenceStore.defaultMissingCustomThemeNotifier,
        systemIsDark: @escaping @MainActor () -> Bool = AppearancePreferenceStore.defaultSystemIsDark
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.themeLibrary = themeLibrary
        self.missingCustomThemeNotifier = missingCustomThemeNotifier
        self.systemIsDark = systemIsDark
    }

    var appearanceSelection: AppearanceSelection {
        get {
            guard let rawValue = defaults.string(forKey: DefaultsKey.appearanceSelection) else {
                return .system
            }
            return AppearanceSelection(rawValue: rawValue)
        }
        set {
            guard appearanceSelection != newValue else {
                return
            }

            defaults.set(newValue.rawValue, forKey: DefaultsKey.appearanceSelection)
            notifyIfNeeded(forMissingCustomTheme: newValue)
            applyResolvedPalette()
            notificationCenter.post(
                name: .appearancePreferenceDidChange,
                object: self,
                userInfo: AppearancePreferenceChange(selection: newValue).userInfo
            )
        }
    }

    func resolvedPalette() -> ReaderThemePalette {
        switch appearanceSelection {
        case .system:
            systemIsDark() ? .dark : .light
        case .light:
            .light
        case .dark:
            .dark
        case .custom(let name):
            themeLibrary.palette(named: name) ?? .dark
        }
    }

    @discardableResult
    func reloadThemes() -> ThemeLibraryLoadResult {
        themeLibrary.loadThemes()
    }

    func applyResolvedPalette() {
        ReaderTheme.setCurrent(resolvedPalette())
    }

    func applySystemAppearanceIfNeeded() {
        guard appearanceSelection == .system else {
            return
        }

        applyResolvedPalette()
    }

    private func notifyIfNeeded(forMissingCustomTheme selection: AppearanceSelection) {
        guard case .custom(let name) = selection, themeLibrary.palette(named: name) == nil else {
            return
        }

        guard notifiedMissingCustomThemeNames.insert(name).inserted else {
            return
        }

        missingCustomThemeNotifier(name)
    }

    private static func defaultSystemIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func defaultMissingCustomThemeNotifier(name: String) {
        let alert = NSAlert()
        alert.messageText = "Custom Theme Unavailable"
        alert.informativeText = "\"\(name)\" could not be loaded. Wafer is using Dark until the theme is available again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
