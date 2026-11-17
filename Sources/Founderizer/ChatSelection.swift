import AppKit
import FleetCore
import SwiftUI

/// **The words of an agent's chat can be selected in two rows at a time** (`ChatWordsSelection` in FleetCore says why):
/// the row under the pointer, where a press starts a selection, and the row whose words he pressed last. In every
/// other row the words of the messages have no hidden text field over them, so a frame of the chat's scroll moves
/// almost none. Each row reads a flag of its own, so a change draws those rows again and not the chat.
@MainActor final class ChatSelection {
    @MainActor @Observable final class Flag {
        fileprivate(set) var on = false
    }

    private var rule = ChatWordsSelection()
    private var flags: [String: Flag] = [:]
    private var monitor: Any?

    /// The flag of `row`, which only that row reads.
    func flag(_ row: String) -> Flag {
        if let flag = flags[row] { return flag }
        let flag = Flag()
        flag.on = rule.selectable.contains(row)
        flags[row] = flag
        return flag
    }

    func hover(_ row: String, inside: Bool) { change { $0.hover(row, inside: inside) } }

    func scroll(moving: Bool) { change { $0.scroll(moving: moving) } }

    /// Watches the presses of the mouse while the chat shows. The monitor runs on the main thread before the press
    /// reaches a view, and the row under the pointer has its fields already, so the press starts a selection there.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                // A click that the hold drops reaches no control of the app, and moves no row (`AppFront.reaches`).
                guard AppFront.reaches(event) else { return }
                self?.change { $0.press(onWords: Self.onWords(event)) }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The press is on words: on a text that he can select or write in, the AppKit view under the pointer, found as
    /// `FleetContextMenus` finds the view of a right click.
    private static func onWords(_ event: NSEvent) -> Bool {
        guard let frameView = event.window?.contentView?.superview else { return false }
        var view = frameView.hitTest(event.locationInWindow)
        while let candidate = view {
            if candidate is NSTextField || candidate is NSTextView { return true }
            view = candidate.superview
        }
        return false
    }

    private func change(_ step: (inout ChatWordsSelection) -> Void) {
        let before = rule.selectable
        step(&rule)
        for row in before.symmetricDifference(rule.selectable) { flags[row]?.on = rule.selectable.contains(row) }
    }
}

extension View {
    /// The words of the chat's row `row` can be selected while `selection` says so (`ChatSelection`).
    func wordsSelectable(in selection: ChatSelection, row: String) -> some View {
        modifier(SelectableRow(selection: selection, row: row))
    }
}

private struct SelectableRow: ViewModifier {
    let selection: ChatSelection
    let row: String

    func body(content: Content) -> some View {
        content
            .environment(\.messageWordsSelectable, selection.flag(row).on)
            // The whole row, also the room between its lines and under its words.
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: selection.hover(row, inside: true)
                case .ended: selection.hover(row, inside: false)
                }
            }
    }
}
