import AppKit
import FleetCore
import SwiftUI

/// **The words of an agent's chat, a task thread, a conversation and a knowledge file can be selected in two rows at a
/// time** (`ChatWordsSelection` in FleetCore says why; a long block or cell of a knowledge file always,
/// `MessageText.selection`): the row under the pointer, where a press starts a selection, and the row whose words he
/// pressed last. In every other row the words of the messages have no hidden text field over them, so a frame of the
/// chat's scroll moves almost none. Each row reads a flag of its own, so a change draws those rows again and not the
/// chat.
@MainActor final class ChatSelection {
    @MainActor @Observable final class Flag {
        fileprivate(set) var on = false
    }

    private var rule = ChatWordsSelection()
    private var flags: [String: Flag] = [:]
    private var monitor: Any?
    /// Where each row of a long text stands in the text (`MessageText.selection`), and the row under the pointer: that
    /// text has one hover for all of its rows (`pointer(at:)`).
    private var places: [String: CGRect] = [:]
    private var placeUnderPointer: String?
    /// Where the pointer stood last in that text; nil while it is not over the text.
    private var lastPoint: CGPoint?

    /// The flag of `row`, which only that row reads.
    func flag(_ row: String) -> Flag {
        if let flag = flags[row] { return flag }
        let flag = Flag()
        flag.on = rule.selectable.contains(row)
        flags[row] = flag
        return flag
    }

    func hover(_ row: String, inside: Bool) { change { $0.hover(row, inside: inside) } }

    /// Where the row `row` of a long text stands in the text, or nil when the row is gone. **A layout that moves the
    /// rows under a pointer that stays still sends no hover** (the text wraps again in a narrower window), so the row
    /// under the pointer is found again when this row comes under the pointer or leaves it.
    func place(_ row: String, at frame: CGRect?) {
        places[row] = frame
        guard let lastPoint else { return }
        if (frame?.contains(lastPoint) ?? false) != (row == placeUnderPointer) { pointer(at: lastPoint) }
    }

    /// The pointer stands at `point` of a long text whose rows have places, or left the text (nil). **One hover for
    /// all the rows of the text**: with the 647 rows of a long file, a hover of each row took about 4.5 ms of each
    /// frame of a scroll under the pointer, and one hover kept the frames under 4 ms.
    func pointer(at point: CGPoint?) {
        lastPoint = point
        let row = point.flatMap { point in places.first { $0.value.contains(point) }?.key }
        guard row != placeUnderPointer else { return }
        let left = placeUnderPointer
        placeUnderPointer = row
        change { rule in
            if let left { rule.hover(left, inside: false) }
            if let row { rule.hover(row, inside: true) }
        }
    }

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

    /// The scroll view is gone, and the fields of its rows with it. **The rule starts again**: it scrolls no more, and
    /// no row of it is under the pointer. A page that keeps its selection while its scroll view goes (the knowledge
    /// reader, back to the list during a scroll's last glide) would else keep a scroll that never ends, and no row of
    /// the next file would get its fields.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        placeUnderPointer = nil
        lastPoint = nil
        change { $0 = ChatWordsSelection() }
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

/// A selection is equal only to itself, so a text that keeps its selection (`MessageText.selection`) stays equal.
extension ChatSelection: Equatable {
    nonisolated static func == (lhs: ChatSelection, rhs: ChatSelection) -> Bool { lhs === rhs }
}

extension View {
    /// **The scroll view of a chat, a thread or a knowledge file**: the rows that take `wordsSelectable(in:row:)`, and
    /// the rows of a `MessageText` with this selection, hear of its scroll and of the presses while it shows
    /// (`ChatSelection`), and a new reading of the fleet waits while it moves (`FleetStore.scroll(_:moving:)`).
    func scrollsAsAChat(_ selection: ChatSelection, store: FleetStore?) -> some View {
        // Fingers that rest on the trackpad (`tracking`) move nothing: only a scroll that moves holds.
        onScrollPhaseChange { _, phase in
            selection.scroll(moving: phase.isScrolling)
            store?.scroll(ObjectIdentifier(selection), moving: phase.isScrolling)
        }
        .onAppear { selection.start() }
        .onDisappear {
            selection.stop()
            store?.scroll(ObjectIdentifier(selection), moving: false)
        }
    }

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
