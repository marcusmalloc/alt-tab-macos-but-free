import Foundation

/// User preferences, persisted in `UserDefaults` and toggled from the status menu.
@MainActor
enum Settings {
    private static let allDisplaysKey = "allDisplays"
    private static let groupByDisplayKey = "groupByDisplay"
    private static let vimKeysKey = "vimKeys"
    private static let switcherDisplayKey = "switcherDisplay"

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

    /// Whether J, K, H and L move the highlight like Down, Up, Left and Right while the switcher is open.
    static var vimKeys: Bool {
        get { UserDefaults.standard.bool(forKey: vimKeysKey) }
        set { UserDefaults.standard.set(newValue, forKey: vimKeysKey) }
    }

    /// UUID of the display the switcher always appears on, or nil to follow the pointer. Which windows
    /// are listed does not change.
    static var switcherDisplay: String? {
        get { UserDefaults.standard.string(forKey: switcherDisplayKey) }
        set { UserDefaults.standard.set(newValue, forKey: switcherDisplayKey) }
    }
}
