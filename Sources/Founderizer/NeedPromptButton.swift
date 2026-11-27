import FleetCore
import SwiftUI

/// **Copy prompt, at the right end of a request card's last line** (the owner, 21 November 2026: "Finally, a button to
/// Copy Prompt that copies the instructions in case the local user wants to use an llm to perform the task", and his
/// "Yes, as drawn" to its picture): **the copy icon alone** (the owner, 27 November 2026: "Instead of copy prompt, just
/// show a copy icon"), an icon button of the app's one shape (`IconButton`: the symbol muted, the grey circle under the
/// pointer), at the small size of the window's icon that stands beside it on Needs you and on the card's title line.
/// "Copy prompt" is its hover text and its VoiceOver label. A press copies the request's prompt for his own AI agent
/// (`NeedPrompt.text`), the symbol is a check for 1.5 seconds, and VoiceOver says "Copied"; a second press in that time
/// copies again and starts the time again. The circle keeps one width for both symbols, so the line does not move, and
/// it takes no room over or under the line's words. Only a card that `NeedPrompt.offers` has it, while no answer of his
/// is on its way (`NeedRequestCard.parts`).
struct NeedPromptButton: View {
    let need: OwnerNeed
    /// The presses so far: each one starts the 1.5 seconds of the check again.
    @State private var presses = 0
    @State private var copied = false

    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "square.on.square", words: String(l10n: "Copy prompt"), size: 12,
                   side: IconMetrics.small) {
            copyMessage(NeedPrompt.text(need: need, from: need.by.agentLabel))
            copied = true
            presses += 1
            AccessibilityNotification.Announcement(String(l10n: "Copied")).post()
        }
        // as the window's icon on the title's line: its middle on the capitals of the line's words (12 points), and no
        // room of its own over and under the line
        .padding(.vertical, -4)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .accessibilityIdentifier("need-prompt-\(need.id)")
        .task(id: presses) {
            guard presses > 0 else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copied = false
        }
    }
}
