import CoreGraphics

/// **Where the app's menu stands** (`FleetMenu` in the Mac app): every right-click menu and every list of a
/// `FleetSelect`. Screen points, with y upward, as AppKit counts them.
public enum MenuPlacement {
    /// The room the menu keeps from the edges of the screen.
    public static let margin: CGFloat = 4

    /// **A right-click opens the menu with its top left corner at the pointer**, as a macOS menu opens. Where it would
    /// pass the screen's right edge it opens to the left of the pointer, and where it would pass the bottom it opens
    /// over the pointer.
    public static func atPointer(_ size: CGSize, pointer: CGPoint, screen: CGRect) -> CGRect {
        var x = pointer.x
        if x + size.width > screen.maxX - margin { x = pointer.x - size.width }
        var y = pointer.y - size.height
        if y < screen.minY + margin { y = pointer.y }
        return fitted(CGRect(x: x, y: y, width: size.width, height: size.height), in: screen)
    }

    /// **A list opens under the control that opens it**, `gap` points under it, with its left edge on the control's;
    /// where that would pass the window's right edge, its right edge is on the control's ("…" at the end of a card
    /// opens to its left). Where the room under the control is too little for it and the room over it larger, it opens
    /// over the control.
    public static func under(_ size: CGSize, control: CGRect, window: CGRect, screen: CGRect, gap: CGFloat) -> CGRect {
        var x = control.minX
        if x + size.width > min(window.maxX, screen.maxX) - margin { x = control.maxX - size.width }
        let below = control.minY - gap - (screen.minY + margin)
        let above = screen.maxY - margin - (control.maxY + gap)
        let y = size.height > below && above > below ? control.maxY + gap : control.minY - gap - size.height
        return fitted(CGRect(x: x, y: y, width: size.width, height: size.height), in: screen)
    }

    /// The most height a list has under the control or over it, whichever is larger: a longer list scrolls in it.
    public static func room(control: CGRect, screen: CGRect, gap: CGFloat) -> CGFloat {
        max(control.minY - gap - (screen.minY + margin), screen.maxY - margin - (control.maxY + gap), 0)
    }

    /// The most height a right-click's menu has, over the pointer or under it.
    public static func room(pointer: CGPoint, screen: CGRect) -> CGFloat {
        max(pointer.y - (screen.minY + margin), screen.maxY - margin - pointer.y, 0)
    }

    /// The frame moved inside the screen, less its margins, where it passes an edge. A frame larger than the screen keeps
    /// its top left corner on it, where its first rows are.
    private static func fitted(_ frame: CGRect, in screen: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = max(screen.minX + margin, min(frame.origin.x, screen.maxX - margin - frame.width))
        frame.origin.y = min(max(frame.origin.y, screen.minY + margin), screen.maxY - margin - frame.height)
        return frame
    }
}
