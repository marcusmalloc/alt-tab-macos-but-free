import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement

/// Menu bar shell: status item, Accessibility permission, launch at login.
/// The switching itself lives in `Switcher`.
@main
enum BareTabApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let keyboard = KeyboardTap()
    private let switcher = Switcher()

    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchAtLogin = NSMenuItem(
        title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
    )

    private var permissionPoll: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        keyboard.handler = { [weak self] key in self?.switcher.handle(key) }

        if !startKeyboardIfTrusted() {
            promptForAccessibility()
            // The system does not notify us when the user flips the switch, so poll until it is on.
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.startKeyboardIfTrusted() else { return }
                    self.permissionPoll?.invalidate()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.stop()
    }

    // MARK: - Menu

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "BareTab"
        )

        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(launchAtLogin)
        menu.addItem(NSMenuItem(
            title: "Quit BareTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ))
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        launchAtLogin.state = service.status == .enabled ? .on : .off
    }

    // MARK: - Accessibility permission

    private func startKeyboardIfTrusted() -> Bool {
        guard AXIsProcessTrusted(), keyboard.start() else {
            statusLine.title = "Accessibility access required"
            return false
        }
        statusLine.title = "Command-Tab active"
        return true
    }

    private func promptForAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }
}
