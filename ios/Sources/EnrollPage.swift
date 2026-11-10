import SwiftUI

/// Add this phone: the owner makes a one-time code in the Mac app and types it here, or scans the Mac's picture of it
/// with the phone's camera (`MobileStore.openLink`). The phone sends it from its own tailnet address, and the hub gives
/// this phone its key — once, and never again (UI-API.md, "The key of a device").
///
/// **A typed code sends itself** the moment it is whole, as the Mac's code fields do: a ninth press on a button
/// that says what the eighth character already said was a step for nothing. A code goes once; a refused one waits
/// for the owner to change it.
///
/// The key goes straight into the keychain. It never shows on this screen, in a log or in a message, and this screen
/// never asks for a password: a code is the only thing the owner types.
///
/// **The page is its title, the code field, one line and the button** (the owner's yes of 28 October 2026 to D-2):
/// three rows under it explained the two locks, the hub's fingerprint and the keychain, and he does nothing with them.
struct EnrollPage: View {
    let store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var problem: String?
    @State private var working = false
    /// The code that went last, so that the field sends each code once and never sends a refused one again.
    @State private var sent: String?
    /// A code that a link brought for another hub: this phone's own hub refuses it, so nothing here sends it (fix round
    /// 2, item 47). Its line's way on is Settings, Forget the key.
    @State private var otherHub: String?

    private var canSend: Bool {
        guard !working, let whole = MobileClient.normalizedCode(code) else { return false }
        return whole != otherHub
    }

    var body: some View {
        Form {
            Section {
                TextField(text: $code, prompt: Text(verbatim: "XXXX-XXXX").foregroundStyle(Brand.placeholder)) {
                    Text(verbatim: "XXXX-XXXX")
                }
                .font(.system(.title2, design: .monospaced).weight(.medium))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.vertical, 6)
                .accessibilityIdentifier("enroll-code")
                .onChange(of: code) { _, typed in
                    guard let whole = MobileClient.normalizedCode(typed), whole != sent, !working else { return }
                    // At once, so the code that is about to go never shows a button for a frame.
                    working = true
                    Task { await add() }
                }
            } header: {
                GroupHeading("The code")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    // Where the Mac keeps its devices since D-4: a group of Settings' Servers.
                    Text("In the Mac app: Settings, Servers, Add device, New code. The code works for ten minutes and once.")
                        .foregroundStyle(Brand.muted)
                    // **A refusal comes under the line, with its way on, and moves nothing** (fix round 2, item 85):
                    // a "Try again" row in the card and the refusal came in one frame and pushed the line 52 points.
                    if let problem {
                        Text(problem).foregroundStyle(Brand.warning)
                            .accessibilityValue(store.enrollDetail ?? "")
                            .accessibilityIdentifier("enroll-problem")
                    }
                    // **Only while it can act** (T-05): a whole code goes by itself, so this shows for a code the hub
                    // refused, to send it again. For a code that went, it says what it does (T-35).
                    // **Its slot has a fixed place** (fix round 3, item 42): a whole code goes by itself, and the way on
                    // came for the one frame before it went, which moved the footer. It shows only for a code that went
                    // and may go again: never for a refused one (COPY).
                    ZStack(alignment: .leading) {
                        TextAction(title: "Try again", font: .footnote) {}.hidden().accessibilityHidden(true)
                        if canSend, sent == MobileClient.normalizedCode(code), !MobileError.refusedCode(problem) {
                            TextAction(title: "Try again", font: .footnote) { Task { await add() } }
                                .accessibilityIdentifier("enroll-send")
                        }
                    }
                }
            }
            .brandRows()
        }
        .brandPage()
        // A code that the Mac's picture brought and the hub refused: it stands in the field with the hub's words.
        .task {
            guard let linked = store.takeLinkedCode() else { return }
            sent = MobileClient.normalizedCode(linked.code)
            if linked.otherHub { otherHub = sent }
            code = linked.code
            problem = linked.problem
        }
        .navigationTitle("Add this phone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() async {
        sent = MobileClient.normalizedCode(code)
        working = true
        problem = nil
        defer { working = false }
        if let words = await store.enroll(code: code) {
            problem = words
        } else {
            code = ""
            await store.readDevice()
            dismiss()
        }
    }
}
