import AppKit
import SwiftUI

// MARK: - Model

@MainActor
final class SwitcherModel: ObservableObject {
    private static let quitConfirmationWindow: TimeInterval = 2

    @Published var windows: [WindowEntry] = []
    @Published var selection = 0

    /// Window armed by a first Q press. A second Q on the same window within
    /// `quitConfirmationWindow` closes it.
    @Published private(set) var pendingQuit: CGWindowID?
    private var quitTimer: Timer?

    func armQuit(_ id: CGWindowID) {
        pendingQuit = id
        quitTimer?.invalidate()
        quitTimer = Timer.scheduledTimer(
            withTimeInterval: Self.quitConfirmationWindow, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.disarmQuit() }
        }
    }

    func disarmQuit() {
        quitTimer?.invalidate()
        pendingQuit = nil
    }
}

// MARK: - View

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, entry in
                row(for: entry, isSelected: index == model.selection)
            }
        }
        .padding(8)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(for entry: WindowEntry, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: entry.icon)
                .resizable()
                .frame(width: 24, height: 24)
            Text(entry.label)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            rowColor(for: entry, isSelected: isSelected),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func rowColor(for entry: WindowEntry, isSelected: Bool) -> Color {
        if entry.id == model.pendingQuit {
            return Color.red.opacity(isSelected ? 0.5 : 0.25)
        }
        return isSelected ? Color.accentColor.opacity(0.35) : .clear
    }
}

// MARK: - Panel

/// Borderless, non-activating overlay centered on a display.
@MainActor
final class SwitcherPanel: NSPanel {
    let model = SwitcherModel()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = NSHostingView(rootView: SwitcherView(model: model))
    }

    func show(on screen: NSScreen?) {
        guard let contentView else { return }
        setContentSize(contentView.fittingSize)

        let area = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2))
        orderFrontRegardless()
    }
}
