import Foundation

/// Menu-bar title display preference (non-sensitive; persisted in UserDefaults).
public enum StatusDisplayMode: String, CaseIterable, Sendable, Equatable {
    case dollarsRemaining = "dollarsRemaining"
    case percentRemaining = "percentRemaining"

    public var settingsLabel: String {
        switch self {
        case .dollarsRemaining:
            return "$ remaining"
        case .percentRemaining:
            return "% remaining"
        }
    }
}

public enum AppPreferences {
    public static let displayModeKey = "statusDisplayMode"

    public static func displayMode(defaults: UserDefaults = .standard) -> StatusDisplayMode {
        if let raw = defaults.string(forKey: displayModeKey),
           let mode = StatusDisplayMode(rawValue: raw)
        {
            return mode
        }
        return .dollarsRemaining
    }

    public static func setDisplayMode(_ mode: StatusDisplayMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: displayModeKey)
    }
}
