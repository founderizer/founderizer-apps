import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **The hover tag of an answered request's mark only draws** (owner feature `need_marks`; the owner's "Yes, badge as
/// drawn", 21 November 2026): it stands over the app's window beside the mark, and he goes on typing in his chat while
/// it shows, so it takes no key, no click and no focus, and it goes when it is hidden. **A click takes it away until the
/// pointer leaves**: a redraw of the card does not bring it back over what he does (review round 1). **Its words are
/// whole**: two lines of words are two lines high (the first build cut them to one).
@Suite(.serialized, .timeLimit(.minutes(1))) struct AnsweredMarkTagTests {
    struct Seen: Sendable {
        let canBecomeKey: Bool
        let ignoresMouse: Bool
        let childOfWindow: Bool
        let keysStayed: Bool
        let oneLine: CGFloat
        let twoLines: CGFloat
        let widest: CGFloat
        let leftAfterHide: Int
        let goneAfterClick: Bool
        let staysAwayOnRedraw: Bool
        let backAfterLeave: Bool
    }

    @Test func theTagTakesNoKeyAndNoClickAndShowsItsWordsWhole() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let reason = "The hub did not make this change: the fleet changed after your yes. Nothing changed, and "
                + "the Fleet Manager knows."
            let state = try ViewHost.reading(needs: [
                ["id": 3, "title": "Add a designer to the team", "why": "", "todo": "", "by": "manager",
                 "raised": Int(Date().timeIntervalSince1970) - 300, "answered": Int(Date().timeIntervalSince1970) - 200,
                 "answer": "Yes: add designer", "options": ["Yes: add designer", "No"], "chosen": 0, "team": true,
                 "team_state": "not_made", "team_reason": reason]],
                features: [AnsweredMark.feature])
            let store = ViewHost.store(state)
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let keys = window.firstResponder
            let stand = NSView(frame: NSRect(x: 200, y: 200, width: 12, height: 12))
            window.contentView?.addSubview(stand)
            defer { stand.removeFromSuperview() }
            @MainActor func height(_ mark: AnsweredMark) -> CGFloat {
                HoverTag.show(AnyView(AnsweredMarkView(mark: mark, moves: false).tag(mark)), over: stand)
                defer { HoverTag.hide() }
                return window.childWindows?.first?.frame.height ?? 0
            }
            let short = height(.done(words: "Changed"))
            let long = height(.failed(words: reason))
            HoverTag.show(AnyView(AnsweredMarkView(mark: .failed(words: reason), moves: false).tag(.failed(words: reason))),
                          over: stand)
            ViewHost.turn(0.3)
            let tag = window.childWindows?.first
            let canBecomeKey = tag?.canBecomeKey ?? true, ignoresMouse = tag?.ignoresMouseEvents ?? false
            let childOfWindow = tag?.parent === window, keysStayed = window.firstResponder === keys
            let widest = tag?.frame.width ?? 0
            HoverTag.hide()
            let left = window.childWindows?.count ?? -1
            // a click anywhere takes the tag away; the mark's next redraw asks for it again, and gets none
            let words = AnyView(AnsweredMarkView(mark: .done(words: "Changed"), moves: false).tag(.done(words: "Changed")))
            HoverTag.show(words, over: stand)
            if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1) {
                NSApp.sendEvent(click)
            }
            let goneAfterClick = (window.childWindows ?? []).isEmpty
            HoverTag.show(words, over: stand)
            let staysAway = (window.childWindows ?? []).isEmpty
            HoverTag.hide(of: stand)                 // the pointer left the mark
            HoverTag.show(words, over: stand)
            let back = !(window.childWindows ?? []).isEmpty
            HoverTag.hide()
            return Seen(canBecomeKey: canBecomeKey, ignoresMouse: ignoresMouse, childOfWindow: childOfWindow,
                        keysStayed: keysStayed, oneLine: short, twoLines: long, widest: widest, leftAfterHide: left,
                        goneAfterClick: goneAfterClick, staysAwayOnRedraw: staysAway, backAfterLeave: back)
        }
        #expect(!seen.canBecomeKey && seen.ignoresMouse && seen.childOfWindow, "a tag that only draws, over the window")
        #expect(seen.keysStayed, "the keys stay where he types")
        #expect(seen.twoLines > seen.oneLine + 10, "a reason of two lines is two lines high")
        #expect(seen.widest <= HoverTag.widest + 20, "it wraps at its widest")
        #expect(seen.leftAfterHide == 0, "it goes when it is hidden")
        #expect(seen.goneAfterClick && seen.staysAwayOnRedraw && seen.backAfterLeave,
                "a click takes it away until the pointer leaves the mark")
        #expect(screen.stayedHis)
    }
}
