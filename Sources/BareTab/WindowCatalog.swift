import AppKit
@preconcurrency import ApplicationServices
import WindowBridge

/// One on-screen window as shown in the switcher.
struct WindowEntry: Identifiable {
    let id: CGWindowID
    let app: NSRunningApplication
    let icon: NSImage
    /// The display the window belongs to, which decides its group when grouped by display.
    let display: CGDirectDisplayID
    /// The app name, later suffixed with the window title when the app is listed more than once.
    var label: String
}

/// Finds, labels, focuses and closes windows on the current Space, scoped to the display under the
/// pointer unless `Settings.allDisplays` is on.
///
/// The one rule here: nothing may wait on another app unless it has to. WindowServer queries are
/// local and fast. Accessibility calls are inter-process and can block for up to `accessibilityTimeout`,
/// so they run on background queues and report back asynchronously. Raises never queue behind each
/// other, so a busy app can only ever delay the switch into itself, and each window's Accessibility
/// element is resolved ahead of time so the release-to-focus path normally does no lookup at all.
@MainActor
enum WindowCatalog {
    private nonisolated static let accessibilityTimeout: Float = 0.5

    private static let raiseQueue = DispatchQueue(label: "BareTab.raise", attributes: .concurrent)
    private static let titleQueue = DispatchQueue(label: "BareTab.titles")
    private static let prefetchQueue = DispatchQueue(label: "BareTab.prefetch", attributes: .concurrent)

    private static var iconCache: [pid_t: NSImage] = [:]

    // MARK: - Snapshot

    /// How long a switch we made counts as done even if its app has not brought the window up yet.
    private static let settleTime: TimeInterval = 1
    private static var lastFocus: (id: CGWindowID, at: Date)?

    /// `headings` names each display when the windows are grouped by display, and is empty otherwise.
    static func snapshot() -> (
        display: CGDirectDisplayID, windows: [WindowEntry], headings: [CGDirectDisplayID: String]
    ) {
        let display = displayUnderPointer()
        let allDisplays = Settings.allDisplays
        let runningApps = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let displays = activeDisplayBounds()

        var entries: [WindowEntry] = []
        for window in onScreenWindows() {
            guard allDisplays || displayID(at: window.center) == display,
                  let app = runningApps[window.pid],
                  app.activationPolicy == .regular,
                  app != .current
            else { continue }

            let icon = iconCache[window.pid] ?? app.icon ?? NSImage()
            iconCache[window.pid] = icon
            entries.append(WindowEntry(
                id: window.id, app: app, icon: icon,
                display: owningDisplay(of: window.bounds, among: displays) ?? display,
                label: app.localizedName ?? "Unknown"
            ))
        }

        // A slow app may not have raised the window we just switched to. Listing it first anyway means
        // a quick second tap goes back to the previous window instead of re-targeting the same one.
        if let lastFocus, Date().timeIntervalSince(lastFocus.at) < settleTime,
           let index = entries.firstIndex(where: { $0.id == lastFocus.id }), index > 0 {
            entries.insert(entries.remove(at: index), at: 0)
        }

        var headings: [CGDirectDisplayID: String] = [:]
        if allDisplays, Settings.groupByDisplay {
            entries = groupedByDisplay(entries)
            for id in Set(entries.map(\.display)) {
                headings[id] = screen(for: id)?.localizedName ?? "Display"
            }
        }

        prefetchElements(for: entries)
        return (display, entries, headings)
    }

    /// Windows gathered by display. Each display keeps its windows in order and is placed by its most
    /// recent window, so the current window stays first and a quick tap stays on the same display.
    private static func groupedByDisplay(_ entries: [WindowEntry]) -> [WindowEntry] {
        var order: [CGDirectDisplayID] = []
        var groups: [CGDirectDisplayID: [WindowEntry]] = [:]
        for entry in entries {
            if groups[entry.display] == nil {
                order.append(entry.display)
            }
            groups[entry.display, default: []].append(entry)
        }
        return order.flatMap { groups[$0] ?? [] }
    }

    static func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display
        }
    }

    // MARK: - Labels

    /// Labels for apps listed more than once, with the window title appended so the rows can be told
    /// apart. Delivered on the main thread once the Accessibility queries finish; only affected window
    /// IDs are included.
    static func labels(
        for entries: [WindowEntry],
        completion: @escaping @MainActor ([CGWindowID: String]) -> Void
    ) {
        let duplicates = Dictionary(grouping: entries, by: \.app.processIdentifier)
            .filter { $0.value.count > 1 }
            .mapValues { $0.map { (id: $0.id, name: $0.label) } }
        guard !duplicates.isEmpty else { return }

        titleQueue.async {
            var labels: [CGWindowID: String] = [:]
            for (pid, windows) in duplicates {
                let elements = cachedElements(for: windows.map(\.id)) ?? refresh(pid: pid)
                for (ordinal, window) in windows.enumerated() {
                    let title = elements[window.id].map(title(of:)) ?? ""
                    let suffix = title.isEmpty ? "Window \(ordinal + 1)" : title
                    labels[window.id] = "\(window.name) — \(suffix)"
                }
            }
            DispatchQueue.main.async { completion(labels) }
        }
    }

    // MARK: - Focus

    private struct FocusRequest: Equatable {
        let generation: Int
        let pid: pid_t
        let id: CGWindowID
    }

    private static var focusCount = 0
    private nonisolated static let focusLock = NSLock()
    /// The newest request. A raise that finishes and finds it has been superseded repeats the newest
    /// one, because the app it was sent to may have answered late and put the wrong window on top.
    nonisolated(unsafe) private static var latestFocus: FocusRequest?

    /// Brings the window to the front right away, then raises it through Accessibility once its app
    /// answers so the app's own notion of its key window catches up.
    static func focus(_ entry: WindowEntry) {
        focusCount += 1
        let request = FocusRequest(generation: focusCount, pid: entry.app.processIdentifier, id: entry.id)
        focusLock.withLock { latestFocus = request }
        lastFocus = (entry.id, Date())

        // The bridge switches at the WindowServer level with no round trip to the target app. Should
        // its private functions disappear, AppKit activation still works, some 30–60 ms slower.
        if !BareTabBringWindowToFront(request.pid, request.id) {
            activate(entry.app)
        }

        raiseQueue.async { raise(request) }
    }

    private static func activate(_ app: NSRunningApplication) {
        // Plain `activate()` is unreliable from a background app under macOS 14 cooperative
        // activation (measured: sometimes ignored). Handing activation over from ourselves is honored.
        if #available(macOS 14, *) {
            app.activate(from: .current, options: [])
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    /// Raises the requested window, resolving its element on demand. Blocking; background only.
    private nonisolated static func raise(_ request: FocusRequest) {
        guard isLatest(request) else { return }

        if let element = cachedElement(request.id) ?? refresh(pid: request.pid)[request.id] {
            let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            // A stale element means the window was recreated under the same ID; resolve it once more.
            if result == .invalidUIElement, let fresh = refresh(pid: request.pid)[request.id] {
                AXUIElementPerformAction(fresh, kAXRaiseAction as CFString)
            }
        }

        if !isLatest(request), let latest = focusLock.withLock({ latestFocus }) {
            raise(latest)
        }
    }

    private nonisolated static func isLatest(_ request: FocusRequest) -> Bool {
        focusLock.withLock { latestFocus == request }
    }

    // MARK: - Close

    /// Closes the window, or quits its app when that was the app's last window. The count comes
    /// from Accessibility rather than the switcher list so windows on other Spaces still count.
    /// An app that exposes no windows at all is quit, since nothing else can be closed.
    static func close(_ entry: WindowEntry) {
        let pid = entry.app.processIdentifier
        let id = entry.id

        raiseQueue.async {
            let windows = refresh(pid: pid)
            guard windows.count > 1 else {
                DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.terminate() }
                return
            }
            if let window = windows[id], let button = closeButton(of: window) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        }
    }

    // MARK: - Element cache

    /// Window ID → its Accessibility element and owning process. An app's entries are replaced
    /// wholesale whenever that app is re-resolved, so nothing accumulates for closed windows.
    nonisolated(unsafe) private static var elementCache: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    private nonisolated static let cacheLock = NSLock()

    /// Resolves elements for every app with an uncached window, while the user is still holding Command.
    private static func prefetchElements(for entries: [WindowEntry]) {
        let uncached = Set(entries.filter { cachedElement($0.id) == nil }.map(\.app.processIdentifier))
        for pid in uncached {
            prefetchQueue.async { refresh(pid: pid) }
        }
    }

    private nonisolated static func cachedElement(_ id: CGWindowID) -> AXUIElement? {
        cacheLock.withLock { elementCache[id]?.element }
    }

    /// All requested elements from the cache, or nil if any is missing.
    private nonisolated static func cachedElements(for ids: [CGWindowID]) -> [CGWindowID: AXUIElement]? {
        cacheLock.withLock {
            var elements: [CGWindowID: AXUIElement] = [:]
            for id in ids {
                guard let cached = elementCache[id] else { return nil }
                elements[id] = cached.element
            }
            return elements
        }
    }

    /// Re-resolves all of an app's windows into the cache and returns them. Blocking; background only.
    @discardableResult
    private nonisolated static func refresh(pid: pid_t) -> [CGWindowID: AXUIElement] {
        let windows = accessibilityWindows(of: pid)
        cacheLock.withLock {
            elementCache = elementCache.filter { $0.value.pid != pid }
            for (id, element) in windows {
                elementCache[id] = (pid, element)
            }
        }
        return windows
    }

    // MARK: - Accessibility (blocking; background only)

    /// The app's Accessibility windows keyed by WindowServer ID, matched through the window bridge.
    private nonisolated static func accessibilityWindows(of pid: pid_t) -> [CGWindowID: AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, accessibilityTimeout)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [:] }

        var byID: [CGWindowID: AXUIElement] = [:]
        for window in windows {
            var id = CGWindowID()
            if BareTabWindowID(window, &id) == .success {
                byID[id] = window
            }
        }
        return byID
    }

    private nonisolated static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        return value as? String ?? ""
    }

    private nonisolated static func closeButton(of window: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - WindowServer

    private struct Window {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    /// Normal-level, visible windows on the current Space, front to back.
    private static func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        return infos.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let rect = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rect),
                  bounds.width > 1, bounds.height > 1
            else { return nil }
            return Window(id: id, pid: pid, bounds: bounds)
        }
    }

    // MARK: - Displays

    /// The pointer marks where the user is looking, a better scope than where the last action happened.
    private static func displayUnderPointer() -> CGDirectDisplayID {
        guard let pointer = CGEvent(source: nil)?.location, let display = displayID(at: pointer) else {
            return CGMainDisplayID()
        }
        return display
    }

    /// Connected displays, identified by UUID because a display's ID can change when it is reconnected.
    static func connectedDisplays() -> [(id: CGDirectDisplayID, uuid: String, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let string = CFUUIDCreateString(nil, uuid)
            else { return nil }
            return (id, string as String, screen.localizedName)
        }
    }

    /// The connected display with this UUID, or nil when it is not connected.
    static func display(withUUID uuid: String) -> CGDirectDisplayID? {
        connectedDisplays().first { $0.uuid == uuid }?.id
    }

    private static func activeDisplayBounds() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        return ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
    }

    /// The display a window overlaps most, else the nearest one. The window's center is not enough:
    /// window managers such as AeroSpace hide windows by parking them almost entirely off screen, with
    /// a sliver left on the display they belong to.
    private static func owningDisplay(
        of window: CGRect, among displays: [(id: CGDirectDisplayID, bounds: CGRect)]
    ) -> CGDirectDisplayID? {
        func overlap(_ display: CGRect) -> CGFloat {
            let shared = window.intersection(display)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        func distance(_ display: CGRect) -> CGFloat {
            hypot(max(display.minX - window.midX, 0, window.midX - display.maxX),
                  max(display.minY - window.midY, 0, window.midY - display.maxY))
        }
        if let best = displays.max(by: { overlap($0.bounds) < overlap($1.bounds) }), overlap(best.bounds) > 0 {
            return best.id
        }
        return displays.min { distance($0.bounds) < distance($1.bounds) }?.id
    }

    private static func displayID(at point: CGPoint) -> CGDirectDisplayID? {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &display, &count)
        return count > 0 ? display : nil
    }
}
