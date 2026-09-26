import AppKit
@preconcurrency import CoreGraphics

/// An active CGEvent tap that owns Command-Tab while running.
///
/// A passive `NSEvent` monitor cannot suppress the native switcher, so this is a real tap at the
/// head of the session's event stream. Its callback blocks keyboard delivery to every app until it
/// returns, which is why it only decides whether to swallow an event and hands the rest to `handler`
/// on the next main-loop turn.
@MainActor
final class KeyboardTap {
    enum Key {
        case forward
        case backward
        case nextGroup
        case previousGroup
        case commit
        case cancel
        case quit
    }

    private enum KeyCode {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

    var handler: ((Key) -> Void)?
    private(set) var isRunning = false

    private var tap: CFMachPort?
    /// True between the first Command-Tab and the release of Command.
    private var inGesture = false

    // MARK: - Start and stop

    func start() -> Bool {
        guard tap == nil else { return true }

        let events = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let tap = Unmanaged<KeyboardTap>.fromOpaque(userInfo!).takeUnretainedValue()
            return MainActor.assumeIsolated { tap.route(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(events),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        isRunning = true
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
        isRunning = false
        inGesture = false
    }

    // MARK: - Routing

    /// Returns nil to swallow the event, or the event itself to let it through.
    private func route(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap it considers slow; re-enable rather than silently losing Command-Tab.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough

        case .flagsChanged:
            if inGesture, !event.flags.contains(.maskCommand) {
                inGesture = false
                emit(.commit)
            }
            return passThrough

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            if keyCode == KeyCode.tab, event.flags.contains(.maskCommand) {
                inGesture = true
                emit(event.flags.contains(.maskShift) ? .backward : .forward)
                return nil
            }
            guard inGesture else { return passThrough }

            switch keyCode {
            case KeyCode.escape:
                inGesture = false
                emit(.cancel)
                return nil
            case KeyCode.returnKey, KeyCode.keypadEnter:
                // Switches now; releasing Command afterwards then does nothing more.
                inGesture = false
                emit(.commit)
                return nil
            case KeyCode.down:
                emit(.forward)
                return nil
            case KeyCode.up:
                emit(.backward)
                return nil
            case KeyCode.right:
                emit(.nextGroup)
                return nil
            case KeyCode.left:
                emit(.previousGroup)
                return nil
            default:
                break
            }
            // Matched by character rather than key code so it works on any keyboard layout.
            if NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() == "q" {
                emit(.quit)
                return nil
            }
            return passThrough

        default:
            return passThrough
        }
    }

    private func emit(_ key: Key) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handler?(key) }
        }
    }
}
