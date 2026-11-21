import AppKit
import FleetCore
import SwiftUI

/// **Copy prompt, at the right end of a request card's last line** (the owner, 21 November 2026: "Finally, a button to
/// Copy Prompt that copies the instructions in case the local user wants to use an llm to perform the task", and his
/// "Yes, as drawn" to its picture): the copy symbol and its words, small and muted as the line, in the words' colour and
/// with the hand under the pointer. A press copies the request's prompt for his own AI agent (`NeedPrompt.text`), and the
/// button says check and "Copied" for 1.5 seconds; a second press in that time copies again and starts the time again.
/// The button keeps the width of its wider words, so the line does not move. Only a card that `NeedPrompt.offers` has
/// it, while no answer of his is on its way (`NeedRequestCard.parts`).
struct NeedPromptButton: View {
    let need: OwnerNeed
    /// The presses so far: each one starts the 1.5 seconds of "Copied" again.
    @State private var presses = 0
    @State private var copied = false
    @State private var hovered = false

    var body: some View {
        Button {
            copyMessage(NeedPrompt.text(need: need, from: need.by.agentLabel))
            copied = true
            presses += 1
            AccessibilityNotification.Announcement(String(l10n: "Copied")).post()
        } label: {
            // both looks in one place, the one at rest hidden: the button takes the wider of the two
            ZStack(alignment: .trailing) {
                look(symbol: "square.on.square", words: String(l10n: "Copy prompt")).opacity(copied ? 0 : 1)
                look(symbol: "checkmark", words: String(l10n: "Copied")).opacity(copied ? 1 : 0)
            }
            .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovered = $0 }
        .padding(.vertical, -IconMetrics.reach)
        .font(FormMetrics.detail)
        .foregroundStyle(hovered ? FleetStyle.text : FleetStyle.muted)
        // VoiceOver: one button "Copy prompt", which says "Copied" after a press
        .accessibilityLabel(String(l10n: "Copy prompt"))
        .accessibilityIdentifier("need-prompt-\(need.id)")
        .task(id: presses) {
            guard presses > 0 else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copied = false
        }
    }

    private func look(symbol: String, words: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(IconMetrics.symbol(11)).accessibilityHidden(true)
            Text(words).lineLimit(1)
        }
        .fixedSize()
    }
}
