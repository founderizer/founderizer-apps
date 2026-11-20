import Foundation

/// Reporting a problem from inside the app, at the moment something is wrong.
///
/// The owner, 18 October 2026: "we should probably have a way to report issues? and like a feedback section? that
/// talks to our founderizer website?". Until now the only route was an address on a web page, which nobody finds
/// while they are staring at the thing that broke.
///
/// **The shape is one form, not two.** A problem and "this screen is confusing" go the same way, because the
/// heavier of the two is already light: a few words, an address to answer, and a few short facts. A second path
/// would only ask the customer to classify his own trouble before he may tell us about it, and we can read which
/// one it is ourselves.
///
/// **Nothing travels that he has not read.** The product's promise is that we hold nothing of his, so the report
/// carries none of his fleet's **work** — no task, no message, no file, no result: it carries what he typed, the
/// address he wants the answer at, and the facts below, each of them drawn on the screen, in full, before he
/// presses Send. `lines` is exactly what goes, in the order it is shown, so Copy report and the request can never
/// differ.
///
/// What a fact may name is the **health of a machine**, because that is the whole of what support can act on: a
/// check that failed says which machine it failed on. That is a machine of his, not the work it did, and it is on
/// the screen before it goes.
///
/// **The screen is a page name, never the work on it.** "Task" and not "T-112 · GitHub read access check". A task
/// number would tell support nothing anyway: we cannot read his hub, and we never will.
public struct ProblemReport: Equatable, Sendable {
    /// What the customer wrote. The website refuses an empty report and anything over this.
    public static let maxText = 4000
    public static let maxEmail = 254

    public let text: String
    public let email: String
    /// The facts that go with it, in the order the screen shows them.
    public let facts: [Fact]

    public init(text: String, email: String, facts: [Fact]) {
        self.text = text
        self.email = email
        self.facts = facts
    }

    /// One fact, named in the customer's words and carrying exactly the value that is sent.
    public struct Fact: Equatable, Sendable, Identifiable {
        public let name: String
        public let value: String
        public var id: String { name }
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Ready to send: he wrote something, it is not longer than the website takes, it holds nothing that looks like a
    /// key, and the address can be answered.
    public var isReady: Bool {
        !trimmedText.isEmpty && trimmedText.count <= Self.maxText && !holdsKey && Self.isAddress(email)
    }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// **What he typed holds what looks like a key** (E2, the owner's yes of 14 November 2026 to its picture): a key in a
    /// report would sit in our mail, so Send waits until it is out. The guard of the chat's composer finds it
    /// (`KeyInText`). Copy report still works: what he does with a copy is his.
    public var holdsKey: Bool { KeyInText.contains(trimmedText) }

    /// The one thing that is not right yet, or nil. One line at a time, the most important fact now.
    public var refusal: String? {
        if trimmedText.isEmpty { return nil }
        if trimmedText.count > Self.maxText { return String(l10n: "That is longer than we take. Keep it under \(Self.maxText.formatted()) characters.") }
        if holdsKey { return String(l10n: "This text holds what looks like a key. Take it out, then send.") }
        if !Self.isAddress(email) { return String(l10n: "Write the address we should answer at.") }
        return nil
    }

    /// An address we can answer: one `@`, something on each side of it, no space, and short enough to be real. The
    /// website checks it again; this one is only so the button does not send a report nobody can answer.
    public static func isAddress(_ email: String) -> Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3, value.count <= maxEmail, !value.contains(" ") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count >= 3, parts[1].contains(".") else { return false }
        return !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    /// The whole report as plain text, for Copy report. It is the request's own content, so what he copies when the
    /// send fails is what the send would have carried.
    public var lines: String {
        (facts.map { "\($0.name): \($0.value)" } + ["Answer to: \(email.trimmingCharacters(in: .whitespacesAndNewlines))", "", trimmedText])
            .joined(separator: "\n")
    }

    public func body() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "text": trimmedText,
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "facts": facts.map { ["name": $0.name, "value": $0.value] }
        ], options: [.sortedKeys])
    }
}

extension ProblemReport {
    /// **The fact of a report whose text the owner's own agent wrote** (`prepare_problem_report`): on the screen with
    /// the other facts before Send, and in what goes, so that support reads the text as an agent's account.
    public static let writtenByAgent = Fact(name: "Written by", value: "Your AI agent")

    /// **The box of the report form, as far as a text that the form did not get from the owner goes**: an agent's
    /// text, or the app's own words of a problem that a button reports (the manager band's Report a problem, the
    /// owner's choice of 16 November 2026). When such a text may go into the box, and whether the report still is an
    /// agent's. The rule, in one place for the form and for its tests:
    /// - Such a text goes into the box only when the box is empty, when it holds exactly the app's words of before
    ///   or, for an agent's new text, the agent's text of before, or when it holds exactly the text of a report that
    ///   was sent. **Text that the owner wrote or changed is never written over**, and the app's words never go over
    ///   an agent's text, which says more.
    /// - The report is an agent's while the box still holds that agent's text whole. The owner may write before it
    ///   and after it. When the owner changes or removes the agent's text, the report is the owner's own. The app's
    ///   own words never make the report an agent's.
    public struct AgentDraft: Equatable, Sendable {
        /// The text that the agent put into the box, while the box still holds it whole.
        public private(set) var agentText: String?
        /// The app's own words that a button put into the box: the box is still free while it holds them unchanged.
        public private(set) var appText: String?

        public init() {}

        /// The report says that an agent wrote it.
        public var isAgents: Bool { agentText != nil }

        /// Whether an agent's new text (`byAgent`) or the app's words may go into the box now. `sent`: the text of
        /// the report that this form sent last, or nil when it sent none.
        public func isFree(box: String, sent: String?, byAgent: Bool = true) -> Bool {
            box.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (byAgent && box == agentText)
                || box == appText || (sent != nil && box == sent)
        }

        /// A text went into the box: the agent's (`byAgent`), or the app's own words.
        public mutating func took(_ text: String, byAgent: Bool = true) {
            (agentText, appText) = byAgent ? (text, nil) : (nil, text)
        }

        /// The box changed, by the owner's hand or by the form.
        public mutating func changed(to box: String) {
            if let agentText, !box.contains(agentText) { self.agentText = nil }
        }
    }

    /// The facts, built from what this Mac already knows. Each one is a short value or "Not reported" — never a
    /// guess, and never a value the app did not actually read. A hub's bare revision is cut to twelve characters,
    /// because that is what the row can show and what goes must be what he read; a release (`hubRelease`) goes whole.
    public static func facts(app: String, system: String, fleet: String?, hub: String?,
                             screen: String, trouble: String?) -> [Fact] {
        let bare = { (value: String) in value.range(of: "^[0-9a-f]{13,64}$", options: .regularExpression) != nil }
        var facts = [
            Fact(name: "Founderizer", value: app),
            Fact(name: "macOS", value: system),
            Fact(name: "Fleet", value: fleet.flatMap { $0.isEmpty ? nil : $0 } ?? "Not reported"),
            Fact(name: "Hub", value: hub.flatMap { $0.isEmpty ? nil : bare($0) ? String($0.prefix(12)) : $0 }
                ?? "Not reported"),
            Fact(name: "Screen", value: screen)
        ]
        if let trouble, !trouble.isEmpty { facts.append(Fact(name: "Last error", value: trouble)) }
        return facts
    }

    /// **The "Hub" fact: the release that the hub runs**, as support finds it: its version and its commit in the
    /// published repository, "2026.11.362 (1f43dab42994)" (`ReleaseState.current`, from `GET /ui/releases`). The hub's
    /// own revision is the head of its configuration branch, a commit that only that fleet has, so it is the fact only
    /// where the hub names no release that it took (a fleet that has taken none, or a hub that does not answer the
    /// releases read).
    public static func hubRelease(_ releases: ReleaseState?, revision: String?) -> String? {
        if let run = releases?.current { return "\(run.version) (\(run.revision.prefix(12)))" }
        return revision
    }

    /// The app's own version, as the bundle carries it.
    public static func appVersion(_ bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return "build \(build)"
        default: return "Not reported"
        }
    }

    public static func systemVersion(_ info: ProcessInfo = .processInfo) -> String {
        let version = info.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The name of the screen he was on, from `String(describing:)` of the app's own destination. It reads the
    /// leading identifier only — `task(112)` is "Task", `agentDetail("studio", messages)` is "Agent details" — so
    /// a page added, renamed or taken away by another screen never breaks this one, and no part of his work (the
    /// task number, the agent's name) ever reaches the value.
    public static func screenName(_ destination: String) -> String {
        let head = destination.prefix { $0.isLetter || $0.isNumber }
        guard !head.isEmpty else { return "Founderizer" }
        switch String(head) {
        case "agent": return "Agent chat"
        case "agentDetail": return "Agent details"
        case "agentRule": return "Agent behaviour"
        case "addAgent": return "Add agent"
        case "addServer": return "Add server"
        case "needs": return "Needs you"
        // The task board, which the sidebar names Tasks, also as an agent's chat panel opens it (`activityFrom`).
        case "activity", "activityFrom": return "Tasks"
        default: break
        }
        // One word stays as it is; `agentMessages` becomes "Agent messages".
        var words = ""
        for character in head {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(character)
        }
        return words.prefix(1).uppercased() + words.dropFirst().lowercased()
    }
}

// ---------------------------------------------------------------- sending it

/// What our website answers a report with: the reference the customer can quote back at us.
public struct ProblemReceipt: Decodable, Equatable, Sendable {
    public let reference: String
    public var isValid: Bool { !reference.isEmpty && reference.count <= 40 }
}

public enum ProblemReportError: LocalizedError, Sendable {
    case badChannel, refused(Int, String), unreadable

    public var errorDescription: String? {
        switch self {
        case .badChannel: String(l10n: "This fleet names a channel this app cannot reach.")
        case .refused(let status, let message):
            message.isEmpty ? String(l10n: "Our site refused the report (\(status)).") : String(l10n: "Our site refused the report: \(message)")
        case .unreadable: String(l10n: "Our site answered something this app could not read.")
        }
    }
}

/// **Our own website, as this app sends to it on the customer's behalf**: Report a problem (`ProblemReportClient`) and
/// error reports (`ErrorReportClient`). One rule for where a request may go, and one session for both.
enum OurSite {
    /// The address of `path` on our own site, or on the fleet's channel when it is HTTPS on our own domain, so that a
    /// staging fleet reports to staging. The hub names the channel, so a channel on any other host, or one without
    /// HTTPS, gives nil and nothing leaves: no hub can send the customer's words to another site (review of 14 November
    /// 2026).
    static func endpoint(channel: String?, path: String) -> URL? {
        let text = (channel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? AppUpdate.defaultChannel
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, isOurs(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        return url.appendingPathComponent(path)
    }

    /// Our own host or a host below it: `founderizer.com` and `staging.founderizer.com`, never `xfounderizer.com`.
    static func isOurs(_ host: String) -> Bool {
        guard let ours = URLComponents(string: AppUpdate.defaultChannel)?.host?.lowercased(), !ours.isEmpty else {
            return false
        }
        let host = host.lowercased()
        return host == ours || host.hasSuffix("." + ours)
    }

    /// A session that keeps nothing (no cookie, no credential, no cache) and follows no redirect. `protocolClasses` is
    /// for a test only: it answers the request with no network.
    static func session(protocolClasses: [AnyClass]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        // A redirect is an answer, never a second request: the words go to the one address that `endpoint` checked.
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
}

/// The request of Report a problem to our own website, on the customer's behalf (error reports have the other one,
/// `ErrorReportClient`). It sends the report and reads back a reference; it carries no key, no token and no cookie, and
/// it follows no redirect.
public final class ProblemReportClient: Sendable {
    public static let path = "api/report"
    private let session: URLSession

    /// `protocolClasses` is for a test only: it answers the request with no network.
    public init(protocolClasses: [AnyClass]? = nil) {
        session = OurSite.session(protocolClasses: protocolClasses)
    }

    /// Where the report goes: our own site, or the fleet's channel when it is HTTPS on our own domain (`OurSite`).
    public static func endpoint(channel: String?) throws -> URL {
        guard let url = OurSite.endpoint(channel: channel, path: path) else { throw ProblemReportError.badChannel }
        return url
    }

    public func send(_ report: ProblemReport, channel: String?, fleet: String?) async throws -> ProblemReceipt {
        var request = URLRequest(url: try Self.endpoint(channel: channel))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let fleet, !fleet.isEmpty { request.setValue(fleet, forHTTPHeaderField: AppUpdate.fleetHeader) }
        request.httpBody = try report.body()
        let (data, response) = try await session.data(for: request)
        guard let answer = response as? HTTPURLResponse else { throw ProblemReportError.unreadable }
        guard answer.statusCode == 200 else {
            // The site answers a refusal with a code and the words for it; the customer reads the words.
            let said = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["says"] as? String
            throw ProblemReportError.refused(answer.statusCode, said ?? "")
        }
        guard let receipt = try? JSONDecoder().decode(ProblemReceipt.self, from: data), receipt.isValid else {
            throw ProblemReportError.unreadable
        }
        return receipt
    }
}
