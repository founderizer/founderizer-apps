import Foundation

/// **One AI of a server, as its row on the server's page.** What the server needs comes from its agents, and whether it
/// has it from its own reading, so that a provider nobody chose is no fault, and a real sign-out is one. On a Mac the row of
/// Codex is the ChatGPT app, whose sign-in Computer Use runs on, and the installer at that Mac is what puts it right.
public struct ProviderRow: Equatable, Sendable {
    public enum Answer: Equatable, Sendable {
        /// A mark, with its words and who acts on it.
        case mark(MarkState, words: String, whoActs: String?)
        /// No fault: this server does not use this provider.
        case notSetUp(String)
    }

    public let name: String
    public let title: String
    public let answer: Answer

    public static let atTheMac = "Open the installer on that Mac."

    public init(name: String, runtime: MachineStatus.Runtime?, reading: MachineStatus) {
        let desktop = reading.security.desktop, onMac = desktop != nil, app = onMac && name == "codex"
        let installed = runtime?.version?.isEmpty == false
        let signedIn = app ? desktop?.chatgpt : installed ? runtime?.signed_in : false
        let needed = (name == "claude" ? reading.needs?.browser : reading.needs?.chatgpt) ?? true
        self.name = name
        title = app ? "ChatGPT" : providerName(name)
        let words = [runtime?.version.flatMap { app || $0.isEmpty ? nil : $0 } ?? (app ? nil : "Version not reported"),
                     signedIn.map { $0 ? "Signed in" : "Not signed in" } ?? "Sign-in not reported"]
            .compactMap { $0 }.joined(separator: " · ")
        if signedIn == true {
            answer = .mark(.good, words: words, whoActs: nil)
        } else if !needed, signedIn == false {
            answer = .notSetUp(onMac ? "Not set up. \(Self.atTheMac)" : "Not set up")
        } else if signedIn == nil {
            answer = .mark(.unknown, words: words, whoActs: nil)
        } else {
            answer = .mark(.bad, words: words, whoActs: onMac ? Self.atTheMac : "Signing in is your own step: the Sign in card below takes it.")
        }
    }
}
