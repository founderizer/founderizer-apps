import AppKit
import Testing
@testable import Founderizer

/// **A badge's press ends its hover when its window loses the keyboard, and a window that stands over other apps
/// tracks the pointer in any state** (`BadgePress.PressView`; a check in a guest Mac of 21 November 2026). The bugs that
/// these catch: the key window's tracking sends no `mouseExited` when the window loses the keyboard, so the lighter look
/// of a badge, a link or a value chip stayed until the pointer came in and went out again; and in a request card's own
/// window, a panel that does not take the app to the front, that tracking gave no hand and no lighter look until the
/// press. The views are AppKit's own, so the tests need no SwiftUI window.
@MainActor @Suite(.serialized) struct BadgePressHoverTests {
    private static func entered(_ press: BadgePress.PressView, in window: NSWindow) {
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil)
        if let event { press.mouseEntered(with: event) }
    }

    @Test func aWindowThatLosesTheKeyboardEndsTheHoverOfItsPressOnce() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let press = BadgePress.PressView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        var seen: [Bool] = []
        press.hover = { seen.append($0) }
        try #require(window.contentView).addSubview(press)
        Self.entered(press, in: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(seen == [true, false], "the hover ends once")
        press.removeFromSuperview()
        #expect(seen == [true, false], "a view that leaves its window with no hover ends nothing more")
    }

    @Test func aPanelThatStandsOverOtherAppsTracksThePointerInAnyState() throws {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.nonactivatingPanel],
                            backing: .buffered, defer: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let inPanel = BadgePress.PressView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        let inWindow = BadgePress.PressView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        try #require(panel.contentView).addSubview(inPanel)
        try #require(window.contentView).addSubview(inWindow)
        #expect(!inPanel.trackingAreas.isEmpty && inPanel.trackingAreas.allSatisfy { $0.options.contains(.activeAlways) })
        #expect(!inWindow.trackingAreas.isEmpty
                && inWindow.trackingAreas.allSatisfy { $0.options.contains(.activeInKeyWindow) })
    }
}
