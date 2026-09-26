import Foundation

/// User preferences, persisted in `UserDefaults` and toggled from the status menu.
@MainActor
enum Settings {
    private static let allDisplaysKey = "allDisplays"

    /// Whether the switcher lists windows from every display, rather than only the one under the pointer.
    static var allDisplays: Bool {
        get { UserDefaults.standard.bool(forKey: allDisplaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: allDisplaysKey) }
    }
}
