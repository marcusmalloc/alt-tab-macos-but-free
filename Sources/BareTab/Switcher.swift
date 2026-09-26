import AppKit

/// The Command-Tab gesture: freeze a window list on the first Tab, move the highlight on each
/// further Tab, and act when Command is released. Owns the overlay panel.
///
/// Like the native switcher, the panel only appears once Command has been held for a moment,
/// so a quick tap switches to the previous window without anything flashing on screen.
@MainActor
final class Switcher {
    private static let showDelay: TimeInterval = 0.04

    private let panel = SwitcherPanel()
    private var model: SwitcherModel { panel.model }

    private var isActive = false
    /// Incremented per gesture so late asynchronous results can tell whether they still apply.
    private var generation = 0
    private var showTimer: Timer?

    func handle(_ key: KeyboardTap.Key) {
        switch key {
        case .forward: move(by: 1)
        case .backward: move(by: -1)
        case .commit: commit()
        case .cancel: end()
        case .quit: quit()
        }
    }

    // MARK: - Gesture

    private func move(by step: Int) {
        if !isActive {
            guard begin() else { return }
        }
        let count = model.windows.count
        model.selection = (model.selection + step + count) % count
    }

    /// Takes the snapshot and schedules the panel. Returns false when there is nothing to switch between.
    private func begin() -> Bool {
        let snapshot = WindowCatalog.snapshot()
        guard !snapshot.windows.isEmpty else { return false }

        isActive = true
        generation += 1
        model.windows = snapshot.windows
        model.headings = snapshot.headings
        model.selection = 0

        let display = snapshot.display
        let gesture = generation
        showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.show(on: display, gesture: gesture)
            }
        }
        return true
    }

    private func show(on display: CGDirectDisplayID, gesture: Int) {
        panel.show(on: WindowCatalog.screen(for: display))

        // Titles arrive later because they require a round trip to each app.
        WindowCatalog.labels(for: model.windows) { [weak self] labels in
            guard let self, self.isActive, self.generation == gesture else { return }
            for index in self.model.windows.indices {
                if let label = labels[self.model.windows[index].id] {
                    self.model.windows[index].label = label
                }
            }
        }
    }

    private func commit() {
        let selected = selectedWindow
        end()
        if let selected {
            WindowCatalog.focus(selected)
        }
    }

    private func end() {
        showTimer?.invalidate()
        isActive = false
        model.disarmQuit()
        panel.orderOut(nil)
    }

    // MARK: - Quit

    /// First Q arms the highlighted window; only a second Q on that same window confirms.
    private func quit() {
        guard isActive, let entry = selectedWindow else { return }

        guard model.pendingQuit == entry.id else {
            model.armQuit(entry.id)
            return
        }

        model.disarmQuit()
        WindowCatalog.close(entry)
        model.windows.remove(at: model.selection)

        if model.windows.isEmpty {
            end()
        } else {
            model.selection = min(model.selection, model.windows.count - 1)
        }
    }

    private var selectedWindow: WindowEntry? {
        model.windows.indices.contains(model.selection) ? model.windows[model.selection] : nil
    }
}
