import AppKit
import CoreGraphics
import FleetCore

/// The three facts of `OwnerPresence`, read on this Mac at the moment of a state read. None of them asks for a macOS
/// permission:
///
/// - **The app is in front:** `NSApplication.isActive` and the frontmost app is this one (`OwnerPresence.appInFront`,
///   `inFront()`): a card's own window that has the keyboard over another app makes the app active, not in front.
/// - **The screen is locked:** `CGSessionCopyCurrentDictionary`, the login session's own facts, which every process of
///   that session reads (`CGSSessionScreenIsLocked`).
/// - **The last input:** `CGEventSource.secondsSinceLastEventType` for any input event, which gives only the time
///   since the last key, click or move of the session, never an event or what it was. Input Monitoring is the
///   permission that reading or watching events needs (an event tap, `CGEventTap`); this reads none.
@MainActor
enum OwnerPresenceProbe {
    /// kCGAnyInputEventType: the time since the last input event of any type.
    private static let anyInput = CGEventType(rawValue: ~0)

    static func now() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let seconds = anyInput.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        return OwnerPresence.present(appActive: inFront(), screenLocked: locked, secondsSinceInput: seconds)
    }

    /// This app is active and the frontmost app (`OwnerPresence.appInFront`).
    static func inFront() -> Bool {
        OwnerPresence.appInFront(isActive: NSApplication.shared.isActive,
                                 frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                 own: ProcessInfo.processInfo.processIdentifier)
    }
}
