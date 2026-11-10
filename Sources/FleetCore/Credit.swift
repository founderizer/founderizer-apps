import Foundation

/// **Who made Founderizer, the same on the Mac and on the phone** (the owner's yes of 10 November 2026 to the picture of
/// its two places: "Yes, add them"). Only the owner, and no list of contributors (his decision of the same day, when
/// Founderizer became free and open source). The Mac's About window carries it in two lines under the version
/// (`AboutPanel`), and the phone's Settings in one muted line under its last group.
public enum Credit {
    /// The words of the credit.
    public static let line = "Made by Miguel Pieras"
    /// His handle on X: the words of the link.
    public static let handle = "@mpieras"
    /// His profile on X, which the handle opens.
    public static let profile = URL(string: "https://x.com/mpieras")!

    /// The phone's one line: the words, a dot, and the handle, which alone is the link.
    public static var oneLine: AttributedString {
        var link = AttributedString(handle)
        link.link = profile
        return AttributedString(line + " · ") + link
    }
}
