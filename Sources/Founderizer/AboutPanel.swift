import AppKit
import FleetCore

/// **Founderizer › About Founderizer: the system's own About window, with the credit under the version** (the owner's
/// yes of 10 November 2026 to the picture of its two lines: "Yes, add them"). The window is the system's, and so are its
/// icon, its name and its version, which it reads from the bundle. The app gives it only the credits (`Credit`): "Made
/// by Miguel Pieras", and under it "@mpieras", the link to his profile on X, centred, at the window's small size. The
/// link takes the system's link colour, as each link of a system window does.
@MainActor
enum AboutPanel {
    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// The two lines.
    static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let words: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                    .foregroundColor: NSColor.labelColor, .paragraphStyle: centred]
        let text = NSMutableAttributedString(string: Credit.line + "\n", attributes: words)
        text.append(NSAttributedString(string: Credit.handle,
                                       attributes: words.merging([.link: Credit.profile]) { _, link in link }))
        return text
    }
}
