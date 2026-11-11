import SwiftUI

// The connection line over a page. It reads the store, so it lives apart from `MobileStyle.swift`, which the share
// extension compiles too and which knows no store.

/// The connection, in plain words, at the top of the page, with its one way on (T-35): Try again while the hub does not
/// answer, Settings while this phone's key or its enrollment stands in the way. It shows only after a read failed, so
/// that no value on the page reads as current, and it stays at the top while the page scrolls.
private struct HubBanner: View {
    let words: String
    let action: Action?

    /// The line's one way on.
    struct Action {
        let title: String
        let run: () -> Void
    }

    /// Settings when this phone's key or its enrollment stands in the way (none on Settings itself, which is the way
    /// on there); Try again for every other failure.
    @MainActor static func action(for store: MobileStore, settings: Bool) -> Action? {
        if store.outageNeedsSettings {
            return settings ? Action(title: "Settings", run: { store.openSettings() }) : nil
        }
        return Action(title: "Try again", run: { _ = Task { await store.refresh() } })
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warning)
            Text(words).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                TextAction(title: action.title, font: .footnote, action: action.run)
                    .accessibilityIdentifier("hub-action")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("hub-status")
    }
}

extension View {
    /// Puts the connection line at the top of a page as **an inset that pushes the page down**, so it never covers a
    /// control or the first row: over the page, it hid Chats' Settings button — the one way to Settings, and so to Add
    /// this phone — and the first row's name. **The inset is always applied, and only its content comes and goes**, so
    /// the page keeps its identity: an inset that came and went with an `if` made the page a new view each time, its
    /// own read started again and cancelled the one on its way, which brought the line back (24 times in 3.3 s, 88
    /// reads in 5 s). `settings` is false on Settings itself, which is the way on there.
    func hubBanner(_ store: MobileStore, settings: Bool = true) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if store.sample {
                SampleLine(store: store)
            } else if let words = store.unavailableWords {
                HubBanner(words: words, action: HubBanner.action(for: store, settings: settings))
            }
        }
    }
}

/// **The sample fleet's line** (the owner's yes of 11 November 2026 to its picture): "Sample fleet" and Leave, over
/// every page while the sample is open, in the connection line's place and look. No warning mark: nothing is wrong.
private struct SampleLine: View {
    let store: MobileStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Sample fleet")
            Spacer(minLength: 0)
            TextAction(title: "Leave", font: .footnote) { store.leaveSample() }
                .accessibilityIdentifier("leave-sample")
        }
        .font(.footnote)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("sample-line")
    }
}
