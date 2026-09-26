import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement

/// Menu bar shell: status item, settings menu, Accessibility permission, launch at login.
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let keyboard = KeyboardTap()
    private let switcher = Switcher()

    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchAtLogin = NSMenuItem(
        title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
    )
    private let allDisplays = NSMenuItem(
        title: "Include All Displays", action: #selector(toggleAllDisplays), keyEquivalent: ""
    )
    private let groupByDisplay = NSMenuItem(
        title: "Group by Display", action: #selector(toggleGroupByDisplay), keyEquivalent: ""
    )
    private let vimKeys = NSMenuItem(
        title: "Vim Keys", action: #selector(toggleVimKeys), keyEquivalent: ""
    )
    private let switcherDisplayMenu = NSMenu()

    private var permissionPoll: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        keyboard.handler = { [weak self] key in self?.switcher.handle(key) }
        keyboard.vimKeys = Settings.vimKeys

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
        allDisplays.target = self
        allDisplays.state = Settings.allDisplays ? .on : .off
        groupByDisplay.target = self
        groupByDisplay.state = Settings.groupByDisplay ? .on : .off
        groupByDisplay.indentationLevel = 1
        vimKeys.target = self
        vimKeys.state = Settings.vimKeys ? .on : .off
        switcherDisplayMenu.delegate = self

        let switcherDisplay = NSMenuItem(title: "Show Switcher On", action: nil, keyEquivalent: "")
        switcherDisplay.submenu = switcherDisplayMenu

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(launchAtLogin)
        menu.addItem(allDisplays)
        menu.addItem(groupByDisplay)
        menu.addItem(switcherDisplay)
        menu.addItem(vimKeys)
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

    @objc private func toggleAllDisplays() {
        Settings.allDisplays.toggle()
        allDisplays.state = Settings.allDisplays ? .on : .off
    }

    @objc private func toggleGroupByDisplay() {
        Settings.groupByDisplay.toggle()
        groupByDisplay.state = Settings.groupByDisplay ? .on : .off
    }

    /// Rebuilt each time it opens, so it lists the displays connected right now. A chosen display that
    /// is not connected is kept in settings but shown as following the pointer, which is what happens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === switcherDisplayMenu else { return }
        let displays = WindowCatalog.connectedDisplays()
        let chosen = displays.first { $0.uuid == Settings.switcherDisplay }?.uuid

        menu.removeAllItems()
        menu.addItem(switcherDisplayItem(title: "Display Under Pointer", uuid: nil, chosen: chosen))
        menu.addItem(.separator())
        for display in displays {
            menu.addItem(switcherDisplayItem(title: display.name, uuid: display.uuid, chosen: chosen))
        }
    }

    private func switcherDisplayItem(title: String, uuid: String?, chosen: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseSwitcherDisplay(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = uuid
        item.state = uuid == chosen ? .on : .off
        return item
    }

    @objc private func chooseSwitcherDisplay(_ sender: NSMenuItem) {
        Settings.switcherDisplay = sender.representedObject as? String
    }

    @objc private func toggleVimKeys() {
        Settings.vimKeys.toggle()
        keyboard.vimKeys = Settings.vimKeys
        vimKeys.state = Settings.vimKeys ? .on : .off
    }

    /// Grouping only means something while every display is included, so it is greyed out otherwise.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem !== groupByDisplay || Settings.allDisplays
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
