import AppKit
import FleetCore
import SwiftUI

/// The answer of one secret request (owner feature `secret_requests`), where the request is: its secure form, which
/// saves the value in the vault, gives it to the agents that the owner chose, sends a sealed copy to each machine's
/// vault and then answers the request with the secret's name and reference. It takes no answer in words: the hub
/// refuses one, because a key typed into an answer is in the agent's conversation before anything can mask it.
struct SecretRequestForm: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed

    var body: some View {
        if SecretEntryView.isOffered(by: store) {
            SecretEntryView(store: store, preset: SecretPreset(need: need), compact: true) { _ in }
                .id("\(store.hub)/\(store.state?.db ?? "")/secret-\(need.id)")
        } else {
            Text("Update the hub to answer this request here. It takes no answer in words.")
                .font(FormMetrics.detail).foregroundStyle(.orange)
        }
    }
}

/// Add secret over the window: from a chat's key button, or from the guard of a key that the owner pasted. The chat's
/// agent gets the secret's name, its reference and who holds it in a message of the owner's, never its value.
struct SecretFormCard: View {
    @Bindable var store: FleetStore
    let preset: SecretPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save a secret").font(FormMetrics.title).accessibilityAddTraits(.isHeader)
                Text(preset.tell.map { "It goes straight into the vault. \($0.agentLabel) gets its name and who holds it, never its value." }
                     ?? "It goes straight into the vault. No agent sees its value.")
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            if SecretEntryView.isOffered(by: store) {
                SecretEntryView(store: store, preset: preset) { _ in store.secretForm = nil }
            } else {
                Text("Update the hub to save secrets from here.").font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                HStack {
                    Spacer()
                    Button("Close") { store.secretForm = nil }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                }
            }
        }
        // The width of every card over the page that holds an item (a secret's, an MCP server's, a file's): 560 points,
        // and the form fills its inside. At 600 its form stood 556 wide, a third width beside those cards' and the
        // 680 of the same form in Settings.
        .padding(22).frame(width: 560, alignment: .leading)
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .accessibilityIdentifier("secret-form-card")
    }
}

/// What the guard of a chat's text holds back. The hub masks only the values that it already knows, so a key in a
/// message is in the agent's conversation, its runtime's own transcript and the hub's records before anything can
/// mask it (`KeyInText`).
enum KeyHold: Equatable {
    /// Cmd+V with what looks like a key on the clipboard: nothing was pasted.
    case paste
    /// The text holds what looks like a key: typed, pasted from the menu, or about to be sent.
    case text
}

/// One question of the guard, for one composer (`FleetStore.stageKey`). It holds no part of the key: the clipboard
/// and the draft do, and they are read again at the owner's choice.
struct HeldKey: Equatable {
    let composer: String
    let hold: KeyHold
}

/// The question of the guard, over the box that the owner writes in: save it in the vault instead, or go on.
struct KeyHoldBanner: View {
    let hold: KeyHold
    /// The agent whose chat this is, which gets the secret's name after the save.
    let agent: String
    let save: () -> Void
    let goOn: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "key.horizontal").font(IconMetrics.symbol(13)).foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hold == .paste ? "That looks like a key, so it was not pasted." : "This message holds what looks like a key.")
                    .font(FormMetrics.detailTitle).foregroundStyle(FleetStyle.text)
                Text("In a message, \(agent.agentLabel) and its transcripts would have it. Saved as a secret, it goes straight into the vault, and \(agent.agentLabel) gets only its name.")
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(hold == .paste ? "Paste it anyway" : "Keep it", action: goOn).buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("key-hold-go-on")
            Button("Save it as a secret", action: save).buttonStyle(FleetPrimaryButtonStyle())
                .accessibilityIdentifier("key-hold-save")
        }
        .padding(10).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .contain).accessibilityIdentifier("key-hold")
    }
}

/// Cmd+V in a box that the owner writes in, while it has the keyboard: a text on the clipboard that looks like a key
/// is not pasted, and the store's `heldKey` asks him what to do with it. Every other paste goes on as before
/// (`PasteAttachments` takes a picture or a file). The clipboard is read here and nothing of it is kept.
struct KeyPasteGuard: ViewModifier {
    @Bindable var store: FleetStore
    /// The composer that the guard watches, or nil while its box does not have the keyboard.
    let composer: String?
    @State private var watch: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { start() }
            .onDisappear { stop() }
            .onChange(of: composer) { _, _ in stop(); start() }
    }

    private func start() {
        guard watch == nil, let composer else { return }
        let store = store
        watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The monitor runs on the main thread, before the menu and the field see the key.
            let held = MainActor.assumeIsolated { () -> Bool in
                let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
                guard keys == .command, !event.isARepeat, event.charactersIgnoringModifiers?.lowercased() == "v",
                      let text = NSPasteboard.general.string(forType: .string), text.count <= 100_000,
                      KeyInText.contains(text) else { return false }
                store.heldKey = HeldKey(composer: composer, hold: .paste)
                return true
            }
            return held ? nil : event
        }
    }

    private func stop() {
        if let watch { NSEvent.removeMonitor(watch) }
        watch = nil
    }
}

extension View {
    /// The guard of a pasted key (`KeyPasteGuard`) for one composer; nil watches nothing.
    func keyPasteGuard(store: FleetStore, composer: String?) -> some View {
        modifier(KeyPasteGuard(store: store, composer: composer))
    }
}

/// The text with what looks like a key taken out of it, and that key: the two parts of "Save it as a secret".
enum KeyCut {
    static func split(_ text: String) -> (rest: String, key: String)? {
        guard let range = KeyInText.first(in: text) else { return nil }
        var rest = text
        rest.removeSubrange(range)
        return (rest.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces), String(text[range]))
    }

    /// The clipboard's key, read at the moment of the owner's choice: nothing of it was kept before.
    static func onClipboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string), text.count <= 100_000 else { return nil }
        return split(text)?.key
    }
}
