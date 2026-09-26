import Foundation

/// User preferences, persisted in `UserDefaults` and toggled from the status menu.
@MainActor
enum Settings {
    private static let allDisplaysKey = "allDisplays"
    private static let groupByDisplayKey = "groupByDisplay"

    /// Whether the switcher lists windows from every display, rather than only the one under the pointer.
    static var allDisplays: Bool {
        get { UserDefaults.standard.bool(forKey: allDisplaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: allDisplaysKey) }
    }

    /// Whether windows from every display are listed under a heading per display. Only applies
    /// while `allDisplays` is on.
    static var groupByDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: groupByDisplayKey) }
        set { UserDefaults.standard.set(newValue, forKey: groupByDisplayKey) }
    }
}
